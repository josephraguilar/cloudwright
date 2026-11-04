<#
.SYNOPSIS
    Add users to an Entra group.
.DESCRIPTION
    A user who is already a member is reported, not an error. Dynamic groups and
    groups synced from Active Directory are refused with the reason.
.PARAMETER GroupId
    Object ID of the group.
.PARAMETER User
    User principal names or object IDs.
.EXAMPLE
    ./Add-EntraGroupMember.ps1 -GroupId <group-id> -User pat.doe@contoso.com, sam.roe@contoso.com
.NOTES
    Requires: Az.Accounts
    Status:   Untested
    Roles:    Groups Administrator, or owner of the group.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$GroupId,
    [Parameter(Mandatory)] [string[]]$User
)
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'EntraAdmin' 'EntraAdmin.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext

foreach ($u in $User) {
    try { Add-EntraGroupMember -GroupId $GroupId -User $u }
    catch {
        Write-Warning "$u`: $($_.Exception.Message)"
        [pscustomobject]@{ User = $u; Group = $GroupId; Result = "Failed: $($_.Exception.Message)" }
    }
}
