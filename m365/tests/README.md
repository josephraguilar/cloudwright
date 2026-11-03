# Tests

Pester tests for the modules. They run without Microsoft.Graph or ExchangeOnlineManagement
installed: Graph and Exchange cmdlets are stubbed inside the module scope and mocked, DNS
goes through a fake resolver, and the onboarding plan is built from the example configs.

```powershell
Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0
Invoke-Pester -Path ./tests
```

What is covered:

- `Safety`: the unmodified read-only policy, direct writes without a plan, forged plans,
  Graph scope/context checks, Exchange read imports, and prepared-command injection.
- `EndToEnd` also runs every task with no recorder and checks for zero writes/browser
  launches under the default policy. Legacy mutation-unit tests mock the policy against
  fake APIs; the GDAP hostless tests override it only in their temporary mirror.

- `M365Helpers`: password generation, settings and client config validation and derivation, tenant GUID resolution, DNS-over-HTTPS normalization; `Invoke-M365Change` (plan text, secrets hidden, quotes escaped, dry run runs nothing, approved plan enforced, placeholders, refusal when the verified connection changed or nobody signed in, audit log without secrets); Exchange tenant checks against a fake module where cmdlets follow the newest connection (client A, B, A again ends in A; one connection at a time; Graph/Exchange mismatch refused).
- `ExchangeHelpers`: SPF analysis (clean, missing EXO include, +all, two records, none, 11 lookups), DMARC analysis and the suggested record, template rendering, mail-contact idempotency and `-WhatIf`.
- `EntraHelpers`: Conditional Access exclusion preserves every other list and skips already-excluded policies; cloud user creation leaves existing users alone and sets no-expiry.
- `GdapHelpers`: role table and resolution, durations and the GA auto-extend rule, template validation, every row of the idempotency matrix in `Compare-GdapRelationship`, request body shape and lock, assignment idempotency and refusals, state file; plus `Invoke-M365WithRetry` and `Write-M365Log` redaction.
- `OnboardingHelpers`: plan order, every step's script exists, every invocation's parameters exist on its script, fan-out per domain and POC, the `contactAddress` override, phase filtering, run record without secrets.
- `EndToEnd`: runs every task script from a copy of the repo against recording stub cmdlets (no network, no tenant): every dry run makes no change and opens no browser; with an empty approved plan no script reaches a write cmdlet; no script fails on a parameter-binding mistake; and a static check that no write cmdlet is called anywhere except through `Invoke-M365Change`.
- `ToolkitHelpers`: catalog, declared parameter order, command lines (quote escaping incl. typographic quotes, booleans, tenant first, relative paths).

What is not covered: anything that needs a live tenant (real cmdlet parameter names, permissions). Every script's `.NOTES` block says whether it has been run for real.
