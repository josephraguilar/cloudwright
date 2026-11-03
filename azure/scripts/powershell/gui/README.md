# GUI

`Start-AvdGui.ps1` is a Windows desktop front end for the same scripts the console runs.
It is PowerShell plus three XAML files, no compiler, no installer. The same trick
Chris Titus's WinUtil uses: PowerShell loads a WPF window from XAML, finds the named
controls, and attaches handlers that are ordinary PowerShell.

```
Start-AvdGui.ps1     the app: sign-in, worker, helpers, the first pages, navigation
gui/pages/*.ps1      the other pages, one file per area, dot-sourced by the app
gui/Shell.xaml       the window: top bar, rail, section panel, page host, log pane, status bar
gui/Theme.xaml       every colour, font, radius and control style (Ember, the default)
gui/Theme.Teal.xaml  the same styles with a management-console palette (-Theme Teal)
```

Windows only (WPF). PowerShell 7 and the Az module, same as the console. Run:

```powershell
./scripts/powershell/Start-AvdGui.ps1               # Ember theme
./scripts/powershell/Start-AvdGui.ps1 -Theme Teal   # console look
```

## Layout

The window is laid out like a management console:

- **Top bar**: app name, a search box that filters the All features page, the
  subscription and host pool pickers, and the account menu (switch account, sign in
  again, open the portal). The menu button on the left hides the section panel.
- **Rail** (left): *All features* and one button per section: Insights, Entra, Cloud
  desktops, Azure, Policies, Applications, Scripting, FinOps, Settings. The rail also
  shows the tenant and subscription in use.
- **Section panel**: the selected section's groups and links.
- **Page**: tables sit in cards with a coloured header band. The band holds Refresh
  and a *Manage* menu; the same menu opens on right-click of a row.
- **Log** (resizable) and **status bar** below the page.

The whole tree is one hashtable, `$Gui.NavTree`, at the top of the Navigation region:
section, groups, items, each item naming its page builder. Adding a page is one line
there plus a `New-*Page` function (in `gui/pages/` for anything new). An item can carry
placeholder text instead of a builder, which makes an honest "not built" page that links
to the portal; none is left today. The tests check that every page function is reachable
from the tree, every tree entry has its function, and every command a page calls exists.

Sign-in, tenant and subscription are remembered in `console.local.json` next to the
script (gitignored), shared with the console.

## Pages

Every rail link is a real page. In-guest actions (scripts, apps, certificates) run
through managed Run Commands on every target at once, from a shared picker: the hosts of
the current pool, or VMs picked from a list.

The current host pool is picked on Cloud desktops > Host pools (select a row, Open), not
in the top bar. The rail shows it under the subscription, and every page that works on
it carries a "Host pool: ..." line with a Change host pool link back to that page.

| Section | Page | What it does | Runs |
| ------- | ---- | ------------ | ---- |
| Insights | Home | Host counts, power states, pool settings, scaling plan, estimated compute cost for the current pool | `Get-AvdHostPoolOverview` |
| | AVD dashboard | Every pool at a glance; connections per hour, failed attempts, top errors and busiest users from Log Analytics | `Get-OpsAvdSummary`, `Get-OpsAvdInsight` |
| | Reports | HTML report plus CSVs: pools, VMs, backups, shares, networks, cost, changes | `insights/Export-ToolboxReport.ps1` |
| Entra | Users | Search; row menu: block or allow sign-in, revoke sessions, reset password (shown once), add to group, assign licence, show groups | `entra/Set-EntraUser.ps1`, `entra/Add-EntraGroupMember.ps1` |
| | Groups | Search, members, add members | `entra/Add-EntraGroupMember.ps1` |
| | Add user / Add group | Cloud user with group and licence; security group with members | `entra/New-EntraUser.ps1`, `entra/New-EntraGroup.ps1` |
| | User actions | One action on a pasted list of users, a result row each | `entra/Set-EntraUser.ps1` |
| Cloud desktops | Host pools | Every pool with host and session counts; the row menu makes one current | `Get-AzWvdHostPool` |
| | Session hosts | Row menu: drain, power, just-in-time RDP, repair; rolling restart; agent update window | `avd/*.ps1` |
| | User sessions | List, message, log off | `avd/Set-AvdHostDrain.ps1` |
| | Autoscale | Scaling plans: view, edit, create, enable or disable | `avd/New-AvdScalingPlan.ps1`, `avd/Set-AvdScalingPlan.ps1` |
| | Desktop images | Gallery definitions and versions; builder VM; sysprep and capture (VM name typed to confirm) | `images/*.ps1` |
| | New environment / Add a host | The build wizard; one host from a marketplace or gallery image | `avd/New-AvdEnvironment.ps1`, `avd/New-AvdSessionHost.ps1` |
| | Profile storage / Pool backup | FSLogix share permissions; vault and policies for a pool | `storage/Set-AvdProfileShareAccess.ps1`, `backup/Enable-AvdBackup.ps1` |
| | Windows 365 images | Managed images, upload to Windows 365, provisioning policies | `images/New-W365Image.ps1` |
| Azure | Servers: list, add | Power, just-in-time RDP, roles (IIS, AD DS forest, SQL); new server | `servers/*.ps1` |
| | Servers: backup and restore | Protected VMs, back up now, recovery points, restore as a new VM or as disks, protect a VM | `backup/*-ItemBackup.ps1` |
| | Azure Files: list, add | Accounts and shares with usage against quota, change quota; new share or account | `storage/New-FilesShare.ps1`, `storage/Set-FilesShareQuota.ps1` |
| | Azure Files: backup and restore | Protected shares; restore to another share, or in place skipping existing files | `backup/*-ItemBackup.ps1` |
| | Network | Virtual networks; NSGs and rules (set to Deny instead of delete); VPN gateways, sites and connections; public IPs (unattached flagged); NAT gateways | `network/*.ps1` |
| Policies | Backup | Daily policies: run time and retention (shorter retention asks first) | `backup/Set-BackupPolicy.ps1` |
| Applications | Winget catalog | Search (on a VM), install or upgrade machine-wide | `apps/Install-App.ps1` |
| | App groups / Shell apps | Named sets of packages; your own install script with detection | `apps/Install-App.ps1` |
| | Certificates | Key Vault certificates by expiry, PFX import, install into VM machine stores | `apps/Import-KvCertificate.ps1`, `apps/Install-GuestCertificate.ps1` |
| | MSIX app attach | Packages: add, activate, registration, assign pool, grant a group | `apps/*-AppAttachPackage.ps1` |
| | Deployments: policies, status | Saved targets plus apps, run on demand; last run command result per VM | `apps/Install-App.ps1`, `Get-GuestRunCommandInfo` |
| Scripting | Windows scripts / groups | The in-guest script library (`library/windows`, your `library/local`), alone or in order | `apps/Invoke-GuestScript.ps1` |
| | Runbooks / groups | Automation accounts, runbooks, jobs and output; start, import | `automation/*.ps1` |
| FinOps | Cost management | Actual cost by group and by day | `Get-OpsCost` |
| | Estimated vs deployed | Retail estimate against actual and projected cost per pool | `Get-OpsCostComparison` |
| Settings | Permissions | What the signed-in account can do | `Test-AvdBuildPermission` |
| | Integrations | AVD diagnostics to Log Analytics (creates the workspace if asked) | `insights/Set-AvdDiagnostic.ps1` |
| | Azure portal / Logs | Portal shortcuts; the session log and the Activity Log | `Get-OpsActivityLog` |

App groups, shell apps, script and runbook groups, and saved deployments live in
`scripts/powershell/toolbox.local.json`, next to the scripts and gitignored. The GUI
adds and replaces entries; to drop one, edit the file.

The console menu (`Start-AvdConsole.ps1`) covers the AVD, server and network actions.
The newer areas above are GUI and command line only: every one is a script you can run
directly with the same parameters the GUI shows before it runs.

## What it will never do

The window has no delete actions. No tear down, no reimage, no rollback after a
failed build. The newer areas follow the same rule: no user, group, member, licence,
share, vault, rule, package, run command or store entry is ever removed. The off
switches are reversible instead: block sign-in, set a rule to Deny, deactivate a
package. Restores never overwrite: a VM comes back as a new VM, a share into another
folder or into itself skipping existing files. Sysprep (one-way for the VM it runs on)
asks for the VM name typed out. The build it starts does not delete directory objects either: if a
stale Entra device record carries a planned host name, the preflight stops and
names it for you to remove in the Entra admin center. The one "remove" left inside
a build is re-installing a VM extension on the very VM being built or repaired,
which is how a retry gets a clean run.

Deleting is done in the Azure portal, on purpose, by a person who can see what
they are deleting. The console and the command line keep `Remove-AvdEnvironment.ps1`
and `Invoke-AvdHostReimage.ps1` for when that is wanted.

## How it works

- **No logic of its own.** Every change ends in one of the scripts under
  `scripts/powershell/<area>/`, and every read in a module function. If the GUI can do it, the
  console and the command line can do it the same way, and every run shows the exact
  parameters before it starts. Dry run buttons pass `-WhatIf`, which every script hands
  on to the module functions it calls (`Set-AzScriptDefault`: preference variables do
  not cross a module boundary on their own, so without it a dry run would act).
- **One worker runspace** owns the Az sign-in and runs every job, one at a time, so
  the window never blocks on Azure. A timer copies the job's verbose, warning and
  error streams into the log pane. Buttons disable while a job runs.
- **Pages are data.** A page is a list of fields (label, type, default, help) that
  the script turns into controls. Adding a question to a form is one line.
- **No closures.** Handlers get their context from the sender's `Tag` and reach
  shared state through the `$Gui` hashtable. `GetNewClosure()` is avoided on purpose:
  a closure is bound to a throwaway module that cannot see the script's functions when
  the script is run from a prompt.

## Styling

Two themes ship. `Theme.xaml` is mapped from `docs/design/ember-studio.md` (warm light
palette, terracotta primary, serif display font, sans body) and is the default.
`Theme.Teal.xaml` has the same control styles with a console palette: teal primary,
slate greys, Open Sans body and Poppins headings, 4 and 6 px corners. Pick it with
`-Theme Teal`. A theme file must define every key the default does; the tests compare
them. Open a theme; the top block is tokens:

| Token | What it controls |
| ----- | ---------------- |
| `Color.Primary`, `Color.PrimaryHover`, `Color.PrimaryTint` | the one accent: primary buttons, active nav, focus rings, selection |
| `Color.Background`, `Color.Surface`, `Color.SurfaceRaised` | page, cards and inputs, hover and selected rows |
| `Color.Text`, `Color.TextSecondary`, `Color.Neutral` | body text, descriptions, captions and placeholders |
| `Color.Border`, `Color.Success`, `Color.Warning`, `Color.Error` | dividers and status colours; Error also backs destructive buttons |
| `Font.Display`, `Font.Body`, `Font.Mono` | headings, everything else, the log |
| `Font.Size*` | the type scale (28 heading, 20 subhead, 15 body, 14 small, 12 caption, 11 overline) |
| `Radius.Control`, `Radius.Card`, `Radius.CardTop`, `Radius.Pill` | buttons and inputs, cards, the header band of a table card, pills for chips |

Change those and every control follows. The styles below the tokens are the control
templates; you only need them for a different shape, not a different colour.

Fonts: the design calls for Playfair Display, Source Sans 3 and Fira Code, which are
Google Fonts. Install them on Windows for the full look. Without them the theme falls
back to Georgia, Segoe UI and Cascadia Mono, which keep the serif-versus-sans contrast.

To apply a different design reference, drop it in `docs/design/`, copy a theme to
`gui/Theme.<Name>.xaml`, map the palette onto `Color.*`, the type onto `Font.*` and the
rounding onto `Radius.*`, and add the name to the `-Theme` parameter's `ValidateSet`.
Nothing else has to change.
