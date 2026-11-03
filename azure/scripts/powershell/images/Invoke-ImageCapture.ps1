<#
.SYNOPSIS
    Capture an image builder VM: sysprep it (unless already generalized), add a
    version to a gallery image definition, and optionally make a managed image
    for Windows 365.
.DESCRIPTION
    Sysprep is one-way. The VM cannot boot again afterwards; keep it (deallocated,
    disk billing only) as the record of what went into the version, or delete it
    in the portal. Nothing here deletes it.
    The version capture runs in Azure for 15 to 60 minutes. This script returns
    once Azure has accepted it; the version shows state Creating, then Succeeded.
.PARAMETER SubscriptionId
    Subscription of the VM and gallery.
.PARAMETER ResourceGroupName
    Resource group of the VM.
.PARAMETER VMName
    The image builder VM.
.PARAMETER DefinitionId
    Resource ID of the gallery image definition.
.PARAMETER Version
    Three whole numbers. Defaults to the date and time, for example 2026.1017.1430.
.PARAMETER ReplicaRegion
    Extra regions to replicate to, besides the definition's own.
.PARAMETER ExcludeFromLatest
    Keep this version out of "latest" until you have tested it.
.PARAMETER ManagedImageName
    Also create a managed image with this name (Windows 365 needs one).
.PARAMETER SkipSysprep
    The VM is already generalized; skip sysprep.
.PARAMETER AllowUntaggedVm
    Allow sysprep on a VM without the purpose=image-builder tag.
.PARAMETER Wait
    Wait for the version capture to finish.
.EXAMPLE
    ./Invoke-ImageCapture.ps1 -SubscriptionId <sub> -ResourceGroupName rg-images -VMName img-win11-01 -DefinitionId <definition-id>
.NOTES
    Requires: Az.Accounts, Az.Compute
    Status:   Untested
    Roles:    Virtual Machine Contributor on the VM; Contributor on the gallery.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$VMName,
    [Parameter(Mandatory)] [string]$DefinitionId,
    [Parameter()] [string]$Version,
    [Parameter()] [string[]]$ReplicaRegion = @(),
    [Parameter()] [switch]$ExcludeFromLatest,
    [Parameter()] [string]$ManagedImageName,
    [Parameter()] [switch]$SkipSysprep,
    [Parameter()] [switch]$AllowUntaggedVm,
    [Parameter()] [switch]$Wait
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'ImageBuild' 'ImageBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId

#region 1. Generalize ----------------------------------------------------------
$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status
$generalized = @($vm.Statuses | Where-Object { $_.Code -eq 'OSState/generalized' }).Count -gt 0
if ($generalized) {
    Write-Verbose "$VMName is already generalized."
} elseif ($SkipSysprep) {
    throw "$VMName is not generalized; run without -SkipSysprep."
} else {
    $r = Invoke-GalleryVmSysprep -ResourceGroupName $ResourceGroupName -VMName $VMName -AllowUntaggedVm:$AllowUntaggedVm
    if (-not $r) { return }   # -WhatIf
}
#endregion

#region 2. Capture --------------------------------------------------------------
$vmId = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName).Id
$p = @{ DefinitionId = $DefinitionId; SourceVmId = $vmId; ReplicaRegion = $ReplicaRegion; ExcludeFromLatest = $ExcludeFromLatest; Wait = $Wait }
if ($Version) { $p.Version = $Version }
New-GalleryImageVersionFromVm @p
if ($ManagedImageName) { New-GalleryManagedImage -SourceVmId $vmId -ResourceGroupName $ResourceGroupName -Name $ManagedImageName | Select-Object Name, ResourceGroupName, Id }
#endregion
