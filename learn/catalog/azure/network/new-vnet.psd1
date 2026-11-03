@{
    Id      = 'azure.network.new-vnet'
    Title   = 'Create a virtual network with one subnet'
    Summary = 'A VNet is a private address space in one region. Subnets carve it up; NICs attach to subnets. Nothing talks to anything without one.'
    Learn   = @(
        'Address spaces cannot overlap with anything you will peer or VPN to later. Pick from the 10.x range and leave room.'
        'The subnet config object is built in memory first, then passed to New-AzVirtualNetwork. Azure reserves 5 addresses per subnet.'
        'An NSG is separate. Create one and associate it in a later task; the VNet works without it, just with no filtering.'
    )
    Requires = @{
        Auth    = 'Azure'
        Modules = @('Az.Network')
        Roles   = @('Network Contributor on the resource group')
    }
    Prerequisites = @('azure.create.resource-group')
    Fields = @(
        @{
            Name     = 'ResourceGroupName'
            Label    = 'Resource group'
            Help     = 'The resource group the VNet lives in. Resources in other groups can still use it.'
            Type     = 'Choice'
            Required = $true
            Source   = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' }
        }
        @{
            Name     = 'Location'
            Label    = 'Region (same as the resource group is simplest)'
            Help     = 'Azure region short name. A VNet is regional; VMs must be in the same region as the VNet.'
            Type     = 'Choice'
            Required = $true
            Default  = 'eastus2'
            Source   = @{ Cmdlet = 'Get-AzLocation'; Display = 'DisplayName'; Value = 'Location'; Auth = 'Azure' }
        }
        @{
            Name     = 'VNetName'
            Label    = 'Virtual network name'
            Help     = 'Name of the VNet resource, unique within the resource group.'
            Type     = 'String'
            Required = $true
            Pattern  = '^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}[A-Za-z0-9_]$'
            Example  = 'vnet-avd-lab'
        }
        @{
            Name     = 'AddressPrefix'
            Label    = 'VNet address space (CIDR)'
            Help     = 'The whole private range of the VNet in CIDR notation: 10.10.0.0/16 means addresses 10.10.0.0 to 10.10.255.255 (65,536). Choose from the RFC 1918 ranges (10.x, 172.16-31.x, 192.168.x) and make sure it does not overlap any network you will peer or VPN with later; overlaps cannot be fixed without rebuilding.'
            Type     = 'String'
            Required = $true
            Default  = '10.10.0.0/16'
            Pattern  = '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$'
        }
        @{
            Name     = 'SubnetName'
            Label    = 'Subnet name'
            Help     = 'Name of the first subnet. VMs and session hosts are placed in a subnet, not directly in the VNet.'
            Type     = 'String'
            Required = $true
            Default  = 'snet-hosts'
        }
        @{
            Name     = 'SubnetPrefix'
            Label    = 'Subnet range (CIDR, inside the VNet space)'
            Help     = 'A slice of the VNet range in CIDR notation. /24 = 256 addresses, of which Azure reserves 5 (network, broadcast, and 3 for its own use), leaving 251 for NICs. Subnets cannot overlap each other and cannot be resized while anything is in them.'
            Type     = 'String'
            Required = $true
            Default  = '10.10.1.0/24'
            Pattern  = '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$'
        }
    )
    Steps = @(
        @{
            Title      = 'Describe the subnet'
            What       = 'Builds a subnet configuration object in memory. Nothing is created in Azure yet.'
            Why        = 'New-AzVirtualNetwork takes subnets as objects, not names, so the subnet is described first.'
            Cmdlet     = 'New-AzVirtualNetworkSubnetConfig'
            Parameters = @{ Name = '{{SubnetName}}'; AddressPrefix = '{{SubnetPrefix}}' }
            Output     = 'subnet'
            WhatIf     = $false
        }
        @{
            Title      = 'Create the virtual network'
            What       = 'Creates the VNet with the subnet from the previous step.'
            Why        = 'The VNet is the unit Azure deploys. The subnet rides along inside it.'
            Cmdlet     = 'New-AzVirtualNetwork'
            Parameters = @{ Name = '{{VNetName}}'; ResourceGroupName = '{{ResourceGroupName}}'; Location = '{{Location}}'; AddressPrefix = '{{AddressPrefix}}'; Subnet = '$subnet' }
            Output     = 'vnet'
        }
        @{
            Title = 'Keep the subnet ID for later'
            OnlyExplained = $true
            What  = 'Reads the subnet resource ID off the VNet object that came back.'
            Why   = 'A VM NIC or an AVD session host needs the subnet ID, not its name. Copy this value into the next task.'
            Raw   = @(
                '$subnetId = ($vnet.Subnets | Where-Object Name -eq {{SubnetName}}).Id'
                '$subnetId'
            )
        }
    )
    Verify   = @('Get-AzVirtualNetwork -Name {{VNetName}} -ResourceGroupName {{ResourceGroupName}} | Select-Object Name, Location, @{ n = ''AddressSpace''; e = { $_.AddressSpace.AddressPrefixes } }, @{ n = ''Subnets''; e = { $_.Subnets.Name } }')
    Rollback = @('Remove-AzVirtualNetwork -Name {{VNetName}} -ResourceGroupName {{ResourceGroupName}} -Force    # Fails if anything is still attached to a subnet. That is a feature.')
    Docs     = @(
        'https://learn.microsoft.com/powershell/module/az.network/new-azvirtualnetwork'
        'https://learn.microsoft.com/powershell/module/az.network/new-azvirtualnetworksubnetconfig'
    )
    Status   = 'Untested'
}
