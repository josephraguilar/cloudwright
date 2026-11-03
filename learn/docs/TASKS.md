# Work plan

Ordered, dependency-tagged work items sized for one worker (human or model) each. Pick the
lowest-numbered item whose **Depends on** are all done and whose **Blocked by** is empty.
Work on a branch named after the item (`T-203-new-nsg`), one item per pull request, with the
item ID in the commit message.

Legend: **Depends on** = other items that must be merged first. **Blocked by** = a
non-code condition (a machine, a tenant, a person). **Done when** = acceptance criteria;
every bullet must be true. Items marked `[auto-ok]` can be done entirely from this repo and
the public docs with no tenant access; the rest need a person to verify on a real machine.

Status column: `todo` / `doing (name)` / `done (PR)`. Update it in the same PR.

## Phase 0: Scaffold (done 2026-10-17, this is what exists)

| ID | Item | Status |
| -- | ---- | ------ |
| T-001 | Research prior art, pick reusable pieces (`docs/prior-art.md`) | done |
| T-002 | Architecture and task schema (`docs/architecture.md`) | done |
| T-003 | Engine module: catalog loader, validator, template expansion, generator, console UI (`src/MsScripter`) | done |
| T-004 | Reference tasks: `azure.context.set-subscription`, `azure.create.resource-group`, `azure.network.new-vnet`, `m365.groups.new-security-group`, path `path.azure.rg-and-network` | done |
| T-005 | Pester suites (module, catalog, generator golden files, read-only guard), PSScriptAnalyzer settings, CI workflow | done, 29 tests green on PowerShell 7.5 (Linux) |
| T-006 | Authoring guide (`docs/authoring-tasks.md`), README | done |
| T-007 | One-liner output style as the default (`-Style OneLiner`, `Format-MsOneLiner`), Explained kept behind a flag; golden files for both | done |
| T-009 | Contoso mode: `catalog/_contoso.psd1` sample tenant, `Set-MsContosoMode`, toolbar toggle, `-Contoso` switch, tests that every lookup has sample rows | done |
| T-008 | WinForms window `Show-MsScripterWindow` as the default entry point: tree, per-field controls, lazy drop-down lookups, Generate / Add to script / Copy / Save | done, **not yet opened on Windows** (written on Linux; parses and lints clean) |

Known gaps left on purpose: the window has never been opened (T-100 is the first thing to
do); nothing has been run on Windows PowerShell 5.1; nothing has been run signed in (pick
lists untested against real Az/Graph); no `az` CLI output yet.

## Phase 1: Make the engine trustworthy on real machines

| ID | Item | Depends on | Blocked by | Status |
| -- | ---- | ---------- | ---------- | ------ |
| T-100 | Open the window on Windows (`.\Start-MsScripter.ps1`) and fix what breaks: layout, drop-down lazy load, Generate, Add to script, Copy, Save. Then repeat in `powershell.exe` 5.1 (`PlaceholderText` is .NET Core only: guard it) | — | A Windows machine | todo |
| T-101 | Run the console UI on Windows PowerShell 5.1 and fix what breaks | — | A Windows machine | todo |
| T-102 | Run signed in to Azure; verify every `Source` lookup in the reference tasks returns a list | — | An Azure subscription with Reader | todo |
| T-103 | Run signed in to Graph; verify read-only scopes are requested and `Get-MgGroup` lookup works | — | A tenant where the user can consent to `Group.Read.All` etc. | todo |
| T-104 | Non-interactive tests for `Read-MsField` and `Select-MsItem` using `Mock Read-Host` `[auto-ok]` | — | — | todo |
| T-105 | `tools/Test-Catalog.ps1`: validate one task file and print problems and a sample render `[auto-ok]` | — | — | todo |
| T-106 | Menu polish: picker hint text per context, show task count per section, `?` shows the task's Learn notes without starting it `[auto-ok]` | — | — | todo |
| T-107 | `-WhatIf` hint only when the cmdlet supports ShouldProcess (check `Get-Command` when the module is installed; keep the hint otherwise) `[auto-ok]` | — | — | todo |
| T-108 | `az` CLI variant: schema key `Cli = @{ Steps = @(@{ Title; What; Why; Command = 'az group create --name {{Name:raw}} ...' }) }`, renderer `New-MsScript -Format Cli`, UI key `[A]`, golden cases `[auto-ok]` | — | — | todo |
| T-109 | Save and load answer sets to `out/answers.local.json` (gitignored) so a lab can be rebuilt without retyping `[auto-ok]` | — | — | todo |
| T-110 | ConsoleGuiTools picker verified on PowerShell 7.2+ (install module, pick from 50+ items, cancel with Esc) | T-101 | A machine with PS 7.2+ | todo |
| T-112 | Verify every one-liner in `tests/golden/auto/` against the cmdlet docs (parameter names and types) and against a real tenant where possible; flip `Status` in the task file to `Tested <date>` as each passes. One PR per section. | T-102, T-103 | A lab tenant | todo |
| T-111 | Generated script footer: "Next tasks" list derived from tasks whose `Prerequisites` include this one `[auto-ok]` | — | — | todo |

### T-101 detail
Run `./Start-MsScripter.ps1 -NoSignIn` in `powershell.exe` (5.1). Walk Azure > Create > Resource group to a generated script, press S, confirm the file lands in `out/`. Then `Invoke-Pester ./tests` in 5.1. Fix anything that is PS 7-only (`??`, ternary, `Join-Path` with several children, `-Encoding utf8` differences, `[regex]::Replace` with scriptblock). **Done when:** both commands succeed on 5.1 and 7, and `README.md` states the versions it was verified on.

### T-104 detail
Pester 5 `Mock Read-Host { 'rg-lab' }` inside `InModuleScope MsScripter`. Cover: required field re-asks on blank; pattern mismatch re-asks; default accepted on Enter; Hashtable text parsed; Bool y/n; Choice with static `Options` falls back to typing when the answer is not a number; remembered answers become the next default. **Done when:** a new `tests/Prompts.Tests.ps1` passes and `Read-MsField` has no uncovered branch except the live `Resolve-MsSource` call.

### T-108 detail
Many admins learn `az` alongside Az PowerShell, and the azure repo has `docs/cheatsheets/az-cli.md`. Keep PowerShell the default. Mine `Azure/azure-operation-script` (MIT) for equivalents. **Done when:** `azure.create.resource-group` and `azure.network.new-vnet` have `Cli` steps, two golden files exist, `Test-MsTaskDefinition` validates `Cli` the same way as `Steps`, and the UI shows `[A]z CLI` only when the task has one.

## Phase 2: Azure catalog

**Status 2026-10-17:** done in the scaffold pass (one-liner goldens reviewed, all `Untested` until run):
T-201, T-202, T-203, T-204, T-211, T-212, T-213, T-214, T-215, T-216, T-221, T-222, T-223 (as
`start-vm`, `stop-vm`, `restart-vm`), T-224, T-225, T-226, T-227, T-228, T-231, T-232, T-233,
T-234, T-235, T-236, T-237, T-238, T-241, T-242, T-243, T-244, T-245, T-246, T-247 (as
`drain-host` + `undrain-host`), T-248, T-249, T-261, T-262, T-264, T-266, T-267, T-271, T-272.
**Remaining:** T-205, T-217, T-239, T-250, T-251, T-263, T-265, T-273.

Every item below is "add one task file" and follows `docs/authoring-tasks.md`. All are
`[auto-ok]` to author; the `Status` inside the file stays `Untested` until a person runs it.
Column **Source lookups** names the read-only cmdlet for each pick list. Column **Docs**
is the Learn page to verify parameters against (open the latest version).

### 2a. Context and inspect

| ID | Task Id | Emits | Fields (Type, Source) | Prereq task | Docs |
| -- | ------- | ----- | --------------------- | ----------- | ---- |
| T-201 | `azure.context.register-providers` | `Register-AzResourceProvider` per namespace, then a `Get-AzResourceProvider` poll loop (Raw). Copy the list and reasoning from azure repo `docs/avd/environment-build-path.md` step 1 | `Namespaces` (MultiChoice, Options: the 10 namespaces + Microsoft.AAD) | set-subscription | az.resources/register-azresourceprovider |
| T-202 | `azure.inspect.list-resources` | `Get-AzResource -ResourceGroupName` piped to `Format-Table` (Raw) | `ResourceGroupName` (Choice, Get-AzResourceGroup) | set-subscription | az.resources/get-azresource |
| T-203 | `azure.inspect.vm-power-state` | `Get-AzVM -Status` select Name, PowerState (Raw). Mirror azure repo `compute/Get-AzVmPowerState.ps1` | `ResourceGroupName` (Choice, optional) | set-subscription | az.compute/get-azvm |
| T-204 | `azure.inspect.role-assignments` | `Get-AzRoleAssignment -Scope` | `Scope` (Choice: subscription or a resource group; Source Get-AzResourceGroup, Value ResourceId) | set-subscription | az.resources/get-azroleassignment |
| T-205 | `azure.inspect.effective-nsg-rules` | `Get-AzEffectiveNetworkSecurityGroup -NetworkInterfaceName` | `ResourceGroupName`, `NicName` (Choice, Get-AzNetworkInterface with Parameters ResourceGroupName) | set-subscription | az.network/get-azeffectivenetworksecuritygroup |

### 2b. Network

| ID | Task Id | Emits | Fields | Prereq task | Docs |
| -- | ------- | ----- | ------ | ----------- | ---- |
| T-211 | `azure.network.new-nsg` | `New-AzNetworkSecurityGroup` | `ResourceGroupName` (Choice), `Location` (Choice), `NsgName` (String) | create.resource-group | az.network/new-aznetworksecuritygroup |
| T-212 | `azure.network.new-nsg-rule` | `Get-AzNetworkSecurityGroup`, `Add-AzNetworkSecurityRuleConfig`, `Set-AzNetworkSecurityGroup` (Raw chain) | `ResourceGroupName`, `NsgName` (Choice, Get-AzNetworkSecurityGroup), `RuleName`, `Priority` (Int), `Direction` (Choice Inbound/Outbound), `Access` (Choice Allow/Deny), `Protocol` (Choice Tcp/Udp/*), `SourceAddressPrefix`, `DestinationPortRange` | new-nsg | az.network/add-aznetworksecurityruleconfig |
| T-213 | `azure.network.set-subnet-nsg` | Get VNet, `Set-AzVirtualNetworkSubnetConfig -NetworkSecurityGroup`, `Set-AzVirtualNetwork` (Raw; example in authoring guide) | `ResourceGroupName`, `VNetName` (Choice, Get-AzVirtualNetwork), `SubnetName` (String), `NsgName` (Choice) | new-vnet, new-nsg | az.network/set-azvirtualnetworksubnetconfig |
| T-214 | `azure.network.add-subnet` | `Add-AzVirtualNetworkSubnetConfig` + `Set-AzVirtualNetwork` (Raw) | `ResourceGroupName`, `VNetName` (Choice), `SubnetName`, `SubnetPrefix` | new-vnet | az.network/add-azvirtualnetworksubnetconfig |
| T-215 | `azure.network.new-public-ip` | `New-AzPublicIpAddress -Sku Standard -AllocationMethod Static` | `ResourceGroupName`, `Location`, `PipName`, `DnsLabel` (optional) | create.resource-group | az.network/new-azpublicipaddress |
| T-216 | `azure.network.new-nic` | `Get-AzVirtualNetwork`, pick subnet, `New-AzNetworkInterface` (Raw + Cmdlet) | `ResourceGroupName`, `Location`, `NicName`, `VNetName` (Choice), `SubnetName`, `PipName` (Choice optional, Get-AzPublicIpAddress), `NsgName` (Choice optional) | new-vnet | az.network/new-aznetworkinterface |
| T-217 | `azure.network.new-private-dns-zone` | `New-AzPrivateDnsZone`, `New-AzPrivateDnsVirtualNetworkLink` | `ResourceGroupName`, `ZoneName`, `VNetName` (Choice), `AutoRegistration` (Bool) | new-vnet | az.privatedns/new-azprivatednszone |

### 2c. Compute and disks

| ID | Task Id | Emits | Fields | Prereq task | Docs |
| -- | ------- | ----- | ------ | ----------- | ---- |
| T-221 | `azure.compute.new-vm-windows` | `New-AzVMConfig`, `Set-AzVMOperatingSystem -Windows -Credential`, `Set-AzVMSourceImage`, `Add-AzVMNetworkInterface`, `Set-AzVMOSDisk`, `Set-AzVMSecurityProfile -SecurityType TrustedLaunch`, `New-AzVM` (Raw chain, the long one; cross-check azure repo `AvdBuild/New-AvdSessionHostVm`) | `ResourceGroupName`, `Location`, `VMName` (Pattern 1-15 chars), `VMSize` (Choice, Get-AzVMSize Parameters Location), `NicName` (Choice), `ImageSku` (Choice Options: win11-24h2-avd-m365, 2022-datacenter-azure-edition, ...), `LocalAdmin` (Secret), `SecurityType` (Choice TrustedLaunch/Standard), `LicenseType` (Choice None/Windows_Client/Windows_Server) | new-nic | az.compute/new-azvm, new-azvmconfig |
| T-222 | `azure.compute.new-vm-linux` | Same chain with `-Linux -DisablePasswordAuthentication` and `Add-AzVMSshPublicKey` | as above, `SshPublicKey` (String), image Options Ubuntu/Debian/RHEL | new-nic | az.compute/add-azvmsshpublickey |
| T-223 | `azure.compute.vm-power` | `Start-AzVM` / `Stop-AzVM -Force` (deallocate) / `Stop-AzVM -StayProvisioned` / `Restart-AzVM`, one step each gated by `When` on a Choice | `ResourceGroupName`, `VMName` (Choice, Get-AzVM), `Action` (Choice) | — | az.compute/stop-azvm |
| T-224 | `azure.compute.resize-vm` | `Get-AzVM`, set `HardwareProfile.VmSize`, `Update-AzVM` (Raw) | `ResourceGroupName`, `VMName` (Choice), `NewSize` (Choice, Get-AzVMSize with Parameters ResourceGroupName + VMName: lists sizes the VM can move to) | — | az.compute/update-azvm |
| T-225 | `azure.compute.new-data-disk` | `New-AzDiskConfig`, `New-AzDisk`, `Get-AzVM`, `Add-AzVMDataDisk -CreateOption Attach`, `Update-AzVM` | `ResourceGroupName`, `Location`, `VMName` (Choice), `DiskName`, `SizeGb` (Int), `Sku` (Choice Premium_LRS/StandardSSD_LRS/Standard_LRS), `Lun` (Int) | — | az.compute/add-azvmdatadisk |
| T-226 | `azure.compute.snapshot-disk` | `Get-AzDisk`, `New-AzSnapshotConfig -SourceUri -CreateOption Copy`, `New-AzSnapshot` | `ResourceGroupName`, `DiskName` (Choice, Get-AzDisk), `SnapshotName` | — | az.compute/new-azsnapshot |
| T-227 | `azure.compute.run-command` | `Invoke-AzVMRunCommand -CommandId RunPowerShellScript -ScriptString` | `ResourceGroupName`, `VMName` (Choice), `Script` (String, multi-line note) | — | az.compute/invoke-azvmruncommand |
| T-228 | `azure.compute.add-entra-login-extension` | `Set-AzVMExtension -Publisher Microsoft.Azure.ActiveDirectory -ExtensionType AADLoginForWindows` + role assignment `Virtual Machine User Login` (reuse azure repo `Grant-AvdVmLogin` logic) | `ResourceGroupName`, `VMName` (Choice), `GroupObjectId` (Choice, Get-AzADGroup) | new-vm-windows | az.compute/set-azvmextension |

### 2d. Storage, Key Vault, identity

| ID | Task Id | Emits | Fields | Prereq task | Docs |
| -- | ------- | ----- | ------ | ----------- | ---- |
| T-231 | `azure.storage.new-storage-account` | `New-AzStorageAccount -Kind StorageV2 -MinimumTlsVersion TLS1_2 -AllowBlobPublicAccess $false` | `ResourceGroupName`, `Location`, `AccountName` (Pattern `^[a-z0-9]{3,24}$`), `Sku` (Choice), `Kind` (Choice StorageV2/FileStorage) | create.resource-group | az.storage/new-azstorageaccount |
| T-232 | `azure.storage.new-file-share` | `New-AzRmStorageShare -QuotaGiB` | `ResourceGroupName`, `AccountName` (Choice, Get-AzStorageAccount), `ShareName`, `QuotaGb` (Int) | new-storage-account | az.storage/new-azrmstorageshare |
| T-233 | `azure.storage.new-blob-container` | `New-AzRmStorageContainer -PublicAccess None` | `ResourceGroupName`, `AccountName` (Choice), `ContainerName` | new-storage-account | az.storage/new-azrmstoragecontainer |
| T-234 | `azure.storage.enable-entra-kerberos` | `Set-AzStorageAccount -EnableAzureActiveDirectoryKerberosForFile $true` + `-DefaultSharePermission`; Learn notes about the admin-consent step. Mirror azure repo `storage/Set-AvdProfileShareAccess.ps1` | `ResourceGroupName`, `AccountName` (Choice), `DefaultSharePermission` (Choice) | new-file-share | az.storage/set-azstorageaccount |
| T-235 | `azure.keyvault.new-key-vault` | `New-AzKeyVault -EnableRbacAuthorization -EnablePurgeProtection` | `ResourceGroupName`, `Location`, `VaultName` (Pattern), `Sku` (Choice Standard/Premium) | create.resource-group | az.keyvault/new-azkeyvault |
| T-236 | `azure.keyvault.set-secret` | `Set-AzKeyVaultSecret -SecretValue` with the Secret rendered as `Read-Host -AsSecureString` | `VaultName` (Choice, Get-AzKeyVault), `SecretName`, `SecretValue` (Secret, SecretKind SecureString) | new-key-vault | az.keyvault/set-azkeyvaultsecret |
| T-237 | `azure.identity.new-role-assignment` | `New-AzRoleAssignment -ObjectId -RoleDefinitionName -Scope` | `PrincipalType` (Choice Group/User/ServicePrincipal), `ObjectId` (Choice, Get-AzADGroup or Get-AzADUser depending; simplest: two optional Choice fields, step uses whichever is set), `Role` (Choice, Get-AzRoleDefinition), `Scope` (Choice, Get-AzResourceGroup Value ResourceId) | — | az.resources/new-azroleassignment |
| T-238 | `azure.identity.new-user-assigned-identity` | `New-AzUserAssignedIdentity` | `ResourceGroupName`, `Location`, `IdentityName` | create.resource-group | az.managedserviceidentity/new-azuserassignedidentity |
| T-239 | `azure.identity.new-entra-group` | `New-AzADGroup -SecurityEnabled -MailNickname` (Az side of m365.groups.new-security-group; Learn note on which to use when) | `DisplayName`, `MailNickname`, `Description` | — | az.resources/new-azadgroup |

### 2e. Azure Virtual Desktop (mirror the `azure` repo; the module functions there are the source of truth)

| ID | Task Id | Emits | Fields | Prereq task | Docs / source |
| -- | ------- | ----- | ------ | ----------- | ------------- |
| T-241 | `azure.avd.new-host-pool` | `New-AzWvdHostPool` with `-CustomRdpProperty 'targetisaadjoined:i:1;...'` when Entra joined | `ResourceGroupName`, `Location`, `HostPoolName`, `HostPoolType` (Choice Pooled/Personal), `LoadBalancerType` (Choice), `MaxSessionLimit` (Int), `EntraJoined` (Bool), `StartVMOnConnect` (Bool) | create.resource-group, register-providers | azure repo `AvdBuild/New-AvdHostPoolResource` |
| T-242 | `azure.avd.new-application-group` | `New-AzWvdApplicationGroup -ApplicationGroupType Desktop -HostPoolArmPath` | `ResourceGroupName`, `Location`, `HostPoolName` (Choice, Get-AzWvdHostPool), `AppGroupName` | new-host-pool | `New-AvdApplicationGroupResource` |
| T-243 | `azure.avd.new-workspace` | `New-AzWvdWorkspace`, `Register-AzWvdApplicationGroup` | `ResourceGroupName`, `Location`, `WorkspaceName`, `AppGroupName` (Choice, Get-AzWvdApplicationGroup) | new-application-group | `New-AvdWorkspaceResource`, `Register-AvdApplicationGroupToWorkspace` |
| T-244 | `azure.avd.grant-desktop-access` | `New-AzRoleAssignment -RoleDefinitionName 'Desktop Virtualization User' -Scope <app group id>` | `ResourceGroupName`, `AppGroupName` (Choice), `GroupObjectId` (Choice, Get-AzADGroup) | new-application-group | `Grant-AvdDesktopAccess` |
| T-245 | `azure.avd.new-registration-token` | `New-AzWvdRegistrationInfo -ExpirationTime (Get-Date).AddHours(N)` then read `.Token` (Raw); Learn: one token per pool, regenerating invalidates | `ResourceGroupName`, `HostPoolName` (Choice), `Hours` (Int, default 24) | new-host-pool | `AvdHelpers/Get-AvdRegistrationToken` |
| T-246 | `azure.avd.new-session-host` | The 7-step chain from azure repo `docs/avd/provisioning-order.md`: resolve image, NIC, VM with `Windows_Client`, join extension (Entra or AD gated by `When`), DSC AVD agent extension with token, FSLogix Run Command (When share set), wait for Available (Raw loop) | `ResourceGroupName`, `Location`, `HostPoolName` (Choice), `VMName`, `VMSize` (Choice), `SubnetId` (String; Learn: copy from new-vnet output), `ImageSku` (Choice), `JoinType` (Choice EntraId/ActiveDirectory), `LocalAdmin` (Secret), `DomainName`, `OUPath`, `DomainJoinCred` (Secret), `FsLogixShare` (String optional), `RegistrationToken` (Secret, SecretKind SecureString; Learn: paste from new-registration-token) | new-host-pool, new-vnet, new-registration-token | `AvdBuild` functions 7 through 13 |
| T-247 | `azure.avd.set-drain-mode` | `Update-AzWvdSessionHost -AllowNewSession` | `ResourceGroupName`, `HostPoolName` (Choice), `SessionHostName` (Choice, Get-AzWvdSessionHost Parameters RG + HostPoolName, Display Name), `Drain` (Bool) | new-session-host | `AvdHelpers/Set-AvdSessionHostDrain` |
| T-248 | `azure.avd.message-users` | `Get-AzWvdUserSession`, `Send-AzWvdUserSessionMessage` loop (Raw) | as T-247 + `Title`, `Body` | new-session-host | `AvdHelpers/Send-AvdUserMessage` |
| T-249 | `azure.avd.logoff-users` | `Remove-AzWvdUserSession -Force` loop (Raw); Rollback: none, Learn: destructive | as T-247 | new-session-host | `AvdHelpers/Remove-AvdUserSession` |
| T-250 | `azure.avd.new-scaling-plan` | `New-AzWvdScalingPlan` with one weekday schedule, `Update-AzWvdScalingPlan -HostPoolReference`; needs the AVD service principal role first (Learn + a role-assignment step) | `ResourceGroupName`, `Location`, `PlanName`, `HostPoolName` (Choice), `TimeZone`, ramp-up/peak/ramp-down hours (Int x3), `MinHostsPercent` (Int) | new-host-pool | az.desktopvirtualization/new-azwvdscalingplan |
| T-251 | `azure.avd.set-fslogix-registry` | `Invoke-AzVMRunCommand -ScriptPath` pointing at azure repo `hostconfig/Set-FsLogixProfile.ps1`, or inline the registry lines (Raw) | `ResourceGroupName`, `VMName` (Choice), `ShareUnc` | new-session-host | azure repo `Set-AvdSessionHostFsLogix` |

### 2f. Backup, monitoring, delete

| ID | Task Id | Emits | Fields | Prereq task | Docs |
| -- | ------- | ----- | ------ | ----------- | ---- |
| T-261 | `azure.backup.new-recovery-vault` | `New-AzRecoveryServicesVault`, `Set-AzRecoveryServicesBackupProperty -BackupStorageRedundancy` | `ResourceGroupName`, `Location`, `VaultName`, `Redundancy` (Choice) | create.resource-group | azure repo `backup/Enable-AvdBackup.ps1` |
| T-262 | `azure.backup.enable-vm-backup` | `Get-AzRecoveryServicesVault`, `Get-AzRecoveryServicesBackupProtectionPolicy -Name DefaultPolicy`, `Enable-AzRecoveryServicesBackupProtection` | `VaultName` (Choice, Get-AzRecoveryServicesVault), `VMResourceGroupName`, `VMName` (Choice), `PolicyName` (String default DefaultPolicy) | new-recovery-vault | az.recoveryservices/enable-azrecoveryservicesbackupprotection |
| T-263 | `azure.backup.enable-file-share-backup` | Register container, `Enable-AzRecoveryServicesBackupProtection -WorkloadType AzureFiles` | `VaultName` (Choice), `AccountName` (Choice), `ShareName` | new-recovery-vault, new-file-share | same |
| T-264 | `azure.monitor.new-log-analytics` | `New-AzOperationalInsightsWorkspace -Sku PerGB2018 -RetentionInDays` | `ResourceGroupName`, `Location`, `WorkspaceName`, `RetentionDays` (Int) | create.resource-group | az.operationalinsights/new-azoperationalinsightsworkspace |
| T-265 | `azure.monitor.set-diagnostic-setting` | `New-AzDiagnosticSetting -ResourceId -WorkspaceId -Log/-Metric` (Raw) | `ResourceId` (String; Learn how to find it), `WorkspaceName` (Choice, Get-AzOperationalInsightsWorkspace) | new-log-analytics | az.monitor/new-azdiagnosticsetting |
| T-266 | `azure.delete.remove-resource-group` | `Get-AzResource` listing first (so you see what dies), then `Remove-AzResourceGroup -Force`; the script asks for a typed confirmation of the name (Raw `Read-Host` compare) | `ResourceGroupName` (Choice) | — | az.resources/remove-azresourcegroup |
| T-267 | `azure.delete.remove-vm-with-disks` | `Get-AzVM`, `Remove-AzVM`, then remove OS disk, data disks, NIC, public IP (Raw; mirror azure repo `Invoke-AvdHostReimage.ps1` delete half) | `ResourceGroupName`, `VMName` (Choice), `KeepDataDisks` (Bool) | — | az.compute/remove-azvm |

### 2g. Build paths (after their tasks exist)

| ID | Path Id | Tasks in order | Share | Depends on |
| -- | ------- | -------------- | ----- | ---------- |
| T-271 | `path.azure.vm-from-scratch` | resource-group, new-vnet, new-nsg, new-nsg-rule (RDP from one IP), set-subnet-nsg, new-public-ip, new-nic, new-vm-windows | ResourceGroupName<-Name, Location | T-211..216, T-221 |
| T-272 | `path.azure.avd-entra-lab` | register-providers, resource-group, new-vnet, new-storage-account, new-file-share, enable-entra-kerberos, new-host-pool, new-application-group, new-workspace, grant-desktop-access, new-registration-token, new-session-host | ResourceGroupName<-Name, Location, HostPoolName | T-201, T-231..234, T-241..246 |
| T-273 | `path.azure.vm-protect` | new-recovery-vault, enable-vm-backup, new-log-analytics, set-diagnostic-setting | ResourceGroupName, Location | T-261, T-262, T-264, T-265 |

## Phase 3: Microsoft 365 and Entra ID (Microsoft Graph PowerShell)

**Status 2026-10-17:** done: T-301, T-302, T-311, T-312, T-313, T-314, T-315, T-316, T-317,
T-318 (as `m365.licenses.*`), T-321, T-322, T-323, T-324, T-325, T-326, T-331, T-332, T-333,
T-334, T-341, T-342. **Remaining:** none in this phase; new items go here.

Needs `Requires.Auth = 'Graph'`, `Requires.Scopes` = the write scopes the *generated script*
needs (the tool itself only ever asks for read scopes, see `Assert-MsGraphContext`).
Verify scope names with `Find-MgGraphPermission` before committing; they do change.

| ID | Task Id | Emits | Fields | Scopes (script) | Prereq |
| -- | ------- | ----- | ------ | --------------- | ------ |
| T-301 | `m365.context.connect-graph` | `Connect-MgGraph -Scopes`, `Get-MgContext`; Learn: delegated vs app, consent | `Scopes` (MultiChoice, Options: ~12 common scopes with Display text), `TenantId` (optional) | — | — |
| T-302 | `m365.context.find-permission` | `Find-MgGraphPermission -SearchString -PermissionType Delegated` (inspect) | `Search` (String) | — | — |
| T-311 | `m365.users.new-user` | `New-MgUser` with `PasswordProfile` built in a Raw step from a `Read-Host -AsSecureString`; `-UsageLocation` | `DisplayName`, `UserPrincipalName`, `MailNickname`, `UsageLocation` (Choice Options US/GB/...), `Password` (Secret SecureString), `ForceChangePassword` (Bool) | User.ReadWrite.All | connect-graph |
| T-312 | `m365.users.set-user-properties` | `Update-MgUser` | `UserId` (Choice, Get-MgUser), `JobTitle`, `Department`, `OfficeLocation`, `MobilePhone` (all optional) | User.ReadWrite.All | — |
| T-313 | `m365.users.set-manager` | `Set-MgUserManagerByRef -BodyParameter @{ '@odata.id' = ... }` (Raw) | `UserId` (Choice), `ManagerId` (Choice, Get-MgUser) | User.ReadWrite.All | — |
| T-314 | `m365.users.reset-password` | `Update-MgUser -PasswordProfile` (Raw with SecureString prompt) | `UserId` (Choice), `Password` (Secret), `ForceChange` (Bool) | User-PasswordProfile.ReadWrite.All | — |
| T-315 | `m365.users.block-sign-in` | `Update-MgUser -AccountEnabled:$false`, `Revoke-MgUserSignInSession` | `UserId` (Choice), `RevokeSessions` (Bool) | User.ReadWrite.All, User.RevokeSessions.All | — |
| T-316 | `m365.users.assign-license` | `Set-MgUserLicense -AddLicenses @{SkuId=...} -RemoveLicenses @()` (Raw); Learn: UsageLocation required first | `UserId` (Choice), `SkuId` (Choice, Get-MgSubscribedSku Display SkuPartNumber Value SkuId) | User.ReadWrite.All, Organization.Read.All | — |
| T-317 | `m365.users.remove-license` | `Set-MgUserLicense -RemoveLicenses` | as above | same | — |
| T-318 | `m365.users.list-licenses` | `Get-MgSubscribedSku` select SkuPartNumber, ConsumedUnits, PrepaidUnits.Enabled (inspect) | — | Organization.Read.All | — |
| T-321 | `m365.groups.add-member` | `New-MgGroupMember -GroupId -DirectoryObjectId` | `GroupId` (Choice, Get-MgGroup), `UserId` (Choice, Get-MgUser) | GroupMember.ReadWrite.All | new-security-group |
| T-322 | `m365.groups.remove-member` | `Remove-MgGroupMemberByRef` | same | same | — |
| T-323 | `m365.groups.add-owner` | `New-MgGroupOwnerByRef` (Raw body) | same | Group.ReadWrite.All | — |
| T-324 | `m365.groups.new-m365-group` | `New-MgGroup -GroupTypes @('Unified') -MailEnabled:$true -Visibility` | `DisplayName`, `MailNickname`, `Visibility` (Choice Private/Public), `Description` | Group.ReadWrite.All | — |
| T-325 | `m365.groups.set-dynamic-rule` | `Update-MgGroup -GroupTypes @('DynamicMembership') -MembershipRule -MembershipRuleProcessingState On`; Learn: P1 licence, rule syntax link | `GroupId` (Choice), `Rule` (String, Example `(user.department -eq "Sales")`) | Group.ReadWrite.All | — |
| T-326 | `m365.groups.list-members` | `Get-MgGroupMember -All` expanded to UPN (Raw, inspect) | `GroupId` (Choice) | GroupMember.Read.All | — |
| T-331 | `entra.roles.assign-directory-role` | `Get-MgDirectoryRole` (activate template if needed), `New-MgDirectoryRoleMemberByRef`; Learn: prefer PIM, this is permanent | `RoleName` (Choice, Get-MgDirectoryRoleTemplate Display DisplayName Value Id), `UserId` (Choice) | RoleManagement.ReadWrite.Directory | — |
| T-332 | `entra.ca.new-named-location` | `New-MgIdentityConditionalAccessNamedLocation` with ipNamedLocation body (Raw) | `Name`, `IpRanges` (MultiChoice typed), `Trusted` (Bool) | Policy.ReadWrite.ConditionalAccess | — |
| T-333 | `entra.ca.new-policy-report-only` | `New-MgIdentityConditionalAccessPolicy` body with `state = 'enabledForReportingButNotEnforced'`, include group, require MFA (Raw); Learn: never create enabled from a script | `PolicyName`, `GroupId` (Choice), `ExcludeGroupId` (Choice; Learn: break-glass) | Policy.ReadWrite.ConditionalAccess | — |
| T-334 | `entra.apps.new-app-registration` | `New-MgApplication`, `New-MgServicePrincipal`; Learn: when you need one (automation), least privilege | `DisplayName`, `SignInAudience` (Choice) | Application.ReadWrite.All | — |
| T-341 | `path.m365.onboard-user` | new-user, assign-license, add-member (x1), set-manager | UserId <- new user's Id via `$user.Id` (needs T-108-style Output reuse: make `UserId` a Reference to `'$user.Id'` literal; design note in item) | T-311, T-316, T-321, T-313 |
| T-342 | `path.m365.offboard-user` | block-sign-in, remove-license, remove from all groups (Raw loop), set manager null, convert mailbox (phase 4) | UserId shared | T-315, T-317, T-322 |

## Phase 4: Exchange Online

**Status 2026-10-17:** done: T-401 through T-408. Lookup cookbook line for `Get-EXOMailbox`
added to `docs/authoring-tasks.md` is still **todo** (T-409).

Add `ExchangeOnline` auth to `Resolve-MsSource` (already stubbed) and a source cookbook
line for `Get-EXOMailbox -ResultSize Unlimited` (Display UserPrincipalName, Value Identity).

| ID | Task Id | Emits | Fields |
| -- | ------- | ----- | ------ |
| T-401 | `m365.exchange.connect` | `Connect-ExchangeOnline -UserPrincipalName`, `Get-ConnectionInformation` | `Upn` (optional) |
| T-402 | `m365.exchange.new-shared-mailbox` | `New-Mailbox -Shared`, then `Add-MailboxPermission -AccessRights FullAccess -AutoMapping`, `Add-RecipientPermission SendAs` gated by When | `Name`, `Alias`, `PrimarySmtpAddress`, `FullAccessUser` (Choice, Get-EXOMailbox), `SendAs` (Bool) |
| T-403 | `m365.exchange.add-mailbox-permission` | `Add-MailboxPermission` / `Add-RecipientPermission` | `Mailbox` (Choice), `User` (Choice), `Right` (Choice FullAccess/SendAs/SendOnBehalf), `AutoMapping` (Bool) |
| T-404 | `m365.exchange.set-forwarding` | `Set-Mailbox -ForwardingSMTPAddress -DeliverToMailboxAndForward` | `Mailbox` (Choice), `ForwardTo`, `KeepCopy` (Bool) |
| T-405 | `m365.exchange.convert-to-shared` | `Set-Mailbox -Type Shared`; Learn: under 50 GB no licence needed, remove licence after | `Mailbox` (Choice) |
| T-406 | `m365.exchange.set-litigation-hold` | `Set-Mailbox -LitigationHoldEnabled $true -LitigationHoldDuration` | `Mailbox` (Choice), `Days` (Int) |
| T-407 | `m365.exchange.new-distribution-group` | `New-DistributionGroup`, `Add-DistributionGroupMember` loop | `Name`, `Alias`, `Members` (MultiChoice, Get-EXORecipient) |
| T-408 | `m365.exchange.mailbox-report` | `Get-EXOMailboxStatistics` for all, select DisplayName, TotalItemSize, LastLogonTime (inspect) | `Top` (Int) |

## Phase 5: Later areas (open an item per task when you get here)

- **Intune** (`Microsoft.Graph.DeviceManagement`): list devices, sync device, create a
  compliance policy from JSON, assign a policy to a group.
- **Teams** (`MicrosoftTeams`): new team from group, add channel, set policies.
- **SharePoint** (`PnP.PowerShell` or Graph): new site, grant site access.
- **Windows 365**: provisioning policy (ties back to the Nerdio comparison).
- **Bicep hand-off**: a task that emits `New-AzResourceGroupDeployment -TemplateFile` for the
  azure repo's `infra/bicep/environments/lab`, so the two repos meet in the middle.

## Phase 6: Window polish

The window exists (T-008). These are refinements once T-100 confirms it runs.

| ID | Item | Depends on | Blocked by |
| -- | ---- | ---------- | ---------- |
| T-601 | ~~WinForms window~~ Done as T-008. Remaining polish after T-100: remember window size, keyboard shortcuts (Ctrl+G generate, Ctrl+C in output), double-click a tree node to generate with defaults (search box done) | T-100 | — |
| T-602 | Syntax-coloured preview in the console via PwshSpectreConsole when installed (optional dependency, degrade to plain text) | — | — |

## Order of attack, summarised

1. T-100 first (open the window on Windows), then T-101, T-102, T-103 (a person with a machine and a lab tenant; everything else can proceed in parallel).
2. T-104, T-105, T-108 (engine), then T-201, T-211 through T-217, T-231 through T-233 (the cheap Azure tasks, in parallel, one worker each).
3. T-221, T-241 through T-246 (the big AVD chain), then T-271, T-272.
4. Phase 3 in ID order; T-341/T-342 last.
5. Phase 4.
6. Everything else as wanted.
