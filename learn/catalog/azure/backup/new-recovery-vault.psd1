@{
    Id      = 'azure.backup.new-recovery-vault'
    Title   = 'Create a Recovery Services vault'
    Summary = 'The container for Azure Backup policies and restore points. One per region; it must be in the same region as what it protects.'
    Learn   = @(
        'Storage redundancy (LRS/ZRS/GRS) can only be changed before the first item is protected. Decide now.'
        'Soft delete is on by default: deleted backup data is kept 14 days. Leave it on.'
        'A vault cannot be deleted while it holds protected items or recovery points. That is deliberate.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.RecoveryServices'); Roles = @('Contributor on the resource group') }
    Prerequisites = @('azure.create.resource-group')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'Location'; Label = 'Region (same as the VMs and shares to protect)'; Help = 'Azure region short name, e.g. eastus2. Resources that talk to each other should share a region.'; Type = 'Choice'; Required = $true; Default = 'eastus2'
           Source = @{ Cmdlet = 'Get-AzLocation'; Display = 'DisplayName'; Value = 'Location'; Auth = 'Azure' } }
        @{ Name = 'VaultName'; Label = 'Vault name'; Help = 'A Recovery Services vault is the container Azure Backup stores restore points and policies in. One per region is typical; it must be in the same region as the VMs and shares it protects. It cannot be deleted while it still holds protected items.'; Type = 'String'; Required = $true; Example = 'rsv-avd-lab'; Pattern = '^[A-Za-z][A-Za-z0-9-]{1,48}$' }
        @{ Name = 'Redundancy'; Label = 'Backup storage redundancy'; Help = 'How many copies of backup data Azure keeps and where. LocallyRedundant = 3 copies in one datacentre (cheapest, survives hardware failure). ZoneRedundant = copies across 3 availability zones (survives a datacentre outage). GeoRedundant = copies in the paired region too (survives a regional disaster, lets you restore elsewhere). Locked once the first item is protected, so decide now.'; Type = 'Choice'; Required = $true; Default = 'LocallyRedundant'; Options = @('LocallyRedundant', 'ZoneRedundant', 'GeoRedundant') }
    )
    Steps = @(
        @{
            Title      = 'Create the vault'
            What       = 'Creates an empty Recovery Services vault.'
            Why        = 'Policies and protected items attach to it next.'
            Cmdlet     = 'New-AzRecoveryServicesVault'
            Parameters = @{ Name = '{{VaultName}}'; ResourceGroupName = '{{ResourceGroupName}}'; Location = '{{Location}}' }
        }
        @{
            Title = 'Set storage redundancy'
            What  = 'Sets LRS/ZRS/GRS for backup data while the vault is still empty.'
            Why   = 'Locked once the first item is protected.'
            Raw   = @('Set-AzRecoveryServicesBackupProperty -Vault (Get-AzRecoveryServicesVault -Name {{VaultName}} -ResourceGroupName {{ResourceGroupName}}) -BackupStorageRedundancy {{Redundancy}}')
        }
    )
    Verify   = @('Get-AzRecoveryServicesVault -Name {{VaultName}} -ResourceGroupName {{ResourceGroupName}} | Get-AzRecoveryServicesBackupProperty | Select-Object BackupStorageRedundancy')
    Rollback = @('Remove-AzRecoveryServicesVault -Vault (Get-AzRecoveryServicesVault -Name {{VaultName}} -ResourceGroupName {{ResourceGroupName}})    # Only works while empty.')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.recoveryservices/new-azrecoveryservicesvault')
    Status   = 'Untested'
}
