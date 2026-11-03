# Security baseline

`config/baselines/security.example.json` is our expectation list; copy it to
`security.local.json` to change it. `security/Test-M365SecurityBaseline.ps1 -Client <name>`
collects the facts and compares. It never changes anything, and it runs as onboarding step
5.15 (with the client's -TenantId and -Organization, checked to be the same tenant). Each
failing row names the remediation, which is usually one of the `security/` scripts, all
idempotent, `-WhatIf` aware and switched with `-State On` / `-State Off`.

A check whose source could not be read is **Unknown**, never Pass or Fail, and the reason is
in the report. Where it helps, Actual carries a detail suffix (for example which custom
outbound policy still allows forwarding).

## Checks

| Id | What | Source |
| -- | ---- | ------ |
| mfaEnforced | Security Defaults on, or an enabled CA policy for All users, All cloud apps, all client apps, requiring MFA (or an authentication strength) | Graph |
| legacyAuthBlocked | Security Defaults on, or an enabled CA policy for All users and All cloud apps, client apps Exchange ActiveSync + other, grant Block | Graph |
| unifiedAuditLog | `Get-AdminAuditLogConfig`.UnifiedAuditLogIngestionEnabled | Exchange |
| mailboxAuditing | `Get-OrganizationConfig`.AuditDisabled is false | Exchange |
| autoForwardingBlocked | default outbound spam policy AutoForwardingMode = Off, and no enabled custom outbound policy set to On | Exchange |
| externalSenderTag | `Get-ExternalInOutlook`.Enabled | Exchange |
| modernAuth | `Get-OrganizationConfig`.OAuth2ClientProfileEnabled | Exchange |
| smtpAuthDisabled | `Get-TransportConfig`.SmtpClientAuthenticationDisabled | Exchange |
| spoofIntelligence | default anti-phish policy EnableSpoofIntelligence | Exchange |
| dkimAllDomains | every custom accepted domain has DKIM enabled | Exchange + DNS |
| passwordNeverExpires | no verified domain with a password validity period | Graph |
| ssprEnabled | authorization policy AllowedToUseSspr | Graph |
| userConsentBlocked | no permission grant policy assigned to default users | Graph |
| guestInviteRestricted | AllowInvitesFrom is adminsAndGuestInviters or none | Graph |
| globalAdminCount | members of Global Administrator, expected 2 to 4 | Graph |
| breakGlassExists | `<break-glass prefix>@<tenant's initial onmicrosoft.com domain>` exists | Graph |
| sharedMailboxSignInBlocked | no shared mailbox whose account is enabled | Exchange + Graph |

### MSP standard (what our onboarding creates)

| Id | What | Source |
| -- | ---- | ------ |
| breakGlassIsGlobalAdmin | the break-glass account is a member of Global Administrator | Graph |
| breakGlassExcludedFromCA | no enabled CA policy lacks the break-glass account in excludeUsers | Graph |
| mspAdminExists | a user whose UPN starts with an `adminAccounts` prefix (mspadmin) exists | Graph |
| technicalContactSet | `msp.supportEmail` is in the organization's technicalNotificationMails | Graph |
| mspContactHidden | the client alias (`<name>.clients@msp.example`) is a mail contact hidden from the GAL | Exchange |
| supportContactHidden | the support address is a mail contact hidden from the GAL | Exchange |
| itListConfigured | `IT@<domain>` exists and has the client-alias contact as a member | Exchange |
| alertsListConfigured | `MSPalerts@<domain>` exists and has the support contact as a member | Exchange |

These need the client's alias and domain, so run the audit with `-Client <shortName>`; without
it those rows show Unknown. The 911@ mailbox is conditional (ironScales) and stays in
`Test-ClientOnboarding.ps1`.

Report-only Conditional Access policies do not count as enforcement.

## Adding a check

1. Add a row to the baseline file: `id`, `title`, `expected` (bool, string, number, or `{min,max}`), `severity`, `remediation`.
2. Add a collector in `SecurityHelpers.Get-M365SecurityFact` that sets `$facts['<id>']`. Wrap it with the `$collect` helper so a failure becomes an Unknown row instead of aborting the audit.
3. If there is a safe fix, add a `security/Set-M365<Thing>.ps1` script and a function in `SecurityHelpers`; name it in the row's remediation.

## Not covered yet

A Conditional Access policy deployer (named policies from JSON, created in report-only mode
first), Defender for Office 365 preset policies, Intune compliance, and anything that needs a
license the client may not have. The audit reports what it can see and marks the rest Unknown.
