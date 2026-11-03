# Roadmap

Goal: the recurring Microsoft 365 work of an MSP (onboarding a tenant, securing it, the
everyday "add a contact / list / alias" tickets) as short, single-purpose scripts you can run
from the command line, from the console menu, or from an orchestrator, and later from an app.

Status is per script, in its `.NOTES` block. Nothing has been run against a live tenant yet.

## Task scripts (one job each)

| Area | Script | Does | Status |
| ---- | ------ | ---- | ------ |
| entra | `Get-M365UserReview.ps1` | users + licenses + roles + last sign-in (+MFA), CSV | Untested |
| entra | `New-M365BreakGlassAccount.ps1` | emergency GA account, CA-excluded, password to Hudu | Untested |
| entra | `New-M365AdminAccount.ps1` | named MSP admin with roles, password to Hudu | Untested |
| entra | `Add-M365RoleAssignment.ps1` | assign an Entra role by UPN | Untested |
| entra | `Add-M365ConditionalAccessExclusion.ps1` | exclude a user from CA policies | Untested |
| entra | `Set-M365TechnicalContact.ps1` | add our address to tenant notification contacts | Untested |
| entra | `Get-M365Group.ps1` | group object ids by display name (fills GDAP template group ids) | Untested |
| exchange | `New-M365MailContact.ps1` | external contact, optionally hidden | Untested |
| exchange | `New-M365DistributionList.ps1` | list + members, external senders allowed | Untested |
| exchange | `Add-M365DistributionListMember.ps1` | add a member | Untested |
| exchange | `New-M365SharedMailbox.ps1` | shared mailbox (+ Full Access) | Untested |
| exchange | `Add-M365MailboxAlias.ps1` | secondary SMTP address | Untested |
| exchange | `New-M365MailboxFolder.ps1` | folder in a (shared) mailbox via Graph | Untested |
| exchange | `New-M365InboxRule.ps1` | server-side rule to a folder | Untested |
| exchange | `Send-M365TemplateMail.ps1` | HTML mail from a `{{token}}` template (not wired into onboarding yet) | Untested |
| mailauth | `Test-M365SpfRecord.ps1` | SPF analysis incl. lookup count | Tested 2026-10-16 (public DNS) |
| mailauth | `Test-M365DmarcRecord.ps1` | DMARC analysis + suggested record | Tested 2026-10-16 (public DNS) |
| mailauth | `Get-M365DkimStatus.ps1` | signing state + CNAME presence | Untested |
| mailauth | `Enable-M365Dkim.ps1` | create config, enable when DNS is live | Untested |
| mailauth | `Test-M365MailAuth.ps1` | SPF + DKIM + DMARC in one row | Untested (DKIM half) |
| partner | `Get-M365GdapCustomer.ps1` | customers with a GDAP relationship | Untested |
| partner | `Get-M365GdapRelationship.ps1` | GDAP relationships, roles, expiry, group assignments | Untested |
| partner | `Test-M365GdapCompliance.ps1` | relationships vs. template: state, missing roles/assignments, proposed actions | Untested |
| partner | `New-M365GdapRequest.ps1` | create relationship + lock for approval, show link | Untested |
| partner | `Wait-M365GdapApproval.ps1` | poll until active / failed / timeout | Untested |
| partner | `Set-M365GdapAccessAssignment.ps1` | assign template security groups to an active relationship | Untested |
| partner | `Start-M365GdapOnboarding.ps1` | guided, idempotent GDAP onboarding end to end | Untested |
| security | `Test-M365SecurityBaseline.ps1` | read-only audit vs. config/baselines/security (17 checks) | Untested |
| security | `Set-M365AuditLogging.ps1`, `Set-M365ExternalForwarding.ps1`, `Set-M365ExternalSenderTag.ps1`, `Set-M365SmtpAuth.ps1`, `Set-M365SecurityDefaults.ps1` | idempotent remediations for baseline failures | Untested |
| reports | `Get-M365LicenseReport.ps1`, `Get-M365AdminReport.ps1`, `Get-M365MailboxPermissionReport.ps1`, `Get-M365ForwardingReport.ps1` | read-only reports, optional CSV | Untested |
| lifecycle | `Disable-M365UserSignIn.ps1`, `Remove-M365UserLicense.ps1`, `ConvertTo-M365SharedMailbox.ps1`, `Set-M365MailboxForwarding.ps1`, `Add-M365MailboxPermission.ps1`, `Set-M365MailboxAutoReply.ps1` | offboarding steps, each idempotent | Untested |
| lifecycle | `Invoke-M365UserOffboarding.ps1` | the steps above in safe order; never deletes | Untested |
| lifecycle | `New-M365User.ps1`, `Set-M365UserLicense.ps1`, `Add-M365GroupMember.ps1`, `Set-M365MailboxRegionalConfig.ps1`, `New-M365TemporaryAccessPass.ps1` | new-user steps, each idempotent | Untested |
| lifecycle | `Invoke-M365UserOnboarding.ps1` | new user the client's standard way, from newUserDefaults in the client config; hands over one secret (TAP or password) once | Untested |
| gui | `Start-M365Gui.ps1` + `Views/GdapView.xaml`, `Views/TaskView.xaml` | WPF front end (Genesis theme): GDAP workflow, generic task view for every other area, shared Review-and-run dock | Untested (Windows only) |
| onboarding | `New-ClientOnboarding.ps1` | runs sections 1 and 5 of the checklist from a client config (welcome letter stays manual) | Untested |
| onboarding | `Test-ClientOnboarding.ps1` | read-only verification of every item | Untested |
| (root) | `Start-M365Console.ps1` | menu over all of the above | Untested |

## Modules (the reusable logic)

- `M365Helpers`: settings, client config, tenant GUID resolution, Graph/Exchange session assertion, DNS over HTTPS, password generation, Hudu password write, checklist output.
- `ExchangeHelpers`: recipients, folders, rules, templated mail, SPF/DKIM/DMARC analysis.
- `EntraHelpers`: user review, cloud users, role assignment, CA exclusion, break-glass and admin composition, technical contact, GDAP listing.
- `OnboardingHelpers`: the plan (step order, applicability, which script, which parameters), scopes per phase, run record.
- `GdapHelpers`: role table and resolution, template, customer/relationship/assignment discovery, compliance comparison, request + lock, approval polling, access assignments, resumable state. Plan: `docs/gdap/implementation-plan.md`.
- `SecurityHelpers`: baseline file, fact collectors (Graph + Exchange, each isolated), pure comparison, remediations.
- `ToolkitHelpers`: task catalog from the scripts' own parameter blocks and help; command-line composition; form value coercion. The GUI task view and the console "any task" menu are built on it.

## Next

0. **GDAP first live run.** `Test-M365GdapCompliance.ps1` against a Pax8-onboarded customer (read-only), then `Start-M365GdapOnboarding.ps1 -WhatIf`, then for real on a customer without GDAP. Fill `config/gdap-roles.local.json` group ids first.
1. **First onboarding live run.** Pick a lab or a willing new client, run `New-ClientOnboarding.ps1 -WhatIf`, then for real with `-Interactive`. Expect parameter-name and permission mistakes a linter cannot catch; fix, flip `Status:` lines, update this table.
2. **Welcome letter.** Deferred on purpose. When the text is approved and the recipient rule is decided, `templates/welcome-letter.html` plus `Send-M365TemplateMail.ps1` turn 5.14 from Manual into Assisted with one plan change.
3. **Naming conventions** are set: `breakglass@<client>.onmicrosoft.com`, `mspadmin@<client>.onmicrosoft.com`, alias `<name>.clients@msp.example`.
4. **Security baseline in onboarding.** `Test-M365SecurityBaseline.ps1` exists; wire it into the onboarding plan as 5.15 (assisted) once the baseline expectations are agreed. A Conditional Access policy deployer (named policies from JSON, report-only first) is the natural next write.
5. **`hudu/` module.** Article creation from templates (section 2), AI Context article, Master Index row. Folders: the Hudu MCP (checked 2026-10-16) has no folder create; test the REST `POST /api/v1/folders` against our instance before relying on it.
6. **`psa/` (Autotask) and `csp/` (Pax8) modules.** Steps 1.2 to 1.5 and 1.8 have REST APIs.
7. **`rmm/` (NinjaOne).** Organization and child policy creation (3.1, 3.3).
8. **More everyday tasks.** Onboarding a new user (create, license, groups, mailbox settings), group membership changes, Teams/SharePoint basics, Intune enrollment status. Each is one short script in the same shape, and the catalog picks it up.

## Out of scope

- Deleting anything. Review scripts tell a person; a person deletes.
- Client-specific values in the repo. Real values live in `*.local.json`, which is gitignored.
