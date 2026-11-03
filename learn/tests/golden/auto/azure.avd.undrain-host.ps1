Update-AzWvdSessionHost -ResourceGroupName 'sample-resourcegroupname' -HostPoolName 'sample-hostpoolname' -Name ('sample-sessionhostname' -split '/')[-1] -AllowNewSession:$true
