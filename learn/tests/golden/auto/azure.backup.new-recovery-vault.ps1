New-AzRecoveryServicesVault -Name 'rsv-avd-lab' -ResourceGroupName 'sample-resourcegroupname' -Location 'eastus2'
Set-AzRecoveryServicesBackupProperty -Vault (Get-AzRecoveryServicesVault -Name 'rsv-avd-lab' -ResourceGroupName 'sample-resourcegroupname') -BackupStorageRedundancy 'LocallyRedundant'
