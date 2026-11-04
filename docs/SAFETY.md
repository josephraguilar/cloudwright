# Cloudwright safe mode

Cloudwright 0.2.1 applies safe mode to **all of Cloudwright**. Learn generates text and
performs optional read lookups; option 3 / `cloudwright m365` permits tenant inspections
and reports. Azure/AVD execution is blocked pending a reviewed read-only implementation.
There is no supported flag, environment variable, menu toggle, or approval that enables
Microsoft 365 writes or Azure execution. Local setup, settings, reports, and logs can
still write files.

## Enforcement

- GUI and console tasks come from an explicit allowlist of 16 inspections and reports.
  Adding a script to a folder does not automatically admit it to safe mode.
- Prepared commands must name one allowed script with literal arguments. Additional
  commands, executable expressions, pipelines, redirection, and arbitrary paths are refused.
- All 35 catalog write scripts and the GDAP onboarding entry point refuse before sign-in
  or lookups. The shared mutation helper independently rejects writes, including approved plans,
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
**changes tenant permission grants** and requires a separate administrator decision.
Decline organization-wide consent unless that change was explicitly intended. To reverse
accidental admin consent, review the exact enterprise application's Permissions > Admin
consent entry in Entra and revoke the specific unwanted grant after checking its users
and dependencies. This is separate administrative work, never an automated safe-mode task.
See [Microsoft's review and revoke instructions](https://learn.microsoft.com/entra/identity/enterprise-apps/manage-application-permissions).

Requesting read scopes does not revoke previous grants. If the SDK reports additional
permissions from earlier consent, safe mode disconnects and refuses access. A dedicated
read-only Graph application is the recommended isolation design; this release does not
automatically provision or configure one. Review existing grants with your tenant
administrator; do not weaken the allowlist to get past a refusal. Matching context
metadata to actual token scopes still needs a disposable-tenant integration test.

See Microsoft's documentation for [Graph authentication and application isolation](https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands),
[Exchange command importing](https://learn.microsoft.com/powershell/module/exchangepowershell/connect-exchangeonline),
and [Exchange RBAC](https://learn.microsoft.com/exchange/permissions-exo/permissions-exo).

**Azure execution is disabled, including direct calls.** Every runtime PowerShell file
throws before its first executable statement: scripts, modules, GUI pages, guest scripts
and the Automation runbook. Module imports fail without exporting functions, even with
`-ErrorAction Continue`. The CLI entry point exits with an error. These blocks do not
depend on a shared policy file, session preference, environment variable or confirmation.
The retained implementation still needs review before any read-only Azure features return.
Bicep templates and documentation commands are reference material: Cloudwright cannot
constrain someone invoking external Azure tools or deploying a template separately.
Learn generates text only; copied commands can change or delete resources when executed
outside Learn. Its own Graph lookups reject broad sessions.
See [the review and remaining requirements](SECURITY-REVIEW.md).

The policy protects the reviewed toolkit's behavior. It cannot constrain modified source,
arbitrary PowerShell, or malicious dependencies running as the same user. SDK dependencies,
the host, and distribution source must be trusted. No code review can promise zero risk
with privileged credentials. Read-only reports can still expose sensitive tenant data;
keep local settings and reports out of Git and shared folders.

## Existing installations

The new bootstrap refuses cached snapshots without safety baseline 2 and preserves their
files. Install the reviewed release into a **new `-InstallPath`**, transfer only necessary
local settings, and verify `cloudwright version` reports `0.2.1`. A previously installed
command still uses its old checkout until reinstalled. Previously deployed Automation
runbooks and already-loaded old modules also retain their old behavior; use a fresh
PowerShell process with the reviewed installation. The marker checks compatibility,
not cryptographic integrity. The new archive and checkout must declare baseline 2 too.

Prefer a reviewed, commit-pinned checkout for administrative use. `irm | iex` from `main`
executes what is served at that moment; safeguards in that code cannot authenticate their
own replacement or defend against a compromised distribution path.

## Validation limits

Safety tests exercise the unmodified policy against fake APIs, including forged plans,
malformed commands, broad sessions, and tenant mismatches. End-to-end tests invoke every
catalog task without an approval recorder: read tasks must complete against fixtures,
write tasks must return the exact safe-mode refusal, and none may reach a write or browser.
An unrelated error fails the test. The fake Exchange session enforces the imported
command list, and the tenant-lookup canary runs under StrictMode. Legacy mutation-unit tests mock the policy against fake APIs to retain
algorithm coverage; GDAP runspace tests override it only in a temporary test copy.
Azure legacy algorithm tests use copies inside Pester TestDrive with the release block
removed; they are not evidence that production functions can execute. Separate release
tests use unmodified source for every script and isolated processes for module imports.

No live tenant was connected or changed. Mocked tests do not establish real SDK behavior,
permissions, tenant-specific correctness, or Windows desktop behavior. Validate those
separately in a disposable test tenant with a reader account before production use. Tenant
writes remain disabled pending a separately reviewed release.
