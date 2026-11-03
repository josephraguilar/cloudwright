# Script library

Scripts the GUI (Scripting > Windows scripts) and `apps/Invoke-GuestScript.ps1`
run inside VMs through managed Run Commands: as SYSTEM, in Windows PowerShell 5.1,
one VM or a whole host pool at a time.

- `windows/` ships with the repo. Read-mostly checks and small, safe changes.
  Nothing here deletes files, users or data.
- `local/` is yours and gitignored. Drop a `.ps1` there and it shows up in the
  list. Give it a `.SYNOPSIS` and a `param()` block; the list reads both.

Parameters are passed as strings, so a script should take `[string]` or simple
types and convert itself. Output is captured (the last 4 KB per VM) and shown in
the log and the results table. Exit with a non-zero code to report failure.
