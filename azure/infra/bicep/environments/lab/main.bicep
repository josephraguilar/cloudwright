// Lab environment: everything an AVD host pool needs before New-AvdHostPool.ps1 runs.
// Status: deployed successfully 2026-10-17 (westus3, Standard_LRS, no gallery).
// Network is always deployed. Profile storage and the image gallery are switches.

// ---- 1. Scope and parameters -----------------------------------------------
//   WHAT   One resource group. Two feature flags. Names derived from the
//          environment label unless overridden.
//   WHY    Entra-only lab: network + profile share is the minimum for pooled
//          hosts with roaming profiles. The gallery is only for custom images.
targetScope = 'resourceGroup'

@description('Environment label used in names and tags.')
param environment string = 'lab'

@description('Azure region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('VNet address space.')
param addressPrefix string = '10.10.0.0/16'

@description('Session host subnet.')
param subnetPrefix string = '10.10.1.0/24'

@description('Deploy the FSLogix profile storage account and share.')
param deployProfileStorage bool = true

@description('Globally unique storage account name. Required when deployProfileStorage is true.')
param storageAccountName string = ''

@description('Storage SKU. Premium_LRS for real use, Standard_LRS for a cheap lab.')
param storageSkuName string = 'Premium_LRS'

@description('Profile share name.')
param profileShareName string = 'profiles'

@description('Deploy a Compute Gallery and image definition for custom images.')
param deployGallery bool = false

@description('Gallery name. No hyphens.')
param galleryName string = 'gal_avd_${environment}'

@description('Image definition name.')
param imageDefinitionName string = 'win11-avd-m365'

// ---- 2. Shared values ------------------------------------------------------
var tags = {
  environment: environment
  workload: 'avd'
  managedBy: 'bicep'
}

// ---- 3. Modules ------------------------------------------------------------
//   WHAT   Network always. Storage and gallery behind "= if (...)". Each is a
//          composition (infra/bicep/compositions) built from single-resource
//          modules (infra/bicep/modules).
//   WHY    Conditional modules let one environment file serve a bare lab and a
//          fuller one. Flip the bool in main.bicepparam, redeploy, nothing else
//          changes.
module network '../../compositions/avd-network.bicep' = {
  name: 'network-${environment}'
  params: {
    vnetName: 'vnet-avd-${environment}'
    location: location
    addressPrefix: addressPrefix
    subnetPrefix: subnetPrefix
    tags: tags
  }
}

module profileStorage '../../compositions/avd-profile-storage.bicep' = if (deployProfileStorage) {
  name: 'profile-storage-${environment}'
  params: {
    storageAccountName: storageAccountName
    location: location
    skuName: storageSkuName
    shareName: profileShareName
    tags: tags
  }
}

module gallery '../../compositions/avd-image-gallery.bicep' = if (deployGallery) {
  name: 'gallery-${environment}'
  params: {
    galleryName: galleryName
    location: location
    imageDefinitionName: imageDefinitionName
    tags: tags
  }
}

// ---- 4. Outputs ------------------------------------------------------------
//   WHAT   The values the PowerShell scripts need next.
//   WHY    Start-AvdConsole.ps1 and New-AvdEnvironment.ps1 read these after
//          deploying and feed them to the session host build.
//   GOTCHA A module declared with "= if (...)" may not exist, so its outputs are
//          read with the safe-dereference operator ".?" and defaulted with "??".
//          A plain ternary compiles but the linter warns (BCP318) because ARM
//          evaluates the reference before the condition.
output subnetId string = network.outputs.subnetId
output profileShareUnc string = profileStorage.?outputs.uncPath ?? ''
output storageAccountName string = profileStorage.?outputs.storageAccountName ?? ''
output galleryName string = gallery.?outputs.galleryName ?? ''
output imageDefinitionName string = gallery.?outputs.imageDefinitionName ?? ''
