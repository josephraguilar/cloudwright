@{
    Id      = 'path.azure.vm-from-scratch'
    Title   = 'Windows VM from nothing: group, network, NSG, VM'
    Summary = 'Resource group, VNet with a subnet, NSG with one RDP rule from your IP, NSG on the subnet, then the VM. The order every Azure build follows.'
    Tasks   = @('azure.create.resource-group', 'azure.network.new-vnet', 'azure.network.new-nsg', 'azure.network.new-nsg-rule', 'azure.network.set-subnet-nsg', 'azure.compute.new-vm-windows')
    Share   = @{ ResourceGroupName = 'Name' }
}
