# Adding a task to the catalog

This is the procedure for every "add catalog task" work item in `TASKS.md`. Follow it
exactly. Most tasks take one `.psd1` file, one line in a test, and one generated golden
file.

## Before you start

1. Read `docs/architecture.md`, section "Task definition". That is the schema.
2. Open `catalog/azure/create/resource-group.psd1` (simplest), `catalog/azure/network/new-vnet.psd1`
   (multi-step, `Raw` step, variable passed between steps), and
   `catalog/m365/groups/new-security-group.psd1` (Graph, literal `$true`/`@()` parameters,
   `{{Field:raw}}` inside a quoted filter). Copy the closest one.
3. Open the official cmdlet reference on learn.microsoft.com for every cmdlet you will emit.
   Do not write a parameter from memory. Parameter names change between Az versions.

## Rules

- **Data only.** No scriptblocks, no `[ordered]`, no expressions. `Import-PowerShellDataFile`
  must load it. If you need logic, you need a `Raw` step or a second task.
- **Read-only lookups only.** `Source.Cmdlet` verb must be `Get`, `Find`, `Search`, or
  `Resolve`. The test fails otherwise.
- **No tenant data.** Examples and defaults are generic (`rg-avd-lab`, `eastus2`,
  `00000000-0000-0000-0000-000000000000`). Never a real name, ID, or domain.
- **Secrets are `Type = 'Secret'`.** They are never asked for and never rendered. The
  script prompts for them at run time.
- **Every step has `What` and `Why`.** One or two sentences each, written for someone
  seeing this cmdlet for the first time. Say what depends on what. Add `Gotcha` when there
  is a known trap.
- **Every field has `Help`.** One or two sentences a first-timer needs: what the value is, what
  it affects, a common mistake. It appears on the (i) icon next to the control. The test
  fails a field without it.
- **`Learn` is three bullets or fewer.** Concepts, not steps.
- **`Verify` reads back.** At least one `Get-*` line that proves the change landed.
- **`Rollback` undoes.** One line per thing created, with a trailing comment stating the
  blast radius. Omit only when there is nothing to undo (read-only tasks).
- **`Status = 'Untested'`** until a person runs the generated script for real. Only a
  person flips it to `Tested yyyy-mm-dd`.
- **`Prerequisites` lists task Ids** that should be done first (not modules). Only Ids that
  exist. Cycles fail the test.
- **Every flag comes from a field.** Hardcoded parameter values fail the test unless listed in
  the step's `Fixed`. Fixed is only for values that define the task. Anything a person might
  change (a SKU, a TLS version, an extension version, automapping) is a field with a `Default`.
- **State-changing cmdlets keep the `-WhatIf` hint.** Set `WhatIf = $false` only on cmdlets
  that do not support it (`Connect-*`, `Set-AzContext`, `New-*Config` object builders,
  anything returning a config object instead of touching Azure).

## Procedure

1. Pick the Id from `TASKS.md`: `<area>.<section>.<slug>`. The file is
   `catalog/<area>/<section>/<slug>.psd1`. The test checks they match.
2. Create the file from the closest example. Fill every key.
3. Add one case to `$Cases` in `tests/Generator.Tests.ps1`, with a complete, generic answer
   set. If the task has optional fields, add a second case that leaves them blank.
4. Generate the golden file once:
   ```powershell
   $env:MS_SCRIPTER_UPDATE_GOLDEN = '1'; Invoke-Pester ./tests -Output Detailed; Remove-Item Env:MS_SCRIPTER_UPDATE_GOLDEN
   ```
5. **Read `tests/golden/<case>.ps1` top to bottom.** You are reviewing the script a
   person will paste and run. Check: every parameter name against the docs, quoting,
   variable names flowing between steps, the verify line, the rollback line. Fix the
   `.psd1`, regenerate, read again.
6. Run `Invoke-Pester ./tests` with the env var unset. All green.
7. Run `Invoke-ScriptAnalyzer -Path ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1`
   if you touched anything under `src/`. Zero findings.
8. If a field's `Source.Cmdlet` is new to the catalog, add a table of sample rows for it to
   `catalog/_contoso.psd1` (Contoso mode). Rows need the `Display` and `Value` properties the
   field reads, plus any property the Source filters on. Fictional names, `@contoso.com` only.
9. Add the task to the table in `README.md` under its section, with `Untested`.
10. Commit: `catalog: add <task id>`. One task per commit.

## Field cookbook

| You need | Use |
| -------- | --- |
| A resource group | `Type = 'Choice'; Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' }` |
| A region | `Source = @{ Cmdlet = 'Get-AzLocation'; Display = 'DisplayName'; Value = 'Location'; Auth = 'Azure' }` with `Default = 'eastus2'` |
| A VNet in the chosen group | `Source = @{ Cmdlet = 'Get-AzVirtualNetwork'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' }` |
| A VM size | `Source = @{ Cmdlet = 'Get-AzVMSize'; Parameters = @{ Location = '{{Location}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' }` |
| An Entra group (Azure side) | `Source = @{ Cmdlet = 'Get-AzADGroup'; Display = 'DisplayName'; Value = 'Id'; Auth = 'Azure' }` |
| An Entra group (Graph side) | `Source = @{ Cmdlet = 'Get-MgGroup'; Parameters = @{ All = '$true' }; Display = 'DisplayName'; Value = 'Id'; Auth = 'Graph' }` |
| A user | `Source = @{ Cmdlet = 'Get-MgUser'; Parameters = @{ All = '$true' }; Display = 'UserPrincipalName'; Value = 'Id'; Auth = 'Graph' }` |
| A mailbox (Exchange) | `Source = @{ Cmdlet = 'Get-EXOMailbox'; Parameters = @{ ResultSize = 'Unlimited' }; Display = 'PrimarySmtpAddress'; Value = 'PrimarySmtpAddress'; Auth = 'ExchangeOnline' }` |
| A license SKU | `Source = @{ Cmdlet = 'Get-MgSubscribedSku'; Display = 'SkuPartNumber'; Value = 'SkuId'; Auth = 'Graph' }` |
| A role | `Source = @{ Cmdlet = 'Get-AzRoleDefinition'; Display = 'Name'; Value = 'Name'; Auth = 'Azure' }` |
| Fixed choices | `Type = 'Choice'; Options = @('Pooled', 'Personal')` or `Options = @(@{ Display = 'Breadth first (spread users)'; Value = 'BreadthFirst' }, ...)` |
| A password or credential | `Type = 'Secret'` (+ `SecretKind = 'SecureString'` for `-Password`, `'PlainText'` for Graph password profiles; default is `Get-Credential`) |
| A `[bool]` parameter (not a switch) | Add the name to the step's `BoolParameters` so one-liners emit `-Name $true`. Check the docs: `-Force` is a switch, `-AutoMapping` and `-DeliverToMailboxAndForward` are bools. |
| Same value as another field | `Type = 'Reference'; From = 'OtherField'` |
| A literal in a splat | Put it straight in Parameters: `SecurityEnabled = '$true'`, `GroupTypes = '@()'`, `Subnet = '$subnet'` |
| A field inside a quoted string | `{{Field:raw}}`, e.g. `-Filter "displayName eq '{{DisplayName:raw}}'"` |

Note on `Parameters = @{ All = '$true' }` in a Source: `Resolve-MsSource` strips the quotes
and passes the string `$true`, which Graph cmdlets accept for a switch. If a lookup needs a
real boolean, leave the parameter out and filter client-side instead.

## Keep one-liners clean

The default output is one command per line with no variables. Design steps so that works:

- A helper object (`New-AzVirtualNetworkSubnetConfig`, `New-AzVMConfig` chains) should be a
  Cmdlet step with `Output`, and the consuming step passes it as the whole parameter
  value (`Subnet = '$subnet'`). The renderer nests it inline: `-Subnet (New-AzVirtual...)`.
- A step that only exists to teach (read an ID off a result, print it) gets
  `OnlyExplained = $true`. It shows in the Explained style and is dropped from one-liners.
- Avoid Raw steps that depend on an earlier step's variable unless there is no cmdlet
  form; they force a `$name =` assignment into the one-liner output.
- Check `tests/golden/oneliner-*.ps1` after generating. If you see a `$`, ask whether the
  person pasting this line by line actually needs it.

## When the cmdlet needs something splatting cannot say

Use a `Raw` step. Examples: a pipeline, a `foreach`, reading a property off a previous
step's output, a `Set-*` after a `Get-*`. Keep it to a few lines and still write `What`/`Why`.

```powershell
@{
    Title = 'Attach the NSG to the subnet'
    What  = 'Gets the VNet, updates the subnet config in memory, writes the VNet back.'
    Why   = 'Subnet properties are changed through the parent VNet. There is no Set-AzSubnet.'
    Raw   = @(
        '$vnet = Get-AzVirtualNetwork -Name {{VNetName}} -ResourceGroupName {{ResourceGroupName}}'
        'Set-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name {{SubnetName}} -AddressPrefix {{SubnetPrefix}} -NetworkSecurityGroup $nsg | Out-Null'
        '$vnet | Set-AzVirtualNetwork'
    )
}
```

## Build paths

`catalog/paths/<slug>.psd1`. `Tasks` is the ordered list of task Ids. `Share` maps a later
task's field to an earlier task's field so it is asked once. Add a golden case with
`Tasks = @(...)` and `Share = @{...}` and review the whole combined script, especially that
variables from one task are not reused with a different meaning in the next.
