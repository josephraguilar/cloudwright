<#
.SYNOPSIS
    List the VMs in a resource group, or the whole subscription, with power state,
    size, image, private IP and role tag.
.PARAMETER SubscriptionId
    Subscription to read.
.PARAMETER ResourceGroupName
    Limit to one resource group. Omit for every VM the account can see.
.EXAMPLE
    ./Get-ServerInventory.ps1 -SubscriptionId <sub> -ResourceGroupName rg-servers | Format-Table
.NOTES
    Requires: Az.Accounts, Az.Compute, Az.Network
    Status:   Untested
    Roles:    Reader.
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ResourceGroupName
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

#region 3. List ---------------------------------------------------------------
$p = @{}
if ($ResourceGroupName) { $p.ResourceGroupName = $ResourceGroupName }
Get-ServerVmInfo @p | Sort-Object ResourceGroupName, Name
#endregion
