@{
    Id      = 'azure.network.new-public-ip'
    Title   = 'Create a public IP address'
    Summary = 'A Standard SKU static public IP you can attach to a NIC, load balancer, Bastion, or NAT gateway.'
    Learn   = @(
        'Standard SKU is zone-redundant capable and secure by default (closed until an NSG allows traffic). Basic SKU is retired for new deployments.'
        'Static means the address survives the VM being deallocated. Standard SKU is always static.'
        'A DNS label gives you <label>.<region>.cloudapp.azure.com for free.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Network'); Roles = @('Network Contributor on the resource group') }
    Prerequisites = @('azure.create.resource-group')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'Location'; Label = 'Region'; Help = 'Azure region short name, e.g. eastus2. Resources that talk to each other should share a region.'; Type = 'Choice'; Required = $true; Default = 'eastus2'
           Source = @{ Cmdlet = 'Get-AzLocation'; Display = 'DisplayName'; Value = 'Location'; Auth = 'Azure' } }
        @{ Name = 'PipName'; Label = 'Public IP name'; Help = 'A public IP address is its own Azure resource that you attach to a NIC, load balancer, Bastion, or NAT gateway. Leave blank to keep the NIC private; you then reach the VM through Bastion, a VPN, or AVD.'; Type = 'String'; Required = $true; Example = 'pip-vm-jump' }
        @{ Name = 'Sku'; Label = 'SKU'; Help = 'Standard is the current SKU: always static, zone-capable, and closed until an NSG allows traffic in. Basic is retired for new deployments and open by default. Standard SKU public IPs only attach to Standard SKU load balancers and vice versa.'; Type = 'Choice'; Required = $true; Default = 'Standard'; Options = @(@{ Display = 'Standard (zone-capable, secure by default)'; Value = 'Standard' }, @{ Display = 'Basic (retired for new deployments)'; Value = 'Basic' }) }
        @{ Name = 'AllocationMethod'; Label = 'Allocation'; Help = 'Static means the address is reserved and never changes, even if the resource it is attached to is deallocated. Dynamic (Basic SKU only) hands out an address when attached and may change it after a deallocate. Standard SKU is always static. Use static for anything with a DNS record or firewall rule pointing at it.'; Type = 'Choice'; Required = $true; Default = 'Static'; Options = @('Static', 'Dynamic') }
        @{ Name = 'DnsLabel'; Label = 'DNS label (blank for none, lowercase, unique per region)'; Help = 'Optional hostname Azure registers for you as <label>.<region>.cloudapp.azure.com, so you can RDP or browse by name instead of IP. Lowercase letters, digits, hyphens; must be unique within the region. For your own domain add a CNAME pointing at this name.'; Type = 'String'; Required = $false; Pattern = '^[a-z][a-z0-9-]{1,61}[a-z0-9]$'; Example = 'contoso-jump' }
    )
    Steps = @(
        @{
            Title      = 'Create the public IP'
            What       = 'Allocates a static Standard SKU IPv4 address.'
            Why        = 'Attach it to a NIC or load balancer in a later task.'
            Cmdlet     = 'New-AzPublicIpAddress'
            Parameters = @{ Name = '{{PipName}}'; ResourceGroupName = '{{ResourceGroupName}}'; Location = '{{Location}}'; Sku = '{{Sku}}'; AllocationMethod = '{{AllocationMethod}}'; DomainNameLabel = '{{DnsLabel}}' }
            Output     = 'pip'
        }
    )
    Verify   = @('Get-AzPublicIpAddress -Name {{PipName}} -ResourceGroupName {{ResourceGroupName}} | Select-Object Name, IpAddress, @{ n = ''Fqdn''; e = { $_.DnsSettings.Fqdn } }, @{ n = ''AttachedTo''; e = { $_.IpConfiguration.Id } }')
    Rollback = @('Remove-AzPublicIpAddress -Name {{PipName}} -ResourceGroupName {{ResourceGroupName}} -Force    # Fails while attached.')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.network/new-azpublicipaddress')
    Status   = 'Untested'
}
