# GDAP module: implementation plan

Status of this plan: the read-only half (discovery, compliance comparison, state, logging,
retry) and the write half (request creation, lock for approval, access assignments) are
implemented in `GdapHelpers` and the `partner/` scripts with `-WhatIf` throughout. Nothing
has run against the live partner tenant yet. The GUI does not exist yet; the console menu is
the interactive surface. See "What exists today" and "What is deferred" at the end.

## 1. What the repo already had that this builds on

| Spec asks for | Already in repo | Reused as |
| ------------- | --------------- | --------- |
| Partner authentication, MFA, session reuse | `Assert-M365Graph` (tenant GUID comparison, scope check, reconnect) | unchanged; GDAP scripts call it against `msp.homeTenantId` |
| Customer tenant validation | `Resolve-M365TenantId` (public OpenID endpoint, no auth) | validates a typed tenant ID or domain before anything is created |
| Relationship listing | `Get-M365GdapRelationship` in `EntraHelpers` | still exported; `GdapHelpers.Get-GdapRelationship` returns the same data plus assignments, approval URL, expiry math |
| Config without secrets | `config/msp.settings.*.json`, `Get-M365Settings` | new `partner` section; new `config/gdap-roles.*.json` template |
| Idempotent, `-WhatIf`, verify-after-write | every module function | same pattern |
| Tests without live tenants | Pester with cmdlet stubs and mocks | same pattern |

Spec layout (`Core/`, `Modules/GDAP/`, `CLI/Commands/`, `GUI/`) maps onto the existing layout
without moving files:

| Spec | Here |
| ---- | ---- |
| `Core/Authentication`, `Configuration`, `Logging`, `ErrorHandling`, `ApiClients` | `scripts/powershell/modules/M365Helpers` |
| `Modules/GDAP` | `scripts/powershell/modules/GdapHelpers` |
| `Modules/Entra`, `Modules/Exchange` | `EntraHelpers`, `ExchangeHelpers` |
| `CLI/Commands` | `scripts/powershell/<area>/*.ps1` (one job each) |
| `GUI/` | not built yet; `Start-M365Console.ps1` is the interactive front end |
| `Config/partner.json`, `gdap-roles.json` | `config/msp.settings.local.json` (`partner` section), `config/gdap-roles.local.json` |
| `Tests/` | `tests/` |

Recommendation: keep this layout until the GUI lands. A rename-only restructure is cheap
then, and expensive now while scripts are still changing.

## 2. Microsoft Graph surface

All v1.0. Module: `Microsoft.Graph.Identity.Partner` (cmdlets) plus `Microsoft.Graph.Groups`.

| Operation | Endpoint / cmdlet | Notes |
| --------- | ----------------- | ----- |
| Customers with any GDAP relationship | `GET /tenantRelationships/delegatedAdminCustomers` / `Get-MgTenantRelationshipDelegatedAdminCustomer` | Only customers that already have a relationship. A brand-new customer is entered by tenant ID or domain and validated with `Resolve-M365TenantId`. The full Partner Center customer list is a different API (`api.partnercenter.microsoft.com`, its own scope); later. |
| List relationships | `GET /tenantRelationships/delegatedAdminRelationships` / `Get-MgTenantRelationshipDelegatedAdminRelationship -All` | Filter client-side on `customer.tenantId`. |
| Access assignments | `GET .../delegatedAdminRelationships/{id}/accessAssignments` / `Get-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment` | `accessContainer.accessContainerId` is the MSP security group object ID. |
| Create relationship | `POST /tenantRelationships/delegatedAdminRelationships` / `New-MgTenantRelationshipDelegatedAdminRelationship` | Body: `displayName` (max 50), `duration` (ISO 8601, `P1D`..`P730D`), `customer.tenantId`, `accessDetails.unifiedRoles[].roleDefinitionId`, `autoExtendDuration` (`PT0S` or `P180D`). Status after create: `created`. |
| Lock for approval | `POST .../{id}/requests` body `{ "action": "lockForApproval" }` / `New-MgTenantRelationshipDelegatedAdminRelationshipRequest` | Status becomes `approvalPending`. Roles and duration are frozen. |
| Customer approval link | `https://admin.microsoft.com/AdminPortal/Home#/partners/invitation/granularAdminRelationships/{id}` | Deterministic from the relationship ID; no API call needed. |
| Create access assignment | `POST .../{id}/accessAssignments` / `New-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment` | Body: `accessContainer { accessContainerId, accessContainerType: "securityGroup" }`, `accessDetails.unifiedRoles[]`. Only after status `active`. Roles must be a subset of the relationship's roles. |
| Terminate | `POST .../{id}/requests` body `{ "action": "terminate" }` | Not called by any script. Operator action in Partner Center. |
| Group existence | `GET /groups/{id}` / `Get-MgGroup` | Before any assignment. |
| Role names | `Get-MgRoleManagementDirectoryRoleDefinition` | Role template IDs are identical in every tenant; a built-in table covers offline use and tests, Graph wins when connected. |

Relationship `status` values: `created`, `approvalPending`, `approved`, `activating`, `active`,
`expiring`, `expired`, `terminating`, `terminated`, `terminationRequested`.

Rules enforced in code because Microsoft enforces them server-side with unhelpful errors:

- A relationship containing Global Administrator cannot auto-extend. `New-GdapRequest` refuses `autoExtendDuration` other than `PT0S` when GA is in the template. Our template is "allAdmin": a fixed, verified table of 27 roles (every Administrator role plus the directory readers, Global Administrator included), never the live Graph role list, so the dry run, the GUI count and the real request always agree. It uses `PT0S` and a 730-day term: a reminder to renew lands in the compliance warnings 60 days before expiry. Each request's display name carries the date (`MSP GDAP - <customer> yyyy-MM-dd`) because Graph requires unique names and renewals reuse the customer name; do the dry run and the run on the same day.
- Roles cannot be added to an existing relationship. "Missing roles" always means a new, supplementary relationship.
- Access assignments need the relationship `active`, and every role in the assignment must be in the relationship.

## 3. Permissions

| Who | Needs |
| --- | ----- |
| The signed-in partner account | Member of the partner tenant's **Admin Agents** group (Partner Center role). Global Administrator in the partner tenant also works but is not required. |
| Delegated Graph scopes (partner tenant) | `DelegatedAdminRelationship.ReadWrite.All` (read-only scripts ask for `.Read.All`), `Group.Read.All`, `RoleManagement.Read.Directory`. |
| The customer approver | Global Administrator in the customer tenant, signing in at the approval link. We never hold their credentials. |

`Get-OnboardingGraphScopes -Phase Partner` returns the set, so consent is one prompt.

## 4. Authentication and sessions

Unchanged from the rest of the repo. `Assert-M365Graph -TenantId <partner>` reuses an open
session when tenant GUID and scopes match, otherwise `Connect-MgGraph` interactively (MFA
via the browser). The Graph SDK caches tokens per account, so a second script in the same
terminal does not prompt. Everything GDAP runs in the **partner** tenant; nothing signs in
to the customer tenant. The customer's own sign-in happens inside Microsoft's approval page.

## 5. Customer approval UX

Decision (2026-10-17, after confirming that the technician is normally the approver, holding
an admin account in the customer tenant): **open the approval page on this machine, in an
isolated session.**

- **GUI:** an in-app window hosting the admin-center approval page in WebView2 with a fresh
  user-data folder (no shared cookies, so the partner sign-in is never auto-selected; the
  folder is deleted when the window closes). Creating a request opens it automatically;
  "Open approval page" reopens it. The window closes itself once polling sees `active`.
  Needs the WebView2 assemblies in `gui/lib/webview2` (see its README) and the WebView2
  Runtime, which ships with Windows 11 and Edge. Without them the GUI falls back to the CLI
  behavior below and says so in the activity log.
- **CLI:** `Open-GdapApprovalPage` launches Edge InPrivate, else Chrome Incognito, else the
  default browser. `-NoBrowser` suppresses it. The link is printed and copied in every case
  for the client-approves-remotely scenario.
- **Wrong-tenant protection** is Microsoft's: the request is created with `customer.tenantId`,
  so only a Global Administrator of that tenant can approve it, and polling by relationship
  id confirms the right one went active. The isolated session only prevents the wrong account
  from being offered first.
- **Never** any simulated approval. The code opens a page and reads status; the approve
  click is a person's, on Microsoft's page.

What was weighed: WebView2 is a real Chromium, so Microsoft sign-in and MFA work in it, and
customer Conditional Access that requires a compliant device would block it exactly as it
would block a browser on the same machine. That is acceptable because the approver's device
is ours.

## 6. State and resumability

`runs/gdap/<customerTenantId>.json` (gitignored) records: customer tenant ID and name,
relationship ID, display name, status at last check, approval URL, template name, created
and last-checked timestamps, correlation ID. `Start-M365GdapOnboarding.ps1` reads it first,
so a run interrupted during "awaiting approval" resumes with the same request and URL.
The file never contains tokens or secrets.

Ground truth is always Graph. The state file is a pointer; every run re-queries the
relationship by ID and, if Graph does not know it, reports that rather than trusting the file.

## 7. Error handling

- `Invoke-M365WithRetry` wraps Graph calls: exponential backoff with jitter on 429, 503, 504,
  gateway and timeout errors, honoring `Retry-After` when present, 5 attempts. Anything else
  is rethrown unchanged. The Graph SDK already retries 429 internally; this covers the rest.
- A status query that fails never triggers a create. Creation happens only when a fresh,
  successful listing shows no usable relationship.
- 403 from the relationship endpoints is explained as "not in Admin Agents or missing
  `DelegatedAdminRelationship.ReadWrite.All`" and stops the run.
- Invalid tenant ID stops before any call that could create anything.
- Partial assignment failures are reported per group; the next run repairs what is missing.
- `Write-M365Log` appends JSON lines to `runs/logs/<date>.jsonl` with timestamp, level,
  correlation ID, operation, tenant ID and a sanitized message (anything that looks like a
  bearer token is redacted). No tokens, no credentials.

## 8. Idempotency matrix (from the spec, as implemented in `Compare-GdapRelationship`)

| Existing condition | State | What `Start-M365GdapOnboarding.ps1` does |
| ------------------ | ----- | --------------------------------------- |
| No relationship | `NoRelationship` | create + lock + show link + wait |
| Active, roles cover template, assignments present | `Compliant` | verify, report, no changes |
| Active, assignments missing or incomplete | `MissingAssignments` | create only the missing assignments |
| Active but template roles missing | `MissingRoles` | propose a supplementary relationship; create only with confirmation |
| `created` or `approvalPending` | `PendingApproval` | reuse it, show the same link, wait |
| Expired or terminated only | `Expired` | propose a replacement; create only with confirmation |
| Several active, overlapping | `Compliant` or `MissingRoles` plus an overlap warning | never terminates anything |
| 403 / insufficient privilege | stop | explain which role or scope is missing |
| Invalid tenant | stop | before any write |
| Customer rejected | `Expired` state with the rejection noted | explicit `-Force` to request again |

## 9. Tests

Pure functions are tested with no Graph: `Compare-GdapRelationship` for every row of the
matrix, approval URL, duration and auto-extend validation (including the GA rule), role
name/ID resolution from the built-in table, template validation (placeholders rejected),
state save/load. Graph-calling functions are tested with cmdlet stubs and mocks for the
idempotent paths (existing assignment is not re-created; `-WhatIf` creates nothing).

## 10. What exists today / what is deferred

Exists (all `Status: Untested` against live Graph):

- `GdapHelpers`: role table and resolution, template loading, customer and relationship
  discovery with assignments, compliance comparison, request creation and lock, approval
  polling, access assignment creation, state file, approval URL.
- `partner/`: `Get-M365GdapCustomer.ps1`, `Get-M365GdapRelationship.ps1` (now with
  assignments), `Test-M365GdapCompliance.ps1`, `New-M365GdapRequest.ps1`,
  `Wait-M365GdapApproval.ps1`, `Set-M365GdapAccessAssignment.ps1`,
  `Start-M365GdapOnboarding.ps1`.
- Console menu entries for the above.
- `M365Helpers`: `Invoke-M365WithRetry`, `Write-M365Log`, `New-M365CorrelationId`.

Also exists: the WPF GUI shell with the GDAP view and the in-app WebView2 approval window
(`gui/`, Windows only). The GUI follows a review-before-run rule: write actions compose the
exact `partner/` script command into a review box; the operator copies it, dry-runs it with
`-WhatIf`, or runs it after reading it. Read-only actions run directly.

Deferred:

- Partner Center customer list (different API and scope).
- Terminating relationships (operator action, Partner Center).
- The other eight GUI modules.

Note on Pax8: the GDAP relationship Pax8 establishes is the reseller relationship for
licensing and carries reseller-level roles. Admin access is a separate relationship, and this
module is what creates it. Against a Pax8-only customer, `Test-M365GdapCompliance.ps1` will
report `MissingRoles` and propose a supplementary request; that is the expected result.

Suggested first live run: `Test-M365GdapCompliance.ps1` against a current client. It is
read-only and exercises sign-in, listing, assignments and the template comparison. Then
`Start-M365GdapOnboarding.ps1 -WhatIf`, then for real.
