$templateFile = ".\azuredeploy.json"
$parameterFile = ".\azuredeploy.parameters.json"
$apppropertiesfile = ".\application.properties"
$resourceGroupName = "nvclrg"
$database = "NVCL"
$NVCLDSInstallerLocation = "https://nvclwebservices.csiro.au/Downloads/NVCLDataServicesInstaller.exe"


Write-Host "Checking dependencies..."

# Check Azure CLI
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI is not installed. Install from https://aka.ms/installazurecliwindows"
    exit 1
}

# Check sqlcmd
if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    Write-Error "sqlcmd is not installed. Install from https://learn.microsoft.com/sql/tools/sqlcmd-utility"
    exit 1
}

# Check Azure login
$azAccount = az account show --query "user.name" -o tsv 2>$null
if (-not $azAccount) {
    Write-Error "You are not logged in to Azure CLI. Run 'az login' first."
    exit 1
}


Write-Host "All dependencies verified. Proceeding with deployment..."

# prep empty application.properties file
Copy-Item -Path  ".\application.properties.empty" -Destination $apppropertiesfile -Force

# Read parameters from JSON
$json = Get-Content $parameterFile -Raw | ConvertFrom-Json
$location = $json.parameters.location.value
$publichostname = $json.parameters.publichostname.value
$stateShortName = $json.parameters.stateShortName.value
$systemSupportEmail = $json.parameters.systemSupportEmail.value

# Create resource group
az group create --name $resourceGroupName --location $location

# Deploy ARM template

$outputsJson = az deployment group create `
    --name NVCLNode `
    --resource-group $resourceGroupName `
    --template-file $templateFile `
    --parameters $parameterFile `
    --query properties.outputs `
    --output json


if ($LASTEXITCODE -ne 0) {
    Write-Error "Deployment failed. Azure CLI exit code: $LASTEXITCODE"
    exit $LASTEXITCODE
}


$outputs = $outputsJson | ConvertFrom-Json
$storageAccountName = $outputs.storageAccountName.value
$DBserver = $outputs.SQLServerName.value
$nvcldbreadonlyUser = $outputs.nvcldbreadonlyUser.value
$nvcldbreadonlyPassword = $outputs.nvcldbreadonlyPassword.value
$vmname =  $outputs.VMName.value
$databaseAdministratorUsername = $outputs.databaseAdministratorUsername.value
$databaseAdministratorPassword = $outputs.databaseAdministratorPassword.value
$frontDoorName = $outputs.frontDoorName.value

$fqdnserver = "$DBserver.database.windows.net"

# Update application.properties
function Update-PropertyInFile {
    param(
        [string]$FilePath,
        [string]$Key,
        [string]$NewValue
    )
    if (-Not (Test-Path $FilePath)) {
        Write-Error "File not found: $FilePath"
        return
    }
    $lines = Get-Content $FilePath
    $keyFound = $false
    $updatedLines = $lines | ForEach-Object {
        if ($_ -match "^#?\s*$Key\s*=") {
            $keyFound = $true
            "$Key=$NewValue"
        } else {
            $_
        }
    }
    if (-Not $keyFound) {
        $updatedLines += "$Key=$NewValue"
    }
    $updatedLines | Set-Content $FilePath
    Write-Host "Property '$Key' updated to '$NewValue' in '$FilePath'"
}

Write-Host "Updating properties file"

Update-PropertyInFile -FilePath $apppropertiesfile -Key "webapp.url" -NewValue "https://$publichostname/NVCLDataServices/"
Update-PropertyInFile -FilePath $apppropertiesfile -Key "download.url" -NewValue "https://$publichostname/NVCLPreparedDownloads/"
Update-PropertyInFile -FilePath $apppropertiesfile -Key "downloadFileMirror" -NewValue "https://nvclstore.data.auscope.org.au/$stateShortName/"
Update-PropertyInFile -FilePath $apppropertiesfile -Key "tsg.connectionString" -NewValue "$fqdnserver@$database"
Update-PropertyInFile -FilePath $apppropertiesfile -Key "tsg.username" -NewValue $nvcldbreadonlyUser
Update-PropertyInFile -FilePath $apppropertiesfile -Key "tsg.password" -NewValue $nvcldbreadonlyPassword
Update-PropertyInFile -FilePath $apppropertiesfile -Key "jdbc.url" -NewValue "jdbc:sqlserver://$fqdnserver;database=$database"
Update-PropertyInFile -FilePath $apppropertiesfile -Key "jdbc.username" -NewValue $nvcldbreadonlyUser
Update-PropertyInFile -FilePath $apppropertiesfile -Key "jdbc.password" -NewValue $nvcldbreadonlyPassword
Update-PropertyInFile -FilePath $apppropertiesfile -Key "azureStorageEndPoint" -NewValue "https://$storageAccountName.blob.core.windows.net/"
Update-PropertyInFile -FilePath $apppropertiesfile -Key "sysadmin.email" -NewValue $systemSupportEmail

Write-Host "Completed: Updating properties file"

Write-Host "Setting current user as database administrator"

# Get signed-in user info
$currentuser = az ad signed-in-user show --query userPrincipalName -o tsv
$currentuserObjectID = az ad signed-in-user show --query id -o tsv

# Set Azure AD admin for SQL Server
az sql server ad-admin create `
    --display-name "$currentuser" `
    --resource-group $resourceGroupName `
    --server "$DBserver" `
    --object-id "$currentuserObjectID"

Write-Host "Completed: Setting current user as database administrator"

Write-Host "adding database firewall rule to allow current IP address to access database"

$myIp = (Invoke-RestMethod -Uri "https://api.ipify.org").Trim()

az sql server firewall-rule create --resource-group $resourceGroupName --server $DBserver --name AllowMyIP --start-ip-address $myIp --end-ip-address $myIp

Write-Host "Completed: adding database firewall rule to allow current IP address to access database"

Write-Host "Getting database access token"

$token = az account get-access-token --resource https://database.windows.net --query accessToken -o tsv


if ($null -ne $token -and $token -ne '') {
    Write-Host "Completed: Getting database access token"
} else {
    Write-Host "failed to get token"
    exit 1
}


$result = Invoke-Sqlcmd -ServerInstance $fqdnserver -Database $database -AccessToken $token -Query "SELECT CASE WHEN OBJECT_ID(N'dbo.DATASETS', N'U') IS NOT NULL THEN 1 ELSE 0 END AS TableExists;"

$exists = ($result.TableExists -eq 1)

if ($exists) {
    Write-Host "Table exists, assuming database has already be initialised."

} else {
    Write-Host "Table does not exist, assuming database hasnt been imported. attempting import now"
    az sql db import --name "NVCL" --server $DBserver --resource-group $resourceGroupName --storage-uri "https://nvcldb.blob.core.windows.net/nvcldb/NVCL-2025-12-23.bacpac" --storage-key-type "SharedAccessKey" --storage-key "nokey" -p $databaseAdministratorPassword -u $databaseAdministratorUsername 
    Write-Host "Completed: Importing database"
}


Write-Host "Creating database logins, users and assigning roles"

Invoke-Sqlcmd -ServerInstance $fqdnserver -Database $database -AccessToken $token -Query "
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = '$vmname')
    CREATE USER [$vmname] FROM EXTERNAL PROVIDER;
"

# Add roles for external user
Invoke-Sqlcmd -ServerInstance $fqdnserver -Database $database -AccessToken $token -Query "
IF NOT EXISTS (
    SELECT 1 FROM sys.database_role_members drm
    JOIN sys.database_principals dp ON drm.member_principal_id = dp.principal_id
    JOIN sys.database_principals rp ON drm.role_principal_id = rp.principal_id
    WHERE dp.name = '$vmname' AND rp.name = 'WEBSERVICE'
)
EXEC sp_addrolemember N'WEBSERVICE', [$vmname];
"

Invoke-Sqlcmd -ServerInstance $fqdnserver -Database $database -AccessToken $token -Query "
IF NOT EXISTS (
    SELECT 1 FROM sys.database_role_members drm
    JOIN sys.database_principals dp ON drm.member_principal_id = dp.principal_id
    JOIN sys.database_principals rp ON drm.role_principal_id = rp.principal_id
    WHERE dp.name = '$vmname' AND rp.name = 'TSGVIEWER'
)
EXEC sp_addrolemember N'TSGVIEWER', [$vmname];
"

# Create login and user for readonly account
Invoke-Sqlcmd -ServerInstance $fqdnserver -Database "master" -AccessToken $token -Query "
IF NOT EXISTS (SELECT * FROM sys.sql_logins WHERE name = '$nvcldbreadonlyUser')
    CREATE LOGIN [$nvcldbreadonlyUser] WITH PASSWORD = '$nvcldbreadonlyPassword';
"

Invoke-Sqlcmd -ServerInstance $fqdnserver -Database $database -AccessToken $token -Query "
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = '$nvcldbreadonlyUser')
    CREATE USER [$nvcldbreadonlyUser] FROM LOGIN [$nvcldbreadonlyUser];
    GO
    EXEC sp_addrolemember N'WEBSERVICE', N'$nvcldbreadonlyUser'
    GO
    EXEC sp_addrolemember N'TSGVIEWER', N'$nvcldbreadonlyUser'
    GO
"


Write-Host "Completed: Creating database logins, users and assigning roles"

Write-Host "assigning 'Storage Blob Data Owner' to current user"


$identityId = az vm show --resource-group $resourceGroupName --name $vmname --query identity.principalId -o tsv 
$subscriptionid = $(az account show --query id -o tsv)

az role assignment create --assignee-object-id $currentuserObjectID --role "Storage Blob Data Owner" --assignee-principal-type User --scope "/subscriptions/$subscriptionid/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$storageAccountName"

Write-Host "Completed: assigning 'Storage Blob Data Owner' to current user"



# Assign reader role on the storage account to the VM's managed identity
Write-Host "assigning 'Storage Blob Data Reader' to VM managed identity" 
az role assignment create --assignee-object-id $identityId --role "Storage Blob Data Reader" --assignee-principal-type ServicePrincipal --scope "/subscriptions/$subscriptionid/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$storageAccountName"
Write-Host "Completed: assigning 'Storage Blob Data Reader' to VM managed identity"


az storage blob upload --account-name $storageAccountName --container-name `$web --name index.html --file index.html --auth-mode login
az storage blob upload --account-name $storageAccountName --container-name `$web --name 404.html --file 404.html --auth-mode login

az storage blob service-properties update --account-name $storageAccountName --static-website --index-document index.html --404-document 404.html --auth-mode login


az role assignment create --assignee-object-id $identityId --role "Storage Blob Data Contributor" --assignee-principal-type ServicePrincipal --scope "/subscriptions/$subscriptionid/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$storageAccountName/blobServices/default/containers/`$web"


Write-Host "Attempting to install cholatey"
az vm run-command invoke --resource-group $resourceGroupName --name $vmname --command-id RunPowerShellScript --scripts '[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-Expression ((New-Object System.Net.WebClient).DownloadString(\"https://community.chocolatey.org/install.ps1\"))'
Write-Host "Completed: Install cholatey"

Write-Host "Scheduling weekly Amazon Corretto updates"
az vm run-command invoke --resource-group $resourceGroupName --name $vmName --command-id RunPowerShellScript --scripts 'schtasks /Create /TN UpdateCorrettoWeekly /SC WEEKLY /D MON /ST 03:00 /RU SYSTEM /RL HIGHEST /F /TR \"C:\ProgramData\chocolatey\bin\choco.exe upgrade corretto17jdk -y --no-progress\"'
Write-Host "Completed: Scheduling weekly Amazon Corretto updates"

Write-Host "Running scheduled Amazon Corretto update task to ensure Corretto is installed"
az vm run-command invoke --resource-group $resourceGroupName --name $vmName --command-id RunPowerShellScript --scripts 'schtasks /Run /TN UpdateCorrettoWeekly'
Write-Host "Completed: Running scheduled Amazon Corretto update task to ensure Corretto is installed"

Write-Host "Attempting to install NVCLDataServices"
az vm run-command invoke --resource-group $resourceGroupName --name $vmname --command-id RunPowerShellScript --scripts "Invoke-WebRequest -Uri ""$NVCLDSInstallerLocation"" -OutFile nvclds.exe; Start-Process -FilePath .\nvclds.exe -ArgumentList ""/S"" -Wait -NoNewWindow"
Write-Host "Completed: install NVCLDataServices"

Write-Host "Attempting to install VC++ 2015-2019 Redistributables"
az vm run-command invoke --resource-group $resourceGroupName --name $vmname --command-id RunPowerShellScript --scripts "Invoke-WebRequest -Uri ""https://aka.ms/vc14/vc_redist.x86.exe"" -OutFile vc_redist.x86.exe; Start-Process -FilePath .\vc_redist.x86.exe -ArgumentList ""/quiet"" -Wait -NoNewWindow"
Write-Host "Completed: install VC++ 2015-2019 Redistributables"

Write-Host "Attempting to install VC++ 2015-2019 Redistributables (x64)"
az vm run-command invoke --resource-group $resourceGroupName --name $vmname --command-id RunPowerShellScript --scripts "Invoke-WebRequest -Uri ""https://aka.ms/vc14/vc_redist.x64.exe"" -OutFile vc_redist.x64.exe; Start-Process -FilePath .\vc_redist.x64.exe -ArgumentList ""/quiet"" -Wait -NoNewWindow"
Write-Host "Completed: install VC++ 2015-2019 Redistributables (x64)"

Write-Host "Attempting to install MS OLE DB Driver for SQL Server"
az vm run-command invoke --resource-group $resourceGroupName --name $vmname --command-id RunPowerShellScript --scripts "`$ProgressPreference = 'SilentlyContinue';`$msiPath = Join-Path `$env:TEMP ""msoledbsql.msi""; Invoke-WebRequest -Uri ""https://go.microsoft.com/fwlink/?linkid=2318101"" -OutFile `$msiPath ; Start-Process msiexec.exe -ArgumentList @( '/i', `$msiPath, '/quiet', '/norestart' , '/L*v', 'c:\windows\temp\inslog.log' ,'IACCEPTMSOLEDBSQLLICENSETERMS=YES' ) -Wait -NoNewWindow"
Write-Host "Completed: install MS OLE DB Driver for SQL Server"

Write-Host "Updating firewall rule to allow TCP 8080"
az vm run-command invoke --resource-group $resourceGroupName --name $vmname --command-id RunPowerShellScript --scripts 'New-NetFirewallRule -DisplayName ""Allow TCP 8080"" -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow'
Write-Host "Completed: Updating firewall rule to allow TCP 8080"

Write-Host "Installing Azure Monitor Agent on VM"
az vm extension set --name AzureMonitorWindowsAgent --publisher Microsoft.Azure.Monitor --vm-name $vmName --resource-group $resourceGroupName --enable-auto-upgrade true
Write-Host "Completed: Installing Azure Monitor Agent on VM"

function Push-FileToAzureVMUsingRunCommand {
    param (
        [string]$ResourceGroupName,
        [string]$VMName,
        [string]$LocalFilePath,
        [string]$DestinationPath
    )

    # Read and encode the file
    $fileBytes = [System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $LocalFilePath))
    $base64 = [Convert]::ToBase64String($fileBytes)

    # Create the script to decode and write the file on the VM
    $script = "`$base64='$base64'; `$bytes = [Convert]::FromBase64String(`$base64); [System.IO.File]::WriteAllBytes('$DestinationPath', `$bytes)"

    # Run the script on the VM
    az vm run-command invoke --resource-group $ResourceGroupName --name $VMName --command-id 'RunPowerShellScript' --scripts $script 

    Write-Host "File pushed to VM '$VMName' at '$DestinationPath'"
}

Push-FileToAzureVMUsingRunCommand -ResourceGroupName $resourceGroupName -VMName $vmname -LocalFilePath $apppropertiesfile -DestinationPath "C:\Program Files\NVCLDataServices\application.properties"

az vm restart --resource-group $resourceGroupName --name $vmname 

Write-Host "Azure Front Door"

$nicid = $(az vm show --name $vmname --resource-group $resourceGroupName --query "networkProfile.networkInterfaces[0].id" -o tsv)
$ipid = $(az network nic show --ids $nicid --query "ipConfigurations[0].publicIPAddress.id" -o tsv)

$VMIP=$(az network public-ip show --ids $ipid --query "ipAddress" -o tsv)


az afd origin-group create --resource-group $resourceGroupName --profile-name $frontDoorName --name "NVCLDataServices-og" --probe-request-type GET --probe-path "/NVCLDataServices/" --probe-interval-in-seconds 30 --probe-protocol "Http" --sample-size 3 --successful-samples-required 3 


az afd origin-group create --resource-group $resourceGroupName --profile-name $frontDoorName --name "NVCLDownloads-og" --probe-request-type GET --probe-path "/" --probe-interval-in-seconds 100 --probe-protocol "Https" --sample-size 3 --successful-samples-required 3 


az afd origin create --profile-name $frontDoorName --resource-group $resourceGroupName --origin-group-name "NVCLDataServices-og" --name "NVCLVM" --host-name $VMIP --origin-host-header $publichostname --http-port 8080 --enabled Enabled

$staticweburl = $(az storage account show --name $storageAccountName --resource-group $resourceGroupName --query "primaryEndpoints.web" -o tsv)
$statichostname = ([System.Uri]$staticweburl).Host

az afd origin create --profile-name $frontDoorName --resource-group $resourceGroupName --origin-group-name "NVCLDownloads-og" --name "NVCLStorage" --host-name $statichostname --origin-host-header $statichostname --https-port 443 --enabled Enabled


az afd route create --resource-group $resourceGroupName --profile-name $frontDoorName  --endpoint-name "nvclNode" --custom-domains "nvclhostname" --name "NVCLDataServicesRoute" --origin-group "NVCLDataServices-og" --patterns-to-match "/NVCLDataServices/*" --supported-protocols Http Https --forwarding-protocol HttpOnly --https-redirect Enabled --link-to-default-domain Enabled


az afd route create --resource-group $resourceGroupName --profile-name $frontDoorName --endpoint-name "nvclNode" --custom-domains "nvclhostname" --name "NVCLDownloadsRoute" --origin-group "NVCLDownloads-og" --origin-path "/" --patterns-to-match "/*" --supported-protocols Http Https --forwarding-protocol MatchRequest --https-redirect Enabled --link-to-default-domain Enabled 


$blobResourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$storageAccountName/blobServices/default"
$workspaceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.OperationalInsights/workspaces/NVCLNode-LogAnalytics"

az monitor diagnostic-settings create --name "storageAccountLogs" --resource $blobResourceId --workspace $workspaceId --logs '[{"category":"StorageRead","enabled":true},{"category":"StorageWrite","enabled":true},{"category":"StorageDelete","enabled":true}]' --metrics '[{"category":"AllMetrics","enabled":true}]'


$afdProfileId="/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Cdn/profiles/$frontDoorName"


$logsJson = '[{"categoryGroup":"audit","enabled":false,"retentionPolicy":{"days":0,"enabled":false}},{"categoryGroup":"allLogs","enabled":true,"retentionPolicy":{"days":0,"enabled":false}}]'

$metricsJson = '[{"category":"AllMetrics","enabled":true,"retentionPolicy":{"days":0,"enabled":false}}]'

az monitor diagnostic-settings create --name "FrontDoorLogs" --resource $afdProfileId --workspace $workspaceId --logs "$logsJson" --metrics "$metricsJson"




