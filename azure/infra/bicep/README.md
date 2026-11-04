# Bicep

**Safe release:** these templates are retained design/reference material. Cloudwright does not deploy them. Running the external deployment commands below would change Azure resources and is outside Cloudwright safe mode.

Declarative infrastructure. Bicep compiles to ARM JSON at deploy time, so only `.bicep`
and `.bicepparam` files are committed.

```
modules/        One resource type per file, grouped by area (network/, storage/, compute/).
                No environment names inside. These are the Lego bricks.
compositions/   AVD-shaped bundles: avd-network (VNet + subnet + NSG), avd-profile-storage
                (account + share with Entra Kerberos), avd-image-gallery (gallery + definition).
environments/   One folder per environment. main.bicep picks compositions; main.bicepparam supplies values.
```

Subnets are a parameter of the VNet module, not their own module, on purpose: a VNet
redeployed without its subnets inline deletes them.

## Deploy an environment

```bash
az group create --name rg-learn-dev --location eastus
az deployment group create \
  --resource-group rg-learn-dev \
  --template-file infra/bicep/environments/dev/main.bicep \
  --parameters infra/bicep/environments/dev/main.bicepparam
```

Preview changes first with `az deployment group what-if` using the same arguments.

The PowerShell equivalent is `New-AzResourceGroupDeployment -ResourceGroupName rg-learn-dev -TemplateFile ... -TemplateParameterFile ...`.

## Validate without deploying

```bash
az bicep build --file infra/bicep/environments/dev/main.bicep --stdout > /dev/null
```

## Adding a module

1. Create `modules/<area>/<resource-type>.bicep` with `@description()` on every parameter.
2. Expose `output id string` and `output name string` at minimum.
3. Use it from a composition (`module x '../modules/<area>/<file>.bicep'`) or directly from
   an environment (`module x '../../modules/<area>/<file>.bicep'`).
