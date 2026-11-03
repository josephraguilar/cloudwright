// One SMB file share on an existing storage account, plus the file service
// settings that go with it (soft delete, multichannel).

// ---- 1. Parameters ---------------------------------------------------------
//   WHAT   The parent account by name, the share, and two service-level knobs.
//   WHY    Soft delete and multichannel live on the account's file service, not
//          the share, but nobody wants to think about "the file service" as a
//          thing. They are set here because the share is why you care.
@description('Existing storage account name.')
param storageAccountName string

@description('Share name.')
param name string

@description('Share size in GiB. On Premium this is provisioned size and sets IOPS.')
@minValue(1)
param quotaGiB int = 100

@description('Soft delete retention for shares, in days. 0 disables.')
@minValue(0)
@maxValue(365)
param softDeleteDays int = 14

@description('Enable SMB Multichannel. Premium accounts only.')
param enableMultichannel bool = false

// ---- 2. Resources ----------------------------------------------------------
resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: sa
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: softDeleteDays > 0 ? {
      enabled: true
      days: max(softDeleteDays, 1)
    } : {
      enabled: false
    }
    protocolSettings: enableMultichannel ? {
      smb: {
        multichannel: {
          enabled: true
        }
      }
    } : null
  }
}

resource share 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: name
  properties: {
    shareQuota: quotaGiB
    enabledProtocols: 'SMB'
  }
}

// ---- 3. Outputs ------------------------------------------------------------
//   WHAT   The UNC path is what FSLogix and users mount.
output name string = share.name
output uncPath string = '\\\\${sa.name}.file.${environment().suffixes.storage}\\${share.name}'
