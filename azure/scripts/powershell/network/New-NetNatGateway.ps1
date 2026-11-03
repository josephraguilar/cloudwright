<#
.SYNOPSIS
    Create a NAT gateway with a public IP, and attach it to subnets.
.DESCRIPTION
    Gives the subnets one fixed outbound IP without public IPs on the VMs.
    The gateway and its IP bill hourly. Existing ones are reused.
.PARAMETER SubscriptionId
    Subscription for the gateway.
.PARAMETER ResourceGroupName
    Resource group (must exist).
.PARAMETER Name
    NAT gateway name.
.PARAMETER Location
    Region. Defaults to the resource group's. Must match the VNet.
.PARAMETER SubnetId
    Subnets to attach it to (optional).
.PARAMETER IdleTimeoutMinutes
    TCP idle timeout, 4 to 120. Default 4.
.EXAMPLE
    ./New-NetNatGateway.ps1 -SubscriptionId <sub> -ResourceGroupName rg-net -Name natgw-lab -SubnetId <subnet-id>
.NOTES
    Requires: Az.Accounts, Az.Network, Az.Resources
    Status:   Untested
    Roles:    Network Contributor on the resource group and the VNet.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$Name,
    [Parameter()] [string]$Location,
    [Parameter()] [string[]]$SubnetId = @(),
    [Parameter()] [ValidateRange(4, 120)] [int]$IdleTimeoutMinutes = 4
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'NetworkBuild' 'NetworkBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
if (-not $Location) { $Location = (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop).Location }
$nat = New-NetNatGateway -ResourceGroupName $ResourceGroupName -Name $Name -Location $Location -IdleTimeoutMinutes $IdleTimeoutMinutes
if (-not $nat) { return }
foreach ($s in $SubnetId) {
    $parts = $s -split '/'
    $vnetId = ($parts[0..8] -join '/')
    try { $null = Set-NetSubnetNatGateway -VirtualNetworkId $vnetId -SubnetName $parts[10] -NatGatewayId $nat.Id }
    catch { Write-Warning "$($parts[10]): $($_.Exception.Message)" }
}
Get-NetNatGatewayInfo | Where-Object Name -eq $Name
