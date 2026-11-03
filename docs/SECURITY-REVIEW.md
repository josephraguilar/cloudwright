# Cloudwright safety review

Date: 2026-11-03. Baseline: `fbb7f367e129d363f6e609680be204703c22cf0a`.
Candidate: version 0.2.0 on `safety/read-only-audit`.

## Decision

**Do not treat this repository as approved for routine Global Administrator use.**
The candidate makes Microsoft 365 (option 3) read-only for tenant operations. Azure
administration remains write-capable. Local installation, settings, logs, and report
exports can still write files. Learn only generates scripts; executing them elsewhere
is outside its safety boundary.

The primary review and the Fable 5.1 max-effort baseline review found concrete defects.
Fable saved its report before its provider hit a usage limit. The requested Opus 5.5
max-effort review of the candidate is pending; this is not an independent sign-off.
Neither static analysis nor mocked tests prove the absence of every defect. See
[SAFETY.md](SAFETY.md) for the security boundary and upgrade requirements.

## Implemented safeguards and corrections

1. **Mandatory Microsoft 365 write refusal.** `M365Helpers/Safety.ps1` supplies a
   constant read-only policy. `Invoke-M365Change` checks it before any preview,
   confirmation, target override, or approval-plan processing. Direct scripts,
   forged plans, `-WhatIf`, and `-Confirm:$false` cannot unlock writes. Hudu writes
   and GDAP approval-page launches are also refused. A missing policy file fails
   module initialization rather than falling through to the legacy implementation.
2. **Restricted task dispatch.** The console and GUI admit 16 explicitly listed
   read tasks. An AST check accepts one allowed script with literal arguments and
   known parameter names; expressions, additional commands, redirection, and
   arbitrary script paths are refused. GUI worker initialization uses literal
   arguments and stops on initialization errors. Each GDAP read rechecks the partner
   tenant instead of trusting a previous GUI sign-in.
3. **Narrower authentication.** Graph requests an exact read-scope allowlist with
   process-scoped authentication, rejects unknown/overprivileged context metadata,
   and checks the returned tenant and scopes. Exchange imports an explicit read
   cmdlet list and replaces connections not established under that policy. These
   are application controls, not a reduction of a Global Administrator's actual
   role. Real SDK behavior has not been verified against a tenant.
4. **Safer generated PowerShell.** Learn now escapes PowerShell's typographic quote
   delimiters, renders OData filters as escaped literals, restricts remaining raw
   substitutions, and rejects multiline/comment-terminating context values. Its
   Graph lookups reject broad sessions and cache results by tenant, subscription,
   account, command, and parameters.
5. **Azure directory cleanup disabled.** The original device query interpolated an
   unescaped name and deleted every match. The lookup now validates and encodes the
   name and verifies returned names. Both device and Kerberos application deletion
   by display name are disabled, even with confirmation suppressed: a name cannot
   establish ownership. Automatic cleanup and rejoin flows that relied on these
   functions now stop or report skipped directory cleanup. Other Azure mutations
   remain enabled.
6. **Upgrade and example hygiene.** The bootstrap refuses cached snapshots without
   the safe-mode baseline and preserves existing local settings. Install preflight
   requires the policy file. The GDAP example's unexplained group GUID was replaced
   with an explicitly fictional placeholder; no evidence established whether the
   old value was real. The baseline marker is not a signature or integrity check.

## Findings and disposition

IDs H/M/L refer to Fable's baseline report, not to a claim that a whole component is
now safe. Items described as blocked still require fixes before writes return.

| Finding | Candidate disposition / required next change |
| --- | --- |
| H1: generated administrator password lost in the GUI | Account creation is blocked. Before re-enabling, require a verified secret-delivery destination or a one-time secret dialog, surface storage failures, and avoid normal activity logs. |
| H2: crafted device filter can broaden directory deletion | Fixed by validating/encoding lookup input and disabling all directory cleanup by display name. Future cleanup must bind a verified immutable object ID to the original resource and tenant. |
| M1/M2: Azure writes can skip preview or the central runner | Open. Route every mutation through a common guard; require an explicit preview and exact approved parameters. Changing only the default answer is insufficient. |
| M3: Azure directory operations use the current tenant implicitly | Open. Require an explicit tenant and verify it at the API boundary; also verify every resource subscription against the selected context. |
| M4: RDP access accepts broad networks and has no automatic expiry | Open. The expiry is descriptive until a revoke is run. Implement enforced expiry and narrow source validation, or disable this capability. |
| M5: Learn raw substitutions and typographic quotes change generated code | Fixed for the identified generation paths, with adversarial regression tests. Catalog content and the commands the operator executes still require review. |
| M6: write scopes, broad cached sessions, manual target override | Read scopes/process contexts enforced; the unconditional mutation block makes manual targets unable to authorize writes. Server-side reader roles and a dedicated approved application are still required for stronger isolation. |
| M7: direct M365 scripts can write without a preview | Blocked unconditionally. Before writes return, make plan enforcement mandatory at the mutation boundary, including direct calls. |
| M8: inbox-rule creation can discard client-only rules | Creation is blocked. Review mailbox rule preservation and explicit consent before any future write-enabled release. |
| M9: generated passwords/TAPs reach normal output or GUI logs | Creation is blocked. A future write-enabled GUI needs dedicated secret handling, redaction, and delivery/error tests. |
| L1: unexplained group GUID in example | Replaced with a clearly fictional value. |
| L2: vendor names and onboarding conventions | Generic integration names are not proof of a connection to a particular operator. A separate editorial decision remains about publishing the detailed workflow; no claim of completed anonymity verification follows from a secret scan. |
| L3: mutable IEX bootstrap and dependency versions | Open trust boundary. Use a reviewed commit and verified artifacts; pin/test release dependencies and add signing or independently verifiable release digests. |
| L4: persisted sessions and local state | M365 Graph now uses process scope and approval browsers are disabled. Azure cache behavior and broader session cleanup remain open. Read-only reports still contain sensitive information. |
| L5: CA read-back compares counts, ambiguous application deletion, incomplete static guard, third-party lookups | CA writes are blocked; name-based application deletion is disabled; Learn broad-session reuse is fixed. Content-level concurrency checking, exhaustive mutation classification, and third-party disclosure choices remain future work. |

The primary review additionally found that the old shared M365 wrapper only enforced
an approved plan when one was present. Fable's positive description of plan binding
applies to the console/GUI workflow, not to every direct module invocation. The new
unconditional guard is tested with no recorder at all. A future write-enabled version
must not treat the old plan mechanism as sufficient without that correction.

The GDAP example still describes a broad legacy role set including Global
Administrator. Safe mode cannot create or assign it. Replace that default with
task-specific least privilege before considering any future GDAP write workflow.

## Validation evidence and limits

- PowerShell 7.6.9 / Pester 5.7.1: root **29**, Learn **135**, M365 **500**, Azure
  **134** tests passed (**798 total**). The affected GDAP tests were also rerun after
  replacing the example identifier: **75 passed** (a subset, not additional tests).
- All **414 PowerShell files** parsed without errors. Repository analyzer checks
  are run across root and all three components. Eleven Bicep templates compiled;
  the Bash script passed ShellCheck; XAML and example JSON parsed.
- The unmodified M365 policy is covered by adversarial tests and an end-to-end
  attempt to run each task with no approved-plan recorder. Legacy mutation tests
  deliberately mock the policy against fake APIs; a temporary GDAP test copy does
  the same for isolated runspaces. Those legacy tests do not demonstrate production
  write availability.
- Tests use fake SDK/API commands. No tenant was connected; no cloud resource,
  mailbox, directory object, or service was changed. Windows WPF/WinForms/WebView2,
  real sign-in/consent, service permissions, and real module-version behavior were
  not exercised. Parser and analyzer success is not a security proof.
- Review covered all components and scanned the repository. Fable explicitly
  identifies Azure function bodies, in-guest scripts, Bicep, XAML, and parts of the
  catalog/tests as scanned or sampled rather than read line by line. A complete
  line-by-line independent audit is therefore **not yet established**.

## Requirements before production use

1. Complete the requested independent Opus review and address its blockers.
2. Validate the permitted reads in a disposable tenant on Windows using a separate
   reader identity, including tenant switching and already-consented broad scopes.
   Confirm that the deployed dependencies and actual returned token context behave
   as assumed. Do not use production GA credentials for this verification.
3. For enforcement independent of this code, provision only the required reader
   roles and application permissions; separate read and write identities. Exchange's
   imported-command filter does not change server RBAC. See [Microsoft's Exchange
   permissions documentation](https://learn.microsoft.com/exchange/permissions-exo/permissions-exo).
4. Keep Azure outside any claim of read-only operation until its mutations are
   centrally blocked or reviewed and the open targeting/expiry issues are resolved.
5. Publish only the reviewed candidate through the repository approval process, then
   reinstall into a new directory. Existing installs and the public `main` IEX URL
   do not acquire these local changes until publication and upgrade.
