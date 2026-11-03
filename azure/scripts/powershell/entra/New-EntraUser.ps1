<#
.SYNOPSIS
    Create a cloud user in Entra ID, optionally add it to groups and give it a licence.
.DESCRIPTION
    Without -Password a random 16-character password is generated. The output
    object carries it as a SecureString in TemporaryPassword; it is never written
    to the verbose stream or the log. Read it with:
        [System.Net.NetworkCredential]::new('', $result.TemporaryPassword).Password
    The user must change it at first sign-in unless -NoPasswordChange is given.
.PARAMETER DisplayName
    Full name as people see it.
.PARAMETER UserPrincipalName
    Sign-in name, user@verified-domain.
.PARAMETER Password
    Initial password. Leave out for a random one.
.PARAMETER NoPasswordChange
    Do not force a password change at first sign-in.
.PARAMETER GivenName
    First name.
.PARAMETER Surname
    Last name.
.PARAMETER JobTitle
    Job title.
.PARAMETER Department
    Department.
.PARAMETER UsageLocation
    Two-letter country code. Required before a licence can be assigned.
.PARAMETER GroupId
    Groups to add the new user to.
.PARAMETER LicenseSkuId
    Licence SKU to assign (see Get-EntraLicenseInfo).
.EXAMPLE
    ./New-EntraUser.ps1 -DisplayName 'Pat Doe' -UserPrincipalName pat.doe@contoso.com -UsageLocation US -GroupId <group-id>
.NOTES
    Requires: Az.Accounts
    Status:   Untested
    Roles:    User Administrator (and License Administrator for -LicenseSkuId) in Entra ID.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$DisplayName,
    [Parameter(Mandatory)] [string]$UserPrincipalName,
    [Parameter()] [securestring]$Password,
    [Parameter()] [switch]$NoPasswordChange,
    [Parameter()] [string]$GivenName,
    [Parameter()] [string]$Surname,
    [Parameter()] [string]$JobTitle,
    [Parameter()] [string]$Department,
    [Parameter()] [string]$UsageLocation,
    [Parameter()] [string[]]$GroupId = @(),
    [Parameter()] [string]$LicenseSkuId
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'EntraAdmin' 'EntraAdmin.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext

#region Create, then group and licence ----------------------------------------
#   WHY    Group and licence steps report failures as warnings: the user exists
#          by then, and a half-done user is fixed by running the step again.
$p = @{ DisplayName = $DisplayName; UserPrincipalName = $UserPrincipalName; ForceChangePassword = (-not $NoPasswordChange) }
foreach ($k in 'Password', 'GivenName', 'Surname', 'JobTitle', 'Department', 'UsageLocation') {
    if ($PSBoundParameters.ContainsKey($k) -and $PSBoundParameters[$k]) { $p[$k] = $PSBoundParameters[$k] }
}
$user = New-EntraUser @p
if (-not $user) { return }   # -WhatIf
$notes = [System.Collections.Generic.List[string]]::new()
foreach ($g in $GroupId) {
    try { $r = Add-EntraGroupMember -GroupId $g -User $user.Id; $notes.Add("$($r.Group): $($r.Result)") }
    catch { Write-Warning "Group $g`: $($_.Exception.Message)"; $notes.Add("$g`: failed") }
}
if ($LicenseSkuId) {
    try { $r = Add-EntraUserLicense -User $user.Id -SkuId $LicenseSkuId -UsageLocation $UsageLocation; $notes.Add($r.Result) }
    catch { Write-Warning "Licence: $($_.Exception.Message)"; $notes.Add('Licence failed') }
}
$user | Add-Member -NotePropertyName Notes -NotePropertyValue ($notes -join '; ') -PassThru
#endregion
