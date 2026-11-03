(New-AzWvdRegistrationInfo -ResourceGroupName 'sample-resourcegroupname' -HostPoolName 'sample-hostpoolname' -ExpirationTime (Get-Date).AddHours(24)).Token
