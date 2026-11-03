@{
    Id      = 'path.azure.rg-and-network'
    Title   = 'Resource group, then a virtual network inside it'
    Summary = 'The first two steps of almost any Azure build, as one script with two regions. Shows how the group name flows into the network.'
    Tasks   = @('azure.create.resource-group', 'azure.network.new-vnet')
    Share   = @{ ResourceGroupName = 'Name' }    # the VNet task's ResourceGroupName comes from the RG task's Name
}
