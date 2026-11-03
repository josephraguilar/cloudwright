// AVD network: one VNet, one session host subnet, one NSG. Composed from
// modules/network. Use this from an environment; use the modules directly when
// you need a different shape.

// ---- 1. Parameters ---------------------------------------------------------
@description('Virtual network name.')
param vnetName string

@description('Azure region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('VNet address space in CIDR.')
param addressPrefix string = '10.10.0.0/16'

@description('Session host subnet name.')
param subnetName string = 'snet-avd'

@description('Session host subnet in CIDR. /24 gives 251 usable addresses.')
param subnetPrefix string = '10.10.1.0/24'

@description('Custom DNS servers. Leave empty for Azure-provided DNS (fine for Entra-only). Set to domain controllers for AD join.')
param dnsServers array = []

@description('Tags applied to every resource.')
param tags object = {}

// ---- 2. Modules ------------------------------------------------------------
//   WHAT   NSG first (the VNet references its ID), then the VNet with one subnet.
//   WHY    AVD needs no inbound rules: hosts dial out on 443 (reverse connect).
//          The NSG exists so there is somewhere to put outbound restrictions later.
module nsg '../modules/network/network-security-group.bicep' = {
  name: 'nsg-${subnetName}'
  params: {
    name: 'nsg-${subnetName}'
    location: location
    tags: tags
  }
}

module vnet '../modules/network/virtual-network.bicep' = {
  name: vnetName
  params: {
    name: vnetName
    location: location
    addressPrefixes: [addressPrefix]
    dnsServers: dnsServers
    subnets: [
      {
        name: subnetName
        addressPrefix: subnetPrefix
        networkSecurityGroupId: nsg.outputs.id
      }
    ]
    tags: tags
  }
}

// ---- 3. Outputs ------------------------------------------------------------
//   WHAT   subnetId is what New-AvdSessionHost.ps1 takes as -SubnetId.
output vnetId string = vnet.outputs.id
output subnetId string = vnet.outputs.subnetIds[subnetName]
output nsgId string = nsg.outputs.id
