// One virtual network with its subnets declared inline.

// ---- 1. Parameters ---------------------------------------------------------
//   WHAT   Address space, DNS, and an array of subnets.
//   WHY    Subnets are a parameter of the VNet, not their own module, on purpose.
//          A VNet PUT that omits subnets removes the ones that exist, so a VNet
//          redeployed without its subnets inline would delete them. Keeping them
//          here means every redeploy is safe.
//   GOTCHA Each subnet item: { name, addressPrefix, networkSecurityGroupId? }.
@description('VNet name.')
param name string

@description('Azure region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Address spaces in CIDR.')
param addressPrefixes array

@description('Custom DNS servers. Empty = Azure-provided DNS.')
param dnsServers array = []

@description('Subnets: array of { name: string, addressPrefix: string, networkSecurityGroupId: string (optional) }.')
param subnets array

@description('Tags applied to the resource.')
param tags object = {}

// ---- 2. Resource -----------------------------------------------------------
//   WHAT   The VNet. dhcpOptions is omitted entirely when dnsServers is empty.
//   WHY    An empty dnsServers array would mean "no DNS", not "Azure DNS".
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: addressPrefixes
    }
    dhcpOptions: empty(dnsServers) ? null : {
      dnsServers: dnsServers
    }
    subnets: [for s in subnets: {
      name: s.name
      properties: union(
        { addressPrefix: s.addressPrefix },
        empty(s.?networkSecurityGroupId ?? '') ? {} : { networkSecurityGroup: { id: s.networkSecurityGroupId } }
      )
    }]
  }
}

// ---- 3. Outputs ------------------------------------------------------------
//   WHAT   The VNet ID and a map of subnet name to subnet ID.
//   WHY    Callers look up the subnet they need by name: outputs.subnetIds['snet-avd'].
output id string = vnet.id
output name string = vnet.name
output subnetIds object = toObject(subnets, s => s.name, s => resourceId('Microsoft.Network/virtualNetworks/subnets', name, s.name))
