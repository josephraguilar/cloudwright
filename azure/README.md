# azure

Part of [Cloudwright](../README.md). After installing the root launcher, run
`cloudwright azure` or `cloudwright azure -Console`.
Direct-script examples below run from this `azure/` directory.

**Azure launcher, console and GUI administration are disabled in this safe release.**
The legacy scripts/modules below remain write-capable source and are outside the
supported read-only interface. Automatic Entra cleanup and Kerberos consent by display
name are disabled. Entra reimage and the retired cleanup switch refuse before changes;
new Entra hosts are checked for existing device records before VM creation. See the
[safety review and unresolved findings](../docs/SECURITY-REVIEW.md).

Personal repo for learning Azure and for building Nerdio-style Azure Virtual Desktop
(AVD) automation without the UI: PowerShell scripts, Bicep, Automation runbooks, and notes.

Longer term, logic from here may feed a web app, so the repo keeps **reusable logic**
(PowerShell modules, Bicep modules) separate from **entry points** (scripts, runbooks,
environment deployments). Build the logic once, call it from anywhere.

## Rules

1. **Nothing client-specific, ever.** No tenant IDs, subscription IDs, hostnames,
   resource names, or credentials. Every example uses an obvious placeholder.
   Real values go in local files matching `*.local.*` or `*.secrets.*`, which are gitignored.
2. **Scripts are thin.** They parse parameters, call module functions, print results.
   Logic lives in `scripts/powershell/modules/`: AzHelpers (sign-in), AvdHelpers
   (operations on existing hosts), AvdBuild (one function per build step), and one
   module per further area (servers, network, Entra, images, files, backup, apps,
   automation, operations). A script hands its `-WhatIf` to them with
   `Set-AzScriptDefault`; the tests fail a script that forgets.
   Bicep follows the same idea: `modules/` is one resource type per file,
   `compositions/` bundles them into AVD shapes, `environments/` picks compositions.
3. **Every script states whether it has been run.** The `.NOTES` block carries a
   `Status:` line: `Untested`, or `Tested <yyyy-mm-dd>` once it has been run for real.
4. **Add a service folder when a second script needs it.** Do not pre-create empty folders.

## Layout

```
.
├── scripts/powershell/      Interactive admin scripts (you are logged in, you run them)
│   ├── Start-AvdConsole.ps1 Menu-driven front end for everything below
│   ├── Start-AvdGui.ps1     Windows desktop front end (WPF) for the same actions
│   ├── gui/                 Shell.xaml (window), Theme.xaml and Theme.Teal.xaml, pages/ (one file per area)
│   ├── modules/AzHelpers/   Auth, context, resource providers
│   ├── modules/AvdHelpers/  AVD operations: drain, sessions, messaging, waits, tokens
│   ├── modules/AvdBuild/    AVD build steps: pool objects, image, NIC, VM, join, agent, FSLogix, roles
│   │   └── hostconfig/      Scripts that run ON a session host via Run Command
│   ├── modules/ServerBuild/ Plain servers: inventory, power, VM build, roles (IIS, AD DS forest, SQL) via in-guest scripts
│   │   └── hostconfig/      Role scripts that run INSIDE the server via managed Run Command
│   ├── avd/                 Thin scripts: host pool, session host, drain, power, rolling restart, autoscale, reimage, environment
│   ├── servers/             Thin scripts: server inventory, power, new server, install role, just-in-time RDP
│   ├── modules/NetworkBuild/ VNets, subnets, NSGs and rules, public IPs, NAT gateways, site-to-site VPN
│   ├── network/             Thin scripts: VNets, subnets, NSGs and rules, public IPs, NAT gateways, VPN
│   ├── modules/EntraAdmin/  Users and groups through Graph: list, create, members, sign-in, password, licence
│   ├── modules/ImageBuild/  Compute Gallery, image builder VM, sysprep and capture, Windows 365 images
│   ├── modules/FilesAdmin/  Storage accounts and file shares: usage, create, quota
│   ├── modules/BackupAdmin/ Vaults, protected items, recovery points, back up now, restore (never overwrite), policies
│   ├── modules/AppDeploy/   Run Command runner, script library, winget, shell apps, certificates, MSIX app attach, local store
│   ├── modules/AutomationAdmin/ Automation accounts, runbooks, jobs, start, import
│   ├── modules/OpsAdmin/    AVD dashboard data, Log Analytics, diagnostics, Cost Management, Activity Log, HTML report
│   ├── entra/               Thin scripts: new user, new group, add members, user actions
│   ├── images/              Thin scripts: image definition, builder VM, capture, Windows 365 upload
│   ├── apps/                Thin scripts: run a library script, install apps, certificates, app attach
│   ├── automation/          Thin scripts: start a runbook or a runbook group, import a runbook
│   ├── insights/            Thin scripts: AVD diagnostics to Log Analytics, the HTML report
│   ├── library/             In-guest scripts: windows/ (repo), local/ (yours, gitignored)
│   ├── backup/              Recovery Services: pool backup, protect items, back up now, restore, policies
│   ├── storage/             Profile share access and NTFS; new share, share quota
│   └── _template.ps1        Copy this to start a new script
├── scripts/cli/             Azure CLI (bash) equivalents where useful
├── runbooks/                Timer-triggered scripts for Azure Automation (managed identity, no login)
├── infra/bicep/
│   ├── modules/             One resource type per file: network/, storage/, compute/
│   ├── compositions/        AVD-shaped bundles of modules: network, profile storage, image gallery
│   └── environments/        lab/ = everything before the host pool; dev/ = the original example
├── docs/
│   ├── avd/                 AVD design notes, provisioning order, roadmap
│   ├── design/              Design system references the GUI theme is mapped from
│   └── cheatsheets/         Command references
├── tests/                   Pester tests for the modules
└── .github/workflows/       CI: PSScriptAnalyzer, Pester, Bicep build, shellcheck
```

Organized by tool first (`powershell/`, `cli/`, `bicep/`) because linters and CI are
per-tool, then by Azure service area underneath.

`scripts/` and `runbooks/` are separate on purpose. Interactive scripts assume a person
ran `Connect-AzAccount`. Runbooks run unattended in Azure Automation and authenticate
with the Automation account's managed identity. Same module, different entry point.

### Where things go

| I want to...                                       | Put it in                                    |
| -------------------------------------------------- | -------------------------------------------- |
| Run an admin task by hand                          | `scripts/powershell/<area>/Verb-Noun.ps1`    |
| Run something on a schedule in Azure               | `runbooks/Verb-Noun.ps1`                     |
| Share a function between scripts or runbooks       | `scripts/powershell/modules/<Module>/`       |
| Declare one resource type                          | `infra/bicep/modules/<area>/<resource>.bicep` |
| Bundle resources into an AVD shape                 | `infra/bicep/compositions/avd-<thing>.bicep` |
| Deploy a set of resources for an environment       | `infra/bicep/environments/<env>/`            |
| Write down a design decision or step order         | `docs/avd/`                                  |
| Remember a command                                 | `docs/cheatsheets/`                          |

## Conventions

**Code notes (every file)**

This repo is for learning, so every script, module, and Bicep file is split into
numbered sections with a short note explaining what the section does and why it is
there. PowerShell uses `#region` / `#endregion`, which VS Code folds and lists in the
outline. Bash and Bicep use a dashed banner comment, since they have no region syntax.

```powershell
#region 2. Setup --------------------------------------------------------------
#   WHAT   Strict mode, fail fast, load AzHelpers, confirm Azure context.
#   WHY    Same opening as every script so behaviour is identical whether you
#          were already logged in or not.
#   GOTCHA One level down from _template.ps1 the module path is '..', 'modules', ...
Set-StrictMode -Version Latest
...
#endregion
```

- `WHAT` is one or two lines. `WHY` is the part worth reading twice. `GOTCHA` is
  optional and only for things that actually bite.
- Keep notes short. If a WHY needs a paragraph, it belongs in `docs/` with a link.
- Number the sections. When a script calls another script, the notes can say
  "see New-AvdSessionHost.ps1 region 4" and mean something.
- Read the file top to bottom with folding collapsed and the region titles alone
  should tell the story.

**PowerShell**
- `Verb-Noun.ps1` with an [approved verb](https://learn.microsoft.com/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands).
- Comment-based help, `[CmdletBinding()]` `param()` block, and `SupportsShouldProcess`
  on anything that changes state so `-WhatIf` always works.
- Start from `scripts/powershell/_template.ps1`. Call `Assert-AzContext` first.
- Runbooks call `Assert-AzContext -Identity` and never prompt.

**Azure CLI**
- `verb-noun.sh`, `set -euo pipefail`, usage comment at the top.

**Bicep**
- Bicep is the source of truth. Compiled ARM JSON is gitignored.
- `@description()` on every parameter. Modules expose `output id` and `output name`.
- Secrets never go in `.bicepparam`. Reference Key Vault or pass at deploy time.

**AVD autoscale**
- Use native scaling plans. No custom scaling script lives here.

## How the pieces talk to Azure

| Tool                                      | Talks to                   | Use it for                                     |
| ----------------------------------------- | -------------------------- | ---------------------------------------------- |
| Az PowerShell (`Az.*`, incl. `Az.DesktopVirtualization`) | ARM         | Admin automation, runbooks                     |
| Azure CLI (`az`, `az desktopvirtualization`) | ARM                     | Quick interactive work, bash pipelines         |
| Bicep                                     | ARM (compiles to ARM JSON) | Declaring what should exist                    |
| `Invoke-AzRestMethod` / `az rest`         | ARM directly               | Features the cmdlets don't cover yet           |
| Microsoft Graph (`Microsoft.Graph`, `az ad`) | Graph, **not** ARM      | Entra ID users, groups, app registrations      |

Entra ID objects live behind Microsoft Graph. RBAC role assignments and AVD app group
assignments are ARM resources, so assigning an Entra group to a desktop app group is an
ARM call that takes a Graph object ID.

## Getting started

```powershell
Install-Module Az -Scope CurrentUser          # includes Az.DesktopVirtualization, Az.RecoveryServices
./scripts/powershell/Start-AvdConsole.ps1     # signs you in, then shows a menu
./scripts/powershell/Start-AvdGui.ps1         # same actions as a desktop window (Windows only)
```

The GUI and the console share `console.local.json` (gitignored), so signing in once
remembers the tenant and subscription for both. `scripts/powershell/gui/README.md`
explains how the window is put together and how to restyle it.

If your account can see several tenants (MSP accounts), pass the tenant that holds
the lab subscription so Az does not try to enumerate all of them:

```powershell
./scripts/powershell/Start-AvdConsole.ps1 -TenantId <tenant-id>
```

Or call any script directly. Every one supports `-WhatIf` and `-Verbose`:

```powershell
./scripts/powershell/avd/New-AvdHostPool.ps1 -SubscriptionId <sub> -ResourceGroupName rg-avd-lab `
    -Location westus3 -HostPoolName hp-lab -WorkspaceName ws-lab -WhatIf
```

The AVD scripts and what they do are listed in `docs/avd/roadmap.md`.

Run the same checks CI runs before pushing:

```powershell
Install-Module PSScriptAnalyzer, Pester -Scope CurrentUser
Invoke-ScriptAnalyzer -Path ./scripts/powershell -Recurse
Invoke-ScriptAnalyzer -Path ./runbooks -Recurse
Invoke-Pester -Path ./tests
```

```bash
az bicep build --file infra/bicep/environments/dev/main.bicep --stdout > /dev/null
```
