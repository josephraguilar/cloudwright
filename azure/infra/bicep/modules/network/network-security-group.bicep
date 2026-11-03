// One network security group.

// ---- 1. Parameters ---------------------------------------------------------
//   WHAT   Name, location, optional rules.
//   WHY    Rules default to none. The built-in defaults (allow VNet and load
//          balancer inbound, deny other inbound, allow all outbound) are what an
//          AVD subnet needs; AVD is outbound-only via reverse connect.
@description('NSG name.')
param name string

@description('Azure region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Security rules. Each entry is a full securityRules item (name + properties). Empty = defaults only.')
param securityRules array = []

@description('Tags applied to the resource.')
param tags object = {}

// ---- 2. Resource -----------------------------------------------------------
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    securityRules: securityRules
  }
}

// ---- 3. Outputs ------------------------------------------------------------
output id string = nsg.id
output name string = nsg.name
