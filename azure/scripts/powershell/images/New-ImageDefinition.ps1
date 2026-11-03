<#
.SYNOPSIS
    Create a Compute Gallery (if missing) and an image definition in it.
.DESCRIPTION
    The definition is Windows, generalized, Gen2. Trusted Launch is the default
    and must match the builder VM: a Trusted Launch VM captures only into a
    TrustedLaunch definition. Existing galleries and definitions are reused.
.PARAMETER SubscriptionId
    Subscription for the gallery.
.PARAMETER ResourceGroupName
    Resource group of the gallery (must exist).
.PARAMETER GalleryName
    Gallery name: letters, digits, underscores and periods; no hyphens.
.PARAMETER DefinitionName
    Image definition name, for example win11-avd-apps.
.PARAMETER Location
    Region. Defaults to the resource group's.
.PARAMETER SecurityType
    TrustedLaunch (default) or Standard.
.PARAMETER Publisher
    Free text identifying who publishes the image.
.PARAMETER Offer
    Free text grouping of images.
.PARAMETER Description
    What the image is for.
.EXAMPLE
    ./New-ImageDefinition.ps1 -SubscriptionId <sub> -ResourceGroupName rg-images -GalleryName gal_images -DefinitionName win11-avd-apps
.NOTES
    Requires: Az.Accounts, Az.Compute, Az.Resources
    Status:   Untested
    Roles:    Contributor on the resource group.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$GalleryName,
    [Parameter(Mandatory)] [string]$DefinitionName,
    [Parameter()] [string]$Location,
    [Parameter()] [ValidateSet('TrustedLaunch', 'Standard')] [string]$SecurityType = 'TrustedLaunch',
    [Parameter()] [string]$Publisher = 'Toolbox',
    [Parameter()] [string]$Offer = 'Desktop',
    [Parameter()] [string]$Description
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'ImageBuild' 'ImageBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
if (-not $Location) { $Location = (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop).Location }

$null = New-GalleryResource -ResourceGroupName $ResourceGroupName -Name $GalleryName -Location $Location
$p = @{ ResourceGroupName = $ResourceGroupName; GalleryName = $GalleryName; Name = $DefinitionName; Location = $Location; SecurityType = $SecurityType; Publisher = $Publisher; Offer = $Offer }
if ($Description) { $p.Description = $Description }
$null = New-GalleryImageDefinitionResource @p
if ($WhatIfPreference) { return }
Get-GalleryImageInfo -ResourceGroupName $ResourceGroupName -GalleryName $GalleryName | Where-Object Name -eq $DefinitionName
