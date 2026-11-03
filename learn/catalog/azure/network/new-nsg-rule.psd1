@{
    Id      = 'azure.network.new-nsg-rule'
    Title   = 'Add a rule to a network security group'
    Summary = 'Adds one inbound or outbound rule. Lower priority number wins. Rules are evaluated top down and the first match decides.'
    Learn   = @(
        'NSG rules are edited in memory and written back as a whole: get the NSG, add the rule config, set the NSG. Nothing changes until Set-AzNetworkSecurityGroup runs.'
        'Never open 3389 or 22 to the internet (*). Use your public IP /32, Bastion, or a VPN.'
        'Priorities 100 to 4096. Leave gaps (100, 110, 120) so you can insert later.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.Network'); Roles = @('Network Contributor on the resource group') }
    Prerequisites = @('azure.network.new-nsg')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'NsgName'; Label = 'NSG'; Help = 'A Network Security Group is a stateful layer-4 firewall (IP, port, protocol) attached to a subnet or a NIC. New NSGs allow all traffic inside the VNet and all outbound, and block inbound from the internet, until you add rules. One per subnet is the usual design.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzNetworkSecurityGroup'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'RuleName'; Label = 'Rule name'; Help = 'The NSG rule name, unique within the NSG.'; Type = 'String'; Required = $true; Example = 'Allow-RDP-From-Office' }
        @{ Name = 'Priority'; Label = 'Priority (100-4096, lower wins)'; Help = 'Rule evaluation order within the NSG, 100 to 4096. Rules are checked lowest number first and the first match wins, so a Deny at 100 beats an Allow at 200. The built-in default rules sit at 65000+ and cannot be removed. Leave gaps (100, 110, 120) so you can insert later.'; Type = 'Int'; Required = $true; Default = '100' }
        @{ Name = 'Direction'; Label = 'Direction'; Help = 'Inbound rules filter traffic arriving at the NIC or subnet (from the internet, other subnets, or the same subnet). Outbound rules filter traffic leaving. NSGs are stateful: a reply to allowed traffic is allowed automatically, so you do not need matching rules in both directions.'; Type = 'Choice'; Required = $true; Default = 'Inbound'; Options = @('Inbound', 'Outbound') }
        @{ Name = 'Access'; Label = 'Action'; Help = 'Allow or Deny matching traffic.'; Type = 'Choice'; Required = $true; Default = 'Allow'; Options = @('Allow', 'Deny') }
        @{ Name = 'Protocol'; Label = 'Protocol'; Help = 'Transport protocol to match. Tcp covers RDP, SSH, HTTPS, SMB. Udp covers DNS and some VPNs. Icmp is ping. * matches all of them.'; Type = 'Choice'; Required = $true; Default = 'Tcp'; Options = @('Tcp', 'Udp', 'Icmp', '*') }
        @{ Name = 'SourceAddressPrefix'; Label = 'Source (CIDR, tag like VirtualNetwork, or *)'; Help = 'Where matching traffic may come from. A CIDR (203.0.113.10/32 = exactly one address), a service tag (a name Azure keeps updated for a group of IPs: VirtualNetwork = everything in this VNet and peered ones, Internet = outside Azure, AzureLoadBalancer = health probes, AzureCloud = all Azure public IPs), or * for anything.'; Type = 'String'; Required = $true; Example = '203.0.113.10/32' }
        @{ Name = 'DestinationPortRange'; Label = 'Destination port(s)'; Help = 'The port on the destination side. Common values: 3389 RDP, 22 SSH, 443 HTTPS, 445 SMB (Azure Files). A range is 1000-2000; several values are comma separated.'; Type = 'String'; Required = $true; Example = '3389' }
        @{ Name = 'DestinationAddressPrefix'; Label = 'Destination (CIDR, tag, or *)'; Help = 'Where matching traffic may go. A CIDR, a service tag (VirtualNetwork, Internet, Storage, Sql, ...), or * for anything. For an inbound rule on a subnet this is usually * or the subnet range.'; Type = 'String'; Required = $true; Default = '*' }
        @{ Name = 'SourcePortRange'; Label = 'Source port(s) (* because clients use random ports)'; Help = 'The port on the sending side. Clients pick a random high port for every connection, so filtering on it almost never makes sense; * is correct for nearly every rule.'; Type = 'String'; Required = $true; Default = '*' }
    )
    Steps = @(
        @{
            Title = 'Add the rule and save the NSG'
            What  = 'Gets the NSG, appends a rule config, writes the NSG back.'
            Why   = 'That is the only way NSG rules are edited. SourcePortRange is * because clients use random source ports.'
            Raw   = @('Get-AzNetworkSecurityGroup -Name {{NsgName}} -ResourceGroupName {{ResourceGroupName}} | Add-AzNetworkSecurityRuleConfig -Name {{RuleName}} -Priority {{Priority}} -Direction {{Direction}} -Access {{Access}} -Protocol {{Protocol}} -SourceAddressPrefix {{SourceAddressPrefix}} -SourcePortRange {{SourcePortRange}} -DestinationAddressPrefix {{DestinationAddressPrefix}} -DestinationPortRange {{DestinationPortRange}} | Set-AzNetworkSecurityGroup')
        }
    )
    Verify   = @('(Get-AzNetworkSecurityGroup -Name {{NsgName}} -ResourceGroupName {{ResourceGroupName}}).SecurityRules | Sort-Object Priority | Format-Table Name, Priority, Direction, Access, Protocol, SourceAddressPrefix, DestinationPortRange -AutoSize')
    Rollback = @('Get-AzNetworkSecurityGroup -Name {{NsgName}} -ResourceGroupName {{ResourceGroupName}} | Remove-AzNetworkSecurityRuleConfig -Name {{RuleName}} | Set-AzNetworkSecurityGroup')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.network/add-aznetworksecurityruleconfig')
    Status   = 'Untested'
}
