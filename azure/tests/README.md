# Tests

[Pester](https://pester.dev) tests for the PowerShell modules. Run with:

```powershell
Invoke-Pester -Path ./tests
```

Keep tests free of real Azure calls so they run in CI without credentials.
Mock `Get-AzContext`, `Get-AzVM`, etc. with Pester's `Mock` when testing logic
that would otherwise hit ARM.

Beyond each module's own tests (manifest, exports, `-WhatIf` on every change, no
deletes), a few guards catch what would otherwise only fail on Windows with a click:

- `Gui.Tests.ps1`: the XAML parses and every theme has the same keys; every page in the
  nav tree has its function and the other way round; every `$Gui.Scripts` path and
  worker module exists; no closures, no `$script:` in the GUI; no local variable spelled
  like one of its function's parameters; the GUI never calls a delete.
- `Static.Tests.ps1`: every script calls `Set-AzScriptDefault` after its imports (so dry
  runs stay dry); every command a script, module or GUI page calls resolves to a
  function, a module export, an Az or Graph cmdlet, or a built-in.

CI has no Az module. Tests that need an Az call define a stub with every parameter the
modules pass (`function global:Invoke-AzRestMethod { param($Method, $Path, $Uri, $Payload) }`)
and mock it; keep the stub identical across files, because the first file to run defines it.

Release-policy tests in `Safety.Tests.ps1` use the unmodified source. Every direct script
must throw the exact release refusal, and module imports must leave no exports even
with `-ErrorAction Continue`. The checks include guest scripts and the Automation runbook.
These checks alone do not detect suppressed-throw bypasses: Pester's `Should -Throw`
wraps the call in `try/catch`, which changes PowerShell's error behavior.

The root `tests/RefusalPreferences.Tests.ps1` suite therefore runs fresh processes without
a catch around each invocation. It covers all runtime scripts, module files and manifests
under default settings; common SilentlyContinue, Ignore and Inquire; global and wildcard
default SilentlyContinue/Ignore; and dot-sourced scripts under those global preferences.
Every probe requires the expected refusal and no body/side-effect canary. Module-import
errors may be suppressed at the caller, but no module or exported function may remain.
Run the root suite as well as this component suite when changing a release block.

Legacy algorithm tests use `helpers/LegacyAzure.ps1` to make an isolated copy inside
Pester TestDrive and remove the release block only from that copy. They use fake APIs
and do not establish production write availability. Never run development tests in an
administrator session; test fixtures are deliberately outside the runtime safety boundary.
