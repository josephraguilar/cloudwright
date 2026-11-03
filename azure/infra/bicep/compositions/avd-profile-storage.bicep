// FSLogix profile storage: a storage account with Microsoft Entra Kerberos
// identity-based access, and one SMB share. This is the declarative half of the
// portal's "Identity-based access" blade. The imperative half (NTFS permissions,
// admin consent) is scripts/powershell/storage/Set-AvdProfileShareAccess.ps1.

// ---- 1. Parameters ---------------------------------------------------------
//   WHAT   Mirrors the portal blade: identity source, default share permission,
//          plus the share itself and soft delete.
@description('Storage account name. Globally unique, 3-24 lowercase letters and numbers.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Azure region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Premium_LRS/Premium_ZRS for real use (FileStorage, fast). Standard_* for a lab.')
@allowed([
  'Premium_LRS'
  'Premium_ZRS'
  'Standard_LRS'
  'Standard_ZRS'
])
param skuName string = 'Premium_LRS'

@description('File share name.')
param shareName string = 'profiles'

@description('Share size in GiB.')
@minValue(100)
param shareQuotaGiB int = 100

@description('Identity source. AADKERB = Microsoft Entra Kerberos. None = identity-based access off.')
@allowed([
  'AADKERB'
  'None'
])
param identitySource string = 'AADKERB'

@description('Default share-level permission for all authenticated identities. None = rely on RBAC on the share.')
@allowed([
  'StorageFileDataSmbShareContributor'
  'StorageFileDataSmbShareReader'
  'StorageFileDataSmbShareElevatedContributor'
  'None'
])
param defaultSharePermission string = 'StorageFileDataSmbShareContributor'

@description('Soft delete retention for shares, in days.')
@minValue(1)
@maxValue(365)
param softDeleteDays int = 14

@description('Tags applied to every resource.')
param tags object = {}

var isPremium = startsWith(skuName, 'Premium')

// ---- 2. Modules ------------------------------------------------------------
//   WHAT   The account with the identity block, then the share on it.
//   WHY    Enabling Entra Kerberos creates an app registration named
//          "[Storage Account] <name>.file.core.windows.net" that needs admin
//          consent once. The script prints those steps.
module account '../modules/storage/storage-account.bicep' = {
  name: 'sa-${storageAccountName}'
  params: {
    name: storageAccountName
    location: location
    skuName: skuName
    allowSharedKeyAccess: true
    identityBasedAuth: identitySource == 'None' ? {
      directoryServiceOptions: 'None'
    } : {
      directoryServiceOptions: 'AADKERB'
      defaultSharePermission: defaultSharePermission
    }
    tags: tags
  }
}

module share '../modules/storage/file-share.bicep' = {
  name: 'share-${shareName}'
  params: {
    storageAccountName: account.outputs.name
    name: shareName
    quotaGiB: shareQuotaGiB
    softDeleteDays: softDeleteDays
    enableMultichannel: isPremium
  }
}

// ---- 3. Outputs ------------------------------------------------------------
//   WHAT   The UNC path goes into FSLogix VHDLocations on every host.
output storageAccountId string = account.outputs.id
output storageAccountName string = account.outputs.name
output shareName string = share.outputs.name
output uncPath string = share.outputs.uncPath
