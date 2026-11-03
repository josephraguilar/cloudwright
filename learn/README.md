# ms-scripter

Part of [Cloudwright](../README.md). After installing the root launcher, run
`cloudwright learn` or `cloudwright learn -Contoso -Console`.
Direct-script examples below run from this `learn/` directory.

A PowerShell GUI that **builds** Microsoft admin commands (Azure, Microsoft 365, Entra ID)
for you to read, copy, and run in another window. It never runs them itself.

Pick a task in the tree, fill in the drop-downs, press Generate, and you get the one-liners:

```powershell
New-AzResourceGroup -Name 'rg-avd-lab' -Location 'eastus2' -Tag @{ env = 'lab' }
```

```powershell
New-AzVirtualNetwork -Name 'vnet-avd-lab' -ResourceGroupName 'rg-avd-lab' -Location 'eastus2' -AddressPrefix '10.10.0.0/16' -Subnet (New-AzVirtualNetworkSubnetConfig -Name 'snet-hosts' -AddressPrefix '10.10.1.0/24')
```

No variables, no comments, no splatting. One line you can paste on its own.

Two reasons it exists:

1. **Learning.** Every generated script explains each step: what the cmdlet does, why it
   comes after the previous one, how to verify it, how to undo it. You run the steps one
   region at a time and see what each one changes.
2. **Safety.** Before anything touches a tenant, the exact commands are on screen. Pick a
   security group from a list instead of typing its ID; see the `-Name` you are about to
   create; notice the wrong subscription in region 0.

It is the read-only learning component of Cloudwright, alongside
[Azure/AVD](../azure/README.md) and [Microsoft 365](../m365/README.md).

## Run it

```powershell
.\Start-MsScripter.ps1             # opens the window (Windows)
.\Start-MsScripter.ps1 -Console    # text menu instead (and the fallback on macOS/Linux)
```

Works on Windows PowerShell 5.1 and PowerShell 7. Nothing is required beyond that. Optional:

| Install | Gives you |
| ------- | --------- |
| `Install-Module Az -Scope CurrentUser` | Pick lists for subscriptions, regions, resource groups, VNets, VM sizes |
| `Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Groups, Microsoft.Graph.Users -Scope CurrentUser` | Pick lists for users, groups, licenses (read-only scopes only) |
| `Install-Module Microsoft.PowerShell.ConsoleGuiTools -Scope CurrentUser` (PS 7.2+) | A filterable grid picker instead of a numbered list |

Signing in is optional. Without it, every pick list becomes a typed value and the tool
still generates the same script.

## What it looks like

```
+------------------------------------------------------------------------------------+
| [Sign in: Azure] [Sign in: Graph (read-only)] [Subscription v] [Refresh] [Contoso] |
+----------------------+-------------------------------------------------------------+
| [ search tasks...  x]| Create a virtual network with one subnet                    |
| v Azure              |                                                             |
|   > Context          | A VNet is a private address space in one region ...         |
|   v Create           |                                                             |
|     Create a resource| Resource group *      [rg-avd-lab            v]  Open the   |
|   v Network          | Region *              [eastus2               v]  list to    |
|     Create a virtual | Virtual network name* [vnet-avd-lab           ]  load live  |
| > Microsoft 365      | VNet address space *  [10.10.0.0/16           ]  values...  |
| > Build paths        | Subnet name *         [snet-hosts             ]             |
|                      | Subnet range *        [10.10.1.0/24           ]             |
|                      +-------------------------------------------------------------+
|                      | [Generate] [Add to script] [ ] Explain steps [ ] Sign-in    |
|                      |   lines [ ] Verify [ ] Rollback        [Copy] [Save] [Clear]|
|                      | New-AzVirtualNetwork -Name 'vnet-avd-lab' -ResourceGroupNa.. |
|                      |                                                             |
+----------------------+-------------------------------------------------------------+
```

- **Search** above the tree filters by task name, section, or the cmdlet it generates
  (type `New-MgUser` or `nsg`). Ctrl+F focuses it, Esc clears.
- **Drop-downs** load their list the first time you open them, using a read-only lookup
  (`Get-AzResourceGroup`, `Get-AzLocation`, `Get-MgGroup`, ...) if you are signed in.
  Signed out, or if the lookup fails, just type the value.
- **Generate** replaces the output; **Add to script** appends, so you can build a
  multi-step script from several tasks. Fields you already answered keep their values.
- **Explain steps** switches to the long form: header, `WHAT`/`WHY` comments per step,
  splatted parameters, verify and rollback regions. Off by default.
- **Build paths** are pre-ordered chains of tasks (for example resource group, then VNet)
  that ask shared values once.

`tests/golden/` has complete examples of both output styles.

## Contoso mode (offline study)

Press **Contoso mode** in the toolbar, or start with `.\Start-MsScripter.ps1 -Contoso`.
Nothing connects to anything. Every drop-down is filled from a fictional tenant
(`contoso.com`: Adele Vance and friends, groups like "AVD Users - Lab", subscriptions,
resource groups, host pools, mailboxes, licence SKUs), text fields pre-fill with their
example values, and the window tints so you know you are offline. Pick a task, read the
fields, press Generate, read the command. Good for learning the cmdlets, for training, and
for screenshots. The sample tenant lives in `catalog/_contoso.psd1`; a test makes sure every
drop-down in the catalog has rows there.

## The one rule

ms-scripter executes exactly two kinds of thing: the optional sign-ins, and read-only
`Get-*` lookups that fill pick lists. A test fails the build if the engine contains
`Invoke-Expression` or friends, or if any catalog lookup uses a non-read verb. Generated
scripts go to the screen, your clipboard, or `out/` (gitignored). See
`docs/architecture.md`.

## Layout

```
Start-MsScripter.ps1      Entry point: window on Windows, console with -Console
src/MsScripter/           Engine module: catalog loader, validator, generator, window UI, console UI
catalog/                  One .psd1 per task. Data only. Folder = menu section.
  azure/  m365/  entra/  paths/
tests/                    Pester: catalog validity, golden-file generator tests, read-only guard
tests/golden/             Reviewed example output, one per test case
docs/                     architecture.md, authoring-tasks.md, TASKS.md, prior-art.md
out/                      Saved scripts. Gitignored.
```

## Catalog

Status is per task: `Untested` means nobody has run the generated script against a real
tenant yet. Only a person flips it to `Tested <date>`, in the task file.

<!-- catalog:start (generated by tools/Update-ReadmeCatalog.ps1) -->
| Section | Task | Id | Status |
| ------- | ---- | -- | ------ |
| Azure / AVD | Build an Entra-joined session host | `azure.avd.new-session-host` | Untested |
| Azure / AVD | Create a workspace and register the app group | `azure.avd.new-workspace` | Untested |
| Azure / AVD | Create an application group (desktop or RemoteApp) | `azure.avd.new-application-group` | Untested |
| Azure / AVD | Create an AVD host pool | `azure.avd.new-host-pool` | Untested |
| Azure / AVD | Drain a session host (block new sessions) | `azure.avd.drain-host` | Untested |
| Azure / AVD | Generate a host pool registration token | `azure.avd.new-registration-token` | Untested |
| Azure / AVD | Grant a group access to the desktop | `azure.avd.grant-desktop-access` | Untested |
| Azure / AVD | Log off every user on a session host | `azure.avd.logoff-users` | Untested |
| Azure / AVD | Send a message to every user on a session host | `azure.avd.message-users` | Untested |
| Azure / AVD | Un-drain a session host (allow new sessions) | `azure.avd.undrain-host` | Untested |
| Azure / Backup | Create a Recovery Services vault | `azure.backup.new-recovery-vault` | Untested |
| Azure / Backup | Enable backup for a VM | `azure.backup.enable-vm-backup` | Untested |
| Azure / Compute | Add an empty data disk to a VM | `azure.compute.new-data-disk` | Untested |
| Azure / Compute | Create a Linux virtual machine (SSH key) | `azure.compute.new-vm-linux` | Untested |
| Azure / Compute | Create a Windows virtual machine | `azure.compute.new-vm-windows` | Untested |
| Azure / Compute | Enable Entra ID sign-in on a Windows VM | `azure.compute.add-entra-login-extension` | Untested |
| Azure / Compute | Resize a virtual machine | `azure.compute.resize-vm` | Untested |
| Azure / Compute | Restart a virtual machine | `azure.compute.restart-vm` | Untested |
| Azure / Compute | Run a PowerShell command inside a VM | `azure.compute.run-command` | Untested |
| Azure / Compute | Snapshot a managed disk | `azure.compute.snapshot-disk` | Untested |
| Azure / Compute | Start a virtual machine | `azure.compute.start-vm` | Untested |
| Azure / Compute | Stop (deallocate) a virtual machine | `azure.compute.stop-vm` | Untested |
| Azure / Context | Register resource providers | `azure.context.register-providers` | Untested |
| Azure / Context | Sign in and select a subscription | `azure.context.set-subscription` | Untested |
| Azure / Create | Create a resource group | `azure.create.resource-group` | Untested |
| Azure / Delete | Delete a resource group and everything in it | `azure.delete.remove-resource-group` | Untested |
| Azure / Delete | Delete a VM and its OS disk and NIC | `azure.delete.remove-vm-with-disks` | Untested |
| Azure / Identity | Create a user-assigned managed identity | `azure.identity.new-user-assigned-identity` | Untested |
| Azure / Identity | Grant a role to a group on a resource group | `azure.identity.new-role-assignment` | Untested |
| Azure / Inspect | List everything in a resource group | `azure.inspect.list-resources` | Untested |
| Azure / Inspect | Show VM power states | `azure.inspect.vm-power-state` | Untested |
| Azure / Inspect | Who has access to a resource group | `azure.inspect.role-assignments` | Untested |
| Azure / Keyvault | Create a Key Vault | `azure.keyvault.new-key-vault` | Untested |
| Azure / Keyvault | Store a secret in Key Vault | `azure.keyvault.set-secret` | Untested |
| Azure / Monitor | Create a Log Analytics workspace | `azure.monitor.new-log-analytics` | Untested |
| Azure / Network | Add a rule to a network security group | `azure.network.new-nsg-rule` | Untested |
| Azure / Network | Add a subnet to an existing virtual network | `azure.network.add-subnet` | Untested |
| Azure / Network | Attach an NSG to a subnet | `azure.network.set-subnet-nsg` | Untested |
| Azure / Network | Create a network interface | `azure.network.new-nic` | Untested |
| Azure / Network | Create a network security group | `azure.network.new-nsg` | Untested |
| Azure / Network | Create a public IP address | `azure.network.new-public-ip` | Untested |
| Azure / Network | Create a virtual network with one subnet | `azure.network.new-vnet` | Untested |
| Azure / Storage | Create a blob container | `azure.storage.new-blob-container` | Untested |
| Azure / Storage | Create a storage account | `azure.storage.new-storage-account` | Untested |
| Azure / Storage | Create an Azure Files share | `azure.storage.new-file-share` | Untested |
| Azure / Storage | Enable Entra Kerberos on a storage account (FSLogix on Entra-joined hosts) | `azure.storage.enable-entra-kerberos` | Untested |
| Build paths | AVD lab, Entra-joined, from nothing | `path.azure.avd-entra-lab` | Path |
| Build paths | Offboard a user: block, forward, convert mailbox, remove licence | `path.m365.offboard-user` | Path |
| Build paths | Onboard a user: create, licence, group, manager | `path.m365.onboard-user` | Path |
| Build paths | Resource group, then a virtual network inside it | `path.azure.rg-and-network` | Path |
| Build paths | Windows VM from nothing: group, network, NSG, VM | `path.azure.vm-from-scratch` | Path |
| Entra ID / Apps | Create an app registration and service principal | `entra.apps.new-app-registration` | Untested |
| Entra ID / Ca | Create a Conditional Access policy requiring MFA (report-only) | `entra.ca.new-policy-report-only` | Untested |
| Entra ID / Ca | Create a trusted IP named location | `entra.ca.new-named-location` | Untested |
| Entra ID / Roles | Assign an Entra admin role (permanent) | `entra.roles.assign-directory-role` | Untested |
| Microsoft 365 / Context | Connect to Microsoft Graph | `m365.context.connect-graph` | Untested |
| Microsoft 365 / Context | Find the Graph permission a cmdlet needs | `m365.context.find-permission` | Untested |
| Microsoft 365 / Exchange | Connect to Exchange Online | `m365.exchange.connect` | Untested |
| Microsoft 365 / Exchange | Convert a user mailbox to shared | `m365.exchange.convert-to-shared` | Untested |
| Microsoft 365 / Exchange | Create a distribution list | `m365.exchange.new-distribution-group` | Untested |
| Microsoft 365 / Exchange | Create a shared mailbox and grant access | `m365.exchange.new-shared-mailbox` | Untested |
| Microsoft 365 / Exchange | Forward a mailbox to another address | `m365.exchange.set-forwarding` | Untested |
| Microsoft 365 / Exchange | Grant a user access to another mailbox | `m365.exchange.add-mailbox-permission` | Untested |
| Microsoft 365 / Exchange | Largest mailboxes report | `m365.exchange.mailbox-report` | Untested |
| Microsoft 365 / Exchange | Put a mailbox on litigation hold | `m365.exchange.set-litigation-hold` | Untested |
| Microsoft 365 / Groups | Add a user to a group | `m365.groups.add-member` | Untested |
| Microsoft 365 / Groups | Add an owner to a group | `m365.groups.add-owner` | Untested |
| Microsoft 365 / Groups | Create a Microsoft 365 group | `m365.groups.new-m365-group` | Untested |
| Microsoft 365 / Groups | Create an Entra security group | `m365.groups.new-security-group` | Untested |
| Microsoft 365 / Groups | List the members of a group | `m365.groups.list-members` | Untested |
| Microsoft 365 / Groups | Make a group dynamic (membership rule) | `m365.groups.set-dynamic-rule` | Untested |
| Microsoft 365 / Groups | Remove a user from a group | `m365.groups.remove-member` | Untested |
| Microsoft 365 / Licenses | Assign a licence to a user | `m365.licenses.assign-license` | Untested |
| Microsoft 365 / Licenses | List licence SKUs and how many are in use | `m365.licenses.list-skus` | Untested |
| Microsoft 365 / Licenses | Remove a licence from a user | `m365.licenses.remove-license` | Untested |
| Microsoft 365 / Users | Block sign-in and revoke sessions | `m365.users.block-sign-in` | Untested |
| Microsoft 365 / Users | Create a user | `m365.users.new-user` | Untested |
| Microsoft 365 / Users | Reset a user's password | `m365.users.reset-password` | Untested |
| Microsoft 365 / Users | Set a user's manager | `m365.users.set-manager` | Untested |
| Microsoft 365 / Users | Update a user's profile fields | `m365.users.set-user-properties` | Untested |
<!-- catalog:end -->

What remains to build, and the order, is in [`docs/TASKS.md`](docs/TASKS.md). How to add one is in
[`docs/authoring-tasks.md`](docs/authoring-tasks.md).

## Rules (same as the azure repo)

1. **Nothing client-specific, ever.** No tenant IDs, subscription IDs, hostnames, resource
   names, or credentials in the repo. Placeholders only. Saved scripts go to `out/`, which
   is gitignored, because they will contain your names.
2. **Logic lives in the module.** `Start-MsScripter.ps1` imports and calls. Tests import
   the module without a terminal.
3. **Every task states whether it has been run.** `Status:` in the task file.
4. **Add a section folder when the second task needs it.** No empty folders.

## Develop

```powershell
Install-Module Pester, PSScriptAnalyzer -Scope CurrentUser
Invoke-Pester ./tests
Invoke-ScriptAnalyzer -Path ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

CI runs both on every push and pull request (`.github/workflows/validate.yml`).
