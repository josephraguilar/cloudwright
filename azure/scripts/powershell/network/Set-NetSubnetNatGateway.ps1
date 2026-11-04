<#
.SYNOPSIS
    Attach a NAT gateway to a subnet, or detach it.
.DESCRIPTION
    Outbound traffic from the subnet changes source IP at once; long-lived
    connections drop. Detaching does not delete the gateway.
.PARAMETER SubscriptionId
    Subscription of the VNet.
.PARAMETER SubnetId
    Resource ID of the subnet.
.PARAMETER NatGatewayId
    NAT gateway to attach.
.PARAMETER Detach
    Remove the subnet's NAT gateway association.
.EXAMPLE
    ./Set-NetSubnetNatGateway.ps1 -SubscriptionId <sub> -SubnetId <subnet-id> -NatGatewayId <nat-id>
.NOTES
    Requires: Az.Accounts, Az.Network
    Status:   Untested
    Roles:    Network Contributor on the VNet and the NAT gateway.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Attach')]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$SubnetId,
    [Parameter(ParameterSetName = 'Attach', Mandatory)] [string]$NatGatewayId,
    [Parameter(ParameterSetName = 'Detach', Mandatory)] [switch]$Detach
)
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'NetworkBuild' 'NetworkBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
$parts = $SubnetId -split '/'
$vnetId = ($parts[0..8] -join '/')
if ($Detach) { Set-NetSubnetNatGateway -VirtualNetworkId $vnetId -SubnetName $parts[10] -Detach | Select-Object Name, Id }
else { Set-NetSubnetNatGateway -VirtualNetworkId $vnetId -SubnetName $parts[10] -NatGatewayId $NatGatewayId | Select-Object Name, Id }
