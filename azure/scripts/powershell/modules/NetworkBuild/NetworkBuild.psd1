@{
    RootModule        = 'NetworkBuild.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b3d7e0c1-5a4f-4e2b-9c8d-1f0a6b7c8d9e'
    Author            = 'Cloudwright contributors'
    Description       = 'Virtual networks, subnets, NSGs and their rules, public IPs, NAT gateways and site-to-site VPN: list, create, edit. No deletes.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Get-NetVirtualNetworkInfo'
        'Get-NetSubnetInfo'
        'Get-NetSecurityGroupInfo'
        'Test-NetCidr'
        'Test-NetSubnetPrefix'
        'Get-NetFreeSubnetPrefix'
        'New-NetVirtualNetwork'
        'Set-NetVirtualNetworkDnsServer'
        'Add-NetAddressSpace'
        'New-NetSubnet'
        'Set-NetSubnet'
        'New-NetSecurityGroup'
        'Get-NetSecurityRuleInfo'
        'Set-NetSecurityRule'
        'Get-NetPublicIpInfo'
        'New-NetPublicIp'
        'Get-NetNatGatewayInfo'
        'New-NetNatGateway'
        'Set-NetSubnetNatGateway'
        'Get-NetVpnGatewayInfo'
        'Get-NetLocalGatewayInfo'
        'Get-NetVpnConnectionInfo'
        'New-NetVpnGateway'
        'New-NetLocalGateway'
        'New-NetVpnConnection'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('Azure', 'Network', 'VNet', 'Subnet', 'NSG') } }
}
