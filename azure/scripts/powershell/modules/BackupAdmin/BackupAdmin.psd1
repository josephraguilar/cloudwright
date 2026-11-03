@{
    RootModule        = 'BackupAdmin.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'e1b05f8a-6d27-4c39-9a14-b8f3e2c7d065'
    Author            = 'Cloudwright contributors'
    Description       = 'Azure Backup for VMs and file shares: vaults, protected items, jobs, recovery points, back up now, protect, restore to a new place, daily policies. No deletes, no overwrite restores.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Get-BackupVaultInfo'
        'Get-BackupItemInfo'
        'Get-BackupItemObject'
        'Get-BackupRecoveryPointInfo'
        'Get-BackupJobInfo'
        'Get-BackupPolicyInfo'
        'New-BackupVault'
        'New-BackupDailyPolicy'
        'Set-BackupPolicySchedule'
        'Enable-BackupVm'
        'Enable-BackupFileShare'
        'Start-BackupItemNow'
        'Restore-BackupVmToNew'
        'Restore-BackupFileShareItem'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('Azure', 'Backup', 'RecoveryServices', 'Restore') } }
}
