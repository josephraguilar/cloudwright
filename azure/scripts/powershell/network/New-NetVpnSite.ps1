<#
.SYNOPSIS
    Connect an on-premises site to a VPN gateway: a local network gateway for
    the site, and an IPsec connection with a pre-shared key.
.DESCRIPTION
    The gateway must have finished creating (Succeeded). Configure the same
    pre-shared key and the gateway's public IP on the on-premises device; the
    connection shows Connected once both ends agree. Default IKE policy.
.PARAMETER SubscriptionId
    Subscription of the gateway.
.PARAMETER ResourceGroupName
    Resource group for the local gateway and the connection.
.PARAMETER GatewayId
    Resource ID of the VPN gateway.
.PARAMETER SiteName
    Short name for the site; names the local gateway (lng-<site>) and the
    connection (cn-<site>).
.PARAMETER SiteIpAddress
    Public IP of the on-premises VPN device.
.PARAMETER SiteAddressPrefix
    Address ranges behind the device, for example 192.168.10.0/24.
.PARAMETER SharedKey
    Pre-shared key, also set on the device.
.EXAMPLE
    ./New-NetVpnSite.ps1 -SubscriptionId <sub> -ResourceGroupName rg-net -GatewayId <gw-id> -SiteName office -SiteIpAddress 203.0.113.20 -SiteAddressPrefix 192.168.10.0/24 -SharedKey (Read-Host -AsSecureString)
.NOTES
    Requires: Az.Accounts, Az.Network
    Status:   Untested
    Roles:    Network Contributor on the resource group and the gateway.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$GatewayId,
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9-]{1,40}$')] [string]$SiteName,
    [Parameter(Mandatory)] [string]$SiteIpAddress,
    [Parameter(Mandatory)] [string[]]$SiteAddressPrefix,
    [Parameter(Mandatory)] [securestring]$SharedKey
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'NetworkBuild' 'NetworkBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
$gwParts = $GatewayId -split '/'
$gw = Get-AzVirtualNetworkGateway -ResourceGroupName $gwParts[4] -Name $gwParts[-1] -ErrorAction Stop
$lng = New-NetLocalGateway -ResourceGroupName $ResourceGroupName -Name "lng-$SiteName" -Location $gw.Location -GatewayIpAddress $SiteIpAddress -AddressPrefix $SiteAddressPrefix
if (-not $lng) { Write-Verbose 'WhatIf: the local gateway does not exist yet, so the connection is not previewed.'; return }
New-NetVpnConnection -ResourceGroupName $ResourceGroupName -Name "cn-$SiteName" -GatewayId $GatewayId -LocalGatewayId $lng.Id -SharedKey $SharedKey
