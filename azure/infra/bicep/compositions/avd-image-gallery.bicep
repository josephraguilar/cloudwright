// Compute Gallery with one image definition shaped for AVD session hosts
// (Windows, generalized, Gen2, Trusted Launch capable).

// ---- 1. Parameters ---------------------------------------------------------
@description('Gallery name. No hyphens.')
param galleryName string

@description('Azure region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Image definition name.')
param imageDefinitionName string = 'win11-avd-m365'

@description('Identifier publisher. Free text.')
param publisher string = 'lab'

@description('Identifier offer. Free text.')
param offer string = 'avd'

@description('Identifier SKU. Free text.')
param sku string = 'win11-m365'

@description('Mark the definition Trusted Launch capable. Match what New-AvdSessionHost.ps1 builds.')
param trustedLaunch bool = true

@description('Tags applied to every resource.')
param tags object = {}

// ---- 2. Modules ------------------------------------------------------------
module gallery '../modules/compute/gallery.bicep' = {
  name: 'gallery-${galleryName}'
  params: {
    name: galleryName
    location: location
    galleryDescription: 'AVD session host images'
    tags: tags
  }
}

module definition '../modules/compute/gallery-image-definition.bicep' = {
  name: 'imagedef-${imageDefinitionName}'
  params: {
    galleryName: gallery.outputs.name
    name: imageDefinitionName
    location: location
    publisher: publisher
    offer: offer
    sku: sku
    trustedLaunch: trustedLaunch
    tags: tags
  }
}

// ---- 3. Outputs ------------------------------------------------------------
output galleryId string = gallery.outputs.id
output galleryName string = gallery.outputs.name
output imageDefinitionName string = definition.outputs.name
