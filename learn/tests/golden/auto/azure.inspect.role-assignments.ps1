Get-AzRoleAssignment -ResourceGroupName 'sample-resourcegroupname' | Sort-Object RoleDefinitionName, DisplayName | Format-Table DisplayName, ObjectType, RoleDefinitionName, Scope -AutoSize
