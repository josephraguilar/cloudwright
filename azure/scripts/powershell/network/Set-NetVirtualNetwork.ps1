<#
.SYNOPSIS
    Edit a virtual network: DNS servers (custom or Azure default) and added address space.
.PARAMETER SubscriptionId
    Subscription containing the VNet.
.PARAMETER ResourceGroupName
    Resource group of the VNet.
.PARAMETER Name
    VNet name.
.PARAMETER DnsServer
    Custom DNS servers, in order.
.PARAMETER AzureDefaultDns
    Back to Azure-provided DNS.
.PARAMETER AddAddressPrefix
    CIDRs to add to the address space. Nothing is ever removed.
.EXAMPLE
    ./Set-NetVirtualNetwork.ps1 -SubscriptionId <sub> -ResourceGroupName rg-avd-lab -Name vnet-avd-lab -AzureDefaultDns
.EXAMPLE
    ./Set-NetVirtualNetwork.ps1 ... -Name vnet-avd-lab -DnsServer 10.10.1.4, 168.63.129.16
.NOTES
    Requires: Az.Accounts, Az.Network
    Status:   Untested
    Roles:    Network Contributor on the resource group.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$Name,
    [Parameter()] [string[]]$DnsServer,
    [Parameter()] [switch]$AzureDefaultDns,
    [Parameter()] [string[]]$AddAddressPrefix
)
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'NetworkBuild' 'NetworkBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
$verbose = $VerbosePreference -eq 'Continue'
if ($DnsServer -and $AzureDefaultDns) { throw 'Give -DnsServer or -AzureDefaultDns, not both.' }
$id = (Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop).Id
if ($AzureDefaultDns) { $null = Set-NetVirtualNetworkDnsServer -VirtualNetworkId $id -AzureDefault -Verbose:$verbose }
elseif ($DnsServer)   { $null = Set-NetVirtualNetworkDnsServer -VirtualNetworkId $id -DnsServer $DnsServer -Verbose:$verbose }
foreach ($prefix in @($AddAddressPrefix)) { if ($prefix) { $null = Add-NetAddressSpace -VirtualNetworkId $id -AddressPrefix $prefix -Verbose:$verbose } }
Get-NetVirtualNetworkInfo -ResourceGroupName $ResourceGroupName | Where-Object Name -eq $Name
