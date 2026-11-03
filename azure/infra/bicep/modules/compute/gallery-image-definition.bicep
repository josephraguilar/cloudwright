// One image definition inside an existing Compute Gallery. Versions are
// produced by a capture process, not by Bicep.

// ---- 1. Parameters ---------------------------------------------------------
//   WHAT   The "shape" of an image: OS, state, generation, security features.
//   WHY    Versions captured from Trusted Launch VMs can only go in a definition
//          with the TrustedLaunchSupported feature, and vice versa. Decide here.
@description('Existing gallery name.')
param galleryName string

@description('Image definition name.')
param name string

@description('Azure region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Identifier publisher. Free text.')
param publisher string

@description('Identifier offer. Free text.')
param offer string

@description('Identifier SKU. Free text.')
param sku string

@description('Windows or Linux.')
@allowed([
  'Windows'
  'Linux'
])
param osType string = 'Windows'

@description('Generation. V2 is required for Trusted Launch.')
@allowed([
  'V1'
  'V2'
])
param hyperVGeneration string = 'V2'

@description('Mark the definition Trusted Launch capable.')
param trustedLaunch bool = true

@description('Tags applied to the resource.')
param tags object = {}

// ---- 2. Resources ----------------------------------------------------------
resource gallery 'Microsoft.Compute/galleries@2023-07-03' existing = {
  name: galleryName
}

resource definition 'Microsoft.Compute/galleries/images@2023-07-03' = {
  parent: gallery
  name: name
  location: location
  tags: tags
  properties: {
    osType: osType
    osState: 'Generalized'
    hyperVGeneration: hyperVGeneration
    identifier: {
      publisher: publisher
      offer: offer
      sku: sku
    }
    features: trustedLaunch ? [
      {
        name: 'SecurityType'
        value: 'TrustedLaunchSupported'
      }
    ] : []
  }
}

// ---- 3. Outputs ------------------------------------------------------------
output id string = definition.id
output name string = definition.name
