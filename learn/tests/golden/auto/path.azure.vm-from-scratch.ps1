New-AzResourceGroup -Name 'rg-avd-lab' -Location 'eastus2' -Tag @{ env = 'lab' }

New-AzVirtualNetwork -Name 'vnet-avd-lab' -ResourceGroupName 'rg-avd-lab' -Location 'eastus2' -AddressPrefix '10.10.0.0/16' -Subnet (New-AzVirtualNetworkSubnetConfig -Name 'snet-hosts' -AddressPrefix '10.10.1.0/24')

New-AzNetworkSecurityGroup -Name 'nsg-avd-hosts' -ResourceGroupName 'rg-avd-lab' -Location 'eastus2'

Get-AzNetworkSecurityGroup -Name 'nsg-avd-hosts' -ResourceGroupName 'rg-avd-lab' | Add-AzNetworkSecurityRuleConfig -Name 'Allow-RDP-From-Office' -Priority 100 -Direction 'Inbound' -Access 'Allow' -Protocol 'Tcp' -SourceAddressPrefix '203.0.113.10/32' -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange '3389' | Set-AzNetworkSecurityGroup

Get-AzVirtualNetwork -Name 'vnet-avd-lab' -ResourceGroupName 'rg-avd-lab' | Set-AzVirtualNetworkSubnetConfig -Name 'snet-hosts' -AddressPrefix '10.10.1.0/24' -NetworkSecurityGroup (Get-AzNetworkSecurityGroup -Name 'nsg-avd-hosts' -ResourceGroupName 'rg-avd-lab') | Set-AzVirtualNetwork

New-AzVM -Name 'vm-jump-01' -ResourceGroupName 'rg-avd-lab' -Location 'eastus2' -Image 'Win2022AzureEdition' -Size 'Standard_D2s_v5' -Credential (Get-Credential -Message 'Local administrator') -VirtualNetworkName 'vnet-avd-lab' -SubnetName 'snet-hosts' -SecurityGroupName 'nsg-avd-hosts' -PublicIpAddressName 'pip-vm-jump' -OpenPorts @('3389', '443') -SecurityType 'TrustedLaunch'
