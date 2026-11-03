# AVD automation roadmap

Goal: the pieces Nerdio does for you, as scripts you can read, run, and later wire into
an app. Built one at a time, in this order. Each script's `.NOTES` block says whether it
has been run for real.

| # | Script | Folder | Status |
| - | ------ | ------ | ------ |
| 1 | `New-AvdHostPool.ps1` — host pool, desktop app group, workspace, registration token, optional Entra group assignment, `-EntraJoined` RDP property | `scripts/powershell/avd/` | Tested 2026-10-17 |
| 2 | `New-AvdSessionHost.ps1` — VM from a Compute Gallery image version or a marketplace image, `Windows_Client` license, domain join (AD or Entra), AVD agent via DSC extension with registration token, FSLogix registry post-config, verify host is `Available` | `scripts/powershell/avd/` | Tested 2026-10-17; join verification added after |
| 3 | `Set-AvdHostDrain.ps1` — drain mode on/off, list sessions, message users, log off | `scripts/powershell/avd/` | In repo, untested |
| 4 | `Invoke-AvdHostReimage.ps1` — drain, wait, delete VM + OS disk, recreate from a new image version by calling #2 | `scripts/powershell/avd/` | In repo, untested |
| 5 | `Enable-AvdBackup.ps1` — Recovery Services vault, policy, protect the FSLogix Azure Files share and personal hosts. Pooled hosts are not backed up | `scripts/powershell/backup/` | In repo, untested |
| 4b | `Repair-AvdSessionHost.ps1` — finish or repair an existing VM: login role, agent (removing a failed attempt first), FSLogix, wait for Available. Console option R. | `scripts/powershell/avd/` | In repo, untested |
| 4c | `Remove-AvdEnvironment.ps1` — tear down a lab: delete the resource group, then the Entra device records for its VMs and the Entra app for its storage accounts, optionally the user group. Console option X. | `scripts/powershell/avd/` | In repo, untested |
| 7 | `Get-AvdPoolOverview.ps1` — settings, host counts, power states, scaling plans, estimated compute cost (public retail price API) | `scripts/powershell/avd/` | Untested |
| 8 | `New-AvdScalingPlan.ps1` — grant the AVD service its power role, create a pooled scaling plan (weekday phases, optional weekend off-peak), attach to the pool | `scripts/powershell/avd/` | Untested |
| 8b | `Set-AvdScalingPlan.ps1` — edit an existing plan's weekday schedule, weekend schedule, time zone, exclusion tag; only passed values change | `scripts/powershell/avd/` | Untested |
| 9 | `Set-AvdHostPower.ps1` — start, deallocate, stop, restart by session host name; refuses hosts with sessions unless `-Force` | `scripts/powershell/avd/` | Untested |
| 10 | `Invoke-AvdRollingRestart.ps1` — drain, message, wait, restart, wait for Available, undrain, one host at a time | `scripts/powershell/avd/` | Untested |
| 11 | `Set-AvdAgentUpdateWindow.ps1` — weekly agent update maintenance window on the pool, or back to default | `scripts/powershell/avd/` | Untested |
| 6 | `Test-AvdHostHealth.ps1` — timer-driven: hosts in `Unavailable` / `NeedsAssistance` get restarted and rechecked, then drained and reimaged if still bad, with an alert | `runbooks/` | In repo, untested |

Also in the repo:

- `scripts/powershell/avd/New-AvdEnvironment.ps1`: the orchestrator. One parameter set,
  seven steps in order (providers, resource group, Bicep infra, share access, host pool,
  N hosts, backup), Retry/Skip/Abort when interactive. Abort offers a rollback that
  deletes only what the run created (the whole resource group if the run made it,
  otherwise resource by resource in reverse order; vaults are left for a person).
  `-RollbackOnFailure` does the same unattended. Runs two preflights before creating
  anything: permissions (every Azure action and Entra directory role the build needs,
  as a table; console option C shows the same) and vCPU quota for the chosen size times
  the host count (quota is per VM family, per region, per subscription, and a personal
  subscription can sit at 0 for a family). Entra ID only for now.
- `scripts/powershell/Start-AvdConsole.ps1`: opens with "new or existing". New asks every
  question up front and calls the orchestrator. Existing is the operations menu.
- `scripts/powershell/Start-AvdGui.ps1`: the console as a WPF window laid out like a
  management console: top bar (search, subscription, account menu; the host pool is picked on the Host pools page), a rail of
  sections (Insights, Entra, Cloud desktops, Azure, Policies, Applications, Scripting,
  FinOps, Settings), a section panel of links, tables in cards with header bands and a
  row menu. Every rail link is a page (see `scripts/powershell/gui/README.md` for the
  list); every change ends in a script and every dry run passes `-WhatIf` all the way
  down. By design it has no
  delete actions (no tear down, reimage or rollback) and the builds it starts never delete
  Entra device records: a stale record stops the preflight with its name. Styled from
  `docs/design/ember-studio.md` through `gui/Theme.xaml`, or `-Theme Teal` for the
  console palette.
- `scripts/powershell/modules/AvdHelpers/`: operations on existing hosts (drain, sessions,
  messaging, log-off, waiting, tokens) that scripts 3, 4 and the console call.
- `scripts/powershell/modules/AvdBuild/`: one function per build step (pool objects,
  image, NIC, VM, join, agent, FSLogix, roles). Scripts 1 and 2 are thin wrappers over it.
  Its `hostconfig/Set-FsLogixProfile.ps1` runs on the host via Run Command.
- `scripts/powershell/storage/Set-AvdProfileShareAccess.ps1`: Entra Kerberos, share
  permission, group RBAC, NTFS on the profile share.
- `infra/bicep/modules/`: one resource type per file. `infra/bicep/compositions/`: AVD
  bundles. `infra/bicep/environments/lab/`: network, profile storage (Entra Kerberos on),
  optional gallery. Console option A deploys it.
- `docs/avd/provisioning-order.md`: the step order for a session host and why each step
  depends on the one before it.
- `docs/avd/environment-build-path.md`: the full build order from a fresh subscription
  to a working pool, and which steps the repo does not cover yet.

## Networks

`modules/NetworkBuild/` plus `scripts/powershell/network/`. List VNets and subnets;
create a VNet with its first subnet; set DNS servers or go back to Azure default; add
address space (never remove); add a subnet; change a subnet's prefix; attach or detach
an NSG; create an NSG with default rules. GUI: Networks page. Console: options 20 to 23.
Also NSG rules (add or change; "remove" is set to Deny; an inbound Allow from the whole
internet needs an explicit switch), public IPs with what each is attached to, NAT
gateways (create, attach, detach), and site-to-site VPN (gateway, local gateway,
connection with a pre-shared key). GUI: NSGs, VPN, Public IPs, NAT gateways pages.
All Untested.

## Servers (not AVD)

A second wing for plain Windows servers, same conventions. `modules/ServerBuild/` plus
`scripts/powershell/servers/`:

| Script | What it does | Status |
| ------ | ------------ | ------ |
| `Get-ServerInventory.ps1` | VMs in a group or subscription: power state, size, image, private IP, role tag | Untested |
| `Set-ServerPower.ps1` | Start, deallocate, stop, restart by VM name | Untested |
| `New-Server.ps1` | Windows Server or SQL marketplace VM, Trusted Launch, optional data disk, optional public IP, then a role | Untested |
| `Grant-ServerRdpAccess.ps1` / `Revoke-ServerRdpAccess.ps1` | Just-in-time RDP: public IP attached if missing, NSG rule for 3389 from your IP with an expiry, .rdp file written and launched; revoke sets the rule to Deny (nothing deleted) | Untested |
| `Install-ServerRole.ps1` | IIS, first DC of a new forest (promote, restart, DNS forwarder, verify, optional VNet DNS), or SQL post-config (folders on the data drive, mixed mode, firewall, IaaS registration) | Untested |

Role scripts run inside the guest through the managed Run Command; passwords go as
protected parameters. GUI: Servers and New server pages. Console: options 15 to 17.

## The rest of the console

Each area is a module plus thin scripts, all Untested, all without deletes:

| Area | Module | Scripts | GUI |
| ---- | ------ | ------- | --- |
| Entra users and groups | `EntraAdmin` (Graph through the Az token) | `entra/` | Entra section |
| Desktop images, Windows 365 | `ImageBuild` | `images/` | Desktop images, Windows 365 images |
| Azure Files | `FilesAdmin` | `storage/New-FilesShare.ps1`, `storage/Set-FilesShareQuota.ps1` | Azure Files list, add |
| Backup and restore, policies | `BackupAdmin` | `backup/*-ItemBackup.ps1`, `backup/Set-BackupPolicy.ps1` | Backup and restore (servers, files), Policies |
| Apps and in-guest scripts | `AppDeploy` | `apps/`, `library/` | Applications, Scripting > Windows scripts |
| Runbooks | `AutomationAdmin` | `automation/` | Scripting > Azure runbooks |
| Dashboard, cost, logs, reports | `OpsAdmin` | `insights/` | Insights, FinOps, Settings |

Known limits: deployments run on demand, not on a schedule (that needs something always
on, such as an Automation account, and the local store does not live there); Windows 365
needs the Microsoft.Graph.Authentication module and Cloud PC consent; winget needs App
Installer on the VM (Windows 11 and 10 multi-session have it, Windows Server does not by
default); the console menu does not have entries for these areas, the scripts do.

Script #6 restarts, rechecks, drains, and alerts. It does not reimage. Reimage needs
credentials and an image choice, and those should not live in an Automation account.
The alert names the host and the `Invoke-AvdHostReimage.ps1` call to run.

First real run, 2026-10-17, Entra-only lab in a personal tenant: providers, resource
group, Bicep (network, storage with Entra Kerberos, share), host pool, one session host,
Entra join, agent, user sign-in from the Windows App all worked. Fixed along the way: a
stale DSC package URL, module error handling, a leftover Entra device record blocking
the rejoin, port 445 blocked from the workstation. Still to exercise: drain, message,
log off, reimage, repair, backup, the runbook, NTFS via session host, automatic consent.

Out of scope:

- **Autoscale.** Native AVD scaling plans handle this. No custom scaling script.
- **Anything client-specific.** Placeholders only. See the rules in the root README.
