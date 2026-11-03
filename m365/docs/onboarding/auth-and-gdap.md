# Signing in: GDAP, scopes and sessions

How the scripts reach a client tenant, what they need to be granted, and what they never do.

## Two sessions per tenant

| Session | Module | Used for | Sign-in |
| ------- | ------ | -------- | ------- |
| Microsoft Graph | `Microsoft.Graph.*` | users, roles, Conditional Access, domains, organization contacts, mail folders, send mail, GDAP listing | `Connect-MgGraph -TenantId <client GUID> -Scopes ...` |
| Exchange Online | `ExchangeOnlineManagement` | mail contacts, distribution lists, shared mailboxes, aliases, inbox rules, DKIM | `Connect-ExchangeOnline -DelegatedOrganization <client>.onmicrosoft.com -UserPrincipalName <you>` |

Both are opened by `Assert-M365Graph` / `Assert-M365Exchange` in `M365Helpers`. You
authenticate with **your own partner account**; GDAP maps it to roles in the client tenant. No
account or app registration is created in the client tenant for this tooling.

- `Assert-M365Graph` reuses the open session only when its tenant GUID and scopes match.
- `Assert-M365Exchange -Organization <domain>` is always told the tenant (our own included).
  It asks the open session which tenant it is really in (the initial accepted domain, resolved
  to a GUID) and, when that is not the requested tenant, closes every Exchange connection and
  opens one new one, then checks again. Exchange cmdlets always follow the most recent
  connection, so keeping several open would let a change land in the wrong client.
  `-ExpectedTenantId` (the script's Graph tenant) makes it refuse when Graph and Exchange would
  be two different tenants.
- Every change then goes through `Invoke-M365Change`, which checks right before running that
  the Exchange cmdlet still comes from the verified connection and the Graph context is still
  the verified tenant.

The client config holds two identifiers. `tenantId` (GUID or any verified domain) is for
the Graph sign-in. `onmicrosoftDomain` is the tenant's root `<name>.onmicrosoft.com`, fixed
at tenant creation and typed in by the tech rather than discovered: it is the Exchange
`-DelegatedOrganization` and the UPN domain for break-glass and admin accounts.

`Assert-M365Graph` resolves whatever tenant identifier you pass (GUID, `.onmicrosoft.com`,
custom domain) to the tenant GUID through the public OpenID configuration endpoint, then
compares it to the open session. A domain name can therefore never silently match the wrong
tenant.

## GDAP roles the partner relationship must include

The Pax8-created relationship needs at least these Entra roles for the section 5 steps to
work. Fewer roles means the corresponding step fails with a 403 and the orchestrator reports
it; nothing partial is written.

| Step | Role needed |
| ---- | ----------- |
| 5.1 user review | Global Reader (or Directory Readers + Reports Reader for sign-in dates) |
| 5.3 break-glass, 5.4 admin accounts | User Administrator (create) + Privileged Role Administrator (assign roles) + Conditional Access Administrator (exclusions). In practice Global Administrator, because assigning Global Administrator requires it. |
| 5.6 DKIM, 5.10 to 5.13 Exchange objects | Exchange Administrator |
| 5.9 technical contact | Global Administrator (organization write) |

Delegated Graph scopes requested per phase are listed in `Get-OnboardingGraphScopes`
(`OnboardingHelpers`). First run per tenant prompts for consent once.

## Our tenant

The Internal phase uses `msp.homeTenantId`. Steps there need:

- Exchange: Recipient Management on our tenant (alias, contacts, list members, inbox rule on `clients@`).
- Graph `Mail.ReadWrite.Shared` plus Full Access on `clients@` to create its folder.
- Graph `DelegatedAdminRelationship.Read.All` to list GDAP relationships.
- `Send-M365TemplateMail.ps1` (not part of onboarding yet) needs `Mail.Send.Shared` plus Send As on the sending mailbox.

## Settings and secrets

| Lives in | Tracked in git | Contents |
| -------- | -------------- | -------- |
| `config/msp.settings.example.json` | yes | every key, placeholder values |
| `config/msp.settings.local.json` | no | our real tenant, mailboxes, naming conventions |
| `config/clients/example.client.json` | yes | every key, example client |
| `config/clients/<short>.local.json` | no | one real client |
| `HUDU_API_KEY` environment variable | no | Hudu REST key for `Add-HuduPassword` |
| `runs/` | no | per-run JSON records and user-review CSVs |

Break-glass, admin and new-user passwords are typed by the operator (twice, hidden, checked
for length and complexity) and saved in Hudu by the operator. The toolkit never stores them
and never writes them to the run record, a log, or a ticket. `-GeneratePassword` switches a
script to a random password shown once (and, for break-glass and admin accounts, stored in
Hudu when `HuduCompanyId` and `HUDU_API_KEY` are set). Scripts that prompt are marked
`Interactive: yes` in their notes; the GUI shows them with Copy enabled and Run disabled.

## What the scripts never do

- Delete users, mailboxes, lists or contacts. Review output is for a person to act on.
- Change a password on an account that already exists.
- Touch Conditional Access beyond appending one user to exclusion lists.
- Store a secret anywhere but the client's Hudu Passwords.
