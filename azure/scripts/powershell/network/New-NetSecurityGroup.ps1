<#
.SYNOPSIS
    Create a network security group with the default rules only.
.PARAMETER SubscriptionId
    Subscription to build in.
.PARAMETER ResourceGroupName
    Existing resource group.
.PARAMETER Name
    NSG name.
.PARAMETER Location
    Region. Default: the resource group's.
.EXAMPLE
    ./New-NetSecurityGroup.ps1 -SubscriptionId <sub> -ResourceGroupName rg-net -Name nsg-snet-servers
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
    [Parameter()] [string]$Location
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'NetworkBuild' 'NetworkBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
if (-not $Location) { $Location = (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop).Location }
$nsg = New-NetSecurityGroup -ResourceGroupName $ResourceGroupName -Name $Name -Location $Location -Verbose:($VerbosePreference -eq 'Continue')
if ($nsg) { Get-NetSecurityGroupInfo -ResourceGroupName $ResourceGroupName | Where-Object Name -eq $Name }
