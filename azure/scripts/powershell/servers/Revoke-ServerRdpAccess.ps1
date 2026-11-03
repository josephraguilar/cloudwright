<#
.SYNOPSIS
    Close just-in-time RDP on a VM, or on every VM in a resource group whose
    access has expired. Sets the jit-rdp rule to Deny; deletes nothing.
.PARAMETER SubscriptionId
    Subscription containing the VMs.
.PARAMETER ResourceGroupName
    Resource group of the VMs.
.PARAMETER Name
    One VM. Omit to sweep the whole group for expired access.
.PARAMETER OnlyIfExpired
    Close only rules whose time has passed (always on for a sweep).
.EXAMPLE
    ./Revoke-ServerRdpAccess.ps1 -SubscriptionId <sub> -ResourceGroupName rg-servers -Name web01
.EXAMPLE
    ./Revoke-ServerRdpAccess.ps1 -SubscriptionId <sub> -ResourceGroupName rg-servers      # sweep expired
.NOTES
    Requires: Az.Accounts, Az.Compute, Az.Network
    Status:   Untested
    Roles:    Network Contributor on the resource group.
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter()] [string]$Name,
    [Parameter()] [switch]$OnlyIfExpired
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'ServerBuild' 'ServerBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
#endregion

#region 3. Close --------------------------------------------------------------
if ($Name) {
    Revoke-ServerRdpAccess -ResourceGroupName $ResourceGroupName -Name $Name -OnlyIfExpired:$OnlyIfExpired
} else {
    foreach ($vm in Get-AzVM -ResourceGroupName $ResourceGroupName) {
        try { Revoke-ServerRdpAccess -ResourceGroupName $ResourceGroupName -Name $vm.Name -OnlyIfExpired }
        catch { Write-Warning "$($vm.Name): $($_.Exception.Message)" }
    }
}
#endregion
