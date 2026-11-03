@{
    Id      = 'azure.network.set-subnet-nsg'
    Title   = 'Attach an NSG to a subnet'
    Summary = 'Associates a network security group with a subnet so its rules filter every NIC in that subnet.'
    Learn   = @(
        'Subnet properties are changed through the parent VNet: get the VNet, set the subnet config, write the VNet back. There is no Set-AzSubnet.'
        'You must pass the subnet address prefix again even though it is not changing. Omitting it fails.'
        'A subnet can have one NSG. Setting a new one replaces the old.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Network'); Roles = @('Network Contributor on the resource group') }
    Prerequisites = @('azure.network.new-vnet', 'azure.network.new-nsg')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'VNetName'; Label = 'Virtual network'; Help = 'The virtual network. Subnets live inside it; NICs attach to subnets.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzVirtualNetwork'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'SubnetName'; Label = 'Subnet name'; Help = 'The subnet inside the VNet. NICs, VMs, and session hosts are placed in a subnet.'; Type = 'String'; Required = $true; Default = 'snet-hosts' }
        @{ Name = 'SubnetPrefix'; Label = 'Subnet range (unchanged, but required)'; Help = 'A slice of the VNet range in CIDR notation. /24 = 256 addresses, of which Azure reserves 5 (network, broadcast, and 3 for its own use), leaving 251 for NICs. Subnets cannot overlap each other and cannot be resized while anything is in them.'; Type = 'String'; Required = $true; Default = '10.10.1.0/24'; Pattern = '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$' }
        @{ Name = 'NsgName'; Label = 'NSG to attach'; Help = 'A Network Security Group is a stateful layer-4 firewall (IP, port, protocol) attached to a subnet or a NIC. New NSGs allow all traffic inside the VNet and all outbound, and block inbound from the internet, until you add rules. One per subnet is the usual design.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzNetworkSecurityGroup'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
    )
    Steps = @(
        @{
            Title = 'Set the subnet NSG and save the VNet'
            What  = 'Reads the VNet, updates the one subnet, writes the VNet back.'
            Why   = 'Subnets are children of the VNet resource; they are saved together.'
            Raw   = @('Get-AzVirtualNetwork -Name {{VNetName}} -ResourceGroupName {{ResourceGroupName}} | Set-AzVirtualNetworkSubnetConfig -Name {{SubnetName}} -AddressPrefix {{SubnetPrefix}} -NetworkSecurityGroup (Get-AzNetworkSecurityGroup -Name {{NsgName}} -ResourceGroupName {{ResourceGroupName}}) | Set-AzVirtualNetwork')
        }
    )
    Verify   = @('(Get-AzVirtualNetwork -Name {{VNetName}} -ResourceGroupName {{ResourceGroupName}}).Subnets | Select-Object Name, AddressPrefix, @{ n = ''Nsg''; e = { ($_.NetworkSecurityGroup.Id -split ''/'')[-1] } }')
    Rollback = @('Get-AzVirtualNetwork -Name {{VNetName}} -ResourceGroupName {{ResourceGroupName}} | Set-AzVirtualNetworkSubnetConfig -Name {{SubnetName}} -AddressPrefix {{SubnetPrefix}} | Set-AzVirtualNetwork    # Removes the association, keeps the NSG.')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.network/set-azvirtualnetworksubnetconfig')
    Status   = 'Untested'
}
