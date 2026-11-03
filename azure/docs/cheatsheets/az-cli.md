# Azure CLI cheat sheet

## Session
```bash
az login                                  # browser login
az login --tenant <tenant-id>             # pick a tenant
az account list --output table            # subscriptions you can see
az account set --subscription <name|id>   # switch active subscription
az account show                           # what am I pointed at
```

## Discover
```bash
az group list --output table
az resource list --resource-group <rg> --output table
az vm list --show-details --output table
az vm list --query "[].{name:name, rg:resourceGroup, state:powerState}" --output table
```

## VMs
```bash
az vm start      --resource-group <rg> --name <vm>
az vm stop       --resource-group <rg> --name <vm>   # stopped but still billed
az vm deallocate --resource-group <rg> --name <vm>   # stopped and compute not billed
az vm restart    --resource-group <rg> --name <vm>
```

## Bicep / deployments
```bash
az bicep install
az bicep build --file main.bicep --stdout > /dev/null              # compile check
az deployment group what-if --resource-group <rg> --template-file main.bicep --parameters main.bicepparam
az deployment group create  --resource-group <rg> --template-file main.bicep --parameters main.bicepparam
az deployment group list --resource-group <rg> --output table
```

## Output and querying
```bash
--output table | json | tsv | yaml
--query "[?location=='eastus'].name"           # JMESPath filter
--query "[0].id" --output tsv                   # single raw value for scripting
```

## Escape hatch
```bash
az rest --method get --url "https://management.azure.com/subscriptions/<sub>/resourceGroups?api-version=2021-04-01"
```
