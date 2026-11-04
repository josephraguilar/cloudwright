<#
.SYNOPSIS
    Create a cloud security group in Entra ID and optionally add members.
.DESCRIPTION
    If a group with the same display name exists it is used instead, with a
    warning, so running this twice never makes a duplicate.
.PARAMETER DisplayName
    Group name.
.PARAMETER Description
    What the group is for.
.PARAMETER Member
    User principal names or object IDs to add.
.EXAMPLE
    ./New-EntraGroup.ps1 -DisplayName 'AVD Users' -Description 'Can sign in to the AVD desktop' -Member pat.doe@contoso.com
.NOTES
    Requires: Az.Accounts
    Status:   Untested
    Roles:    Groups Administrator (or User Administrator) in Entra ID.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$DisplayName,
    [Parameter()] [string]$Description,
    [Parameter()] [string[]]$Member = @()
)
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'EntraAdmin' 'EntraAdmin.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext

$g = New-EntraGroup -DisplayName $DisplayName -Description $Description
if (-not $g) { return }
$g
foreach ($m in $Member) {
    try { Add-EntraGroupMember -GroupId $g.Id -User $m }
    catch { Write-Warning "$m`: $($_.Exception.Message)" }
}
