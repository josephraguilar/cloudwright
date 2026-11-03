@{
    Id      = 'azure.storage.new-blob-container'
    Title   = 'Create a blob container'
    Summary = 'A container is a folder-like namespace for blobs. Private by default here; anonymous access is off at the account level too.'
    Learn   = @(
        'PublicAccess None means every read needs a token, key, or RBAC. Keep it that way unless you are hosting a public website.'
        'Grant people Storage Blob Data Contributor on the container or account instead of handing out keys.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Storage'); Roles = @('Contributor on the storage account') }
    Prerequisites = @('azure.storage.new-storage-account')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'AccountName'; Label = 'Storage account'; Help = 'The storage account. 3 to 24 lowercase letters and digits, globally unique.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzStorageAccount'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'StorageAccountName'; Value = 'StorageAccountName'; Auth = 'Azure' } }
        @{ Name = 'ContainerName'; Label = 'Container name (lowercase)'; Help = 'The blob container name, lowercase.'; Type = 'String'; Required = $true; Example = 'scripts'; Pattern = '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' }
        @{ Name = 'PublicAccess'; Label = 'Anonymous access'; Help = 'Anonymous access level for this container. None = every read needs a SAS token, key, or RBAC (private). Blob = anyone with a blob URL can read that blob but cannot list the container. Container = anyone can list and read everything. Only works at all if the account allows public access.'; Type = 'Choice'; Required = $true; Default = 'None'; Options = @(@{ Display = 'None (private)'; Value = 'None' }, @{ Display = 'Blob (anonymous read per blob)'; Value = 'Blob' }, @{ Display = 'Container (anonymous list and read)'; Value = 'Container' }) }
    )
    Steps = @(
        @{
            Title      = 'Create the container'
            What       = 'Creates a private container through the management plane.'
            Why        = 'No storage key needed.'
            Cmdlet     = 'New-AzRmStorageContainer'
            Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}'; StorageAccountName = '{{AccountName}}'; Name = '{{ContainerName}}'; PublicAccess = '{{PublicAccess}}' }
            ParameterOrder = @('ResourceGroupName', 'StorageAccountName', 'Name', 'PublicAccess')
        }
    )
    Verify   = @('Get-AzRmStorageContainer -ResourceGroupName {{ResourceGroupName}} -StorageAccountName {{AccountName}} -Name {{ContainerName}} | Select-Object Name, PublicAccess')
    Rollback = @('Remove-AzRmStorageContainer -ResourceGroupName {{ResourceGroupName}} -StorageAccountName {{AccountName}} -Name {{ContainerName}} -Force')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.storage/new-azrmstoragecontainer')
    Status   = 'Untested'
}
