# Cloudwright

A PowerShell toolkit for learning Microsoft commands and administering Azure, Azure
Virtual Desktop, and Microsoft 365.

**Safe release:** option 3 / `cloudwright m365` permits inspection and reporting;
Microsoft 365 mutation scripts and GDAP approval actions are blocked. Option 2 /
`cloudwright azure` opens a separate read-only Azure/AVD console. The legacy Azure
administration scripts, modules, desktop interface, guest scripts, Automation runbook
and CLI entry point remain blocked.
**Accepting a Microsoft consent prompt can still change tenant permission grants.**
Use a reader account and decline organizational consent unless separately intended.
Read [the safety boundary and upgrade instructions](docs/SAFETY.md) before signing in.

```powershell
cloudwright                 # Choose an area
cloudwright learn           # Build and understand commands
cloudwright azure           # Inspect Azure and AVD in read-only safe mode
cloudwright m365            # Inspect Microsoft 365 in read-only safe mode
```

## One-line download and launch

Open **PowerShell 7** (`pwsh`) and run:

```powershell
irm https://raw.githubusercontent.com/josephraguilar/cloudwright/main/Get-Cloudwright.ps1 | iex
```

This downloads the full toolkit, installs the `cloudwright` command for your current
user, and opens the menu. No GitHub login, Git installation, or administrator rights
are required. `irm` downloads the bootstrap and `iex` executes it; you can inspect
[`Get-Cloudwright.ps1`](Get-Cloudwright.ps1) first.

On Windows the toolkit stays in `%LOCALAPPDATA%\Cloudwright\toolkit`. Other systems
use `$XDG_DATA_HOME/Cloudwright/toolkit`, or `~/.local/share/Cloudwright/toolkit` when
that variable is unset. Keep this directory: it also holds your local settings and
generated output. Subsequent bootstrap runs reuse it and preserve those files;
they do not automatically upgrade the snapshot. For a later snapshot, use a new
`-InstallPath` and transfer only the local settings you need from the old directory.
The new bootstrap requires safety baseline 3 and refuses older cached snapshots,
including the earlier candidates with suppressible refusal errors. Existing installed commands and deployed
runbooks are not upgraded automatically. A refusal leaves the old `cloudwright` command
active. Follow the complete replacement command printed by the refusal, then open a fresh
PowerShell session and confirm `cloudwright version` reports `0.3.0` before using it.

After the first install, just run `cloudwright` in any PowerShell 7 session. To
download without opening the menu or to choose a location, save the bootstrap and run:

```powershell
./Get-Cloudwright.ps1 -NoLaunch -InstallPath "$HOME/Cloudwright"
```

`-Console` selects the text interface and `-WhatIf` previews installation without
downloading or launching anything. `-ModulePath` selects a custom parent module
directory, with the same discovery requirements as the checkout installer below.

## Install from a Git checkout

Use **PowerShell 7** (`pwsh`). Keep the checkout in a permanent location:

```powershell
git clone https://github.com/josephraguilar/cloudwright.git
cd cloudwright
./Install-Cloudwright.ps1
cloudwright
```

The installer registers a small `Cloudwright` module in your current user's module
directory. PowerShell discovers its `cloudwright` alias automatically, including in
new sessions and from other directories. No administrator rights or profile edits
are needed. The full command name is `Start-Cloudwright`.

This is a checkout-based installation: **keep the checkout after installing**. The
launcher points to it, so the tools and their local settings stay together. After
updating or moving the checkout, run:

```powershell
./Install-Cloudwright.ps1 -Force
```

To try the toolkit in the current session without installing anything:

```powershell
Import-Module ./Cloudwright.psd1
cloudwright
```

`Install-Cloudwright.ps1 -WhatIf` previews installation. `-ModulePath` accepts a custom
parent module directory; add that directory to `PSModulePath` if you want automatic
discovery in future sessions. There is no PowerShell Gallery release at this stage.

## Choose an area

| Command | Tool | First-use requirements |
| --- | --- | --- |
| `cloudwright learn` | Command builder from ms-scripter; explanations, verification/rollback examples, and offline study | PowerShell alone works; Azure/Graph lookup modules are optional |
| `cloudwright azure` | Read-only Azure/AVD console: subscriptions, VMs, host pools, session hosts, user sessions, AVD health check, networks | Five Az modules (it prints the install command); a tenant ID; Reader role recommended |
| `cloudwright m365` | Exchange, Entra, GDAP, security and onboarding inspections/reports | First-use setup checks modules and prompts for local settings; mutation tasks are blocked |

Windows opens the Learn and Microsoft 365 desktop interfaces by default. Other platforms
use their console interface. `-Console` selects the text interface on Windows too. Azure
always uses its read-only console:

```powershell
cloudwright learn -Contoso -Console   # Fictional tenant; no connections
cloudwright learn -Console -NoSignIn  # Type values without optional sign-in prompts
cloudwright azure -TenantId <tenant-id> -SubscriptionId <subscription-id>
cloudwright azure -TenantId <tenant-id> -DeviceCode   # Sign in on another device
cloudwright m365 -Console
cloudwright m365 -Setup               # Revisit Microsoft 365 setup
cloudwright help
cloudwright version
```

`cloudwright m365 -WhatIf` previews the launcher entry point without opening it.
M365 mutation scripts refuse instead of running their legacy dry-run workflows.

The Azure read-only console runs only an allowlist of read commands through one checked
gateway, refuses Compute, Network and AVD reads unless their resource provider is already
registered (Az could otherwise register it), keeps Az's sign-in state in that PowerShell
process, and verifies the tenant and subscription before every report. On Windows the
sign-in broker still remembers the account. See [its README](azure/readonly/README.md).
Legacy Azure entry points refuse execution even when called directly, and their modules
refuse import. Each block sets its own error preference before refusing; the tested settings and
runtime limits are documented in [SAFETY.md](docs/SAFETY.md). Legacy bodies remain for review. Bicep and
documentation commands are reference material; Cloudwright does not deploy them.

The top-level menu, help, and version do not sign in or install cloud dependencies.
Each selected area runs in a fresh PowerShell process. In-memory sessions from your
calling shell are not passed into it; its existing sign-in flow selects its context.

Learn produces text and never executes generated commands. Executing those scripts
elsewhere can change resources. Microsoft 365 adds a mandatory read-only policy
in front of its legacy change-plan code. Installation does not run a tenant operation.

## Repository layout

```text
Cloudwright.psd1 / Cloudwright.psm1  Public command and launcher
Install-Cloudwright.ps1             Current-user command installation
Get-Cloudwright.ps1                 Anonymous download, installation, and launch
learn/                             ms-scripter engine, catalog, UI, and tests
azure/                             Azure/AVD read-only console (readonly/), blocked legacy scripts, Bicep, tests
m365/                              Microsoft 365 modules, scripts, UI, and tests
tests/                             Launcher and installation tests
docs/MIGRATION.md                  Source commits and consolidation decisions
.github/workflows/validate.yml      Combined validation
```

Component instructions and direct-script usage:
[Learn](learn/README.md), [Azure/AVD](azure/README.md),
[Microsoft 365](m365/README.md). Direct-script examples in those documents run from
their component directory. The existing components remain independently testable.

Keep credentials, tenant data, generated scripts, and run logs out of Git. Local
settings remain in the existing gitignored component locations; this migration does
not copy settings from another workstation. Examples use fictional values.

## Develop and validate

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser
Import-Module Pester -RequiredVersion 5.7.1
Invoke-Pester ./tests
```

Run each component's suite in a separate PowerShell process from its own directory:

```powershell
Push-Location learn
pwsh -NoProfile -Command 'Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester ./tests -CI'
Pop-Location
# Repeat for azure/ and m365/.
```

The root workflow also runs each component's existing analyzer settings, validates
XAML and JSON, checks filename collisions on Windows, compiles Bicep, and runs
Shellcheck. It tests the root launcher on Linux and Windows. Component unit tests
mock tenant APIs; passing them does not establish live tenant or desktop UI behavior.
Preserve each script's existing `Status:` notes.
