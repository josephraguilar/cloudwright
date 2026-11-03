# Connect-AzAccount -Tenant '00000000-0000-0000-0000-00000000aaaa'
# Set-AzContext -Subscription '00000000-0000-0000-0000-000000000001'

New-AzResourceGroup -Name 'rg-avd-lab' -Location 'eastus2'

New-AzVirtualNetwork -Name 'vnet-avd-lab' -ResourceGroupName 'rg-avd-lab' -Location 'eastus2' -AddressPrefix '10.10.0.0/16' -Subnet (New-AzVirtualNetworkSubnetConfig -Name 'snet-hosts' -AddressPrefix '10.10.1.0/24')

# Verify
Get-AzResourceGroup -Name 'rg-avd-lab' | Format-List ResourceGroupName, Location, ProvisioningState, Tags
Get-AzVirtualNetwork -Name 'vnet-avd-lab' -ResourceGroupName 'rg-avd-lab' | Select-Object Name, Location, @{ n = 'AddressSpace'; e = { $_.AddressSpace.AddressPrefixes } }, @{ n = 'Subnets'; e = { $_.Subnets.Name } }

# Rollback
# Remove-AzVirtualNetwork -Name 'vnet-avd-lab' -ResourceGroupName 'rg-avd-lab' -Force    # Fails if anything is still attached to a subnet. That is a feature.
# Remove-AzResourceGroup -Name 'rg-avd-lab' -Force    # Deletes EVERYTHING in the group. No undo.
