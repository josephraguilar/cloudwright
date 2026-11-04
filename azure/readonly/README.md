# Azure read-only mode

Part of [Cloudwright](../../README.md). `cloudwright azure` opens this console. It reads
Azure and Azure Virtual Desktop (AVD) and changes nothing. The legacy administration
scripts, modules, desktop interface and runbook under `../scripts` and `../runbooks` stay
blocked; this folder does not load them.

```powershell
Install-Module Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.DesktopVirtualization -Scope CurrentUser
cloudwright azure                                    # prompts for the tenant ID
cloudwright azure -TenantId <tenant-id> -SubscriptionId <subscription-id>
cloudwright azure -TenantId <tenant-id> -DeviceCode  # sign in on another device
```

The console checks for the five Az modules and prints the install command if any are
missing; it does not install them. Windows opens the same text console: the legacy
desktop interface stays disabled. Without `-SubscriptionId`, Az may show its own
subscription picker during sign-in; the console uses that choice if it belongs to the
tenant, asks you to pick one otherwise, and option 2 switches later.

## What it shows

| Option | Shows |
| --- | --- |
| Subscriptions | Subscriptions the account can read in the tenant, including the owning tenant of delegated ones |
| Switch subscription | Points this PowerShell window at another subscription in the same tenant |
| Resource groups | Name, location, provisioning state |
| Virtual machines | Power state, size and OS for every VM in the subscription |
| AVD environments | Each host pool with its type, load balancing, app groups, the workspaces that publish them, and scaling plans |
| Host pool details | Session hosts with status, drain mode, sessions, VM power, agent version and failed health checks |
| User sessions | Who is signed in to a host pool, on which host, active or disconnected |
| AVD health check | Problems and warnings across every host pool (below) |
| Networks | VNets, subnets with their NSG and NAT gateway, NSGs with inbound rules open to any internet source |
| Sign-in and access | Account, tenant, subscription, and whether the account could change resources |

The health check reports a **Problem** for a host users cannot reach (any status other
than Available, Shutdown or Upgrading), failed health checks, a failed agent update, a
session host whose VM no longer exists, a pool with no application group, and a pool where
no host is running while Start VM On Connect is off. It reports a **Warning** for drain mode,
an app group no workspace publishes, a pool with no hosts, and VMs it could not read.

## Safety boundary

- **One gateway, one allowlist.** Every Azure call names one of 16 commands in
  `AzureReadOnly.psm1` and goes through `Invoke-AzReadCommand`. The command must come from
  its expected Az module and may receive only its listed parameters; abbreviations and
  aliases are refused. Anything else is refused before PowerShell even looks the command up.
- **Get is not enough.** The list excludes Get commands that return keys, tokens, run-command
  output or VM user data, and host pools' registration tokens are never shown. Reports
  return only the fields they display.
- **Sign-in stays in this process.** Context autosave is disabled for the process before
  signing in, and the sign-in, subscription switch and autosave change are pinned to
  `-Scope Process`. The console refuses to sign in unless Az confirms process mode, in which
  Az reports no context or token cache file. Your saved Az settings are not changed, and a
  later PowerShell window cannot reuse this sign-in through Az.
- **The target is verified.** The tenant and subscription must be GUIDs. After sign-in the
  active context must be the account that just signed in, in the requested tenant and
  subscription. Every report checks that again first and refuses if the context changed.
- **The only REST call is a permission check.** `Invoke-AzRestMethod` is pinned to GET of
  the selected subscription's own `Microsoft.Authorization/permissions` path.

## Limits

Cloudwright only reads, but **it does not reduce your account's Azure permissions.** The
access summary tells you when the account could change resources; for routine inspection
use an account with the **Reader** role. That summary covers subscription scope only:
resource-group and resource roles can grant more. Reports can show sensitive data such as
user names and network layout.

Importing Az.Accounts writes its own settings files under `~/.Azure`. Az's telemetry and
the Windows sign-in broker (WAM), which remembers the Windows account you pick, follow
their own settings. Contexts saved by earlier
sessions are loaded when Az.Accounts loads; this mode replaces the active one with a fresh
sign-in and does not use or delete the saved ones. This is an application guard, not a
sandbox: it cannot constrain other code running in the same PowerShell session.

Tests run against fake Az modules (`../tests/ReadOnly.Tests.ps1`). No live tenant has been
read with this mode yet. Validate it with a Reader account in a test subscription before
relying on it. Status: Untested.
