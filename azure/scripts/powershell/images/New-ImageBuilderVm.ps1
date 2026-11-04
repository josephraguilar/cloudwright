<#
.SYNOPSIS
    Create a VM to build a desktop image on.
.DESCRIPTION
    Marketplace image, no domain join, no AVD agent, no public IP, tagged
    purpose=image-builder (the capture refuses untagged VMs unless told
    otherwise). Reach it with Generate RDP on the Servers page, install the apps,
    then capture it with Invoke-ImageCapture.ps1.
.PARAMETER SubscriptionId
    Subscription for the VM.
.PARAMETER ResourceGroupName
    Resource group for the VM.
.PARAMETER VMName
    15 characters or fewer.
.PARAMETER SubnetId
    Subnet for the NIC.
.PARAMETER ImageKey
    publisher:offer:sku, for example MicrosoftWindowsDesktop:office-365:win11-25h2-avd-m365.
.PARAMETER LocalAdminCredential
    Local administrator for the VM.
.PARAMETER VMSize
    Size. Default Standard_D4s_v5.
.PARAMETER SecurityType
    TrustedLaunch (default) or Standard. Must match the image definition.
.PARAMETER Location
    Region. Defaults to the resource group's.
.EXAMPLE
    ./New-ImageBuilderVm.ps1 -SubscriptionId <sub> -ResourceGroupName rg-images -VMName img-win11-01 -SubnetId <subnet-id> -ImageKey MicrosoftWindowsDesktop:office-365:win11-25h2-avd-m365 -LocalAdminCredential (Get-Credential)
.NOTES
    Requires: Az.Accounts, Az.Compute, Az.Network, Az.Resources
    Status:   Untested
    Roles:    Virtual Machine Contributor and Network Contributor on the resource group.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [ValidateLength(1, 15)] [string]$VMName,
    [Parameter(Mandatory)] [string]$SubnetId,
    [Parameter(Mandatory)] [string]$ImageKey,
    [Parameter(Mandatory)] [pscredential]$LocalAdminCredential,
    [Parameter()] [string]$VMSize = 'Standard_D4s_v5',
    [Parameter()] [ValidateSet('TrustedLaunch', 'Standard')] [string]$SecurityType = 'TrustedLaunch',
    [Parameter()] [string]$Location
)
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'ImageBuild' 'ImageBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
if (-not $Location) { $Location = (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop).Location }

New-GalleryBuilderVm -ResourceGroupName $ResourceGroupName -VMName $VMName -Location $Location -SubnetId $SubnetId -ImageKey $ImageKey `
    -LocalAdminCredential $LocalAdminCredential -VMSize $VMSize -SecurityType $SecurityType
