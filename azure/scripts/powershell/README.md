# PowerShell scripts

Requires PowerShell 7+ and the `Az` module (`Install-Module Az -Scope CurrentUser`).

- `Start-AvdConsole.ps1` is the interactive front end. Run it with no arguments.
- `Start-AvdGui.ps1` is the same front end as a WPF window (Windows only). `gui/` holds its XAML; see `gui/README.md`.
- `modules/AzHelpers/` handles sign-in and subscription context. Every script imports it.
- `modules/AvdHelpers/` holds operations on existing hosts (drain, sessions, waits, tokens).
- `modules/AvdBuild/` holds one function per build step (pool objects, image, NIC, VM, join, agent, FSLogix, roles).
- `modules/AvdBuild/hostconfig/` holds scripts that run inside a session host via Run Command, not on your machine.
- `modules/ServerBuild/` is the same idea for plain Windows servers: inventory, power, VM build, and roles (IIS, AD DS forest, SQL Server) applied by scripts in `hostconfig/` that run inside the guest.
- `modules/NetworkBuild/` lists, creates and edits virtual networks, subnets and NSGs. Edits only: DNS, added address space, subnet prefix, NSG attach or detach.
- `modules/EntraAdmin/`, `ImageBuild/`, `FilesAdmin/`, `BackupAdmin/`, `AppDeploy/`, `AutomationAdmin/` and `OpsAdmin/` cover the rest of the console (users and groups, images, file shares, backup and restore, apps and in-guest scripts, runbooks, dashboard, cost and logs).
- `library/windows/` holds in-guest scripts that run through Run Command; `library/local/` is yours and gitignored.
- The avd/, servers/, network/, entra/, images/, storage/, backup/, apps/, automation/ and insights/ scripts are thin wrappers over those modules.
- Every script calls `Set-AzScriptDefault` after its imports, so `-WhatIf`, `-Verbose` and `-Confirm:$false` reach the module functions (they do not on their own). The tests fail a script that forgets.
- Service folders (`avd/`, `backup/`, ...) hold `Verb-Noun.ps1` entry points.
- `_template.ps1` is the starting point for a new script. Copy it into a service folder
  and update the `Import-Module` path (it becomes `../modules/...` one level down).
- Keep the `Status:` line in `.NOTES` honest. `Untested` until you have run it for real.

Every script should run cleanly with `-WhatIf` and `-Verbose`.

Scripts that run on a timer with no one logged in belong in `../../runbooks/`, not here.
