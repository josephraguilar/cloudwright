Get-AzResource -ResourceGroupName 'sample-resourcegroupname' | Format-Table Name, ResourceType -AutoSize
Remove-AzResourceGroup -Name 'sample-resourcegroupname' -Force
