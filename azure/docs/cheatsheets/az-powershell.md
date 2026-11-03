# Az PowerShell cheat sheet

## Session
```powershell
Install-Module Az -Scope CurrentUser
Connect-AzAccount                               # browser login
Connect-AzAccount -Tenant <tenant-id>
Get-AzSubscription | Format-Table Name, Id, State
Set-AzContext -Subscription <name|id>
Get-AzContext
```

## Discover
```powershell
Get-AzResourceGroup | Format-Table ResourceGroupName, Location
Get-AzResource -ResourceGroupName <rg> | Format-Table Name, ResourceType
Get-AzVM -Status | Select-Object Name, ResourceGroupName, PowerState
```

## VMs
```powershell
Start-AzVM -ResourceGroupName <rg> -Name <vm>
Stop-AzVM  -ResourceGroupName <rg> -Name <vm> -Force          # deallocates by default
Stop-AzVM  -ResourceGroupName <rg> -Name <vm> -StayProvisioned # stopped but still billed
Restart-AzVM -ResourceGroupName <rg> -Name <vm>
```

## Bicep / deployments
```powershell
New-AzResourceGroup -Name <rg> -Location eastus
New-AzResourceGroupDeployment -ResourceGroupName <rg> -TemplateFile main.bicep -TemplateParameterFile main.bicepparam -WhatIf
New-AzResourceGroupDeployment -ResourceGroupName <rg> -TemplateFile main.bicep -TemplateParameterFile main.bicepparam
Get-AzResourceGroupDeployment -ResourceGroupName <rg>
```

## Escape hatch
```powershell
Invoke-AzRestMethod -Method GET -Path "/subscriptions/<sub>/resourceGroups?api-version=2021-04-01"
```

## Habits
- Add `-WhatIf` to anything that changes state. Add `-Verbose` to see what a script is doing.
- `Get-Command -Module Az.Compute -Verb Get` to explore a module.
- `Get-Help <cmdlet> -Examples` beats guessing parameters.
