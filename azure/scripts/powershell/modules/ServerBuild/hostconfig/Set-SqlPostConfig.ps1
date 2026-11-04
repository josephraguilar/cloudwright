<#
.SYNOPSIS
    Runs INSIDE a SQL Server marketplace VM: default data, log and backup folders
    on the data drive, optional mixed-mode authentication with the sa password,
    and a Windows Firewall rule for 1433.
.NOTES
    The marketplace image has SQL installed, TCP enabled and the SQL IaaS Agent
    extension registered. This only sets the things every new box needs.
    SaPassword arrives as a protected run command parameter (not logged).
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'SaPassword', Justification = 'Arrives as a managed Run Command protected parameter, which the platform delivers as a string and never logs.')]
param(
    [string]$DataDrive = 'F',
    [int]$EnableSqlAuth = 0,
    [string]$SaPassword = ''
)
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

$ErrorActionPreference = 'Stop'
$instance = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop).MSSQLSERVER
if (-not $instance) { throw 'No default SQL Server instance found on this VM.' }
$reg = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instance\MSSQLServer"

if ($DataDrive -and (Test-Path "${DataDrive}:\")) {
    foreach ($d in 'Data', 'Log', 'Backup') { $null = New-Item -ItemType Directory -Path "${DataDrive}:\$d" -Force }
    $svcAccount = (Get-CimInstance Win32_Service -Filter "Name='MSSQLSERVER'").StartName
    foreach ($d in 'Data', 'Log', 'Backup') { & icacls "${DataDrive}:\$d" /grant "${svcAccount}:(OI)(CI)F" | Out-Null }
    Set-ItemProperty -Path $reg -Name DefaultData -Value "${DataDrive}:\Data"
    Set-ItemProperty -Path $reg -Name DefaultLog -Value "${DataDrive}:\Log"
    Set-ItemProperty -Path $reg -Name BackupDirectory -Value "${DataDrive}:\Backup"
    "Default folders: ${DataDrive}:\Data, ${DataDrive}:\Log, ${DataDrive}:\Backup."
}
if ($EnableSqlAuth -eq 1) {
    Set-ItemProperty -Path $reg -Name LoginMode -Value 2
    'Mixed-mode authentication enabled.'
}
Restart-Service MSSQLSERVER -Force
Start-Sleep -Seconds 10
if ($EnableSqlAuth -eq 1 -and $SaPassword) {
    $escaped = $SaPassword -replace "'", "''"
    & sqlcmd -S . -E -b -Q "ALTER LOGIN [sa] WITH PASSWORD = N'$escaped'; ALTER LOGIN [sa] ENABLE;"
    if ($LASTEXITCODE -ne 0) { throw 'Setting the sa password failed.' }
    'sa enabled with the supplied password.'
}
if (-not (Get-NetFirewallRule -DisplayName 'SQL Server (TCP 1433)' -ErrorAction SilentlyContinue)) {
    $null = New-NetFirewallRule -DisplayName 'SQL Server (TCP 1433)' -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow -Profile Domain, Private
    'Windows Firewall: TCP 1433 allowed (Domain and Private profiles).'
}
"MSSQLSERVER: $((Get-Service MSSQLSERVER).Status)."
