Remove-AzVM -Name 'sample-vmname' -ResourceGroupName 'sample-resourcegroupname' -Force
Remove-AzDisk -ResourceGroupName 'sample-resourcegroupname' -DiskName 'sample-osdiskname' -Force
Remove-AzNetworkInterface -Name 'sample-nicname' -ResourceGroupName 'sample-resourcegroupname' -Force
