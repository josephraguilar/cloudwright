@{
    Id      = 'azure.storage.enable-entra-kerberos'
    Title   = 'Enable Entra Kerberos on a storage account (FSLogix on Entra-joined hosts)'
    Summary = 'Lets Entra-joined session hosts mount Azure Files with the signed-in user''s identity, no domain controllers. One cmdlet, then a one-time admin consent in the portal.'
    Learn   = @(
        'After this, an Entra app named [Storage Account] <name>.file.core.windows.net appears. A Global Admin must grant admin consent to it (Entra admin center > Enterprise apps > that app > Permissions). Until then, mounts fail with access denied.'
        'The default share permission gives every authenticated user the same share-level right, so you do not have to assign the SMB RBAC role per user. NTFS permissions still apply underneath.'
        'This is the same step the azure repo''s Set-AvdProfileShareAccess.ps1 performs before setting NTFS ACLs.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Storage'); Roles = @('Contributor on the storage account; then a Global Administrator for consent') }
    Prerequisites = @('azure.storage.new-file-share')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'AccountName'; Label = 'Storage account'; Help = 'The storage account. 3 to 24 lowercase letters and digits, globally unique.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzStorageAccount'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'StorageAccountName'; Value = 'StorageAccountName'; Auth = 'Azure' } }
        @{ Name = 'DefaultSharePermission'; Label = 'Default share-level permission for all users'; Help = 'Azure Files has two permission layers: share-level (Azure RBAC roles called Storage File Data SMB Share Reader / Contributor / Elevated Contributor) and NTFS inside the share. This sets one share-level role for every authenticated user so you do not assign the role per user or group; NTFS ACLs still decide what each user can touch. FSLogix needs Contributor at the share level. Elevated Contributor can also change NTFS ACLs from a host. None = assign the SMB roles yourself.'; Type = 'Choice'; Required = $true; Default = 'StorageFileDataSmbShareContributor'
           Options = @(
               @{ Display = 'Contributor (read/write/delete) - FSLogix profiles'; Value = 'StorageFileDataSmbShareContributor' }
               @{ Display = 'Reader'; Value = 'StorageFileDataSmbShareReader' }
               @{ Display = 'Elevated Contributor (can change NTFS ACLs)'; Value = 'StorageFileDataSmbShareElevatedContributor' }
               @{ Display = 'None (assign SMB roles per group yourself)'; Value = 'None' }
           ) }
    )
    Steps = @(
        @{
            Title      = 'Enable Entra Kerberos and set the default share permission'
            What       = 'Flips identity-based authentication to Entra Kerberos and sets the default share-level permission.'
            Why        = 'Entra-joined hosts have no AD identity. Kerberos tickets come from Entra instead.'
            Cmdlet     = 'Set-AzStorageAccount'
            Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}'; Name = '{{AccountName}}'; EnableAzureActiveDirectoryKerberosForFile = '$true'; DefaultSharePermission = '{{DefaultSharePermission}}' }
            ParameterOrder = @('ResourceGroupName', 'Name', 'EnableAzureActiveDirectoryKerberosForFile', 'DefaultSharePermission')
            BoolParameters = @('EnableAzureActiveDirectoryKerberosForFile')
            Fixed          = @('EnableAzureActiveDirectoryKerberosForFile')
        }
        @{
            Title = 'Grant admin consent (portal, one time)'
            What  = 'Prints the app name to look for. Consent itself is a portal click by a Global Administrator.'
            Why   = 'The storage account''s Entra app needs openid, profile, and User.Read delegated permissions consented tenant-wide.'
            Raw   = @('Write-Host "Now: Entra admin center > Enterprise applications > ''[Storage Account] {{AccountName:raw}}.file.core.windows.net'' > Permissions > Grant admin consent"')
        }
    )
    Verify   = @('(Get-AzStorageAccount -Name {{AccountName}} -ResourceGroupName {{ResourceGroupName}}).AzureFilesIdentityBasedAuth | Select-Object DirectoryServiceOptions, DefaultSharePermission')
    Rollback = @('Set-AzStorageAccount -ResourceGroupName {{ResourceGroupName}} -Name {{AccountName}} -EnableAzureActiveDirectoryKerberosForFile $false')
    Docs     = @('https://learn.microsoft.com/azure/storage/files/storage-files-identity-auth-hybrid-identities-enable', 'https://learn.microsoft.com/powershell/module/az.storage/set-azstorageaccount')
    Status   = 'Untested'
}
