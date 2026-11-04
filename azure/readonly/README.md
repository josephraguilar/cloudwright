# Azure read-only mode

Part of [Cloudwright](../../README.md). `cloudwright azure` opens this console. It reads
Azure and Azure Virtual Desktop (AVD) and is designed to change nothing; see the
provider-registration guard below for the one way Az itself could otherwise write. The legacy administration
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
no host is running while Start VM On Connect is off (only when every host's power state is
known). It reports a **Warning** for drain mode, an app group no workspace publishes, a pool
with no hosts, and VMs it could not read. Only Azure VMs in the selected subscription are
joined to their session hosts; others show `other subscription` or `not an Azure VM` (for
example Azure Local) instead of a power state, and are never called orphaned. These are
pointers for an operator, not a full health evaluation. The network report's
`OpenToInternet` column lists inbound Allow rules from any internet source; it does not
apply rule priority or Deny rules.

## Safety boundary

- **One gateway, one allowlist.** Every Azure call names one of 16 commands in
  `AzureReadOnly.psm1` and goes through `Invoke-AzReadCommand`. The command must come from
  its expected Az module and may receive only its listed parameters; names compare exactly
  and ordinally, so abbreviations, aliases and look-alike characters are refused. Anything
  else is refused before PowerShell looks the command up, and the resolved command must be
  the named one from that module.
- **No provider registration.** Az.Accounts registers a resource provider and retries when
  Azure answers "not registered to use namespace", even for a Get, if the account has
  `*/register/action` (Owner and Contributor do). That would be an Azure write. Before any
  Compute, Network or AVD command, the gateway reads that provider's registration state and
  refuses unless it is `Registered` ("Microsoft.Compute is not registered in this
  subscription, so it has nothing to read"). The other commands reach providers that are
  always registered (Resources, Authorization) or tenant-level endpoints.
- **Get is not enough.** The list excludes Get commands that return keys, tokens, run-command
  output or VM user data, and host pools' registration tokens are never shown. Reports
  return only the fields they display.
- **Az keeps this sign-in in the process.** Context autosave is disabled for the process
  before signing in, and the sign-in, subscription switch and autosave change are pinned to
  `-Scope Process`. The console refuses to sign in unless Az confirms process mode, in which
  Az keeps its context and token cache in memory only. Your saved Az settings are not
  changed. **On Windows, Az signs in through the Windows sign-in broker (WAM) by default,
  which remembers the account and can sign it in again later without a password**;
  `-DeviceCode` does not use WAM. Run the console through `cloudwright azure`, which uses a
  fresh PowerShell process that exits on Q. Running the script directly in an existing
  window leaves the signed-in context there until you close it.
- **The target is verified.** The tenant and subscription must be GUIDs. After sign-in the
  active context must be the account that just signed in, in the requested tenant and
  subscription. Every report checks that again first and refuses if the context changed.
- **The only REST calls are checks.** `Invoke-AzRestMethod` is pinned to GET of four exact
  paths in the selected subscription: the account's own `Microsoft.Authorization/permissions`
  and the registration state of Microsoft.Compute, Microsoft.Network and
  Microsoft.DesktopVirtualization.

## Limits

Cloudwright only reads, but **it does not reduce your account's Azure permissions.** For
routine inspection use an account with the **Reader** role. The access summary flags any
permission at subscription scope beyond reading, including data-plane permissions such as
blob or VM-login access. It does not include resource-group, resource or deny
assignments, and it says when Azure listed more permissions than it read; "no change or data
permissions found" is not a guarantee. Reports can show sensitive data such as user names
and network layout. A delegated (Lighthouse) subscription shows the tenant that owns it.

Importing Az.Accounts writes its own settings files under `~/.Azure`. Az's telemetry and
the Windows sign-in broker (WAM), which remembers the Windows account you pick, follow
their own settings. Contexts saved by earlier
sessions are loaded when Az.Accounts loads; this mode replaces the active one with a fresh
sign-in and does not use or delete the saved ones. The first Azure PowerShell sign-in in a
tenant that has never used it may add Azure PowerShell's service principal to that tenant;
that is Entra's behavior, outside Cloudwright's control, and is unverified here. This is an
application guard, not a sandbox: it cannot constrain other code running in the same
PowerShell session.

Tests run against fake Az modules (`../tests/ReadOnly.Tests.ps1`), and a metadata test
checks every allowlisted command, parameter and call shape against the current real Az
modules. No live tenant has been read with this mode yet. Before relying on it, validate it
in a disposable subscription with a Reader account and, separately, a Contributor account:
confirm in the Activity Log that no provider is registered when one is unregistered, and
check WAM behavior on Windows. Status: Untested.
