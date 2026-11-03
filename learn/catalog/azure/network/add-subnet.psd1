@{
    Id      = 'azure.network.add-subnet'
    Title   = 'Add a subnet to an existing virtual network'
    Summary = 'Carves another range out of the VNet address space. Subnets are how you separate tiers (hosts, management, private endpoints) and attach different NSGs.'
    Learn   = @(
        'The new range must be inside the VNet address space and not overlap an existing subnet.'
        'Azure reserves the first four and the last address of every subnet. A /29 gives you 3 usable.'
        'Some services want a dedicated subnet with a delegation (Bastion wants AzureBastionSubnet, a /26 or larger).'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Network'); Roles = @('Network Contributor on the resource group') }
    Prerequisites = @('azure.network.new-vnet')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'VNetName'; Label = 'Virtual network'; Help = 'The virtual network. Subnets live inside it; NICs attach to subnets.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzVirtualNetwork'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'SubnetName'; Label = 'New subnet name'; Help = 'The subnet inside the VNet. NICs, VMs, and session hosts are placed in a subnet.'; Type = 'String'; Required = $true; Example = 'snet-mgmt' }
        @{ Name = 'SubnetPrefix'; Label = 'New subnet range (CIDR)'; Help = 'A slice of the VNet range in CIDR notation. /24 = 256 addresses, of which Azure reserves 5 (network, broadcast, and 3 for its own use), leaving 251 for NICs. Subnets cannot overlap each other and cannot be resized while anything is in them.'; Type = 'String'; Required = $true; Example = '10.10.2.0/24'; Pattern = '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$' }
    )
    Steps = @(
        @{
            Title = 'Add the subnet and save the VNet'
            What  = 'Appends a subnet config to the VNet in memory and writes it back.'
            Why   = 'Same get/modify/set pattern as every subnet change.'
            Raw   = @('Get-AzVirtualNetwork -Name {{VNetName}} -ResourceGroupName {{ResourceGroupName}} | Add-AzVirtualNetworkSubnetConfig -Name {{SubnetName}} -AddressPrefix {{SubnetPrefix}} | Set-AzVirtualNetwork')
        }
    )
    Verify   = @('(Get-AzVirtualNetwork -Name {{VNetName}} -ResourceGroupName {{ResourceGroupName}}).Subnets | Format-Table Name, AddressPrefix')
    Rollback = @('Get-AzVirtualNetwork -Name {{VNetName}} -ResourceGroupName {{ResourceGroupName}} | Remove-AzVirtualNetworkSubnetConfig -Name {{SubnetName}} | Set-AzVirtualNetwork    # Fails if anything is attached.')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.network/add-azvirtualnetworksubnetconfig')
    Status   = 'Untested'
}
