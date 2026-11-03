<#
.SYNOPSIS
    Creates a new user (person) with usage location, names, title, department and manager.
.DESCRIPTION
    Never takes over an existing account: if the UPN already exists nothing is created or changed and the result says AlreadyExisted (pick another UPN). The manager must exist before anything is created; if setting it fails afterwards the user and the password are still returned and ManagerError says why. Password must change at first sign-in; prefer issuing a Temporary Access Pass (New-M365TemporaryAccessPass.ps1) over sharing the password. A generated password is printed once and returned once in InitialPassword.
.PARAMETER TenantId
    Client tenant (GUID or any verified domain).
.PARAMETER UserPrincipalName
    Full UPN on a verified domain.
.PARAMETER DisplayName
    Display name.
.PARAMETER GivenName
    First name.
.PARAMETER Surname
    Last name.
.PARAMETER UsageLocation
    Two-letter country code. Default US.
.PARAMETER JobTitle
    Optional.
.PARAMETER Department
    Optional.
.PARAMETER ManagerUpn
    Optional manager UPN (must exist).
.PARAMETER GeneratePassword
    Generate the initial password and show it once instead of asking you to type one.
.EXAMPLE
    ./New-M365User.ps1 -TenantId contoso.onmicrosoft.com -UserPrincipalName jane@contoso.com -DisplayName 'Jane Doe' -GivenName Jane -Surname Doe -WhatIf
.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Identity.DirectoryManagement
    Graph scopes: User.ReadWrite.All
    Interactive: yes (prompts for the initial password unless -GeneratePassword)
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$UserPrincipalName,

    [Parameter(Mandatory)]
    [string]$DisplayName,

    [Parameter()]
    [string]$GivenName,

    [Parameter()]
    [string]$Surname,

    [Parameter()]
    [string]$UsageLocation = 'US',

    [Parameter()]
    [string]$JobTitle,

    [Parameter()]
    [string]$Department,

    [Parameter()]
    [string]$ManagerUpn,

    [Parameter()]
    [switch]$GeneratePassword
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
foreach ($m in 'M365Helpers', 'EntraHelpers') { Import-Module (Join-Path $modules $m "$m.psd1") -Force }
Assert-M365WriteAllowed   # Refuse legacy write tasks before sign-in, lookups, or prompts.
$null = Assert-M365Graph -TenantId $TenantId -Scopes 'User.ReadWrite.All'
#endregion

#region 3. Apply -------------------------------------------------------------------
#   WHAT   Look the UPN up before asking for a password: an existing account is never changed,
#          so a typed password would only be one nobody applied.
$params = @{ UserPrincipalName = $UserPrincipalName; DisplayName = $DisplayName; UsageLocation = $UsageLocation }
if ($GivenName) { $params.GivenName = $GivenName }
if ($Surname) { $params.Surname = $Surname }
if ($JobTitle) { $params.JobTitle = $JobTitle }
if ($Department) { $params.Department = $Department }
if ($ManagerUpn) { $params.ManagerUpn = $ManagerUpn }
$exists = @(Get-MgUser -Filter "userPrincipalName eq '$($UserPrincipalName.Replace("'", "''"))'" -Property id -ErrorAction Stop).Count -gt 0
$typed = $false
if (-not $exists -and -not $GeneratePassword -and -not $WhatIfPreference) { $params.Password = Read-M365Password -Prompt "Initial password for $UserPrincipalName" -MinimumLength 12; $typed = $true }
$result = New-M365User @params -WhatIf:$WhatIfPreference
$shown = $null
if ($result.Password -and -not $typed) {
    $shown = $result.Password
    Write-Warning "Initial password for $($result.UserPrincipalName) (shown once; the user must change it at first sign-in): $($result.Password)"
}
if ($result.AlreadyExisted) { Write-Warning "$UserPrincipalName already exists ('$($result.DisplayName)'). Nothing was created or changed." }
$result | Select-Object UserPrincipalName, Id, DisplayName, Created, AlreadyExisted, ManagerSet, ManagerError, WhatIf, @{ n = 'InitialPassword'; e = { $shown } }
#endregion
