<#
.SYNOPSIS
    Create a route-based VPN gateway in a virtual network.
.DESCRIPTION
    Takes 30 to 45 minutes and bills from the start (VpnGw1AZ costs about as much
    as a small VM running all month). Adds GatewaySubnet when the VNet has none.
    Returns as soon as Azure has the request; the gateway shows Updating, then
    Succeeded. Then connect a site with New-NetVpnSite.ps1.
.PARAMETER SubscriptionId
    Subscription of the VNet.
.PARAMETER ResourceGroupName
    Resource group for the gateway and its public IP.
.PARAMETER Name
    Gateway name.
.PARAMETER VirtualNetworkId
    Resource ID of the VNet.
.PARAMETER GatewaySubnetPrefix
    A free /27 (or larger) inside the VNet, when it has no GatewaySubnet yet.
.PARAMETER Sku
    VpnGw1AZ (default), VpnGw2AZ, VpnGw3AZ, VpnGw1 or VpnGw2.
.EXAMPLE
    ./New-NetVpnGateway.ps1 -SubscriptionId <sub> -ResourceGroupName rg-net -Name vpngw-lab -VirtualNetworkId <vnet-id> -GatewaySubnetPrefix 10.10.255.0/27
.NOTES
    Requires: Az.Accounts, Az.Network
    Status:   Untested
    Roles:    Network Contributor on the resource group and the VNet.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$Name,
    [Parameter(Mandatory)] [string]$VirtualNetworkId,
    [Parameter()] [string]$GatewaySubnetPrefix,
    [Parameter()] [ValidateSet('VpnGw1AZ', 'VpnGw2AZ', 'VpnGw3AZ', 'VpnGw1', 'VpnGw2')] [string]$Sku = 'VpnGw1AZ'
)
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'NetworkBuild' 'NetworkBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
$p = @{ ResourceGroupName = $ResourceGroupName; Name = $Name; VirtualNetworkId = $VirtualNetworkId; Sku = $Sku }
if ($GatewaySubnetPrefix) { $p.GatewaySubnetPrefix = $GatewaySubnetPrefix }
New-NetVpnGateway @p
