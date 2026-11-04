<#
.SYNOPSIS
    Add a rule to a network security group, or change one with the same name.
.DESCRIPTION
    Rules are never removed here: to stop a rule letting traffic in, set its
    -Access to Deny. An inbound Allow from the whole internet (*, Internet,
    0.0.0.0/0) is refused unless -AllowInternetSource is given; prefer your own
    public IP or a known range, and Generate RDP for remote desktop.
.PARAMETER SubscriptionId
    Subscription of the NSG.
.PARAMETER ResourceGroupName
    Resource group of the NSG.
.PARAMETER NetworkSecurityGroupName
    NSG name.
.PARAMETER Name
    Rule name.
.PARAMETER Priority
    100 to 4096, lower wins. Must be free in that direction.
.PARAMETER Direction
    Inbound or Outbound.
.PARAMETER Access
    Allow or Deny.
.PARAMETER Protocol
    Tcp, Udp, Icmp or *.
.PARAMETER SourceAddressPrefix
    CIDRs, IPs or service tags. Default VirtualNetwork.
.PARAMETER SourcePortRange
    Usually *.
.PARAMETER DestinationAddressPrefix
    CIDRs, IPs or service tags. Default *.
.PARAMETER DestinationPortRange
    Ports or ranges, for example 443 or 8000-8100.
.PARAMETER Description
    Why the rule exists.
.PARAMETER AllowInternetSource
    Allow an inbound Allow rule from the whole internet.
.EXAMPLE
    ./Set-NetSecurityRule.ps1 -SubscriptionId <sub> -ResourceGroupName rg-net -NetworkSecurityGroupName nsg-web -Name allow-https -Priority 200 -Direction Inbound -Access Allow -SourceAddressPrefix 203.0.113.10 -DestinationPortRange 443
.EXAMPLE
    ./Set-NetSecurityRule.ps1 -SubscriptionId <sub> -ResourceGroupName rg-net -NetworkSecurityGroupName nsg-web -Name allow-https -Priority 200 -Direction Inbound -Access Deny -DestinationPortRange 443
    Turns the rule off without removing it.
.NOTES
    Requires: Az.Accounts, Az.Network
    Status:   Untested
    Roles:    Network Contributor on the NSG.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$NetworkSecurityGroupName,
    [Parameter(Mandatory)] [string]$Name,
    [Parameter(Mandatory)] [int]$Priority,
    [Parameter(Mandatory)] [ValidateSet('Inbound', 'Outbound')] [string]$Direction,
    [Parameter(Mandatory)] [ValidateSet('Allow', 'Deny')] [string]$Access,
    [Parameter()] [ValidateSet('Tcp', 'Udp', 'Icmp', '*')] [string]$Protocol = 'Tcp',
    [Parameter()] [string[]]$SourceAddressPrefix = @('VirtualNetwork'),
    [Parameter()] [string[]]$SourcePortRange = @('*'),
    [Parameter()] [string[]]$DestinationAddressPrefix = @('*'),
    [Parameter(Mandatory)] [string[]]$DestinationPortRange,
    [Parameter()] [string]$Description,
    [Parameter()] [switch]$AllowInternetSource
)
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'NetworkBuild' 'NetworkBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
$nsgId = (Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $NetworkSecurityGroupName -ErrorAction Stop).Id
$p = @{
    NetworkSecurityGroupId = $nsgId; Name = $Name; Priority = $Priority; Direction = $Direction; Access = $Access; Protocol = $Protocol
    SourceAddressPrefix = $SourceAddressPrefix; SourcePortRange = $SourcePortRange; DestinationAddressPrefix = $DestinationAddressPrefix
    DestinationPortRange = $DestinationPortRange; AllowInternetSource = $AllowInternetSource
}
if ($Description) { $p.Description = $Description }
Set-NetSecurityRule @p
