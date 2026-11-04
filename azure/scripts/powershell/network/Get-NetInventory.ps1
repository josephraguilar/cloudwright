<#
.SYNOPSIS
    Virtual networks and their subnets, as two tables.
.PARAMETER SubscriptionId
    Subscription to read.
.PARAMETER ResourceGroupName
    Limit to one resource group.
.EXAMPLE
    ./Get-NetInventory.ps1 -SubscriptionId <sub>
.NOTES
    Requires: Az.Accounts, Az.Network
    Status:   Untested
    Roles:    Reader.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter()] [string]$ResourceGroupName
)
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'NetworkBuild' 'NetworkBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
$p = @{}
if ($ResourceGroupName) { $p.ResourceGroupName = $ResourceGroupName }
$vnets = @(Get-NetVirtualNetworkInfo @p)
[pscustomobject]@{
    VirtualNetworks = $vnets
    Subnets         = @($vnets | ForEach-Object { Get-NetSubnetInfo -VirtualNetworkId $_.Id })
}
