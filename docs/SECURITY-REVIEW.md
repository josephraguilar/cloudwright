# Cloudwright safety review

Date: 2026-11-03. Original baseline: `fbb7f367e129d363f6e609680be204703c22cf0a`.
Candidate: version 0.2.2 on `safety/read-only-audit`.

## Decision and scope

**Do not treat this repository as approved for routine Global Administrator use.**
The owner confirmed safe mode covers all of Cloudwright. The interface permits Learn and
Microsoft 365 inspection/reporting. Azure execution is blocked in the root launcher and
every runtime entry file, including direct scripts, modules, guest scripts, GUI pages,
the Automation runbook and CLI. Its legacy bodies remain for review behind enforced
refusals. Learn generates text; running that text or deploying reference Bicep with external
tools can change resources. Local setup, settings and report files can change.

Microsoft 365 script/API mutations are blocked. **Accepting Microsoft's consent prompt
can still create or extend tenant permission grants.** Consent is a separate administrator
decision; decline organizational consent unless intended. See [SAFETY.md](SAFETY.md) for
permissions, recovery from accidental consent, distribution trust and upgrade limits.

Fable 5.1 and Opus 5.5 reviewed at max effort. Fable reviewed the original baseline;
Opus round r2 reviewed `54a9290` and found no reachable M365 tenant-write path, but rejected
publication due to correctness defects and inadequate end-to-end test evidence. The
changes below address those findings. Round r3 was stopped when the owner confirmed the
broader scope, before it returned a verdict. Round r4 reviewed `c1bebf7` and rejected
publication after finding error-preference bypasses despite 918 passing tests. The
0.2.2 candidate addresses those findings; a fresh independent review is pending.
This report is not an independent sign-off or a proof that every defect is absent.

## What the candidate enforces

- All 35 catalog write scripts and the GDAP onboarding entry point refuse before sign-in,
  lookups or prompts. The shared mutation helper independently refuses before rendering,
  plans, targets or confirmations. Direct calls, manual targets, forged plans, `-WhatIf`
  and `-Confirm:$false` do not unlock writes. Missing policy code prevents module import.
- GUI/console admit 16 explicit read tasks. Command validation requires one physical line,
  an allowed script, literal arguments and known parameters. It rejects executable
  expressions, extra statements, requirements directives and redirection. Worker startup
  uses literal arguments and stops on errors. GDAP reads recheck the partner tenant.
- Graph requests approved read scopes in Process context, rejects broad/unknown context
  metadata and verifies the tenant. Exchange imports a specific read-cmdlet list and
  verifies the actual tenant. Neither control downgrades an account's directory roles;
  Exchange's session retains the account's full server permissions.
- Hudu writes and customer approval browsers are blocked. The default GDAP assessment
  now asks for Global Reader only and requires the operator to supply a real reader-group
  object ID. Existing custom local templates are preserved and require separate review.
- Learn quotes PowerShell values and OData filters separately, restricts raw fields and
  rejects control/line-separator characters in answers (recursively) and unsafe context
  headers. It rejects broad Graph sessions, isolates lookup caches by context, and keeps
  the console usable when sign-in is refused.
- Azure directory deletion and Kerberos consent based on display names are disabled.
  Entra reimage refuses before authentication, drain or deletion. The retired cleanup
  switch refuses at entry; new Entra hosts check for existing records before VM creation;
  joins/preflight stop on stale records or failed lookups instead of continuing.
- All 101 Azure runtime PowerShell files begin with a separate scope that sets
  `$ErrorActionPreference = 'Stop'` and throws before initialization or function
  definitions. Suppressed caller-facing import errors leave no module or exports.
  The CLI also refuses, returning to the caller when sourced.
  There is no shared guard dependency or supported override. Parameter defaults contain
  only reviewed local reads; no Azure authentication occurs before the block.
- Bootstrap refuses old incompatible caches and preserves their settings. The policy file
  is required by install preflight. Version 0.2.2 requires safety baseline 3 in the archive,
  checkout and cache record; baseline 1 only covered M365 and baseline 2 had suppressible
  refusal errors. These markers are compatibility
  checks and do not verify authenticity.

## Opus round r2 findings and response

| Finding | Change / remaining boundary |
| --- | --- |
| C1: E2E stub errors allowed false-positive safety tests | Optional stub arguments now use strict-safe indexing. Tenant resolution has a StrictMode canary. Every catalog read must complete against fixtures; every catalog write must return the specific safe-mode refusal. An unrelated exception fails the test. The fake Exchange connection checks CommandName. The old 798-pass result alone did not establish this property and is superseded below. |
| C2: Entra reimage could destroy a VM before the new cleanup refusal | Entra reimage is refused before any initialization or destructive work. Retired cleanup flags refuse before changes. Stale lookups no longer swallow failures; new host preflight runs before VM creation. Automatic cleanup remains disabled. |
| C3: missing Exchange reads produced false report failures | Added Get-MailContact and Get-DistributionGroup. A reachability test walks the reviewed tasks/local functions and covers dynamic Get-$Kind calls; the integration stub enforces imported commands. Empty rule/relationship lists now produce ordinary failed checks rather than property errors. |
| C4: display-name lookup could consent to the wrong application | Automatic Kerberos consent is disabled by the Azure module block and an additional function refusal. A future design must bind exact application identity to the storage account; it must not overwrite unrelated consent scopes. |
| C5: newline escaped a commented rollback command | All answer values, including nested values and dictionary keys, reject control/line-separator characters before either rendering style. Regression tests include LF, CRLF, CR, tab and Unicode separators. |
| C6: fictional GUID did not trigger setup prompts | The shipped group ID is now an actual angle-bracket placeholder. Group and tenant fixture IDs differ. Broad-role legacy tests use their own explicit fixture. |
| C7: Learn console exited on refused Graph context | It catches the refusal, warns, and continues with typed values/offline mode. |
| C8: additional hardening | Missing-policy test now actually imports with Continue. Command AST rejects line breaks/requirements. M365 GUI relaunch uses NoProfile. Relative command paths still rely on the frontend's fixed working directory; same-process malicious code remains outside the boundary. |
| D1: Azure accessible from the same safe menu | Owner confirmed all of Cloudwright must be read-only. Root, console/GUI, direct scripts, module imports, guest scripts, runbook and CLI all refuse. Azure stays unavailable until a read-only implementation receives review. |
| D2/D3/D4: privilege, prior consent and consent writes | Documented limitations remain. Use a reader identity. Context metadata must be checked against actual token scopes in a disposable tenant. Existing broad consent can cause refusal; requesting reads does not revoke old grants. A dedicated read-only app is recommended but is not provisioned/configured automatically by this release. |
| D5: broad GDAP template nudges users toward GA | Default template now contains Global Reader only. Existing local templates are not silently changed. |

## Opus round r4 findings and response

| Finding | Change / remaining boundary |
| --- | --- |
| R4-1 critical: Azure bare throws could be suppressed | All 101 runtime files and the root Azure refusal now use a separate scope that sets Stop before throwing. Fresh-process tests invoke every script and import every module/manifest without try/catch, with common, global and wildcard default error settings. Dot-sourcing is covered too. Legacy bodies stay disabled. |
| R4-2 high: M365 write entry scripts could sign in with write scopes; direct mutation helper could execute | Authorization checks and the mutation helper set their own Stop preference before checking policy. The Hudu password helper refuses before reading settings. Tests exercise all 36 write entry points and direct helper calls with suppressed errors, requiring the specific refusal before a sign-in/body/write canary. |
| R4-3 medium: documentation overstated the boundary | The prior 918-pass result is explicitly superseded for this property. Documentation describes local preference enforcement, caller-facing import errors, tested runtime/settings, consent writes and untested integration behavior. |
| R4-4/R4-5: launcher, command validation, GDAP and Learn checks | Hardened the root refusal, literal-command validator, approval browser and Learn source/context checks. Learn generation and catalog validation also set Stop so malformed-answer rejection cannot be silenced. Direct regression probes cover these boundaries. |
| R4-6: Exchange reachability test had a fixed noun list | The test now collects all reachable external Get-* calls, excluding built-ins, repository functions, Graph commands and local Exchange connection metadata; dynamic recipient kinds remain covered. |
| R4-7: registrable fixture domains | Replaced the reported test/help domains with reserved .example names and corrected their matching expectations. |
| R4-8: small maintenance concerns | Sourced CLI refusal now returns instead of exiting the parent shell. The optional local test hook uses the same Pester 5.7.1 pin as root CI. Component workflow copies are inactive in the monorepo; root CI is authoritative. Action tags and runtime dependency pinning remain supply-chain work. |

The suggestion to relocate the onboarding script's direct mutation-helper call is deferred
until that disabled workflow is redesigned. Reusing the existing mailbox helper would
introduce a live lookup before its new-mailbox dry-run placeholder exists. The central
mutation refusal now establishes Stop itself, and its direct-call regression does not
depend on a module caller. This hardening does not fix the old optional plan mechanism.

## Other findings that must remain blocked or be fixed before writes return

Fable's H1/M8/M9 remain underlying defects in disabled M365 mutation workflows:
generated administrator passwords need reliable one-time delivery, inbox-rule creation
must preserve existing client-only rules, and TAP/password output must avoid normal GUI
logs. Conditional Access read-back must compare contents rather than list counts. Direct
write callers must require an approved exact plan; the old wrapper only checked a plan
when one was supplied. Fable's positive assessment of that mechanism applied to the
console/GUI workflow, not every direct invocation.

Legacy Azure still needs a central mutation guard/preview, explicit directory tenant and
resource subscription validation, enforced RDP expiry and narrow network validation,
and verified immutable identities for cleanup and consent. Blocking all entry points
does not fix the retained algorithms. Existing destructive examples in legacy documentation
are reference material and describe operations unavailable in this release.

Supply-chain risks remain: mutable IEX/main downloads, unpinned dependencies, host and SDK
trust. Old installed commands, loaded modules and deployed runbooks keep old behavior.
Read scopes and reports can expose
sensitive mail, identity and audit information; DNS checks can disclose domains to a
third-party resolver. Vendor integration names are not proof of personal attribution,
and a secret scan is not an anonymity certification.

## Validation and coverage

PowerShell 7.6.9, Pester 5.7.1: root **1,578**, Learn **137**, M365 **504**, Azure **246**:
**2,465 passed, 0 failed, 0 skipped**. All four suites ran against the current executable
source with fake APIs. All **419** PowerShell files parse;
configured analyzer checks report zero warnings/errors. ShellCheck passes and XAML/
example JSON parse. Unchanged infrastructure previously had 11 Bicep templates compiled.
The root suite includes **1,546 fresh-process refusal cases** across 89 Azure scripts,
12 module files, 12 manifests, 36 M365 write entry scripts and 13 direct helper/launcher
checks. It tests common SilentlyContinue/Ignore/Inquire; global and wildcard default
SilentlyContinue/Ignore; normal Continue; and dot-sourced scripts with the global settings.
The CLI refusal is also checked. The repository secret scan found no leaks; staged
identifier checks found no unexplained personal/company identifiers, email addresses,
credential patterns, phone numbers or Discord IDs. Fictional test addresses are retained.

The real-policy tests never mock the read-only guard. The E2E matrix exercises all 51
catalog tasks with expected outcomes, including no approved-plan recorder. It now
checks successful read completion and exact write refusal, not merely absence of writes.
Legacy mutation-unit tests deliberately mock the policy against fake APIs; GDAP hostless
runspaces do so only in a temporary test copy. Those tests do not prove production write
availability. Azure legacy tests explicitly remove the block only in copies inside
Pester TestDrive. The separate unmodified-policy matrix invokes every script and imports
every module in fresh processes, requiring the exact refusal and no exported functions.
No try/catch wraps the tested invocation. Sign-in, network, browser, write and protected-body
canaries fail the test if reached; the normal caller must not continue after a script
refusal. Import errors can be suppressed only if the module and exports remain absent.
Representative negative controls reproduce the previous candidate's Azure-script,
M365-script and direct-mutation-helper bypasses, then require refusal on the fixed source.
The old 918-pass result did not cover these error-preference properties.

No tenant was connected. No actual Graph/Exchange module sign-in, token/consent behavior,
Windows WPF/WinForms/WebView2 UI or CI execution was verified. Mocked APIs cannot establish
real service permissions or tenant-specific correctness. New guards were tested locally;
cloud resources, mailboxes and directory objects were never changed.

Both independent reviewers covered all components through a mixture of line reading,
whole-tree AST scans and tests. Neither established a complete line-by-line audit of all
legacy write bodies, Azure modules/guest scripts/Bicep, catalog, XAML and CI. Opus's
original fuzz found the newline problem; the new regression tests cover its cause.
Do not represent this as exhaustive certification of every file or zero risk with GA.

## Before production use

1. Complete the fresh independent review and address any remaining release blockers.
2. In a disposable Windows tenant, use a separate reader identity to validate all 16 read
   tasks, Exchange imports, tenant switching, SDK/token scope agreement, existing broad
   consent refusal and intentional consent handling. Determine the least role each
   report actually requires; Global Reader alone is not a promise that every report works.
3. Use server-side reader roles and appropriately consented applications. Exchange's
   import filter does not alter server RBAC; see [Microsoft's permissions documentation](https://learn.microsoft.com/exchange/permissions-exo/permissions-exo).
4. Install the reviewed, commit-pinned artifact into a new path and stop using old installs.
   Keep reports and local state confidential. Avoid mutable IEX/main for admin sessions.
5. Publish only after repository-owner approval. The public launcher has not acquired
   these local changes until that approval, publication and upgrade occur.
