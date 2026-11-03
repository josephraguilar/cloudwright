@{
    Id      = 'azure.storage.new-storage-account'
    Title   = 'Create a storage account'
    Summary = 'A storage account holds blobs, file shares, queues, and tables under one globally unique name. Secure defaults: TLS 1.2, no anonymous blob access.'
    Learn   = @(
        'The name is a DNS label: 3-24 lowercase letters and digits, unique across all of Azure. Check with Get-AzStorageAccountNameAvailability first.'
        'StorageV2 is the general-purpose kind. FileStorage (Premium_LRS only) is for premium SMB shares such as FSLogix profiles at scale.'
        'Redundancy is in the SKU: LRS (one datacentre), ZRS (three zones), GRS (second region). You can change some of these later, not all.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Storage'); Roles = @('Contributor on the resource group') }
    Prerequisites = @('azure.create.resource-group')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'Location'; Label = 'Region'; Help = 'Azure region short name, e.g. eastus2. Resources that talk to each other should share a region.'; Type = 'Choice'; Required = $true; Default = 'eastus2'
           Source = @{ Cmdlet = 'Get-AzLocation'; Display = 'DisplayName'; Value = 'Location'; Auth = 'Azure' } }
        @{ Name = 'AccountName'; Label = 'Account name (3-24 lowercase letters/digits, globally unique)'; Help = 'The storage account. 3 to 24 lowercase letters and digits, globally unique.'; Type = 'String'; Required = $true; Pattern = '^[a-z0-9]{3,24}$'; Example = 'stavdlabprof01' }
        @{ Name = 'Sku'; Label = 'Redundancy / performance'; Help = 'Performance tier and redundancy in one value. Standard = HDD-backed, Premium = SSD. The suffix is how many copies Azure keeps and where: LRS (locally redundant) = 3 copies in one datacentre, survives a disk or rack failure; ZRS (zone redundant) = 3 copies across 3 availability zones in the region, survives a datacentre outage; GRS (geo redundant) = LRS plus 3 more copies in the paired region hundreds of miles away, survives a regional disaster (read access only after Microsoft fails over, unless RA-GRS). Cost rises LRS < ZRS < GRS. Labs: Standard_LRS. FSLogix profiles in production: Premium_LRS or Premium_ZRS.'; Type = 'Choice'; Required = $true; Default = 'Standard_LRS'; Options = @('Standard_LRS', 'Standard_ZRS', 'Standard_GRS', 'Premium_LRS', 'Premium_ZRS') }
        @{ Name = 'Kind'; Label = 'Kind'; Help = 'StorageV2 (general purpose v2) holds blobs, files, queues, and tables on standard or premium storage and is the right default. FileStorage is a premium-only account type for SMB/NFS file shares with provisioned IOPS, used for large FSLogix deployments. BlobStorage and Storage (v1) are legacy.'; Type = 'Choice'; Required = $true; Default = 'StorageV2'; Options = @(@{ Display = 'StorageV2 (general purpose)'; Value = 'StorageV2' }, @{ Display = 'FileStorage (premium file shares only)'; Value = 'FileStorage' }) }
        @{ Name = 'MinimumTlsVersion'; Label = 'Minimum TLS version'; Help = 'Clients negotiating an older TLS version than this are refused. TLS1_2 is the baseline every current OS and SDK supports; TLS 1.0 and 1.1 are deprecated and fail most compliance scans. Only lower it for a known legacy client, and plan to remove it.'; Type = 'Choice'; Required = $true; Default = 'TLS1_2'; Options = @('TLS1_2', 'TLS1_1', 'TLS1_0') }
        @{ Name = 'AllowBlobPublicAccess'; Label = 'Allow anonymous blob access'; Help = 'Account-level switch for anonymous (no token, no sign-in) access to blobs. Off means no container can be made public even by mistake. Leave it off unless the account hosts a public website or downloads; a leaked public container is the classic storage breach.'; Type = 'TrueFalse'; Required = $false; Default = $false }
    )
    Steps = @(
        @{
            Title      = 'Create the storage account'
            What       = 'Creates the account with TLS 1.2 minimum and anonymous blob access off.'
            Why        = 'Those two settings are the ones auditors ask about first.'
            Cmdlet     = 'New-AzStorageAccount'
            Parameters = @{ Name = '{{AccountName}}'; ResourceGroupName = '{{ResourceGroupName}}'; Location = '{{Location}}'; SkuName = '{{Sku}}'; Kind = '{{Kind}}'; MinimumTlsVersion = '{{MinimumTlsVersion}}'; AllowBlobPublicAccess = '{{AllowBlobPublicAccess}}' }
            ParameterOrder = @('Name', 'ResourceGroupName', 'Location', 'SkuName', 'Kind', 'MinimumTlsVersion', 'AllowBlobPublicAccess')
            BoolParameters = @('AllowBlobPublicAccess')
            Output     = 'sa'
        }
    )
    Verify   = @('Get-AzStorageAccount -Name {{AccountName}} -ResourceGroupName {{ResourceGroupName}} | Select-Object StorageAccountName, Kind, @{ n = ''Sku''; e = { $_.Sku.Name } }, MinimumTlsVersion, AllowBlobPublicAccess, ProvisioningState')
    Rollback = @('Remove-AzStorageAccount -Name {{AccountName}} -ResourceGroupName {{ResourceGroupName}} -Force    # Everything in it is gone. No soft delete for the account itself.')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.storage/new-azstorageaccount')
    Status   = 'Untested'
}
