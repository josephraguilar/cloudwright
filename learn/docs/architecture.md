# Architecture

## The one rule

**ms-scripter never runs a generated command.** The only things it executes are:

1. Signing in (`Connect-AzAccount`, `Connect-MgGraph` with read-only scopes), and only if you ask.
2. Read-only lookups that fill pick lists (`Get-AzResourceGroup`, `Get-MgGroup`, ...).

Everything else is text. You read it, copy it, paste it into another window, and run it
yourself, one step at a time. A Pester test (`tests/ReadOnly.Tests.ps1`) fails the build if
any lookup in the catalog uses a verb other than `Get`, `Find`, `Search`, or `Resolve`, and if
the engine source contains `Invoke-Expression`, `Invoke-Command`, `& $`, or `.Invoke(`.

## Layers

```
Start-MsScripter.ps1        Entry point. Loads the module, runs the console UI.
src/MsScripter/             The engine. A normal PowerShell module.
  Public/
    Get-MsTaskCatalog       Load + validate every task file under catalog/
    Get-MsTask              One task by Id
    Test-MsTaskDefinition   Validate a task hashtable, return a list of problems
    New-MsScript            Task + answers -> script text. Pure. No prompts, no network.
    Show-MsScripterWindow   The WinForms UI (tree -> fields -> Generate). Windows only. Default.
    Show-MsScripter         The console UI loop (sections -> task -> fields -> generate). -Console, and the non-Windows fallback.
  Private/
    Read-MsField            Ask one field: text, yes/no, pick list, secret
    Select-MsItem           The picker. ConsoleGuiTools if present, else Out-GridView
                            on Windows, else numbered list with type-to-filter.
    Resolve-MsSource        Run a read-only lookup for a Choice field. Cached per session.
    Assert-MsAzContext      Copied from azure/AzHelpers (Assert-AzContext)
    Assert-MsGraphContext   Connect-MgGraph with read-only scopes, reuse if already connected
    Format-MsScriptBlock    Render one step (splat hashtable + cmdlet call)
    Format-MsValue          Quote a string, render a hashtable/array/switch/int
catalog/                    One .psd1 per task. Folder = section path. Data only.
  azure/<section>/<task>.psd1
  m365/<section>/<task>.psd1
  entra/<section>/<task>.psd1
  paths/<name>.psd1         Build paths: an ordered list of task Ids rendered as one script
tests/                      Pester. Catalog validation, generator golden files, read-only guard
docs/                       This file, TASKS.md, authoring guide, prior art
out/                        Where generated scripts are saved. Gitignored.
```

Why a module plus a thin entry script: same split as the `azure` repo. Logic lives where
Pester can import it without a terminal; `Start-MsScripter.ps1` is the only file allowed to
`Write-Host`.

## Task definition (the catalog schema)

One task is one `.psd1` file that evaluates to a hashtable. PSD1 because
`Import-PowerShellDataFile` loads it **without executing code**, which keeps the catalog
data and lets a model author tasks without being able to break the engine. No scriptblocks.

```powershell
@{
    Id       = 'azure.create.resource-group'      # <area>.<section>.<slug>, matches the path
    Title    = 'Create a resource group'
    Summary  = 'A resource group is a lifecycle, RBAC, and cost boundary. Delete it and everything inside goes.'
    Learn    = @(                                  # shown before the questions and in the script header
        'Resource groups are not a network or identity boundary. A VM in one group can use a subnet in another.'
        'Pick the split before building. Moving resources between groups later is possible for most types but never pleasant.'
    )
    Requires = @{
        Auth    = 'Azure'                          # Azure | Graph | ExchangeOnline | None
        Modules = @('Az.Resources')                # what the GENERATED script needs installed
        Roles   = @('Contributor on the subscription')
    }
    Prerequisites = @('azure.context.set-subscription')   # task Ids shown as "Do these first"
    Fields = @(
        @{
            Name     = 'Name'
            Label    = 'Resource group name'
            Type     = 'String'
            Required = $true
            Pattern  = '^[-\w\.\(\)]{1,90}$'
            Help     = '1-90 chars. Letters, digits, underscore, hyphen, period, parentheses.'   # required: shown on the (i) icon
            Example  = 'rg-avd-lab'
        }
        @{
            Name     = 'Location'
            Label    = 'Region'
            Type     = 'Choice'
            Required = $true
            Default  = 'eastus2'
            Source   = @{ Cmdlet = 'Get-AzLocation'; Display = 'DisplayName'; Value = 'Location'; Auth = 'Azure' }
        }
        @{
            Name     = 'Tags'
            Label    = 'Tags (key=value, comma separated)'
            Type     = 'Hashtable'
            Required = $false
            Example  = 'env=lab, owner=jane'
        }
    )
    Steps = @(
        @{
            Title      = 'Create the resource group'
            What       = 'One ARM call. Idempotent: running it again on an existing group of the same name and region is a no-op.'
            Why        = 'Every other Azure resource needs a group to live in.'
            Cmdlet     = 'New-AzResourceGroup'
            Parameters = [ordered]@{ Name = '{{Name}}'; Location = '{{Location}}'; Tag = '{{Tags}}' }
            Output     = 'rg'                       # becomes $rg = ... so later steps can reference it
        }
    )
    Verify   = @('Get-AzResourceGroup -Name {{Name}} | Format-List ResourceGroupName, Location, ProvisioningState')
    Rollback = @('Remove-AzResourceGroup -Name {{Name}} -Force    # Deletes EVERYTHING in the group. No undo.')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.resources/new-azresourcegroup')
    Status   = 'Untested'                           # Untested | Tested yyyy-mm-dd (someone ran the generated script for real)
}
```

### Field types

| Type | Asked as | Rendered in the script as |
| ---- | -------- | ------------------------- |
| `String` | Free text, validated against `Pattern` if set | `'value'` (single-quoted, embedded quotes doubled) |
| `Int` | Free text, must parse | bare number |
| `Bool` | Yes/No | switch parameter present when true, dropped when false |
| `TrueFalse` | Yes/No | always written: `$true` or `$false` (for `[bool]` parameters whose off state matters, like `-AllowBlobPublicAccess $false`) |
| `Choice` | Picker. Items from `Options` (static) or `Source` (live lookup). Always allows typing a value instead. | `'value'` |
| `MultiChoice` | Picker, pick many | `@('a', 'b')` |
| `Hashtable` | `key=value, key=value` | `@{ key = 'value'; key = 'value' }` |
| `Secret` | **Never asked.** | `(Get-Credential ...)` by default; `SecretKind = 'SecureString'` gives `(Read-Host -AsSecureString)`, `'PlainText'` gives `(Read-Host)` for APIs that want a string (Graph password profiles). The secret is typed where the script runs, never here |
| `Reference` | Not asked. Copies another field's value (`From = 'OtherField'`). | Same as the referenced field |

Parameters whose rendered value is empty are dropped from the splat. That is how optional
fields work without any `if` in the template.

### Sources (live lookups)

```powershell
Source = @{
    Cmdlet     = 'Get-AzVirtualNetwork'            # verb MUST be Get, Find, Search, or Resolve
    Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }   # may reference earlier fields
    Display    = 'Name'                            # property shown in the picker
    Value      = 'Name'                            # property written into the script
    Auth       = 'Azure'                           # which connection it needs
}
```

If the user is not signed in, or the lookup fails, the picker degrades to free text and
says so. The tool must always work offline.

### Steps

Two shapes. Prefer the first.

```powershell
# Splatted cmdlet. The renderer builds the hashtable, drops empty values, calls the cmdlet.
@{ Title = ''; What = ''; Why = ''; Cmdlet = 'New-AzVM'; Parameters = [ordered]@{ ... }; Output = 'vm'; When = 'FieldName' }

# Raw lines, for anything splatting cannot express. {{Field}} tokens are substituted.
@{ Title = ''; What = ''; Why = ''; Raw = @('$token = (New-AzWvdRegistrationInfo ...).Token'); When = 'FieldName' }
```

`When` makes the whole step conditional on a field being non-empty (or `$true` for Bool).
**Every flag in the output must come from a field.** A Cmdlet parameter or Raw flag with a
hardcoded value fails the catalog test unless the step lists it under `Fixed = @('Shared')`,
which is reserved for values that define the task (`-Shared` on "create a shared mailbox",
`-Force` on a delete, an extension's Publisher). If a person might reasonably want a different
value, it is a field with a `Default`, not a Fixed.
`BoolParameters = @('AutoMapping')` names parameters that are `[bool]`, not `[switch]`, so
one-liners write `-AutoMapping $true` instead of bare `-AutoMapping` (bare fails for a bool).
`OnlyExplained = $true` marks a step as teaching glue (reading a property off a result,
printing an ID) that appears only in the Explained style, never in one-liners.

`{{Field}}` substitution is the only template feature. No loops, no expressions. If a task
needs more than that, it needs a `Raw` step or it is really two tasks.

### Build paths

`catalog/paths/avd-entra-lab.psd1`:

```powershell
@{
    Id      = 'path.avd.entra-lab'
    Title   = 'AVD lab, Entra-joined, from nothing'
    Summary = 'Resource group, network, profile storage, host pool, one session host.'
    Tasks   = @('azure.create.resource-group', 'azure.network.new-vnet', 'azure.storage.new-storage-account', 'azure.avd.new-host-pool', 'azure.avd.new-session-host')
    Share   = @{ ResourceGroupName = 'Name'; Location = 'Location' }   # answer once, reuse: later field <- earlier task's field
}
```

The UI asks every task's questions in order (shared answers asked once), then renders one
script with a numbered region per task. This is the "learn the steps" feature: you see
that a session host needs a host pool, which needs a resource group, as regions 1, 2, 3.

## Output styles

`New-MsScript -Style OneLiner` (default) emits one command per line and nothing else:
`Verb-Noun -Param value -Param value`. Switch values become bare `-Param`, `$false`
becomes `-Param:$false`, empty values are dropped. **No variables**: when a step's result
is only ever passed whole to a later cmdlet (a `New-*Config` object, say), the call is
nested inline in parentheses instead; steps marked `OnlyExplained` are skipped. A `$name =`
assignment appears only when something that is actually emitted needs it by name (a Raw
line, or Verify/Rollback when those are switched on). `-WithContext`, `-WithVerify`,
`-WithRollback` add those sections (the window exposes them as check boxes).

`-Style Explained` is the long form below: header, `WHAT`/`WHY` comments, splatted
parameters, verify and rollback regions. The window's "Explain steps" check box.

## Generated script shape (Explained style)

```powershell
<#
.SYNOPSIS
    Create a resource group
.DESCRIPTION
    <Summary>
    <Learn bullets>
.NOTES
    Generated by ms-scripter on 2026-10-17 for Azure subscription <name> (<id>).
    Review every line before running. Run one region at a time.
    Requires: Az.Resources
    Roles:    Contributor on the subscription
    Docs:     <urls>
#>
#Requires -Modules Az.Resources

#region 0. Context ------------------------------------------------------------
#   WHAT   Confirm you are in the tenant and subscription you think you are.
#   WHY    Running the right script against the wrong subscription is the classic mistake.
Get-AzContext | Format-List Account, Tenant, Subscription
# Set-AzContext -Subscription '<id>'
#endregion

#region 1. Create the resource group -----------------------------------------
#   WHAT   One ARM call...
#   WHY    Every other Azure resource...
$rg = @{
    Name     = 'rg-avd-lab'
    Location = 'eastus2'
    Tag      = @{ env = 'lab' }
}
New-AzResourceGroup @rg -WhatIf     # dry run first
New-AzResourceGroup @rg
#endregion

#region 2. Verify ------------------------------------------------------------
Get-AzResourceGroup -Name 'rg-avd-lab' | Format-List ResourceGroupName, Location, ProvisioningState
#endregion

#region 3. Rollback (only if you need to undo) -------------------------------
# Remove-AzResourceGroup -Name 'rg-avd-lab' -Force    # Deletes EVERYTHING in the group. No undo.
#endregion
```

State-changing cmdlets get a commented `-WhatIf` line above the real call when the cmdlet
supports it (the renderer checks `Get-Command` if the module is installed, otherwise it
emits the line anyway with a note). Rollback lines are commented out. Secrets are never in
the file.

## Window (default UI)

`Show-MsScripterWindow`, WinForms, Windows only. Top bar: Sign in Azure / Sign in Graph
(read-only scopes) / subscription picker / Refresh lists (clears the lookup cache). Left:
search box (filters the tree as you type on title, section, summary, and emitted cmdlet
names; Ctrl+F focuses it, Esc clears, Down/Enter jumps to the tree) above a TreeView built
from catalog folders. Right top: one row per field: label, control, and an
(i) icon whose tooltip (hover) and message box (click) show the field's `Help`, example,
format, and where its list comes from. `Help` is required on every field.
String and Int are TextBoxes, Bool a CheckBox, Choice an editable ComboBox that calls
`Resolve-MsSource` the first time it is dropped down, MultiChoice a CheckedListBox plus a
free-text box, Hashtable a TextBox (`k=v, k=v`). Secret and Reference fields show a note
and no control. Right bottom: Generate, Add to script (append), style check boxes, Copy,
Save (SaveFileDialog, defaults to `out/`), Clear, and the read-only output box.

All window state lives in `$script:Win` because event handlers run after the function
that created them has returned. Handlers never call anything but the public engine
functions and `Resolve-MsSource`.

## Contoso mode

`Set-MsContosoMode` flips a module flag. While it is on, `Resolve-MsSource` never checks a
connection or runs a cmdlet: it returns rows from `catalog/_contoso.psd1`, keyed by the
lookup cmdlet name, filtered by any `Source.Parameters` the rows have a property for
(`ResourceGroupName`, `HostPoolName`). Fields with no `Default` fall back to their `Example`.
The window pre-selects the first sample row in every drop-down, disables the sign-in buttons,
tints the form, and re-renders the current task. The sample file is data only, every address
is `@contoso.com` or `@contoso.onmicrosoft.com`, and `tests/Contoso.Tests.ps1` fails if a
field's lookup cmdlet has no sample rows or a row lacks the Display/Value property a field
reads. Adding a task with a new lookup cmdlet means adding a table there too.

## Console UI flow

```
Start-MsScripter.ps1
  Sign in to Azure?  [y/N]     -> Assert-MsAzContext, pick subscription (optional)
  Sign in to Graph?  [y/N]     -> Assert-MsGraphContext, read-only scopes (optional)
  ------------------------------------------------------------
  Azure | Microsoft 365 | Entra ID | Build paths | Q
    Create | Manage | Inspect | Delete
      Resource group | Network | Virtual machine | Disk | Storage | ...
        <task>  -> shows Summary, Learn, Prerequisites, Requires
                -> asks each Field in order (picker if Choice and signed in)
                -> Review: numbered list of answers, pick a number to change one
                -> [G]enerate
                   -> prints the script
                   -> [C]opy to clipboard  [S]ave to out/  [A]z CLI variant (if the task has one)
                      [N]ext task (append to the same script)  [B]ack
```

Answers are remembered for the session under the field Name (`ResourceGroupName` typed once
is the default everywhere), the same trick as `$script:Remembered` in `Start-AvdConsole.ps1`.
Nothing is written to disk unless you press S.

## Authentication for lookups

| Connection | Cmdlet | Scopes / notes |
| ---------- | ------ | -------------- |
| Azure | `Connect-AzAccount` via `Assert-MsAzContext` | Whatever the user has. Lookups are all `Get-*`. |
| Graph | `Connect-MgGraph -Scopes` | `User.Read.All`, `Group.Read.All`, `Directory.Read.All`, `Organization.Read.All`. Read-only. Added per phase, never `*.ReadWrite.*`. Verify current names with `Find-MgGraphPermission` before changing. |
| Exchange Online | `Connect-ExchangeOnline` | Phase 4. Lookups via `Get-EXOMailbox`, `Get-EXORecipient`. |

Generated scripts contain their **own** connect line (commented) in region 0 so they run
in a fresh window. The tool's session is never reused by the pasted script.

## Testing strategy

- `tests/Catalog.Tests.ps1`: every `.psd1` under `catalog/` loads with
  `Import-PowerShellDataFile`, passes `Test-MsTaskDefinition`, has an `Id` matching its path,
  references only existing task Ids in `Prerequisites`, and every `{{Token}}` names a Field.
- `tests/Generator.Tests.ps1`: `New-MsScript` with fixed answers produces exactly the text in
  `tests/golden/<task-id>.ps1`. Golden files are reviewed by a person once, then guard
  against regressions. Also: generated text parses (`[System.Management.Automation.Language.Parser]::ParseInput` returns no errors).
- `tests/ReadOnly.Tests.ps1`: the guard described at the top.
- `tests/Module.Tests.ps1`: manifest valid, exported functions as expected (same as the `azure` repo).

Interactive pickers are not unit tested. They are small and copied from a working console.
