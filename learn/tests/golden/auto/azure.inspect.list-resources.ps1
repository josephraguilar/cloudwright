Get-AzResource -ResourceGroupName 'sample-resourcegroupname' | Sort-Object ResourceType, Name | Format-Table Name, ResourceType, Location -AutoSize
