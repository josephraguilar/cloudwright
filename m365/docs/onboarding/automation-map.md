# New-client onboarding: what can be automated

The Autotask onboarding checklist, step by step, with an honest call on each line. Source of
truth for the steps is the Hudu "Onboarding a New Client" series (SOPs 1 to 6B); this file
only says what a script can do about each one.

Legend

| Kind | Meaning |
| ---- | ------- |
| **Auto** | A script in this repo does it end to end, idempotently. |
| **Assisted** | A script does the API half; a person does the rest (DNS at a registrar, a form, a vendor portal). |
| **Manual** | No usable API, or a human decision. The orchestrator prints it as a reminder with the SOP link. |
| **Future** | An API exists but is a different product (Autotask, Pax8, NinjaOne, Hudu, Acronis, Axcient). Candidate for a later module in this repo. |

"In repo" says whether the script exists today. Nothing has been run against a live tenant yet;
each script's `.NOTES` block carries its `Status:` line.

## 1 - Set Up Client Account, Contract & Internal Comms

Runs in **our** tenant. SOP: configure your organization's documentation link locally.

| # | Step | Kind | How | In repo |
| - | ---- | ---- | --- | ------- |
| 1.1 | Update Client Primary Contact in Partner Dashboard | Manual | Franchise portal, no API. | reminder |
| 1.2 | Confirm client set as Managed Service & Customer in Autotask | Future | Autotask REST API: `Companies` entity, `companyType`, `classification`. | reminder |
| 1.3 | Assign correct contract in Autotask | Future | Autotask REST API: `Contracts`. | reminder |
| 1.4 | Add exclusion contract if Non-Profit | Future | Same. | reminder |
| 1.5 | Set correct tax region in Autotask | Future | Autotask REST API: `Companies.taxRegionID`. | reminder |
| 1.6 | Create client alias on `clients@` shared mailbox | **Auto** | `Set-Mailbox -EmailAddresses @{Add=}` adds `<name>.clients@msp.example` to the single `clients@` mailbox. The tech confirms the alias in the client config (console asks). | `exchange/Add-M365MailboxAlias.ps1` |
| 1.7 | Inbox rule in `clients@` routing client mail to their folder | **Auto** | Folder via Graph (`mailFolders/inbox/childFolders`), then two `New-InboxRule`s: subject/body contains client name; sent to the alias. Two rules because Exchange ANDs conditions inside one rule. | `exchange/New-M365MailboxFolder.ps1`, `exchange/New-M365InboxRule.ps1` |
| 1.8 | Create client account in Pax8 | Future | Pax8 Partner API (`/v1/companies`). | reminder |
| 1.9 | Pax8 CSP agreement to client tenant | Manual | The client must accept the Microsoft Customer Agreement; partner side is Pax8 UI. | reminder |
| 1.10 | Pax8 GDAP connection to client tenant | Manual | Pax8's relationship is the reseller link for licensing; it does not grant admin access. | reminder |
| 1.10b | Admin GDAP relationship to client tenant | **Assisted** | `partner/Start-M365GdapOnboarding.ps1` creates the request from our template, opens the approval page here (you approve with your customer-tenant admin account), waits, and assigns our security groups. | `partner/Start-M365GdapOnboarding.ps1` |
| 1.11 | Add POC to internal Outlook contacts + Client Notifications DL | **Auto** | `New-MailContact` in our tenant, `Add-DistributionGroupMember`. One contact per POC in the client config. | `exchange/New-M365MailContact.ps1`, `exchange/Add-M365DistributionListMember.ps1` |

## 2 - Build Client Documentation in Hudu

SOP: configure your organization's documentation link locally.

| # | Step | Kind | How | In repo |
| - | ---- | ---- | --- | ------- |
| 2.1 | Create client folder structure per KB Master Index | Future | Checked 2026-10-16: the Hudu MCP exposes folder list/show only, no create, so SOP #2 is right for the MCP. The Hudu REST API v1 documents `POST /api/v1/folders`; one test against our instance with the API key would settle whether a `hudu/` script can do it. | no |
| 2.2 | Create Client Overview from template | Future | `POST /api/v1/articles` with the template body and `company_id`. | no |
| 2.3 | Add VIP & POC info to Client Overview | Future | Fill from the client config `poc` list into the template. | no |
| 2.4 | Create Quick Start stub | Future | `POST /api/v1/articles`, draft. | no |
| 2.5 | Physical Network Diagram | Manual | Drawn by a person. | no |
| 2.6 | Logical Network Diagram | Manual | Drawn by a person. | no |
| 2.7 | Upload rack/device photos | Manual | Hudu upload UI (no API upload available to us). | no |
| 2.8 | Document configuration items | Manual | Needs discovery (section 4) first. | no |
| 2.9 | Create AI Context article | Future | Template + `company_id`, folder IDs from the folder listing. | no |
| 2.10 | Update KB Master Index client map | Future | Read article, insert row, `PUT /api/v1/articles/:id`. Risky to automate edits to a shared index; do it last. | no |

A `hudu/` module (`Get-HuduCompany`, `New-HuduArticleFromTemplate`, `Add-HuduPassword`) is the
obvious next area. `Add-HuduPassword` already exists in `M365Helpers` because the break-glass
step needs it.

## 3 - Deploy & Configure NinjaOne + Endpoint AV

SOP: configure your organization's documentation link locally.

| # | Step | Kind | How |
| - | ---- | ---- | --- |
| 3.1 | Create Organization in NinjaOne | Future | NinjaOne public API `POST /v2/organizations`. |
| 3.2 | Inform Tom of NinjaID | Future | Output of 3.1; a Teams/email notice. |
| 3.3 | Create Policy as child of base policy | Future | `POST /v2/policies` with `parentPolicyId`. |
| 3.4 | Enable OpenText AV in policy | Manual | Policy content editing is UI-only. |
| 3.5 | Enable local admin custom field | Manual | UI. |
| 3.6 | Adjust server update policy vs backup windows | Manual | Needs the backup schedule (section 6) first. |
| 3.7 | Deploy agent to all devices | Manual | Installer download per org is API-able; running it is on-site or via GPO/Intune. |
| 3.8 | Confirm hypervisor NTP | Manual | On the hypervisor. |
| 3.9 | Rename devices to naming convention | Future | NinjaOne API can set display name; the OS rename is a scripted task from Ninja. |
| 3.10 | Uninstall extra/conflicting AV | Manual | Ninja scripted task per product. |
| 3.11 | AV account access in OpenText portal | Manual | Vendor portal. |
| 3.12 | Map NinjaOne account under Autotask integration | Manual | Integration UI. |
| 3.13 | Map NinjaOne account/configs under Hudu integration | Manual | Integration UI. |

## 4 - Discover Network, Devices & Credentials

SOP: configure your organization's documentation link locally.

All six steps are gathering and storing. The one script-able piece is the storing: a
`hudu/Add-HuduPassword.ps1` wrapper (the function exists) so credentials gathered on a call
go straight into the client's Hudu Passwords without a copy-paste through chat or a ticket.
Everything else is Manual.

## 5 - Configure & Secure Client 365 Tenant

Runs in the **client** tenant over GDAP. SOP: configure your organization's documentation link locally.

| # | Step | Kind | How | In repo |
| - | ---- | ---- | --- | ------- |
| 5.1 | Review 365 accounts, remove unneeded ones | **Assisted** | Graph: every user with licenses, roles, last sign-in (needs Entra P1 for sign-in dates), optional MFA methods; CSV for the ticket. Removal stays a human call. | `entra/Get-M365UserReview.ps1` |
| 5.2 | Admin rights release form | Manual | Use the `IsAdmin` column from 5.1 to know who. | reminder |
| 5.3 | Create break-glass account | **Auto** | `breakglass@<client>.onmicrosoft.com`, Global Administrator, no expiry, excluded from every CA policy, password straight to Hudu Passwords (or shown once). | `entra/New-M365BreakGlassAccount.ps1` |
| 5.4 | Create domain & 365 tenant admin accounts | **Auto** | `mspadmin@<client>.onmicrosoft.com` (one per entry in `settings.adminAccounts`), roles assigned via the unified role API, password to Hudu. | `entra/New-M365AdminAccount.ps1` |
| 5.5 | Verify SPF | **Assisted** | DNS-over-HTTPS check: one record, EXO include present, `-all`/`~all`, recursive lookup count against 10. Fix is at the registrar. | `mailauth/Test-M365SpfRecord.ps1` |
| 5.6 | Set up DKIM | **Assisted** | Creates the 2048-bit signing config (disabled) so Exchange generates the CNAMEs, prints them, and on the next run enables signing once both resolve. DMARC suggestion follows our DKIM/DMARC SOP. | `mailauth/Enable-M365Dkim.ps1`, `mailauth/Test-M365DmarcRecord.ps1` |
| 5.7 | Connect in Augment & map GDAP | **Assisted** | `Test-M365GdapCompliance.ps1` checks the relationship is active, covers the template roles and has our group assignments. Augment mapping is manual. | `partner/Test-M365GdapCompliance.ps1`, `partner/Get-M365GdapRelationship.ps1` |
| 5.8 | American HelpDesk access | Manual | Could become another `adminAccounts` entry once their access model is written down. | reminder |
| 5.9 | MSP support contact in tenant | **Assisted** | Graph `organization.technicalNotificationMails` (+ security/compliance list). The help desk card has no public API. | `entra/Set-M365TechnicalContact.ps1` |
| 5.10 | `clients@` as a contact, hidden from GAL | **Auto** | `New-MailContact` + `HiddenFromAddressListsEnabled`. The contact's address is the client's alias (`<name>.clients@msp.example`), which is the same `clients@` mailbox, so the inbox rule from 1.7 files the mail. Set `contactAddress` in the client config to use the bare `clients@` address instead. | `exchange/New-M365MailContact.ps1` |
| 5.11 | `IT@<domain>` DL with our alias | **Auto** | `New-DistributionGroup`, external senders allowed, member = the contact from 5.10. | `exchange/New-M365DistributionList.ps1` |
| 5.12 | `MSPalerts@<domain>` DL with support email | **Auto** | Hidden contact for the support address first, then the list. | `exchange/New-M365MailContact.ps1`, `exchange/New-M365DistributionList.ps1` |
| 5.13 | `911@<domain>` mailbox if ironScales | **Auto** | `New-Mailbox -Shared`. Only when `ironScales: true`. | `exchange/New-M365SharedMailbox.ps1` |
| 5.14 | Welcome letter | Manual (deferred) | Parked. `exchange/Send-M365TemplateMail.ps1` can send a `{{token}}` HTML template from our tenant when the letter text is approved and the recipient rule is decided; until then the orchestrator lists it as a reminder. | reminder |

| 5.15 | Security baseline audit (added) | **Assisted** | `Test-M365SecurityBaseline.ps1 -Client <name>`: 17 Microsoft posture checks plus 8 MSP-standard checks (break-glass has GA and is CA-excluded, mspadmin exists, technical contact, hidden contacts, IT@ and MSPalerts@ with the right members). Fail rows name the remediation script. | `security/Test-M365SecurityBaseline.ps1` |

## 6A / 6B - Backups (Acronis / Axcient)

Both vendors have partner APIs (Acronis Cyber Platform API; Axcient x360Recover API).
Account creation and plan templates are automatable in principle; "confirm backup schedule
doesn't conflict with patch window" is a comparison against the NinjaOne policy from 3.6.
Nothing in repo yet. Documenting the account in Hudu 30 - Backup & DR would reuse the Hudu
module from section 2.

## Totals for the 365 half (sections 1 and 5)

| | Count |
| - | ----- |
| Steps on the two checklists | 25 |
| Auto (script does all of it) | 11 |
| Assisted (script does the API half) | 6 |
| Manual (printed as reminders) | 8, of which 4 have an API in another product and 1 (welcome letter) is deferred |

## Order of operations the orchestrator enforces

1. Internal phase (our tenant): alias, folder, rules, POC contact and list.
2. Tenant phase (client tenant): review, break-glass, admins, SPF, DKIM, GDAP check, technical contact, hidden contact(s), lists, 911@.

Sessions are dropped between phases so a stale home-tenant Exchange session can never
create an object in the wrong place. Graph sign-ins compare tenant GUIDs, not domain names,
for the same reason.
