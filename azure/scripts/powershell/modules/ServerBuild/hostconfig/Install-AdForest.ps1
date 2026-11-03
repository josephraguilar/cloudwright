<#
.SYNOPSIS
    Runs INSIDE a VM: installs AD DS and promotes the server to the first domain
    controller of a new forest. Does NOT reboot; the caller restarts the VM.
.NOTES
    SafeModePassword arrives as a protected run command parameter (not logged).
    Database, logs and SYSVOL go on the data drive when one is given; Microsoft's
    guidance for Azure DCs is a separate disk with caching set to None.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'SafeModePassword', Justification = 'Arrives as a managed Run Command protected parameter, which the platform delivers as a string and never logs.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Install-ADDSForest needs a SecureString; the value never leaves this guest process.')]
param(
    [Parameter(Mandatory)] [string]$DomainName,
    [string]$NetbiosName,
    [Parameter(Mandatory)] [string]$SafeModePassword,
    [string]$DataDrive = ''
)
$ErrorActionPreference = 'Stop'
if (Get-Service NTDS -ErrorAction SilentlyContinue) {
    "NTDS service already present: this server is already a domain controller. Nothing to do."
    return
}
$null = Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools
"AD DS and DNS features installed."
if (-not $NetbiosName) { $NetbiosName = ($DomainName -split '\.')[0].ToUpperInvariant() }
$p = @{
    DomainName                    = $DomainName
    DomainNetbiosName             = $NetbiosName
    SafeModeAdministratorPassword = (ConvertTo-SecureString -String $SafeModePassword -AsPlainText -Force)
    InstallDns                    = $true
    CreateDnsDelegation           = $false
    NoRebootOnCompletion          = $true
    Force                         = $true
}
if ($DataDrive -and (Test-Path "${DataDrive}:\")) {
    $p.DatabasePath = "${DataDrive}:\NTDS"
    $p.LogPath      = "${DataDrive}:\NTDS"
    $p.SysvolPath   = "${DataDrive}:\SYSVOL"
    "Database, logs and SYSVOL on ${DataDrive}:."
}
Import-Module ADDSDeployment
$null = Install-ADDSForest @p
"Forest $DomainName ($NetbiosName) installed. Reboot pending."
