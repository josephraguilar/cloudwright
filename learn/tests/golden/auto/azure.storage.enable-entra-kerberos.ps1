Set-AzStorageAccount -ResourceGroupName 'sample-resourcegroupname' -Name 'sample-accountname' -EnableAzureActiveDirectoryKerberosForFile $true -DefaultSharePermission 'StorageFileDataSmbShareContributor'
Write-Host "Now: Entra admin center > Enterprise applications > '[Storage Account] sample-accountname.file.core.windows.net' > Permissions > Grant admin consent"
