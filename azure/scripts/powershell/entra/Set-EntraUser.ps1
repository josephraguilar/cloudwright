<#
.SYNOPSIS
    One helpdesk action on one or more Entra users: block or allow sign-in,
    revoke sessions, reset the password, or assign a licence.
.DESCRIPTION
    Every action here can be undone: allow undoes block, a new reset replaces a
    password, a licence is removed in the admin center. Users synced from Active
    Directory are refused for sign-in and password changes (AD owns those).
    ResetPassword returns each new password as a SecureString in
    TemporaryPassword and never writes it to a stream.
.PARAMETER User
    User principal names or object IDs.
.PARAMETER Action
    BlockSignIn, AllowSignIn, RevokeSessions, ResetPassword or AssignLicense.
.PARAMETER NoPasswordChange
    With ResetPassword: do not force a change at next sign-in.
.PARAMETER SkuId
    With AssignLicense: the licence SKU ID.
.PARAMETER UsageLocation
    With AssignLicense: set this usage location first if the user has none.
.EXAMPLE
    ./Set-EntraUser.ps1 -User pat.doe@contoso.com -Action BlockSignIn
.EXAMPLE
    ./Set-EntraUser.ps1 -User pat.doe@contoso.com -Action AssignLicense -SkuId <sku-id> -UsageLocation US
.NOTES
    Requires: Az.Accounts
    Status:   Untested
    Roles:    User Administrator; License Administrator for AssignLicense;
              Privileged Authentication Administrator to reset an admin's password.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string[]]$User,
    [Parameter(Mandatory)] [ValidateSet('BlockSignIn', 'AllowSignIn', 'RevokeSessions', 'ResetPassword', 'AssignLicense')] [string]$Action,
    [Parameter()] [switch]$NoPasswordChange,
    [Parameter()] [string]$SkuId,
    [Parameter()] [string]$UsageLocation
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'EntraAdmin' 'EntraAdmin.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext
if ($Action -eq 'AssignLicense' -and -not $SkuId) { throw 'AssignLicense needs -SkuId.' }

#   WHAT   One call per user; a failure on one is reported and the loop continues.
foreach ($u in $User) {
    try {
        switch ($Action) {
            'BlockSignIn'    { Set-EntraUserSignIn -User $u -Enabled $false }
            'AllowSignIn'    { Set-EntraUserSignIn -User $u -Enabled $true }
            'RevokeSessions' { Revoke-EntraUserSession -User $u }
            'ResetPassword'  { Reset-EntraUserPassword -User $u -ForceChangePassword (-not $NoPasswordChange) }
            'AssignLicense'  { Add-EntraUserLicense -User $u -SkuId $SkuId -UsageLocation $UsageLocation }
        }
    } catch {
        Write-Warning "$u`: $($_.Exception.Message)"
        [pscustomobject]@{ User = $u; Result = "Failed: $($_.Exception.Message)" }
    }
}
