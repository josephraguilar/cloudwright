# Building an AVD environment from nothing

The scripts in this repo start at the host pool. That is roughly step 7. Everything
before it is shared infrastructure the hosts depend on, and most of it should end up
as Bicep under `infra/`. This is the order, why it is the order, and what each step
produces for the next one.

## The chain

```
0. Decisions        licensing, identity model, naming, region
1. Subscription     sign in, select, register resource providers
2. Resource groups  one per concern
3. Network          VNet, AVD subnet, NSG, DNS, route to domain controllers
4. Identity         DCs reachable, OU, join account, Entra user group
5. Profile storage  storage account, file share, identity-based auth, permissions
6. Image source     Compute Gallery with at least one image version
7. Host pool        New-AvdHostPool.ps1
8. Session hosts    New-AvdSessionHost.ps1, once per host
9. Validate         a real user signs in, a VHDX lands on the share
10. Operations      scaling plan, Enable-AvdBackup.ps1, monitoring, Test-AvdHostHealth runbook
```

Steps 3 to 6 can be built in any order relative to each other, with one exception:
identity (4) must exist before the permissions part of profile storage (5).

## Fast path: Entra-only lab

The shortest route to a working desktop. No domain controllers, no gallery, no profile
share. Good enough to learn on and to prove the scripts work. Expand from here.

| Step | What you do | Skipped and why |
| ---- | ----------- | --------------- |
| 1 | Sign in, pick the subscription, run console option 0 to register providers | |
| 2 | One resource group, e.g. `rg-avd-lab` | Lifecycle split comes later |
| 3 | Console option A deploys `infra/bicep/environments/lab`: VNet, subnet, NSG, and the profile storage account with Entra Kerberos already on | No DNS override, no VPN: there are no domain controllers to reach |
| 4 | One Entra security group for users. The console can search for one or create it. | No OU, no join account |
| 5 | Console option B: NTFS permissions on the share root, then grant admin consent to the storage account's Entra app (one-time, portal) | Nothing skipped. This is the Entra Kerberos setup from the portal's Identity-based access blade, scripted. |
| 6 | Nothing, unless you want your own image: then answer yes to the gallery in option A | `New-AvdSessionHost.ps1 -ImageSource Marketplace` builds from the Windows 11 multi-session + M365 Apps image directly |
| 7 | `New-AvdHostPool.ps1 ... -EntraJoined -UserGroupObjectId <group>` (Pooled or Personal) | `-EntraJoined` sets the RDP property Entra hosts need |
| 8 | `New-AvdSessionHost.ps1 ... -ImageSource Marketplace -JoinType EntraId -UserGroupObjectId <group> -FsLogixProfileShare <unc>` | The group gets Virtual Machine User Login on the VM. The host gets the two Entra Kerberos registry values along with the FSLogix ones. |
| 9 | Sign in with a user in the group from the Windows App. A VHDX appears on the share. | |

Or run `Start-AvdConsole.ps1`: option 0, A, B, then 2, then 3. The console defaults to
Marketplace and EntraId, and after option A it pre-fills the subnet and share path.

**Roles you need** for the fast path: Contributor on the subscription (provider
registration needs subscription scope) and User Access Administrator on the resource
group (two role assignments: the app group role and the VM login role).

**What you give up** on the fast path, in order of when you will want it back:

1. A controlled image with your apps in it (flip `deployGallery` and capture one)
2. Group Policy on the hosts (Entra-only hosts use Intune instead of GPO; the lab
   sets FSLogix and Kerberos values by Run Command instead)
3. Anything that needs a line-of-sight domain: legacy apps with Kerberos auth, on-prem file shares with NTFS ACLs

## Step by step

### 0. Decisions

Made before anything is created, because they change later steps.

| Decision | Options | Changes |
| -------- | ------- | ------- |
| Identity model | Active Directory join, or Entra ID join | Step 3 (DNS, DC reachability), step 4, step 5 (auth method), script 2 `-JoinType` |
| Licensing | M365 E3/E5, Business Premium, Windows E3/E5 | Whether users can sign in at all. Multi-session needs one of these. |
| Pool type | Pooled (shared, FSLogix) or Personal (one VM per user) | Step 5 (Pooled needs it, Personal can skip it), script 1 `-HostPoolType`, backup (Personal hosts are backed up, Pooled are not) |
| Region | One region for everything | Host pool metadata must be in a supported region. Vault, VMs, and storage must share a region. |
| Naming | Pick a convention | Everything. `rg-avd-lab-net`, `vnet-avd-lab`, `snet-avd`, `stavdlabprofiles`, `gal_avd_lab`, `hp-lab`, `avd-lab-01`. |

**AD join** needs domain controllers reachable from the AVD subnet, Entra Connect syncing
users to Entra, and an account that can join computers to an OU. More to build, but
FSLogix on Azure Files works with AD DS Kerberos, which is the well-trodden path.

**Entra join** needs no domain controllers. The VM gets a system-assigned identity and
the AADLoginForWindows extension. FSLogix on Azure Files then needs Entra Kerberos
enabled on the storage account, and client devices that are not themselves Entra
joined need `targetisaadjoined:i:1` in the host pool RDP properties.

### 1. Subscription

```powershell
Connect-AzAccount
Get-AzSubscription | Format-Table Name, Id
Set-AzContext -Subscription <id>
```

Then register resource providers. A provider is the ARM back-end for a family of
resource types. Each must be registered once per subscription before ARM accepts its
types. Registration is free, idempotent, and does nothing until you create a resource.
Forgetting one produces a confusing error at deploy time, so register the whole set now.
Console option 0 does this, or:

```powershell
Import-Module ./scripts/powershell/modules/AzHelpers/AzHelpers.psd1
Assert-AzResourceProvider -Verbose -Namespace @(
    'Microsoft.DesktopVirtualization', 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage',
    'Microsoft.RecoveryServices', 'Microsoft.Automation', 'Microsoft.OperationalInsights', 'Microsoft.Insights',
    'Microsoft.KeyVault', 'Microsoft.ManagedIdentity'
)
```

| Provider | Resource types | Used by |
| -------- | -------------- | ------- |
| Microsoft.DesktopVirtualization | Host pools, app groups, workspaces, scaling plans | Script 1, autoscale |
| Microsoft.Compute | VMs, disks, galleries, extensions | Script 2 |
| Microsoft.Network | VNets, subnets, NICs, NSGs | Step 3, script 2 |
| Microsoft.Storage | Storage accounts, file shares | Step 5 |
| Microsoft.RecoveryServices | Backup vaults | Script 5 |
| Microsoft.Automation | Automation accounts, runbooks, schedules | Script 6 |
| Microsoft.OperationalInsights | Log Analytics workspaces | AVD Insights |
| Microsoft.Insights | Diagnostic settings, metrics, alerts, action groups | Monitoring, alerting |
| Microsoft.KeyVault | Key vaults | Not yet. Needed once runbooks or Bicep read a secret instead of a person typing it. |
| Microsoft.ManagedIdentity | User-assigned managed identities | Not yet. Needed for Image Builder and for identities shared across resources. |

Products like Nerdio register a similar list at onboarding plus `Microsoft.AAD`.
That one is **Entra Domain Services** (the managed AD DS offering), not Entra ID,
despite how it is often labelled. Entra join does not need it. Register it only if you
choose Entra Domain Services as the directory for AD-joined hosts.

### 2. Resource groups

For a lab, one group is fine. For anything real, split by lifecycle:

| Group | Holds | Changes |
| ----- | ----- | ------- |
| `rg-avd-<env>-net` | VNet, subnet, NSG, private DNS | Almost never |
| `rg-avd-<env>-storage` | Profile storage account, Compute Gallery | Rarely (new image versions are additive) |
| `rg-avd-<env>-pool` | Host pool, app group, workspace, session host VMs, NICs, disks | Constantly |
| `rg-avd-<env>-mgmt` | Log Analytics, Automation account, Recovery Services vault | Rarely |

The pool group is the one that gets torn down and rebuilt. Keeping the others separate
means a `Remove-AzResourceGroup` on it cannot take the profiles with it.

**What a resource group is and is not.** It is a lifecycle unit (delete the group,
everything in it goes), an RBAC and Azure Policy scope, a cost roll-up, and the default
scope of a deployment. It is **not** a network, identity, or reference boundary: a VM in
one group uses a subnet in another, boots from a gallery image in a third, and mounts a
share in a fourth with nothing extra configured. Nearly every cross-group reference in
one subscription just works.

The real constraints are narrower than people remember. A resource-group-scoped
deployment creates resources in that one group unless a module targets another. A few
resource pairs must co-locate (a VM and its availability set, for example). Moving a
resource between groups later works for most types but not all and is never pleasant,
so decide the split before building, not after.

Nerdio defaults to one group because it owns lifecycle at the VM level and never
deletes a whole group. The scripts here work the same way (reimage deletes the VM and
disk, not the group), so one group is equally safe. `New-AvdEnvironment.ps1` and the
console wizard use one group. Split by lifecycle when different people own the network
and the pool, or when you want "delete the pool group" as a reset button.

**Repo:** `infra/bicep/environments/<env>/main.bicep` at subscription scope could create
these. Or create them by hand and keep the environment at resource group scope.

### 3. Network

- A VNet with an address space that does not overlap on-prem or other VNets.
- A subnet for session hosts, sized for growth. /24 gives 251 usable addresses.
- An NSG on the subnet. **No inbound rules are needed.** AVD uses reverse connect: the
  host opens an outbound 443 connection to the service and sessions ride over it.
- Outbound 443 to the AVD service, Windows Update, and (for AD join) the domain
  controllers on their usual ports. A lab can leave outbound open. Production restricts
  it with the published service tags (`WindowsVirtualDesktop`, `AzureActiveDirectory`,
  `AzureMonitor`).
- DNS on the VNet pointed at the domain controllers if AD joining. Hosts cannot find
  the domain otherwise.
- If the domain controllers are on-prem: VPN or ExpressRoute first. If they are in
  another VNet: peer it.

**Produces:** the subnet resource ID that script 2 takes as `-SubnetId`.

**Repo:** `infra/bicep/compositions/avd-network.bicep`, built from `modules/network/`. Pass `dnsServers` for AD join.

### 4. Identity

For AD join:

- An OU for session hosts, with any GPOs you want (FSLogix settings can also come from
  GPO instead of the Run Command script).
- A service account that can join computers to that OU. Least privilege: delegate
  "Create Computer objects" and "Delete Computer objects" on the OU, not Domain Admin.
  Reimage reuses the computer account, so the account also needs "Reset password"
  on existing computer objects in the OU.
- Users synced to Entra through Entra Connect. AVD authenticates the user against
  Entra even when the host is AD joined.

For Entra join:

- Nothing to build. The VM gets a system-assigned identity and the AADLoginForWindows
  extension (script 2 does both).
- Users need **Virtual Machine User Login** on the VM, on top of the app group role.
  Script 2's `-UserGroupObjectId` assigns it per host.
- The host pool needs `targetisaadjoined:i:1` in its RDP properties for clients on
  devices that are not themselves Entra joined. Script 1's `-EntraJoined` sets it.

For either model:

- An Entra security group for AVD users. Its object ID is script 1's
  `-UserGroupObjectId`. The same group gets share permissions in step 5.
- An Entra security group for AVD admins, used in step 5 for elevated share access.

**Produces:** the OU path, the join credential, and the user group object ID.

### 5. Profile storage

Personal pools can skip this (the profile lives on the VM). Pooled pools need it.

The portal's **Identity-based access** blade on a storage account has three steps.
This is the same three, split between Bicep (declarative) and a script (imperative):

| Portal step | What it is | Where in the repo |
| ----------- | ---------- | ----------------- |
| 1. Enable an identity source | Which directory issues Kerberos tickets for the share: AD DS, Entra Domain Services, or **Microsoft Entra Kerberos**. Entra Kerberos is the one for Entra-joined hosts: the host asks Entra ID for a ticket, no domain controller involved. | `compositions/avd-profile-storage.bicep` passes the identity block to `modules/storage/storage-account.bicep` |
| 2. Share-level permissions | The coarse gate. Either a default role for all authenticated identities (recommended: **Storage File Data SMB Share Contributor**) or RBAC on the share for specific groups. | Bicep sets the default. `Set-AvdProfileShareAccess.ps1` can add group RBAC. |
| 3. File and directory permissions | NTFS ACLs on the share root. FSLogix set: Authenticated Users Modify on the root only, CREATOR OWNER Modify on what they create, Administrators Full Control. | `Set-AvdProfileShareAccess.ps1 -SetNtfsPermissions` mounts with the key and applies it |

Plus two things the blade does not show:

- **Admin consent.** Enabling Entra Kerberos creates a service principal named
  `[Storage Account] <name>.file.core.windows.net` that needs delegated `openid`,
  `profile` and `User.Read` on Microsoft Graph, consented for all users. The "Grant
  admin consent" button creates one Graph object (an oauth2PermissionGrant).
  `Set-AvdProfileShareAccess.ps1` creates it through Graph when the signed-in account
  is a Global Administrator (or Privileged Role / Cloud Application Administrator),
  and prints the portal steps when it cannot. Until consent exists, mounts fail with
  a Kerberos error.
- **Host-side registry.** Each Entra-joined host needs `CloudKerberosTicketRetrievalEnabled`
  and `LoadCredKeyFromProfile` set. Script 2 does this through the FSLogix Run Command
  step when `-JoinType EntraId`. Intune is the production way to push them.

Other settings the Bicep module makes to match a sensible production account: TLS
1.2 minimum, no public blob access, soft delete on shares (14 days), SMB Multichannel
on Premium.

For **AD-joined** hosts the identity source is AD DS instead: join the storage account
to the domain with Microsoft's `AzFilesHybrid` module (`Join-AzStorageAccount`). Not
in the repo yet.

**Produces:** the UNC path `\\<account>.file.core.windows.net\<share>` that script 2
takes as `-FsLogixProfileShare`, and the storage account and share names that script 5
takes for backup.

### 6. Image source

Script 2 can build straight from the marketplace (`-ImageSource Marketplace`), which
is the fast-path answer and needs nothing here. A gallery is for when you want your own
image with software in it. Then you need:

1. A Compute Gallery.
2. An image definition inside it: OS Windows, state Generalized, Gen2, with the
   `TrustedLaunchSupported` feature if you want Trusted Launch hosts.
3. At least one image version.

For a lab, the quickest path to a version is:

1. Create a VM from the marketplace image **Windows 11 Enterprise multi-session +
   Microsoft 365 Apps** (publisher `MicrosoftWindowsDesktop`, offer `office-365`).
2. Do nothing to it. Run sysprep with generalize and shutdown.
3. Deallocate, mark generalized, capture to the gallery as version `1.0.0`.

That is a pipeline with no customization in it. Later you install software before
sysprep, or move to Azure Image Builder with a template in `infra/`. Marketplace
images already include FSLogix and the AVD-tuned defaults.

**Produces:** gallery resource group, gallery name, image definition name for script 2.

**Repo:** `infra/bicep/compositions/avd-image-gallery.bicep` (gallery + definition from
`modules/compute/`), switched on with `deployGallery` in the lab environment. Versions are produced by a capture
process, not Bicep. A capture script is the next thing to add here.

### 7. Host pool

```powershell
$pool = ./scripts/powershell/avd/New-AvdHostPool.ps1 `
    -SubscriptionId <sub> -ResourceGroupName rg-avd-lab-pool -Location westus3 `
    -HostPoolName hp-lab -WorkspaceName ws-lab -UserGroupObjectId <group-id> -Verbose
```

Creates the pool, desktop app group, workspace, user assignment, and returns a
registration token in `$pool.RegistrationToken`.

### 8. Session hosts

```powershell
./scripts/powershell/avd/New-AvdSessionHost.ps1 `
    -SubscriptionId <sub> -ResourceGroupName rg-avd-lab-pool -HostPoolName hp-lab `
    -RegistrationToken $pool.RegistrationToken -VMName avd-lab-01 `
    -SubnetId <from step 3> `
    -GalleryResourceGroupName rg-avd-lab-storage -GalleryName gal_avd_lab -GalleryImageDefinitionName win11-m365 `
    -LocalAdminCredential (Get-Credential) `
    -JoinType ActiveDirectory -DomainName corp.example -DomainJoinCredential (Get-Credential) -OUPath 'OU=AVD,DC=corp,DC=example' `
    -FsLogixProfileShare '\\stavdlabprofiles.file.core.windows.net\profiles' -Verbose
```

Or run `Start-AvdConsole.ps1` and pick "Add a session host". Repeat per host. The
token from step 7 is good for 24 hours by default.

### 9. Validate

1. The host shows **Available** in the pool (script 2 waits for this).
2. A user in the group opens the Windows App or Remote Desktop client, sees the
   workspace, and gets a desktop.
3. On the share, a folder `<username>_<sid>` with a `Profile_<username>.vhdx` appears
   within a minute of sign-in. If the profile is local on the host instead, step 5
   permissions are wrong. Check `C:\ProgramData\FSLogix\Logs\Profile` on the host.
4. Sign out, sign in to a different host, same profile. That is the whole point.

### 10. Operations

| What | How | Depends on |
| ---- | --- | ---------- |
| Autoscale | A scaling plan assigned to the host pool. The **Azure Virtual Desktop** service principal needs the **Desktop Virtualization Power On Off Contributor** role on the subscription first. Native feature, no script here. | Step 7 |
| Backup | `scripts/powershell/backup/Enable-AvdBackup.ps1`. Protects the profile share and, for Personal pools, the host VMs. | Steps 5, 8 |
| Monitoring | Log Analytics workspace, diagnostic settings on the host pool and workspace, Azure Monitor agent on hosts. AVD Insights in the portal reads from this. | Step 7 |
| Health runbook | Automation account with system-assigned identity. Grant it Desktop Virtualization Contributor on the pool RG and Virtual Machine Contributor on the VM RG. Import Az modules, import `runbooks/Test-AvdHostHealth.ps1`, schedule every 15 to 30 minutes. | Step 8 |
| Day-to-day | `Set-AvdHostDrain.ps1`, `Invoke-AvdHostReimage.ps1`, or the console. | Step 8 |

## What the repo has and what it needs next

| Step | Covered by | Status |
| ---- | ---------- | ------ |
| 1 | Hand, or `Assert-AzContext` | Done |
| 2 | Hand, or console option A creates it | Done |
| 3 | `compositions/avd-network.bicep` via the lab environment | In repo, untested |
| 4 | Console can search or create the Entra group | In repo, untested |
| 5 | `compositions/avd-profile-storage.bicep` + `Set-AvdProfileShareAccess.ps1` | In repo, untested. Admin consent is manual. |
| 6 | `-ImageSource Marketplace`, or `compositions/avd-image-gallery.bicep` with `deployGallery` | In repo, untested. Image capture script not written yet. |
| 7 | `New-AvdHostPool.ps1` | In repo, untested |
| 8 | `New-AvdSessionHost.ps1` | In repo, untested |
| 9 | Hand | Document only |
| 10 | `Enable-AvdBackup.ps1`, `Test-AvdHostHealth.ps1` | In repo, untested |

`infra/bicep/environments/lab/main.bicep` composes steps 3, 5, and 6. One deployment
(console option A, or `az deployment group create`) stands up everything before the
host pool.

## Tearing down

Deleting the resource group stops the meter but leaves three things in Entra ID,
because they are not Azure resources: the device record of each session host VM
(which blocks the next build's Entra join with `error_hostname_duplicate`), the
`[Storage Account] <name>.file.core.windows.net` app from Entra Kerberos, and the user
group. `Remove-AvdEnvironment.ps1` (console option X) deletes the group and the first
two, and keeps the group unless told otherwise. The build also checks for a stale
device record before every join, so a hand-deleted group is recoverable.
