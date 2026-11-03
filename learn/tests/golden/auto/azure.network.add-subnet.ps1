Get-AzVirtualNetwork -Name 'sample-vnetname' -ResourceGroupName 'sample-resourcegroupname' | Add-AzVirtualNetworkSubnetConfig -Name 'snet-mgmt' -AddressPrefix '10.10.2.0/24' | Set-AzVirtualNetwork
