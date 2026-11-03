# Prior art: what already exists, and what we take from it

Researched 2026-10-17. Nothing found does exactly what this repo does (a GUI that
builds Microsoft admin scripts for review and never runs them). Several things do
pieces of it, and a few are worth reusing directly.

## Closest matches

| Project | What it is | License | Verdict |
| ------- | ---------- | ------- | ------- |
| [Graph Explorer code snippets](https://learn.microsoft.com/en-us/graph/graph-explorer/graph-explorer-overview) | Microsoft's web tool. Build a Graph request, then the **Code snippets** tab shows the equivalent `Get-MgUser` etc. command. Good coverage for users and groups, not every API. | Microsoft, web only | The pattern we are copying: pick inputs, get a command. Not reusable as code. Link to it from Graph tasks as "see the raw request". |
| [azure-script (PyPI)](https://pypi.org/project/azure-script) | A mini language that compiles to `az` CLI commands you then run yourself. Command line, Python, early development. | Not checked | Same "generate, don't run" idea. Nothing to reuse (Python, no UI). |
| [leeford/MSGraphAPIGUI](https://github.com/leeford/MSGraphAPIGUI) | PowerShell WPF front end for calling Graph with delegated or app permissions. Needs an app registration. | **GPL-3.0** | Executes requests, so not our model. GPL also means we cannot copy code in. Useful as a reference for how a PowerShell WPF window is laid out, nothing more. |
| [Raph's Azure CLI within PowerShell](https://blog.raph.ws/2021/04/azure-cli-within-powershell/) | Builds an `az` command string from parameters, prints it, then runs it with `Invoke-Expression`. | Blog post | Shows the string-building half. We stop before the `Invoke-Expression`. |
| [CIPP](https://github.com/KelvinTegelaar/CIPP) | CyberDrain Improved Partner Portal. Open source multi-tenant M365 admin portal for MSPs. | **AGPL-3.0** | Executes everything; big web app. Do not copy code (AGPL). **Do** use its feature list as the checklist of what MSPs actually do in M365 (user offboarding, shared mailbox, group membership, CA templates) when deciding which M365 tasks to add to the catalog. |
| [Azure/azure-operation-script](https://github.com/Azure/azure-operation-script) | Microsoft sample scripts, Az PowerShell and CLI side by side. | MIT | Mine it for the CLI equivalents when a task gets an `az` variant. |
| [omer-eltayeb/M365](https://github.com/omer-eltayeb/M365), [m365corner/M365Corner-Scripts](https://github.com/m365corner/M365Corner-Scripts), [pnp/script-samples](https://github.com/nelladath/script-samples) | Script libraries. Read-only by default, `-WhatIf` everywhere, Graph SDK only. | Check each before copying | Reference for the *shape* of a good M365 script. Copy commands, not files, and only from MIT repos. |
| [Azure/avdaccelerator](https://github.com/Azure/avdaccelerator) | Microsoft's AVD landing zone accelerator. Bicep/Terraform, deployable from PowerShell. | MIT | The authoritative build order for AVD. Our own `azure` repo already distils it into `docs/avd/environment-build-path.md`; reuse that. |

Nerdio itself: commercial, no open-source alternative found. What Nerdio does (host pools,
images, autoscale, FSLogix, backup) is already the roadmap of the `azure` repo. This repo
teaches the commands behind those buttons; it does not replace the buttons.

## UI building blocks worth reusing

| Module | What it gives us | License | Requirement | Decision |
| ------ | ---------------- | ------- | ----------- | -------- |
| [Microsoft.PowerShell.ConsoleGuiTools](https://github.com/PowerShell/ConsoleGuiTools) | `Out-ConsoleGridView -OutputMode Single -Filter -Title`: a real, filterable pick list in the terminal. Cross-platform. | MIT | PowerShell 7.2+ | **Use when present** for any picker with more than ~15 items (security groups, VM sizes, regions). Archived June 2026 as feature-complete; community fork is `tui-cs/PSTui`. Pin to 0.7.7. Optional dependency, never required. |
| `Out-GridView` (built in) | Same idea as a Windows GUI window. | Built in | Windows PowerShell 5.1 or PS 7 on Windows | Fallback picker on Windows when ConsoleGuiTools is missing. |
| [PwshSpectreConsole](https://github.com/ShaunLawrie/PwshSpectreConsole) | `Read-SpectreSelection -EnableSearch`, multi-select, panels, syntax-highlighted code blocks. Wraps Spectre.Console. | MIT | PowerShell 7 | Nice to have for the script preview pane. Not in phase 1. Keep it optional. |
| [FormsBuilder](https://www.powershellgallery.com/packages/FormsBuilder/) | WinForms forms from a PSD1 definition. | Unknown, 2019, few downloads | Windows | Skip. Unmaintained and license unclear. If a WinForms front end is ever built, write it directly on `System.Windows.Forms`. |
| [WinFormPS](https://github.com/lazywinadmin/WinFormPS) / WPFPS | Helpers for WinForms/WPF controls. | MIT | Windows | Only relevant if phase 6 (graphical window) happens. |

Numbered-list picker with type-to-filter is the floor. It works everywhere, including
Windows PowerShell 5.1, and the `azure` repo's `Start-AvdConsole.ps1` already has one.

## Shared design origins

The Azure component is the main source. Copied or adapted, with a comment naming the origin:

- `scripts/powershell/modules/AzHelpers/AzHelpers.psm1`: `Assert-AzContext` (sign in once, pick subscription). Reused as-is for the Azure lookup connection.
- `scripts/powershell/Start-AvdConsole.ps1`: `Read-Value`, `Read-YesNo`, `Select-Item`, `Select-EntraGroup`, the `$script:Remembered` answer cache, and the menu loop. These become the console renderer.
- `scripts/powershell/_template.ps1`: the `#region N. Title` + `WHAT / WHY / GOTCHA` comment style. Generated scripts use the same style so the two repos read alike.
- `docs/avd/environment-build-path.md` and `provisioning-order.md`: the ordered chains that become "build paths" (multi-task scripts) in the AVD section.
- `.github/workflows/validate.yml`, `.editorconfig`, `.gitignore`: copied.
- The repo rules (no client data, scripts are thin, state `Status:` in `.NOTES`): kept.

The Microsoft 365 component supplies related administrative workflows; the learning
catalog remains independent and never executes generated commands.

## Sources

- [Graph Explorer overview](https://learn.microsoft.com/en-us/graph/graph-explorer/graph-explorer-overview)
- [Petri: Graph Explorer PowerShell snippets](https://petri.com/microsoft-graph-explorer-powershell/)
- [azure-script on PyPI](https://pypi.org/project/azure-script)
- [leeford/MSGraphAPIGUI](https://github.com/leeford/MSGraphAPIGUI)
- [KelvinTegelaar/CIPP](https://github.com/KelvinTegelaar/CIPP)
- [Azure/azure-operation-script](https://github.com/Azure/azure-operation-script)
- [PowerShell/ConsoleGuiTools](https://github.com/PowerShell/ConsoleGuiTools)
- [ShaunLawrie/PwshSpectreConsole](https://github.com/ShaunLawrie/PwshSpectreConsole)
- [Azure Virtual Desktop landing zone design guide](https://learn.microsoft.com/en-us/Azure/architecture/landing-zones/azure-virtual-desktop/design-guide)
- [Nerdio Manager for Enterprise](https://getnerdio.com/nerdio-manager/enterprise)
- [TechPress: finding Graph PowerShell scopes](https://techpress.net/find-microsoft-graph-powershell-scopes/)
