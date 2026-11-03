<#
.SYNOPSIS
    Create a Standard, static public IP address.
.DESCRIPTION
    Billed whether or not anything uses it. Zone-redundant with -Zone 1,2,3.
    An existing address with the same name is returned untouched.
.PARAMETER SubscriptionId
    Subscription for the address.
.PARAMETER ResourceGroupName
    Resource group (must exist).
.PARAMETER Name
    Name of the public IP resource.
.PARAMETER Location
    Region. Defaults to the resource group's.
.PARAMETER Zone
    Availability zones, for example 1,2,3.
.EXAMPLE
    ./New-NetPublicIp.ps1 -SubscriptionId <sub> -ResourceGroupName rg-net -Name pip-web01
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
    [Parameter()] [string[]]$Zone = @()
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'NetworkBuild' 'NetworkBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
if (-not $Location) { $Location = (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop).Location }
$null = New-NetPublicIp -ResourceGroupName $ResourceGroupName -Name $Name -Location $Location -Zone $Zone
if ($WhatIfPreference) { return }
Get-NetPublicIpInfo -ResourceGroupName $ResourceGroupName | Where-Object Name -eq $Name
