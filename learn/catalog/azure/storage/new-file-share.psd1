@{
    Id      = 'azure.storage.new-file-share'
    Title   = 'Create an Azure Files share'
    Summary = 'An SMB share in a storage account. For FSLogix profiles, user home drives, or anything that wants a UNC path.'
    Learn   = @(
        'New-AzRmStorageShare goes through ARM (management plane) and needs no storage key. New-AzStorageShare is the older data-plane cmdlet.'
        'Quota is a cap in GiB, not a reservation, on standard accounts. On premium (FileStorage) it is also what you pay for.'
        'The UNC path is \\<account>.file.core.windows.net\<share>. Port 445 outbound must be open from wherever you mount it.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Storage'); Roles = @('Contributor on the storage account') }
    Prerequisites = @('azure.storage.new-storage-account')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'AccountName'; Label = 'Storage account'; Help = 'The storage account. 3 to 24 lowercase letters and digits, globally unique.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzStorageAccount'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'StorageAccountName'; Value = 'StorageAccountName'; Auth = 'Azure' } }
        @{ Name = 'ShareName'; Label = 'Share name (lowercase)'; Help = 'The SMB share name, lowercase, 3 to 63 characters. The share is reached as \\<account>.file.core.windows.net\<share> over TCP 445, which many ISPs block from home networks; it works from Azure VMs and office networks that allow it.'; Type = 'String'; Required = $true; Default = 'profiles'; Pattern = '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' }
        @{ Name = 'QuotaGb'; Label = 'Quota in GiB'; Help = 'Maximum size of the share in GiB (1024-based gigabytes). On standard storage accounts it is only a cap you can raise later; you pay for data actually stored. On premium (FileStorage) accounts the quota is provisioned capacity and sets both the price and the IOPS, so size it deliberately.'; Type = 'Int'; Required = $true; Default = '100' }
    )
    Steps = @(
        @{
            Title      = 'Create the share'
            What       = 'Creates the SMB share with the given quota.'
            Why        = 'Management-plane call, so it works with RBAC alone.'
            Cmdlet     = 'New-AzRmStorageShare'
            Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}'; StorageAccountName = '{{AccountName}}'; Name = '{{ShareName}}'; QuotaGiB = '{{QuotaGb}}' }
            ParameterOrder = @('ResourceGroupName', 'StorageAccountName', 'Name', 'QuotaGiB')
        }
    )
    Verify   = @('Get-AzRmStorageShare -ResourceGroupName {{ResourceGroupName}} -StorageAccountName {{AccountName}} -Name {{ShareName}} | Select-Object Name, QuotaGiB, EnabledProtocols', '"\\{{AccountName:raw}}.file.core.windows.net\{{ShareName:raw}}"')
    Rollback = @('Remove-AzRmStorageShare -ResourceGroupName {{ResourceGroupName}} -StorageAccountName {{AccountName}} -Name {{ShareName}} -Force    # Soft-deleted for 7 days if share soft delete is on (default).')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.storage/new-azrmstorageshare')
    Status   = 'Untested'
}
