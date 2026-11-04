# Runbooks

**Safe release:** the bundled runbook refuses before authentication or host operations. Do not deploy it as an active health job. Previously deployed copies are unaffected by a source update.

Scripts meant to run unattended in an Azure Automation account on a schedule.

They differ from `scripts/powershell/` in one important way: **nobody is logged in.**
The runbook authenticates as the Automation account's system-assigned managed identity:

```powershell
Assert-AzContext -Identity -SubscriptionId $SubscriptionId
```

That identity needs RBAC on the resources the runbook touches (for example
`Desktop Virtualization Contributor` and `Virtual Machine Contributor` on the
host pool's resource group). Grant the minimum.

Other differences:

- No `Read-Host`, no `-Confirm`, no `Connect-AzAccount` without `-Identity`.
- Parameters come from the schedule or a Variable asset, not from a person.
- Output goes to `Write-Output` so it lands in the job log.
- The `AzHelpers` module must be imported into the Automation account as a module
  asset, or zipped and uploaded with the runbook, since the repo path does not exist there.

Deploying a runbook (from a machine that is logged in):

```powershell
Import-AzAutomationRunbook -ResourceGroupName <rg> -AutomationAccountName <account> `
  -Path ./runbooks/Test-AvdHostHealth.ps1 -Type PowerShell -Name Test-AvdHostHealth -Published
```
