@{
    Id      = 'azure.network.new-nic'
    Title   = 'Create a network interface'
    Summary = 'A NIC sits in a subnet and is what a VM plugs into. Creating it separately lets you reuse it (and keep its private IP) when you rebuild the VM.'
    Learn   = @(
        'New-AzVM can create a NIC for you. Making it yourself is for when you want control: a fixed private IP, an existing public IP, a per-NIC NSG, or reuse on reimage.'
        'The subnet is passed by resource ID, which is why the VNet is looked up inline.'
        'Public IP and NSG are optional. Leave them blank for an internal-only NIC filtered by the subnet NSG.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Network'); Roles = @('Network Contributor on the resource group') }
    Prerequisites = @('azure.network.new-vnet')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'Location'; Label = 'Region'; Help = 'Azure region short name, e.g. eastus2. Resources that talk to each other should share a region.'; Type = 'Choice'; Required = $true; Default = 'eastus2'
           Source = @{ Cmdlet = 'Get-AzLocation'; Display = 'DisplayName'; Value = 'Location'; Auth = 'Azure' } }
        @{ Name = 'NicName'; Label = 'NIC name'; Help = 'The network interface resource. A VM plugs into a NIC; the NIC sits in a subnet.'; Type = 'String'; Required = $true; Example = 'nic-vm-jump' }
        @{ Name = 'VNetName'; Label = 'Virtual network'; Help = 'The virtual network. Subnets live inside it; NICs attach to subnets.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzVirtualNetwork'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'SubnetName'; Label = 'Subnet name'; Help = 'The subnet inside the VNet. NICs, VMs, and session hosts are placed in a subnet.'; Type = 'String'; Required = $true; Default = 'snet-hosts' }
        @{ Name = 'PipName'; Label = 'Public IP to attach (blank for none)'; Help = 'A public IP address is its own Azure resource that you attach to a NIC, load balancer, Bastion, or NAT gateway. Leave blank to keep the NIC private; you then reach the VM through Bastion, a VPN, or AVD.'; Type = 'Choice'; Required = $false
           Source = @{ Cmdlet = 'Get-AzPublicIpAddress'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'IpConfigName'; Label = 'IP configuration name on the NIC'; Help = 'A NIC can hold several IP configurations (one primary plus secondaries), each with its own private IP and optional public IP. Azure names the one it creates ipconfig1; you only change this if you created the NIC with a different name.'; Type = 'String'; Required = $true; Default = 'ipconfig1' }
    )
    Steps = @(
        @{
            Title = 'Create the NIC in the subnet'
            What  = 'Looks up the subnet ID from the VNet and creates the NIC with a dynamic private IP.'
            Why   = 'The VM task takes the NIC by name.'
            Raw   = @('New-AzNetworkInterface -Name {{NicName}} -ResourceGroupName {{ResourceGroupName}} -Location {{Location}} -SubnetId ((Get-AzVirtualNetwork -Name {{VNetName}} -ResourceGroupName {{ResourceGroupName}}).Subnets | Where-Object Name -eq {{SubnetName}}).Id')
        }
        @{
            Title = 'Attach the public IP'
            When  = 'PipName'
            What  = 'Associates the public IP with the NIC''s primary IP configuration and saves the NIC.'
            Why   = 'Done as a second step so the NIC task works with or without a public IP.'
            Raw   = @('Get-AzNetworkInterface -Name {{NicName}} -ResourceGroupName {{ResourceGroupName}} | Set-AzNetworkInterfaceIpConfig -Name {{IpConfigName}} -PublicIpAddress (Get-AzPublicIpAddress -Name {{PipName}} -ResourceGroupName {{ResourceGroupName}}) -Subnet ((Get-AzVirtualNetwork -Name {{VNetName}} -ResourceGroupName {{ResourceGroupName}}).Subnets | Where-Object Name -eq {{SubnetName}}) | Set-AzNetworkInterface')
        }
    )
    Verify   = @('Get-AzNetworkInterface -Name {{NicName}} -ResourceGroupName {{ResourceGroupName}} | Select-Object Name, @{ n = ''PrivateIp''; e = { $_.IpConfigurations[0].PrivateIpAddress } }, @{ n = ''PublicIp''; e = { ($_.IpConfigurations[0].PublicIpAddress.Id -split ''/'')[-1] } }')
    Rollback = @('Remove-AzNetworkInterface -Name {{NicName}} -ResourceGroupName {{ResourceGroupName}} -Force    # Fails while attached to a VM.')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.network/new-aznetworkinterface')
    Status   = 'Untested'
}
