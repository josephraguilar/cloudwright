<#
.SYNOPSIS
    Add a subnet to a virtual network, optionally with an NSG.
.PARAMETER SubscriptionId
    Subscription containing the VNet.
.PARAMETER ResourceGroupName
    Resource group of the VNet.
.PARAMETER VirtualNetworkName
    VNet name.
.PARAMETER Name
    Subnet name.
.PARAMETER AddressPrefix
    CIDR inside the VNet's address space.
.PARAMETER NetworkSecurityGroupId
    NSG to attach.
.EXAMPLE
    ./New-NetSubnet.ps1 -SubscriptionId <sub> -ResourceGroupName rg-avd-lab -VirtualNetworkName vnet-avd-lab -Name snet-servers -AddressPrefix 10.10.2.0/24
.NOTES
    Requires: Az.Accounts, Az.Network
    Status:   Untested
    Roles:    Network Contributor on the resource group.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$VirtualNetworkName,
    [Parameter(Mandatory)] [string]$Name,
    [Parameter(Mandatory)] [string]$AddressPrefix,
    [Parameter()] [string]$NetworkSecurityGroupId
)
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'NetworkBuild' 'NetworkBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
$id = (Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VirtualNetworkName -ErrorAction Stop).Id
$p = @{ VirtualNetworkId = $id; Name = $Name; AddressPrefix = $AddressPrefix; Verbose = ($VerbosePreference -eq 'Continue') }
if ($NetworkSecurityGroupId) { $p.NetworkSecurityGroupId = $NetworkSecurityGroupId }
$null = New-NetSubnet @p
Get-NetSubnetInfo -VirtualNetworkId $id | Where-Object Name -eq $Name
