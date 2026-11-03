# 365-MGMT

Part of [Cloudwright](../README.md). After installing the root launcher, run
`cloudwright m365` or `cloudwright m365 -Console`.
Direct-script examples below run from this `m365/` directory.

Scripts, modules and a console for administering Microsoft 365 tenants as an MSP: onboarding a
new client's tenant, securing it, and the everyday "add a contact / list / alias / admin"
tasks. Same shape as the `azure` repo: reusable logic in modules, thin single-purpose scripts
on top, an orchestrator that composes them, a menu console that calls them.

First target: the Microsoft 365 half of our new-client checklist (sections 1 and 5 of the
Hudu "Onboarding a New Client" SOPs). `docs/onboarding/automation-map.md` goes through every
checklist line and says what a script can do about it.

## Rules

1. **Nothing client-specific in git.** Real tenant names, addresses and IDs live in
   `config/msp.settings.local.json` and `config/clients/<client>.local.json`, which are
   gitignored. The `*.example.json` files document every key with placeholders.
2. **One job per script.** `New-M365MailContact.ps1` creates a mail contact. It does not
   also create the list the contact goes in; `New-M365DistributionList.ps1` does that. The
   onboarding orchestrator and the console compose them. Anything used twice goes in a module.
3. **Idempotent and `-WhatIf` clean.** Every script that changes state checks first, creates
   only what is missing, and does nothing under `-WhatIf`. It never adopts an existing object
   that is not exactly what it was asked to create (same UPN, same address) unless you pass an
   explicit opt-in switch. Re-running is how you finish an
   onboarding that waited on DNS or a form.
4. **Never delete.** Review scripts tell a person what is stale; a person removes it.
5. **Passwords are typed by you, twice, and saved by you.** The toolkit never stores one and never
   writes one to a log, a run record, or a ticket. `-GeneratePassword` is the opt-in alternative.
6. **Every script states whether it has been run.** The `.NOTES` block carries a `Status:`
   line: `Untested`, or `Tested <yyyy-mm-dd>` once it has run for real.
7. **Every change is shown before it runs, and only what was shown can run.** Every tenant
   change goes through one function, `Invoke-M365Change`. It shows the tenant, what changes in
   plain words, and the exact Exchange/Graph command (passwords hidden), then runs exactly
   that. The GUI and console always do a dry run first and list those changes; you approve the
   list, and the run is refused anything that is not on it. See "How a change runs" below.
8. **Every command names its tenant.** `-Organization` / `-TenantId` are required; there is no
   "blank means our tenant". Our own tenant is passed explicitly like any client. Before any
   change the Exchange session is asked which tenant it is really in, and a script that uses
   Graph and Exchange refuses to run if the two are different tenants.

## Layout

```
.
├── Start-Toolkit.ps1               The one command: setup if needed, then GUI (or -Console)
├── Install-Toolkit.ps1             Modules, local configs with prompts, optional WebView2; safe to re-run
├── scripts/powershell/
│   ├── Start-M365Console.ps1       Menu: pick a client, pick a task, dry run, run
│   ├── gui/                        WPF front end (Windows): Start-M365Gui.ps1, Theme.xaml (Genesis tokens), Views/ (GDAP + generic task view)
│   ├── _template.ps1               Copy this to start a new script
│   ├── modules/
│   │   ├── M365Helpers/            Settings, client config, GDAP sign-in (Graph + Exchange), DNS, passwords, Hudu
│   │   ├── ExchangeHelpers/        Contacts, lists, shared mailboxes, aliases, folders, rules, templated mail, SPF/DKIM/DMARC
│   │   ├── EntraHelpers/           User review, break-glass, admin accounts, roles, CA exclusions, technical contact, GDAP
│   │   ├── OnboardingHelpers/      The checklist as data: step order, applicability, which script, which parameters
│   │   ├── GdapHelpers/            GDAP: template, discovery, compliance, request + lock, approval polling, assignments, state
│   │   ├── SecurityHelpers/        Security baseline: fact collection, comparison, idempotent remediations
│   │   └── ToolkitHelpers/         The catalog: discovers task scripts, their parameters and help; composes command lines
│   ├── entra/                      One script per Entra task
│   ├── exchange/                   One script per Exchange task
│   ├── mailauth/                   SPF, DKIM, DMARC
│   ├── partner/                    GDAP: customers, relationships, compliance, request, wait, assignments, guided onboarding
│   ├── security/                   Baseline audit (read-only) and remediations: audit logging, forwarding, Security Defaults, external tag, SMTP AUTH
│   ├── reports/                    Licenses, admins + MFA, mailbox permissions, forwarding
│   ├── lifecycle/                  New-user onboarding and offboarding: small steps + composites driven by the client's newUserDefaults
│   └── onboarding/                 New-ClientOnboarding.ps1 (runs the checklist), Test-ClientOnboarding.ps1 (verifies it)
├── config/                         msp.settings.example.json, gdap-roles.example.json, baselines/security.example.json, clients/example.client.json (+ gitignored *.local.json)
├── templates/                      welcome-letter.html (draft {{token}} template, not wired in yet)
├── docs/
│   ├── onboarding/automation-map.md   Every checklist step: Auto / Assisted / Manual / Future, and how
│   ├── onboarding/auth-and-gdap.md    How sign-in works, scopes, GDAP roles needed, where secrets live
│   ├── gdap/implementation-plan.md    GDAP module: Graph endpoints, permissions, approval UX decision, state, idempotency matrix
│   ├── gui/design-reference.md, gui/design.md   The Genesis design file and how its tokens map to the WPF theme
│   └── roadmap.md                     Script table with status, what comes next
├── tests/                          Pester tests; run without Graph or Exchange installed
└── .github/workflows/validate.yml  CI: PSScriptAnalyzer, Pester, JSON validity
```

### Where things go

| I want to...                                          | Put it in                                   |
| ----------------------------------------------------- | ------------------------------------------- |
| Do one admin task from the command line               | `scripts/powershell/<area>/Verb-M365Noun.ps1` |
| Share logic between two scripts                       | the matching `modules/*Helpers` module      |
| Add a step to the onboarding checklist                | `Get-OnboardingPlan` in `OnboardingHelpers` |
| Make a script appear in the GUI and console           | nothing: drop it in an area folder with comment help and a Status line; the catalog finds it |
| Add a security check                                  | a row in `config/baselines/security.*.json` and a collector in `SecurityHelpers.Get-M365SecurityFact` |
| Change a naming convention (break-glass, admin, alias, lists) | `config/msp.settings.local.json`     |
| Record a design decision                              | `docs/`                                     |

## Conventions

Same as the `azure` repo. Every file is split into numbered `#region` sections with a short
`WHAT` / `WHY` / optional `GOTCHA` note, so the region titles alone tell the story.
`Verb-Noun` with approved verbs, comment-based help, `[CmdletBinding(SupportsShouldProcess)]`
on anything that changes state, objects out (not text), `Write-Host` only in the console and
checklist output.

Scripts in `entra/` take `-TenantId` (GUID or any verified domain) and sign in with Graph.
Scripts in `exchange/`, `mailauth/`, `security/` and the Exchange-side `lifecycle/` scripts take
a required `-Organization` (the tenant's onmicrosoft.com domain or any verified domain; for our
own tenant, our domain). The partner account to sign in as is `-SignInAs` (defaults from
settings), so `-UserPrincipalName` only ever means a target user. The client config carries
`tenantId` for the Graph sign-in and `onmicrosoftDomain`, the root domain fixed when the tenant
was created, which is where break-glass and admin accounts live. Onboarding checks they are the
same tenant before it signs in anywhere.

Sessions: Graph is reused only when its tenant GUID matches. Exchange keeps one connection at a
time: it asks the open session which tenant it is in (its initial accepted domain) and reconnects
when that is not the requested tenant. Exchange cmdlets always follow the most recent connection,
so "reusing" an older connection to another client would send changes there; that cannot happen.

## How a change runs

Every change is planned, shown, approved, then run exactly as shown:

```
  Changes it will make (2):
   1. [contoso.onmicrosoft.com] Create mail contact 'Example MSP' that delivers to contoso.clients@msp.example
        New-MailContact -Name 'Example MSP' -DisplayName 'Example MSP' -ExternalEmailAddress 'contoso.clients@msp.example'
   2. [contoso.onmicrosoft.com] Hide mail contact contoso.clients@msp.example from the address lists (GAL)
        Set-MailContact -Identity <the mail contact created above (contoso.clients@msp.example)> -HiddenFromAddressListsEnabled:$true
  Type yes to make these 2 change(s):
```

- The dry run (`-WhatIf`) prints the same lines as `What if:` in a terminal and lists them in the
  GUI and console. Nothing changes and no browser opens.
- `<...>` is a value that only exists once an earlier change has run (a new object's id).
- The run is started with that list as its approved plan. A change that is not on the list is
  refused before it runs; a read-only task runs with an empty list, so it cannot change anything.
- Each change runs with `-ErrorAction Stop` and, where the cmdlet has it, `-Confirm:$false`
  (you already confirmed). Each run is written to `runs/logs/<date>.jsonl` with its tenant and
  command, secrets hidden.

## Getting started

One command. It installs the PowerShell modules it needs, creates your local config files,
asks for the two or three values it cannot know, offers to fetch WebView2, and opens the GUI:

```powershell
.\Start-Toolkit.ps1              # GUI (Windows)
.\Start-Toolkit.ps1 -Console     # text menu, any OS
.\Start-Toolkit.ps1 -Setup       # re-run setup (modules, placeholders, WebView2)
```

Values you will be asked for: your partner sign-in UPN, the support mailbox address, and
(optional, for GDAP writes) the object IDs of the two GDAP security groups. Enter skips a
value; read-only features work without it. Set `HUDU_API_KEY` in your environment if you want
break-glass and admin passwords written straight to Hudu.

Everything the launcher does is also available piecemeal: `Install-Toolkit.ps1`, the
`scripts/powershell/*` task scripts, `Start-M365Console.ps1`, `gui/Start-M365Gui.ps1`.

GDAP from the command line, read-only first:

```powershell
./scripts/powershell/partner/Test-M365GdapCompliance.ps1 -CustomerTenantId contoso.onmicrosoft.com | Format-List
./scripts/powershell/partner/Start-M365GdapOnboarding.ps1 -CustomerTenantId contoso.onmicrosoft.com -CustomerName 'Contoso Dental' -WhatIf
```

Tenant onboarding, dry run first:

```powershell
./scripts/powershell/onboarding/New-ClientOnboarding.ps1 -Client contoso -WhatIf
./scripts/powershell/onboarding/New-ClientOnboarding.ps1 -Client contoso -Interactive
./scripts/powershell/onboarding/New-ClientOnboarding.ps1 -Client contoso -Phase Tenant -Only 5.6   # after DNS is published
./scripts/powershell/onboarding/Test-ClientOnboarding.ps1 -Client contoso | Format-Table Id, Result, Check, Detail -Wrap
```

Security audit (read-only), reports, new user, offboarding:

```powershell
./scripts/powershell/lifecycle/Invoke-M365UserOnboarding.ps1 -Client contoso -FirstName Jane -LastName Doe -JobTitle 'Office Manager' -WhatIf
./scripts/powershell/security/Test-M365SecurityBaseline.ps1 -TenantId contoso.onmicrosoft.com -Organization contoso.onmicrosoft.com | Format-Table Result, Severity, Title, Actual -Wrap
./scripts/powershell/reports/Get-M365ForwardingReport.ps1 -Organization contoso.onmicrosoft.com -IncludeInboxRules -ExternalOnly
./scripts/powershell/lifecycle/Invoke-M365UserOffboarding.ps1 -TenantId contoso.onmicrosoft.com -Organization contoso.onmicrosoft.com -UserPrincipalName jane@contoso.com -ForwardTo manager@contoso.com -GrantAccessTo manager@contoso.com -WhatIf
```

Single tasks, no client config needed:

```powershell
./scripts/powershell/mailauth/Test-M365SpfRecord.ps1 -Domain contoso.com
./scripts/powershell/mailauth/Enable-M365Dkim.ps1 -Organization contoso.onmicrosoft.com -Domain contoso.com
./scripts/powershell/exchange/New-M365MailContact.ps1 -Organization contoso.onmicrosoft.com -Name 'Vendor' -ExternalEmailAddress v@vendor.example -HiddenFromAddressLists -WhatIf
./scripts/powershell/entra/Get-M365UserReview.ps1 -TenantId contoso.onmicrosoft.com | Where-Object Stale
```

Run the same checks CI runs before pushing:

```powershell
Install-Module PSScriptAnalyzer, Pester -Scope CurrentUser
Invoke-ScriptAnalyzer -Path ./scripts/powershell -Recurse -Severity Warning, Error
Invoke-Pester -Path ./tests
```

## Status

Conventions baked into the defaults: break-glass `breakglass@<client>.onmicrosoft.com`, admin
`mspadmin@<client>.onmicrosoft.com`, client alias `<name>.clients@msp.example` on the single
`clients@` mailbox, two support lines (business hours and 24x7, chosen per client by
`support24x7`). The welcome letter (5.14) is a manual reminder for now.

Nothing has been run against a live tenant yet. The SPF and DMARC scripts have been exercised
against public DNS; everything else is lint-clean, unit-tested with mocked Graph and Exchange
cmdlets, and run end to end against stub cmdlets (`tests/EndToEnd.Tests.ps1`: every dry run
changes nothing, nothing changes outside an approved plan, no parameter-binding mistakes).
Stubs cannot catch a wrong Exchange/Graph parameter name or a missing permission; expect the
first real run to surface those. Do it in a lab tenant with a dry run first, then flip the
`Status:` line and update `docs/roadmap.md`.
