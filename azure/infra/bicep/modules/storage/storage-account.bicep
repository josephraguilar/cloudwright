// One storage account with secure-by-default settings and optional
// identity-based access for Azure Files.

// ---- 1. Parameters ---------------------------------------------------------
//   WHAT   SKU drives kind: Premium_* = FileStorage (files only, fast), Standard_*
//          = StorageV2 (general purpose).
//   WHY    identityBasedAuth is an object so this module stays generic. Pass {}
//          for a plain account, or the Azure Files identity block for a profile
//          share (see compositions/avd-profile-storage.bicep).
//   GOTCHA Names are globally unique, 3-24 lowercase letters and numbers.
@description('Storage account name. Globally unique, 3-24 lowercase letters and numbers.')
@minLength(3)
@maxLength(24)
param name string

@description('Azure region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Replication SKU. Premium_* creates a FileStorage account.')
@allowed([
  'Standard_LRS'
  'Standard_ZRS'
  'Standard_GRS'
  'Premium_LRS'
  'Premium_ZRS'
])
param skuName string = 'Standard_LRS'

@description('Allow account-key access. Needed once to set NTFS permissions on a share; can be turned off after.')
param allowSharedKeyAccess bool = true

@description('Azure Files identity-based authentication block, e.g. { directoryServiceOptions: \'AADKERB\', defaultSharePermission: \'StorageFileDataSmbShareContributor\' }. Empty = none.')
param identityBasedAuth object = {}

@description('Tags applied to the resource.')
param tags object = {}

var isPremium = startsWith(skuName, 'Premium')

// ---- 2. Resource -----------------------------------------------------------
//   WHAT   The account. TLS 1.2 minimum, HTTPS only, no anonymous blob access.
//   WHY    These three settings are where most storage misconfigurations come
//          from. allowBlobPublicAccess only applies to accounts that have blobs.
resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: name
  location: location
  kind: isPremium ? 'FileStorage' : 'StorageV2'
  sku: {
    name: skuName
  }
  tags: tags
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: isPremium ? null : false
    allowSharedKeyAccess: allowSharedKeyAccess
    azureFilesIdentityBasedAuthentication: empty(identityBasedAuth) ? null : identityBasedAuth
  }
}

// ---- 3. Outputs ------------------------------------------------------------
output id string = sa.id
output name string = sa.name
output fileEndpoint string = sa.properties.primaryEndpoints.file
