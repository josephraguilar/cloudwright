# Cloudwright components

Cloudwright combines three independent tools:

| Directory | Purpose |
| --- | --- |
| `learn/` | Build and understand Microsoft commands without executing them |
| `azure/` | Administer Azure environments and Azure Virtual Desktop |
| `m365/` | Administer Microsoft 365 and delegated client environments |

The public repository starts from a sanitized source snapshot. Examples use fictional
organizations, addresses, and tenant identifiers. Configure your own environment in
the gitignored local settings files. Internal onboarding documentation links can be
set through `onboarding.internalSopUrl` and `onboarding.tenantSopUrl` in the Microsoft
365 local settings; both are blank by default.

The launcher validates the selected area and flags, then passes literal arguments
to a known entry point in a fresh PowerShell process. Windows desktop launches use
STA. A child failure is reported without exiting the calling shell.

Installation registers the launcher and a JSON location record in the current user's
module directory. The toolkit and its local settings remain together in the checkout
or downloaded snapshot. No profiles or cloud dependencies are changed by installation.

The command builder remains generation-only. Azure retains its tenant/subscription
checks and `-WhatIf` support. Microsoft 365 retains its explicit tenant selection and
reviewed change plan. Shared administrative logic must preserve those boundaries.
