<#
.SYNOPSIS
    Upload a managed image to Windows 365 as a custom device image.
.DESCRIPTION
    Windows 365 takes managed images (Microsoft.Compute/images), not gallery
    versions; Invoke-ImageCapture.ps1 -ManagedImageName makes one. The upload
    runs for up to an hour. Uses Microsoft.Graph.Authentication with the
    CloudPC.ReadWrite.All permission; the first run opens a browser to consent.
.PARAMETER SubscriptionId
    Subscription of the managed image.
.PARAMETER ManagedImageId
    Resource ID of the managed image.
.PARAMETER DisplayName
    Name shown in Intune.
.PARAMETER Version
    Three whole numbers, for example 1.0.0.
.EXAMPLE
    ./New-W365Image.ps1 -SubscriptionId <sub> -ManagedImageId <image-id> -DisplayName 'Win11 apps' -Version 1.0.0
.NOTES
    Requires: Az.Accounts, Microsoft.Graph.Authentication
    Status:   Untested
    Roles:    Intune Administrator or Windows 365 Administrator; Reader on the image.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ManagedImageId,
    [Parameter(Mandatory)] [string]$DisplayName,
    [Parameter(Mandatory)] [string]$Version
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'ImageBuild' 'ImageBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
New-W365DeviceImage -DisplayName $DisplayName -Version $Version -ManagedImageId $ManagedImageId
