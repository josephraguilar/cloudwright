# Microsoft 365 safe mode

Cloudwright 0.2.0 makes **option 3 / `cloudwright m365` read-only for tenant operations**.
There is no supported flag, environment variable, menu toggle, or approval that enables
Microsoft 365 writes. Local setup, settings, reports, and logs can still write files.

## Enforcement

- GUI and console tasks come from an explicit allowlist of 16 inspections and reports.
  Adding a script to a folder does not automatically admit it to safe mode.
- Prepared commands must name one allowed script with literal arguments. Additional
  commands, executable expressions, pipelines, redirection, and arbitrary paths are refused.
- The shared mutation helper rejects all writes, including direct scripts, approved plans,
  `-Confirm:$false`, and `-WhatIf`. Hudu writes are also blocked. Mutation scripts are not
  run merely to produce previews in safe mode.
- Graph requests only approved read scopes with `-ContextScope Process`. Unknown,
  persistent, app-only, and overprivileged contexts are not reused. The returned context
  must have the requested scopes, no unapproved scopes, and the intended tenant.
- Exchange imports only explicit read cmdlets. Unknown existing connections are replaced
  and the actual tenant is checked after connecting.
- GDAP inspection remains available. Request creation, assignment changes, and opening
  customer approval pages are disabled.

## Credentials and boundaries

Use a separate account with only the reader roles needed for your reports. **Do not use
Global Administrator as the routine inspection identity.** Exchange's `-CommandName`
limits imported commands; it does not downgrade the account's server-side RBAC permissions.
Graph scope/context checks reduce access but do not sandbox PowerShell. First-time consent
can grant an application access and requires a separate administrator decision.

See Microsoft's documentation for [Graph authentication and application isolation](https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands),
[Exchange command importing](https://learn.microsoft.com/powershell/module/exchangepowershell/connect-exchangeonline),
and [Exchange RBAC](https://learn.microsoft.com/exchange/permissions-exo/permissions-exo).

**Azure/AVD remains a write-capable administration component. It does not inherit this
Microsoft 365 policy.** Learn generates text only; copied commands can change or delete
resources when executed outside Learn. Its own Graph lookups reject broad sessions.
Automatic Azure directory cleanup by device/application display name is disabled;
those names do not establish resource ownership. Other Azure operations can still write.
See [the review and remaining requirements](SECURITY-REVIEW.md).

The policy protects the reviewed toolkit's behavior. It cannot constrain modified source,
arbitrary PowerShell, or malicious dependencies running as the same user. SDK dependencies,
the host, and distribution source must be trusted. No code review can promise zero risk
with privileged credentials. Read-only reports can still expose sensitive tenant data;
keep local settings and reports out of Git and shared folders.

## Existing installations

The new bootstrap refuses cached snapshots without safety baseline 1 and preserves their
files. Install the reviewed release into a **new `-InstallPath`**, transfer only necessary
local settings, and verify `cloudwright version` reports `0.2.0`. A previously installed
command still uses its old checkout until reinstalled. The marker checks compatibility,
not cryptographic integrity.

Prefer a reviewed, commit-pinned checkout for administrative use. `irm | iex` from `main`
executes what is served at that moment; safeguards in that code cannot authenticate their
own replacement or defend against a compromised distribution path.

## Validation limits

Safety tests exercise the unmodified policy against fake APIs, including forged plans,
malformed commands, broad sessions, and tenant mismatches. End-to-end tests invoke every
Microsoft 365 task without an approval recorder and check that no tenant write or browser
launch occurs. Legacy mutation-unit tests mock the policy against fake APIs to retain
algorithm coverage; GDAP runspace tests override it only in a temporary test copy.

No live tenant was connected or changed. Mocked tests do not establish real SDK behavior,
permissions, tenant-specific correctness, or Windows desktop behavior. Validate those
separately in a disposable test tenant with a reader account before production use. Tenant
writes remain disabled pending a separately reviewed release.
