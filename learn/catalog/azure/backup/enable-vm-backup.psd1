@{
    Id      = 'azure.backup.enable-vm-backup'
    Title   = 'Enable backup for a VM'
    Summary = 'Protects a VM with a vault policy. The first backup runs at the next scheduled time; trigger one on demand with Backup-AzRecoveryServicesBackupItem.'
    Learn   = @(
        'DefaultPolicy is daily at a fixed UTC time with 30-day retention. Make your own policy for anything real: New-AzRecoveryServicesBackupProtectionPolicy.'
        'Pooled AVD hosts are disposable and are not backed up; the profile share is. Personal hosts hold user data and are backed up. The azure repo''s Enable-AvdBackup.ps1 follows that rule.'
        'The VM and vault must be in the same region.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.RecoveryServices'); Roles = @('Backup Contributor on the vault, Virtual Machine Contributor on the VM') }
    Prerequisites = @('azure.backup.new-recovery-vault')
    Fields = @(
        @{ Name = 'VaultResourceGroupName'; Label = 'Vault resource group'; Help = 'The resource group holding the Recovery Services vault (can differ from the VM group).'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'VaultName'; Label = 'Recovery Services vault'; Help = 'A Recovery Services vault is the container Azure Backup stores restore points and policies in. One per region is typical; it must be in the same region as the VMs and shares it protects. It cannot be deleted while it still holds protected items.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzRecoveryServicesVault'; Parameters = @{ ResourceGroupName = '{{VaultResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'ResourceGroupName'; Label = 'VM resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'VMName'; Label = 'Virtual machine'; Help = 'The Azure VM resource name. For Windows it is also the computer name, so keep it to 15 characters.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzVM'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'PolicyName'; Label = 'Backup policy name in the vault'; Help = 'The policy name. Use a numbering convention so policies sort and are easy to reference.'; Type = 'String'; Required = $true; Default = 'DefaultPolicy' }
    )
    Steps = @(
        @{
            Title = 'Enable protection with the policy'
            What  = 'Looks up the vault and policy, then enables backup for the VM.'
            Why   = 'The policy decides schedule and retention; the vault decides where it is stored.'
            Raw   = @('Enable-AzRecoveryServicesBackupProtection -ResourceGroupName {{ResourceGroupName}} -Name {{VMName}} -Policy (Get-AzRecoveryServicesBackupProtectionPolicy -Name {{PolicyName}} -VaultId (Get-AzRecoveryServicesVault -Name {{VaultName}} -ResourceGroupName {{VaultResourceGroupName}}).ID) -VaultId (Get-AzRecoveryServicesVault -Name {{VaultName}} -ResourceGroupName {{VaultResourceGroupName}}).ID')
        }
    )
    Verify   = @('Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId (Get-AzRecoveryServicesVault -Name {{VaultName}} -ResourceGroupName {{VaultResourceGroupName}}).ID | Select-Object Name, ProtectionStatus, ProtectionState, LastBackupStatus, LastBackupTime')
    Rollback = @('Disable-AzRecoveryServicesBackupProtection -Item (Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -Name {{VMName}} -VaultId (Get-AzRecoveryServicesVault -Name {{VaultName}} -ResourceGroupName {{VaultResourceGroupName}}).ID) -VaultId (Get-AzRecoveryServicesVault -Name {{VaultName}} -ResourceGroupName {{VaultResourceGroupName}}).ID -Force    # Add -RemoveRecoveryPoints to also delete the backups.')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.recoveryservices/enable-azrecoveryservicesbackupprotection')
    Status   = 'Untested'
}
