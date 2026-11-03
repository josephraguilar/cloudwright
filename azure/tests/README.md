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
