
<#
.SYNOPSIS
    Ensures a contained user in Azure SQL Database 'NVCL' and adds it to role 'NVCLANALYST'.

.DESCRIPTION
    - Azure SQL Database ONLY (no Managed Instance, no server-level logins).
    - Uses az CLI to obtain an Azure AD token for https://database.windows.net.
    - Creates contained user in NVCL with the provided plain text password (escaped for T‑SQL).
    - Grants membership to NVCLANALYST via ALTER ROLE ... ADD MEMBER.

.PARAMETER ServerFqdn
    The fully qualified Azure SQL server host (e.g., myserver.database.windows.net).

.PARAMETER Username
    The contained database user name to create.

.PARAMETER PlainPassword
    The user's password in plain text.

.EXAMPLE
    .\New-AzureSqlDbContainedUser-NVCL.ps1 `
      -ServerFqdn "myserver.database.windows.net" `
      -Username "readonly_nvcl" `
      -PlainPassword "$env:READONLY_NVCL_PWD"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ServerFqdn,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PlainPassword
)

begin {
    # Hard-coded constants as requested
    $Database = 'NVCL'
    $Role     = 'NVCLANALYST'

    # Acquire Azure AD access token for Azure SQL
    $token = az account get-access-token --resource https://database.windows.net --query accessToken -o tsv
    if (-not $token) {
        throw "Failed to obtain Azure AD access token. Run 'az login' and ensure the correct subscription/tenant is selected."
    }

    # Escape values for safe use inside T‑SQL literals
    $uLit = $Username.Replace("'", "''")
    $pLit = $PlainPassword.Replace("'", "''")
    $rLit = $Role.Replace("'", "''")
}

process {
    try {
        # 1) Ensure contained user exists in NVCL
        $tsqlCreateUser = @"
DECLARE @u sysname         = N'$uLit';
DECLARE @pwd nvarchar(256) = N'$pLit';

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @u)
BEGIN
    DECLARE @sql nvarchar(max) =
        N'CREATE USER ' + QUOTENAME(@u) + N' WITH PASSWORD = ''' + REPLACE(@pwd, '''', '''''') + N''';';
    EXEC (@sql);
END
"@

        Invoke-Sqlcmd -ServerInstance $ServerFqdn -Database $Database -AccessToken $token -Query $tsqlCreateUser -ErrorAction Stop

        # 2) Ensure role membership in NVCL (idempotent)
        $tsqlGrantRole = @"
DECLARE @u    sysname = N'$uLit';
DECLARE @role sysname = N'$rLit';

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members drm
    JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
    JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
    WHERE r.name = @role AND m.name = @u
)
BEGIN
    DECLARE @sql nvarchar(max) =
        N'ALTER ROLE ' + QUOTENAME(@role) + N' ADD MEMBER ' + QUOTENAME(@u) + N';';
    EXEC (@sql);
END
"@

        Invoke-Sqlcmd -ServerInstance $ServerFqdn -Database $Database -AccessToken $token -Query $tsqlGrantRole -ErrorAction Stop

        Write-Host "Ensured contained user '$Username' in database 'NVCL' and added to role 'NVCLANALYST'." -ForegroundColor Green
    }
    finally {
        # Best-effort scrub of plaintext password variable reference
        Remove-Variable -Name PlainPassword -Scope 0 -ErrorAction SilentlyContinue
    }
}
