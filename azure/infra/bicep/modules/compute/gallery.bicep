// One Azure Compute Gallery.

// ---- 1. Parameters ---------------------------------------------------------
//   GOTCHA Gallery names allow letters, numbers, periods and underscores. No hyphens.
@description('Gallery name. No hyphens.')
param name string

@description('Azure region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Description shown in the portal.')
param galleryDescription string = ''

@description('Tags applied to the resource.')
param tags object = {}

// ---- 2. Resource -----------------------------------------------------------
resource gallery 'Microsoft.Compute/galleries@2023-07-03' = {
  name: name
  location: location
  tags: tags
  properties: {
    description: galleryDescription
  }
}

// ---- 3. Outputs ------------------------------------------------------------
output id string = gallery.id
output name string = gallery.name
