<#
.SYNOPSIS
    Create a virtual network with its first subnet.
.PARAMETER SubscriptionId
    Subscription to build in.
.PARAMETER ResourceGroupName
    Existing resource group.
.PARAMETER Name
    VNet name.
.PARAMETER Location
    Region. Default: the resource group's.
.PARAMETER AddressPrefix
    One or more CIDRs, e.g. 10.20.0.0/16.
.PARAMETER SubnetName
    First subnet. Default 'default'.
.PARAMETER SubnetPrefix
    First subnet's CIDR, inside the address space.
.PARAMETER DnsServer
    Custom DNS servers. Omit for Azure default.
.PARAMETER NetworkSecurityGroupId
    NSG to attach to the first subnet.
.EXAMPLE
    ./New-NetVirtualNetwork.ps1 -SubscriptionId <sub> -ResourceGroupName rg-net -Name vnet-prod -AddressPrefix 10.20.0.0/16 -SubnetName snet-servers -SubnetPrefix 10.20.1.0/24
.NOTES
    Requires: Az.Accounts, Az.Network, Az.Resources
    Status:   Untested
    Roles:    Network Contributor on the resource group.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$Name,
    [Parameter()] [string]$Location,
    [Parameter(Mandatory)] [string[]]$AddressPrefix,
    [Parameter()] [string]$SubnetName = 'default',
    [Parameter(Mandatory)] [string]$SubnetPrefix,
    [Parameter()] [string[]]$DnsServer,
    [Parameter()] [string]$NetworkSecurityGroupId
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'NetworkBuild' 'NetworkBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
if (-not $Location) { $Location = (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop).Location }
$p = @{ ResourceGroupName = $ResourceGroupName; Name = $Name; Location = $Location; AddressPrefix = $AddressPrefix; SubnetName = $SubnetName; SubnetPrefix = $SubnetPrefix; Verbose = ($VerbosePreference -eq 'Continue') }
if ($DnsServer) { $p.DnsServer = $DnsServer }
if ($NetworkSecurityGroupId) { $p.NetworkSecurityGroupId = $NetworkSecurityGroupId }
$vnet = New-NetVirtualNetwork @p
if ($vnet) { Get-NetVirtualNetworkInfo -ResourceGroupName $ResourceGroupName | Where-Object Name -eq $Name }
