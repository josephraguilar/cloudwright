// Dev environment. Composes modules from ../../modules.

// ---- 1. Scope and parameters -----------------------------------------------
//   WHAT   targetScope says this deploys into an existing resource group.
//          Parameters here are the ones that differ per environment.
//   WHY    Keeping scope at resourceGroup means a mistake can only affect one
//          group. Subscription-scope templates can create groups anywhere.
targetScope = 'resourceGroup'

@description('Environment label used in names and tags.')
param environment string = 'dev'

@description('Azure region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Globally unique storage account name.')
param storageAccountName string

// ---- 2. Shared values ------------------------------------------------------
//   WHAT   Tags every resource in this environment gets.
//   WHY    Defined once so modules stay consistent. Tags are how you find and
//          cost-report things later.
var tags = {
  environment: environment
  managedBy: 'bicep'
}

// ---- 3. Modules ------------------------------------------------------------
//   WHAT   One block per module. name: is the deployment name shown in the portal.
//   WHY    Environments never declare resources inline. They compose modules,
//          so every resource type is defined exactly once in the repo.
module storage '../../modules/storage/storage-account.bicep' = {
  name: 'storage-${environment}'
  params: {
    name: storageAccountName
    location: location
    tags: tags
  }
}

// ---- 4. Outputs ------------------------------------------------------------
//   WHAT   Surface the IDs a script or pipeline would need after deploying.
//   WHY    Scripts can read these with az deployment group show, so they never
//          have to guess resource names.
output storageAccountId string = storage.outputs.id
output storageAccountName string = storage.outputs.name
