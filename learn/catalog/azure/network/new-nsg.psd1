@{
    Id      = 'azure.network.new-nsg'
    Title   = 'Create a network security group'
    Summary = 'An NSG is a stateful packet filter you attach to a subnet or a NIC. New ones allow all outbound and VNet-internal traffic and deny inbound from the internet.'
    Learn   = @(
        'One NSG per subnet is the usual pattern. Per-NIC NSGs are for exceptions.'
        'The default rules (AllowVnetInBound, AllowAzureLoadBalancerInBound, DenyAllInBound, and the outbound set) cannot be deleted, only overridden by lower-numbered rules.'
        'Creating the NSG does nothing until it is associated. That is the next task.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Network'); Roles = @('Network Contributor on the resource group') }
    Prerequisites = @('azure.create.resource-group')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'Location'; Label = 'Region'; Help = 'Azure region short name, e.g. eastus2. Resources that talk to each other should share a region.'; Type = 'Choice'; Required = $true; Default = 'eastus2'
           Source = @{ Cmdlet = 'Get-AzLocation'; Display = 'DisplayName'; Value = 'Location'; Auth = 'Azure' } }
        @{ Name = 'NsgName'; Label = 'NSG name'; Help = 'A Network Security Group is a stateful layer-4 firewall (IP, port, protocol) attached to a subnet or a NIC. New NSGs allow all traffic inside the VNet and all outbound, and block inbound from the internet, until you add rules. One per subnet is the usual design.'; Type = 'String'; Required = $true; Example = 'nsg-avd-hosts'; Pattern = '^[A-Za-z0-9][A-Za-z0-9_.-]{0,78}[A-Za-z0-9_]$' }
    )
    Steps = @(
        @{
            Title      = 'Create the NSG'
            What       = 'Creates an empty NSG with only the default rules.'
            Why        = 'Rules and association come after; the object has to exist first.'
            Cmdlet     = 'New-AzNetworkSecurityGroup'
            Parameters = @{ Name = '{{NsgName}}'; ResourceGroupName = '{{ResourceGroupName}}'; Location = '{{Location}}' }
            Output     = 'nsg'
        }
    )
    Verify   = @('Get-AzNetworkSecurityGroup -Name {{NsgName}} -ResourceGroupName {{ResourceGroupName}} | Select-Object Name, Location, @{ n = ''Rules''; e = { $_.SecurityRules.Name } }')
    Rollback = @('Remove-AzNetworkSecurityGroup -Name {{NsgName}} -ResourceGroupName {{ResourceGroupName}} -Force    # Fails while it is still associated with a subnet or NIC.')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.network/new-aznetworksecuritygroup')
    Status   = 'Untested'
}
