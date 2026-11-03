<#
.SYNOPSIS
    Builds a complete AVD environment from nothing, in order, from one set of answers.
.DESCRIPTION
    The orchestrator. Every other script in avd/, storage/ and backup/ does one job; this
    one calls them in the right order with the right hand-offs:

      1. Register resource providers
      2. Resource group
      3. Lab infrastructure (Bicep): VNet + subnet + NSG, profile storage with Entra
         Kerberos, optional Compute Gallery
      4. Profile share access: NTFS permissions, admin-consent reminder
      5. Host pool, app group, workspace, user assignment, registration token
      6. Session hosts, one at a time, named <prefix>01, <prefix>02, ...
      7. Backup (optional)

    Entra ID join only, for now. Every step is idempotent, so re-running after a failure
    picks up where it left off. When run from a terminal (-Interactive) a failed step asks
    Retry / Skip / Abort; otherwise it throws.

    Abort offers a rollback. The orchestrator records which resources did NOT exist before
    each step, so it knows exactly what this run created. If it created the resource group,
    rollback deletes the group. Otherwise it deletes the owned resources one by one in
    reverse order. Pre-existing resources are never touched. A Recovery Services vault is
    never deleted automatically (vaults have deletion protections by design); rollback
    prints the manual steps for it instead.

    Start-AvdConsole.ps1 collects these parameters with a questionnaire and calls this.
    You can also call it directly, which makes an entire environment one command.
.PARAMETER SubscriptionId
    Subscription to build in.
.PARAMETER Environment
    Short label used in names and tags, e.g. lab, dev, prod.
.PARAMETER Location
    Azure region for everything. Must be an AVD metadata region.
.PARAMETER ResourceGroupName
    One resource group for the whole environment. Created if missing.
.PARAMETER IdentityType
    EntraId is the only value the orchestrator supports today.
.PARAMETER AddressPrefix
    VNet address space.
.PARAMETER SubnetPrefix
    Session host subnet.
.PARAMETER DeployProfileStorage
    Create the FSLogix storage account and share. Default $true.
.PARAMETER StorageAccountName
    Globally unique storage account name. Required when DeployProfileStorage is $true.
.PARAMETER StorageSkuName
    Premium_LRS for real use, Standard_LRS for a cheap lab.
.PARAMETER ProfileShareName
    Share name. Default profiles.
.PARAMETER SetNtfsPermissions
    Apply the FSLogix NTFS set to the share root.
.PARAMETER NtfsVia
    SessionHost (default): after the first session host is built, run the NTFS step
    inside it via Run Command. Works regardless of your ISP. Needs SessionHostCount
    of at least 1. Local: mount from this machine right after the storage deploys;
    needs outbound TCP 445, which most ISPs block.
.PARAMETER PauseForAdminConsent
    If automatic admin consent for the storage account's Entra app fails, stop and wait
    for Enter so you can grant it in the portal before any host tries to use the share.
    When the automatic grant succeeds there is no pause.
.PARAMETER SkipPermissionCheck
    Do not run the permission preflight. By default the build checks the signed-in
    account against every Azure action and Entra role it needs and reports gaps before
    creating anything.
.PARAMETER DeployGallery
    Also create a Compute Gallery and image definition. Default $false.
.PARAMETER GalleryName
    Gallery name, no hyphens. Default gal_avd_<Environment>.
.PARAMETER ImageDefinitionName
    Image definition name. Default win11-avd-m365.
.PARAMETER UserGroupObjectId
    Entra group that gets the desktop and VM sign-in rights.
.PARAMETER HostPoolName
    Default hp-<Environment>.
.PARAMETER WorkspaceName
    Default ws-<Environment>.
.PARAMETER HostPoolType
    Pooled or Personal.
.PARAMETER LoadBalancerType
    BreadthFirst or DepthFirst. Pooled only.
.PARAMETER MaxSessionLimit
    Sessions per host. Pooled only.
.PARAMETER StartVMOnConnect
    Let the service power on deallocated hosts when a user connects.
.PARAMETER SessionHostCount
    How many hosts to build. 0 builds none.
.PARAMETER SessionHostPrefix
    Hosts are named <prefix>01, <prefix>02... Keep prefix + 2 digits under 15 characters.
.PARAMETER VMSize
    Session host size.
.PARAMETER ImageSku
    Marketplace SKU. Default win11-25h2-avd-m365.
.PARAMETER SecurityType
    TrustedLaunch or Standard.
.PARAMETER LocalAdminCredential
    Local administrator for every host. Required when SessionHostCount is above 0.
.PARAMETER EnableBackup
    Create a Recovery Services vault and protect the share (and hosts, if Personal).
.PARAMETER VaultName
    Default rsv-avd-<Environment>.
.PARAMETER Interactive
    Ask Retry / Skip / Abort when a step fails instead of throwing. Abort then asks
    whether to roll back.
.PARAMETER RollbackOnFailure
    Unattended equivalent: when a step fails and -Interactive is not set, roll back
    everything this run created without asking, then throw. Without it (and without
    -Interactive) a failure leaves everything in place and the run stops; re-running
    continues from the first missing piece.
.PARAMETER RemoveStaleEntraDevice
    Let the build delete Entra device records that carry a planned host name but
    have no VM (left over from deleted hosts). Off by default: the preflight reports
    them and stops, and you delete them in the Entra admin center.
.EXAMPLE
    ./New-AvdEnvironment.ps1 -SubscriptionId <sub> -Environment lab -Location westus3 `
        -ResourceGroupName rg-avd-lab -StorageAccountName stavdlab001 -StorageSkuName Standard_LRS `
        -UserGroupObjectId <group-id> -SessionHostCount 1 -SessionHostPrefix avd-lab- `
        -LocalAdminCredential (Get-Credential) -SetNtfsPermissions -PauseForAdminConsent -Interactive -Verbose
.NOTES
    Requires: Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.Storage,
              Az.DesktopVirtualization, Az.RecoveryServices, and the Bicep CLI on PATH.
    Status:   Tested 2026-10-17 (Entra-only lab, one host; NTFS step skipped in that run)
    Roles:    Contributor on the subscription (provider registration) and User Access
              Administrator on the resource group (role assignments).
#>

#region 1. Parameters ---------------------------------------------------------
#   WHAT   The union of every question the console asks. Grouped in the same order
#          as the steps. Defaults derive from -Environment so a minimal call needs
#          only subscription, location, resource group, storage name, group, and a
#          credential.
#   WHY    One parameter set for the whole build means the plan is a single
#          hashtable that can be printed, saved to a *.local.json, or replayed.
#   GOTCHA PSReviewUnusedParameter is suppressed for this file. Almost every
#          parameter is consumed inside a scriptblock handed to Invoke-Step, and the
#          rule does not look inside child scriptblocks, so it reports false
#          positives here. The scriptblocks run in this script's scope, so the
#          parameters are genuinely in use.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parameters are used inside Invoke-Step scriptblocks, which the rule does not inspect.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    # Scope
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9]{2,10}$')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [string]$Location,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter()]
    [ValidateSet('EntraId')]
    [string]$IdentityType = 'EntraId',

    # Network
    [Parameter()]
    [string]$AddressPrefix = '10.10.0.0/16',

    [Parameter()]
    [string]$SubnetPrefix = '10.10.1.0/24',

    # Profile storage
    [Parameter()]
    [bool]$DeployProfileStorage = $true,

    [Parameter()]
    [string]$StorageAccountName,

    [Parameter()]
    [ValidateSet('Premium_LRS', 'Premium_ZRS', 'Standard_LRS', 'Standard_ZRS')]
    [string]$StorageSkuName = 'Premium_LRS',

    [Parameter()]
    [string]$ProfileShareName = 'profiles',

    [Parameter()]
    [switch]$SetNtfsPermissions,

    [Parameter()]
    [ValidateSet('SessionHost', 'Local')]
    [string]$NtfsVia = 'SessionHost',

    [Parameter()]
    [switch]$PauseForAdminConsent,

    [Parameter()]
    [switch]$SkipPermissionCheck,

    [Parameter()]
    [switch]$RemoveStaleEntraDevice,

    # Gallery
    [Parameter()]
    [bool]$DeployGallery = $false,

    [Parameter()]
    [string]$GalleryName,

    [Parameter()]
    [string]$ImageDefinitionName = 'win11-avd-m365',

    # Identity
    [Parameter()]
    [string]$UserGroupObjectId,

    # Host pool
    [Parameter()]
    [string]$HostPoolName,

    [Parameter()]
    [string]$WorkspaceName,

    [Parameter()]
    [ValidateSet('Pooled', 'Personal')]
    [string]$HostPoolType = 'Pooled',

    [Parameter()]
    [ValidateSet('BreadthFirst', 'DepthFirst')]
    [string]$LoadBalancerType = 'BreadthFirst',

    [Parameter()]
    [ValidateRange(1, 999)]
    [int]$MaxSessionLimit = 10,

    [Parameter()]
    [switch]$StartVMOnConnect,

    # Session hosts
    [Parameter()]
    [ValidateRange(0, 50)]
    [int]$SessionHostCount = 1,

    [Parameter()]
    [string]$SessionHostPrefix,

    [Parameter()]
    [string]$VMSize = 'Standard_D4s_v5',

    [Parameter()]
    [string]$ImageSku = 'win11-25h2-avd-m365',

    [Parameter()]
    [ValidateSet('TrustedLaunch', 'Standard')]
    [string]$SecurityType = 'TrustedLaunch',

    [Parameter()]
    [pscredential]$LocalAdminCredential,

    # Backup
    [Parameter()]
    [switch]$EnableBackup,

    [Parameter()]
    [string]$VaultName,

    # Behaviour
    [Parameter()]
    [switch]$Interactive,

    [Parameter()]
    [switch]$RollbackOnFailure
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Modules, context, derived defaults, cross-parameter checks, and two
#          helpers: a step runner and an ownership tracker for rollback.
#   WHY    Everything that can fail before touching Azure fails here. The step
#          runner gives Retry / Skip / Abort without repeating try/catch seven
#          times. The ownership tracker is what makes Abort safe: it only ever
#          deletes things this run created.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AvdHelpers' 'AvdHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AvdBuild' 'AvdBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
Write-Verbose "Building environment '$Environment' in $Location with $IdentityType identity."

if (-not $GalleryName)        { $GalleryName        = "gal_avd_$Environment" }
if (-not $HostPoolName)       { $HostPoolName       = "hp-$Environment" }
if (-not $WorkspaceName)      { $WorkspaceName      = "ws-$Environment" }
if (-not $SessionHostPrefix)  { $SessionHostPrefix  = "avd-$Environment-" }
if (-not $VaultName)          { $VaultName          = "rsv-avd-$Environment" }
$vnetName  = "vnet-avd-$Environment"
$nsgName   = 'nsg-snet-avd'
$appGroupName = "$HostPoolName-dag"

if ($DeployProfileStorage -and -not $StorageAccountName) {
    throw 'DeployProfileStorage is true, so -StorageAccountName is required.'
}
if ($SessionHostCount -gt 0 -and -not $LocalAdminCredential) {
    throw "SessionHostCount is $SessionHostCount, so -LocalAdminCredential is required."
}
if ($SetNtfsPermissions -and $NtfsVia -eq 'SessionHost' -and $SessionHostCount -lt 1) {
    Write-Warning 'NtfsVia SessionHost needs at least one session host. NTFS will be skipped; run Set-AvdProfileShareAccess.ps1 -SetNtfsPermissions -ViaVMName <host> later.'
}
if (($SessionHostPrefix.Length + 2) -gt 15) {
    throw "SessionHostPrefix '$SessionHostPrefix' plus a 2-digit index exceeds the 15-character computer name limit."
}
if (-not (Get-Command bicep -ErrorAction SilentlyContinue)) {
    throw 'The Bicep CLI must be on PATH (winget install Microsoft.Bicep). New-AzResourceGroupDeployment compiles main.bicep with it. The copy inside Azure CLI (az bicep) is not on PATH.'
}

$scripts = @{
    Lab         = Join-Path $PSScriptRoot '..' '..' '..' 'infra' 'bicep' 'environments' 'lab' 'main.bicep'
    ShareAccess = Join-Path $PSScriptRoot '..' 'storage' 'Set-AvdProfileShareAccess.ps1'
    HostPool    = Join-Path $PSScriptRoot 'New-AvdHostPool.ps1'
    SessionHost = Join-Path $PSScriptRoot 'New-AvdSessionHost.ps1'
    Backup      = Join-Path $PSScriptRoot '..' 'backup' 'Enable-AvdBackup.ps1'
}
$verbose = ($VerbosePreference -eq 'Continue')
$state = [ordered]@{}                                           # hand-offs between steps
$consentOk = $false
$owned = [System.Collections.Generic.List[object]]::new()       # resources this run created

function Register-Owned {
    <#
    .SYNOPSIS
        Record a resource as "ours" if it does not exist yet. Called BEFORE the step
        that creates it, so a partial failure inside the step is still tracked.
    .PARAMETER Exists
        Scriptblock returning truthy if the resource exists right now.
    .PARAMETER Remove
        Scriptblock that deletes it. Only ever called from Invoke-Rollback.
    #>
    param(
        [string]$Kind,
        [string]$Name,
        [scriptblock]$Exists,
        [scriptblock]$Remove,
        [int]$Order
    )
    if ($WhatIfPreference) { return }
    if (& $Exists) {
        Write-Verbose "  $Kind $Name already exists; not owned by this run."
        return
    }
    $owned.Add([pscustomobject]@{ Kind = $Kind; Name = $Name; Exists = $Exists; Remove = $Remove; Order = $Order })
}

function Invoke-Rollback {
    <#
    .SYNOPSIS
        Delete what this run created, in reverse dependency order. Asks first when
        interactive.
    #>
    $rgOwned = $owned | Where-Object Kind -eq 'ResourceGroup'
    $present = @($owned | Where-Object { $_.Kind -ne 'ResourceGroup' -and (& $_.Exists) } | Sort-Object Order -Descending)

    if (-not $rgOwned -and $present.Count -eq 0) {
        Write-Warning 'Rollback: nothing was created by this run. Nothing to delete.'
        return
    }

    Write-Warning 'Rollback would delete the following, created by this run:'
    if ($rgOwned) {
        Write-Warning "  Resource group $ResourceGroupName and EVERYTHING in it (this run created the group)."
    } else {
        foreach ($r in $present) { Write-Warning "  $($r.Kind) $($r.Name)" }
    }
    $vault = $owned | Where-Object Kind -eq 'RecoveryServicesVault' | Where-Object { & $_.Exists }
    if ($vault -and -not $rgOwned) {
        Write-Warning "  NOT deleted automatically: vault $VaultName. Disable protection on its items (with -RemoveRecoveryPoints), wait for soft-deleted items to clear, then Remove-AzRecoveryServicesVault."
    }

    if ($Interactive) {
        $answer = (Read-Host '  Delete these now? Type DELETE to confirm, anything else to leave them').Trim()
        if ($answer -ne 'DELETE') {
            Write-Warning 'Rollback skipped. Re-run this script to continue the build, or clean up by hand.'
            return
        }
    }

    if ($rgOwned) {
        if ($vault) {
            Write-Warning "Vault $VaultName will block the resource group delete until its protected items are removed. Deleting everything else first."
            Write-Warning 'Remove the vault by hand, then Remove-AzResourceGroup.'
        }
        Write-Warning "Deleting resource group $ResourceGroupName..."
        try {
            # Names first: the Entra leftovers are keyed by VM and storage account name.
            $vmNames = @($owned | Where-Object Kind -eq 'VirtualMachine' | ForEach-Object Name)
            $saNames = @($owned | Where-Object Kind -eq 'StorageAccount' | ForEach-Object Name)
            $null = Remove-AzResourceGroup -Name $ResourceGroupName -Force
            Write-Warning 'Resource group deleted.'
            foreach ($n in $vmNames) { try { $null = Remove-AvdEntraDevice -Name $n -Confirm:$false } catch { Write-Warning "Entra device record for $n not removed: $($_.Exception.Message)" } }
            foreach ($n in $saNames) { try { $null = Remove-AvdStorageKerberosApp -StorageAccountName $n -Confirm:$false } catch { Write-Warning "Entra app for storage account $n not removed: $($_.Exception.Message)" } }
        } catch {
            Write-Warning "Resource group delete failed: $($_.Exception.Message). Falling back to per-resource delete."
            $rgOwned = $null
        }
    }

    if (-not $rgOwned) {
        foreach ($r in $present) {
            if ($r.Kind -eq 'RecoveryServicesVault') { continue }
            try {
                Write-Warning "Deleting $($r.Kind) $($r.Name)..."
                & $r.Remove
            } catch {
                Write-Warning "  Could not delete $($r.Kind) $($r.Name): $($_.Exception.Message)"
            }
        }
        Write-Warning 'Rollback finished. Check the resource group for anything that could not be removed.'
    }
}

function Invoke-Step {
    <#
    .SYNOPSIS
        Run one step. On failure: Retry / Skip / Abort when -Interactive; otherwise
        roll back if -RollbackOnFailure, then throw.
    #>
    param([string]$Name, [scriptblock]$Action)
    while ($true) {
        Write-Verbose "==== $Name"
        try {
            & $Action
            return $true
        } catch {
            Write-Warning "Step '$Name' failed: $($_.Exception.Message)"
            if (-not $Interactive) {
                if ($RollbackOnFailure) { Invoke-Rollback }
                throw
            }
            $choice = (Read-Host '  [R]etry, [S]kip, or [A]bort').Trim().ToUpperInvariant()
            switch ($choice) {
                'R' { continue }
                'S' { Write-Warning "Skipping '$Name'. Later steps may fail without it."; return $false }
                default {
                    Invoke-Rollback
                    throw "Aborted at step '$Name'."
                }
            }
        }
    }
}
#endregion

#region 2b. Permission preflight ---------------------------------------------
#   WHAT   Check the signed-in account against every Azure action and Entra role
#          the build needs. Report gaps as a table before anything is created.
#   WHY    A missing role otherwise appears twenty minutes in as AuthorizationFailed
#          on step six. Interactive runs can choose to continue anyway; unattended
#          runs stop on a missing required permission.
if (-not $SkipPermissionCheck) {
    $null = Invoke-Step -Name 'Permission preflight' -Action {
        $report = @(Test-AvdBuildPermission -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -IncludeBackup:$EnableBackup)
        $missing = @($report | Where-Object { $_.Required -and $_.Granted -eq $false })
        $unknown = @($report | Where-Object { $null -eq $_.Granted })
        if ($missing.Count -eq 0 -and $unknown.Count -eq 0) {
            Write-Verbose 'Permission preflight: every required permission is granted.'
            return
        }
        foreach ($m in $missing) { Write-Warning "MISSING  $($m.Capability). Fix with: $($m.FixWith)" }
        foreach ($u in $unknown) { Write-Warning "UNKNOWN  $($u.Capability) (could not query Entra directory roles)" }
        if ($missing.Count -gt 0) {
            if ($Interactive) {
                if ((Read-Host '  Some required permissions are missing. Continue anyway? (y/N)').Trim() -notmatch '^[Yy]') {
                    throw 'Stopped at permission preflight. Grant the roles above and re-run.'
                }
            } else {
                throw "Permission preflight failed: $($missing.Count) required permission(s) missing. Pass -SkipPermissionCheck to override."
            }
        }
    }
}
#endregion

#region 2b. Quota preflight ---------------------------------------------------
#   WHAT   Check the region's vCPU quota for the chosen VM size times the host count.
#   WHY    Quota is per VM family, per region, per subscription, and a personal or
#          new subscription often has 0 for a family. Without this check the build
#          creates network, storage and the host pool, then fails on the first VM
#          with OperationNotAllowed, and a rollback deletes all of it. Runs before
#          the resource group exists, so a failure here leaves nothing behind.
if ($SessionHostCount -gt 0) {
    $null = Invoke-Step -Name 'Quota preflight' -Action {
        $q = Test-AvdVmSizeQuota -Location $Location -VMSize $VMSize -Count $SessionHostCount
        if ($q.Ok) { Write-Verbose $q.Message; return }
        Write-Warning $q.Message
        if ($Interactive) {
            if ((Read-Host '  Not enough quota. Continue anyway? (y/N)').Trim() -notmatch '^[Yy]') {
                throw 'Stopped at quota preflight. Request the increase or choose another size, then re-run.'
            }
        } else {
            throw "Quota preflight failed. $($q.Message)"
        }
    }
}
#endregion

#region 3. Resource providers -------------------------------------------------
#   WHAT   The full AVD set, not just DesktopVirtualization.
#   WHY    Storage, Network, Compute and RecoveryServices are all used below. One
#          wait here beats four surprises later. Never rolled back: registration
#          is free and harmless to leave.
$null = Invoke-Step -Name 'Register resource providers' -Action {
    $providers = @('Microsoft.DesktopVirtualization', 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage')
    if ($EnableBackup) { $providers += 'Microsoft.RecoveryServices' }
    Assert-AzResourceProvider -Namespace $providers -Verbose:$verbose
}
#endregion

#region 4. Resource group -----------------------------------------------------
#   WHAT   One group for the whole environment.
#   WHY    A resource group is a lifecycle and RBAC boundary, not a network or
#          reference boundary. Resources in different groups talk to each other
#          freely. One group is the simplest correct answer for a lab; split by
#          lifecycle later if different people own the network and the pool.
#          If this run creates the group, rollback can delete the group and be
#          done, which is the cleanest possible undo.
Register-Owned -Kind 'ResourceGroup' -Name $ResourceGroupName -Order 0 `
    -Exists { Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue } `
    -Remove { Remove-AzResourceGroup -Name $ResourceGroupName -Force }

$null = Invoke-Step -Name "Resource group $ResourceGroupName" -Action {
    if (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue) {
        Write-Verbose "Resource group $ResourceGroupName exists."
    } elseif ($PSCmdlet.ShouldProcess($ResourceGroupName, "Create resource group in $Location")) {
        $null = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag @{ environment = $Environment; workload = 'avd' }
    }
}
#endregion

#region 5. Lab infrastructure (Bicep) ----------------------------------------
#   WHAT   Deploy infra/bicep/environments/lab/main.bicep with this run's answers.
#   WHY    Network, storage and gallery are declarative. Bicep owns them so a later
#          redeploy reconciles rather than recreates. The outputs feed every
#          following step.
#   GOTCHA New-AzResourceGroupDeployment compiles the .bicep with the Bicep CLI on
#          this machine. Under -WhatIf it runs the ARM what-if and yields no
#          outputs, so later steps get placeholders. The resource names below must
#          match what main.bicep produces, or rollback cannot find them.
Register-Owned -Kind 'NetworkSecurityGroup' -Name $nsgName -Order 10 `
    -Exists { Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $nsgName -ErrorAction SilentlyContinue } `
    -Remove { Remove-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $nsgName -Force }
Register-Owned -Kind 'VirtualNetwork' -Name $vnetName -Order 11 `
    -Exists { Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $vnetName -ErrorAction SilentlyContinue } `
    -Remove { Remove-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $vnetName -Force }
if ($DeployProfileStorage) {
    Register-Owned -Kind 'StorageAccount' -Name $StorageAccountName -Order 20 `
        -Exists { Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction SilentlyContinue } `
        -Remove {
            Remove-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -Force
            try { $null = Remove-AvdStorageKerberosApp -StorageAccountName $StorageAccountName -Confirm:$false } catch { Write-Warning "Entra app for storage account $StorageAccountName not removed: $($_.Exception.Message)" }
        }
}
if ($DeployGallery) {
    Register-Owned -Kind 'Gallery' -Name $GalleryName -Order 21 `
        -Exists { Get-AzGallery -ResourceGroupName $ResourceGroupName -Name $GalleryName -ErrorAction SilentlyContinue } `
        -Remove {
            Get-AzGalleryImageDefinition -ResourceGroupName $ResourceGroupName -GalleryName $GalleryName -ErrorAction SilentlyContinue |
                ForEach-Object { Remove-AzGalleryImageDefinition -ResourceGroupName $ResourceGroupName -GalleryName $GalleryName -Name $_.Name -Force }
            Remove-AzGallery -ResourceGroupName $ResourceGroupName -Name $GalleryName -Force
        }
}

$null = Invoke-Step -Name 'Deploy network, storage, gallery (Bicep)' -Action {
    $params = @{
        environment          = $Environment
        location             = $Location
        addressPrefix        = $AddressPrefix
        subnetPrefix         = $SubnetPrefix
        deployProfileStorage = $DeployProfileStorage
        deployGallery        = $DeployGallery
        galleryName          = $GalleryName
        imageDefinitionName  = $ImageDefinitionName
    }
    if ($DeployProfileStorage) {
        $params.storageAccountName = $StorageAccountName
        $params.storageSkuName     = $StorageSkuName
        $params.profileShareName   = $ProfileShareName
    }

    if ($WhatIfPreference) {
        New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateFile $scripts.Lab -TemplateParameterObject $params -WhatIf
        $state.SubnetId        = '<subnet id from deployment>'
        $state.ProfileShareUnc = if ($DeployProfileStorage) { "\\$StorageAccountName.file.core.windows.net\$ProfileShareName" } else { '' }
        return
    }

    $d = New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateFile $scripts.Lab `
        -TemplateParameterObject $params -Name "avd-$Environment-$(Get-Date -Format yyyyMMddHHmm)" -Verbose:$verbose
    if ($d.ProvisioningState -ne 'Succeeded') { throw "Deployment ended in state $($d.ProvisioningState)." }

    $out = $d.Outputs
    $state.SubnetId        = $out['subnetId'].Value
    $state.ProfileShareUnc = if ($out.ContainsKey('profileShareUnc')) { $out['profileShareUnc'].Value } else { '' }
    $state.GalleryName     = if ($out.ContainsKey('galleryName')) { $out['galleryName'].Value } else { '' }
    Write-Verbose "Subnet: $($state.SubnetId)"
    if ($state.ProfileShareUnc) { Write-Verbose "Profile share: $($state.ProfileShareUnc)" }
}
#endregion

#region 6. Profile share access -----------------------------------------------
#   WHAT   Verify Entra Kerberos, the admin-consent reminder, and NTFS if -NtfsVia
#          Local. With the default (SessionHost) the NTFS step is deferred to
#          region 8b, after the first host exists.
#   WHY    Bicep turned Entra Kerberos on. Consent and NTFS are the two things it
#          cannot do, and both must be done before a user's first sign-in or the
#          profile silently stays local. Nothing here needs rollback: it only
#          changes settings on the storage account from step 5.
if ($DeployProfileStorage) {
    $null = Invoke-Step -Name 'Profile share access (Entra Kerberos, NTFS)' -Action {
        $p = @{
            SubscriptionId     = $SubscriptionId
            ResourceGroupName  = $ResourceGroupName
            StorageAccountName = $StorageAccountName
            ShareName          = $ProfileShareName
            SetNtfsPermissions = ($SetNtfsPermissions -and $NtfsVia -eq 'Local')
            NtfsVia            = 'Local'
            Verbose            = $verbose
            WhatIf             = $WhatIfPreference
        }
        $shareResult = & $scripts.ShareAccess @p

        $consentOk = $shareResult -and $shareResult.AdminConsent -in 'Granted', 'AlreadyGranted'
        if ($consentOk) {
            Write-Verbose "Admin consent for the storage account's Entra app: $($shareResult.AdminConsent)."
        } elseif ($PauseForAdminConsent -and -not $WhatIfPreference) {
            Write-Warning "Automatic admin consent did not succeed. Grant it now: Entra admin center > App registrations > All applications > '[Storage Account] $StorageAccountName.file.core.windows.net' > API permissions > Grant admin consent."
            $null = Read-Host '  Press Enter when done (or to continue and do it later)'
        }
    }
}
#endregion

#region 7. Host pool ----------------------------------------------------------
#   WHAT   New-AvdHostPool.ps1 with -EntraJoined. Captures the token for step 8.
#   WHY    Three AVD objects are tracked for rollback. Order matters on delete:
#          app group before host pool (ARM refuses to delete a pool that still has
#          app groups), workspace any time.
Register-Owned -Kind 'ApplicationGroup' -Name $appGroupName -Order 31 `
    -Exists { Get-AzWvdApplicationGroup -ResourceGroupName $ResourceGroupName -Name $appGroupName -ErrorAction SilentlyContinue } `
    -Remove { Remove-AzWvdApplicationGroup -ResourceGroupName $ResourceGroupName -Name $appGroupName }
Register-Owned -Kind 'HostPool' -Name $HostPoolName -Order 30 `
    -Exists { Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName -ErrorAction SilentlyContinue } `
    -Remove { Remove-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName -Force }
Register-Owned -Kind 'Workspace' -Name $WorkspaceName -Order 32 `
    -Exists { Get-AzWvdWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction SilentlyContinue } `
    -Remove { Remove-AzWvdWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName }

$null = Invoke-Step -Name "Host pool $HostPoolName" -Action {
    $p = @{
        SubscriptionId    = $SubscriptionId
        ResourceGroupName = $ResourceGroupName
        Location          = $Location
        HostPoolName      = $HostPoolName
        WorkspaceName     = $WorkspaceName
        AppGroupName      = $appGroupName
        HostPoolType      = $HostPoolType
        LoadBalancerType  = $LoadBalancerType
        MaxSessionLimit   = $MaxSessionLimit
        StartVMOnConnect  = $StartVMOnConnect
        EntraJoined       = $true
        Verbose           = $verbose
        WhatIf            = $WhatIfPreference
    }
    if ($UserGroupObjectId) { $p.UserGroupObjectId = $UserGroupObjectId }
    $pool = & $scripts.HostPool @p
    $state.Token = if ($pool) { $pool.RegistrationToken } else { '<token from host pool>' }
}
#endregion

#region 7b. Preflight: stale Entra device records ----------------------------
#   WHAT   For every host name this run will build, look for an Entra ID device
#          object with that name whose VM no longer exists, and delete it.
#   WHY    A leftover record makes the Entra join fail with error_hostname_duplicate
#          while the extension still reports success. Catching it here means the
#          problem is reported before any VM is built, with all names in one list.
#          Deleting the records is opt-in (-RemoveStaleEntraDevice); the default is
#          to stop and name them, because nothing here should delete a directory
#          object the operator did not ask about.
#   GOTCHA A record whose VM DOES exist is left alone: that is a live host.
if ($SessionHostCount -gt 0 -and -not $WhatIfPreference) {
    $null = Invoke-Step -Name 'Preflight: stale Entra device records' -Action {
        $stale = @()
        for ($i = 1; $i -le $SessionHostCount; $i++) {
            $name = '{0}{1:d2}' -f $SessionHostPrefix, $i
            if (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $name -ErrorAction SilentlyContinue) { continue }
            try {
                $found = @(Find-AvdEntraDevice -Name $name)
                if ($found.Count -eq 0) { continue }
                if ($RemoveStaleEntraDevice) {
                    Write-Warning "Entra ID has $($found.Count) device record(s) named $name but no VM. Removing as asked (-RemoveStaleEntraDevice)."
                    $null = Remove-AvdEntraDevice -Name $name -Confirm:$false
                } else {
                    $stale += $name
                }
            } catch {
                Write-Warning "Could not check Entra for a device named ${name}: $($_.Exception.Message)"
            }
        }
        if ($stale.Count -gt 0) {
            throw "Entra ID still has device records for $($stale -join ', ') from deleted hosts; the Entra join would fail with error_hostname_duplicate. Delete them in Entra admin center > Devices > All devices (search each name), then re-run. Or re-run with -RemoveStaleEntraDevice to let the build delete them."
        }
    }
}
#endregion

#region 8. Session hosts ------------------------------------------------------
#   WHAT   New-AvdSessionHost.ps1 once per host, sequentially, marketplace image,
#          Entra join, FSLogix pointed at the share from step 5.
#   WHY    Sequential is slower than parallel but every failure is attributable to
#          one host, and the first host's failure stops you building ten broken ones.
#   GOTCHA Hosts that already exist are skipped (the build script refuses to
#          overwrite), so re-running after a failure continues the numbering.
#          Each host registers its VM, OS disk and NIC for rollback BEFORE the
#          build, so a VM whose extension failed halfway is still cleaned up.
$state.Hosts = @()
for ($i = 1; $i -le $SessionHostCount; $i++) {
    $vmName = '{0}{1:d2}' -f $SessionHostPrefix, $i
    if (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -ErrorAction SilentlyContinue) {
        Write-Verbose "Session host $vmName already exists. Skipping."
        $state.Hosts += $vmName
        continue
    }

    $thisVm = $vmName   # captured by the scriptblocks below; $vmName changes each loop
    Register-Owned -Kind 'VirtualMachine' -Name $thisVm -Order (100 + $i * 3 + 2) `
        -Exists { Get-AzVM -ResourceGroupName $ResourceGroupName -Name $thisVm -ErrorAction SilentlyContinue }.GetNewClosure() `
        -Remove {
            Remove-AzVM -ResourceGroupName $ResourceGroupName -Name $thisVm -Force
            try { $null = Remove-AvdEntraDevice -Name $thisVm -Confirm:$false } catch { Write-Warning "Entra device record for $thisVm not removed: $($_.Exception.Message)" }
        }.GetNewClosure()
    Register-Owned -Kind 'Disk' -Name "$thisVm-osdisk" -Order (100 + $i * 3 + 1) `
        -Exists { Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName "$thisVm-osdisk" -ErrorAction SilentlyContinue }.GetNewClosure() `
        -Remove { Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName "$thisVm-osdisk" -Force }.GetNewClosure()
    Register-Owned -Kind 'NetworkInterface' -Name "$thisVm-nic" -Order (100 + $i * 3) `
        -Exists { Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name "$thisVm-nic" -ErrorAction SilentlyContinue }.GetNewClosure() `
        -Remove { Remove-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name "$thisVm-nic" -Force }.GetNewClosure()

    $null = Invoke-Step -Name "Session host $vmName ($i of $SessionHostCount)" -Action {
        $p = @{
            SubscriptionId       = $SubscriptionId
            ResourceGroupName    = $ResourceGroupName
            HostPoolName         = $HostPoolName
            RegistrationToken    = $state.Token
            VMName               = $vmName
            VMSize               = $VMSize
            Location             = $Location
            SubnetId             = $state.SubnetId
            ImageSource          = 'Marketplace'
            ImageSku             = $ImageSku
            SecurityType         = $SecurityType
            LocalAdminCredential = $LocalAdminCredential
            JoinType             = 'EntraId'
            RemoveStaleEntraDevice = $RemoveStaleEntraDevice
            Tags                 = @{ environment = $Environment; workload = 'avd' }
            Verbose              = $verbose
            WhatIf               = $WhatIfPreference
        }
        if ($UserGroupObjectId)     { $p.UserGroupObjectId   = $UserGroupObjectId }
        if ($state.ProfileShareUnc) { $p.FsLogixProfileShare = $state.ProfileShareUnc }
        $null = & $scripts.SessionHost @p
        $state.Hosts += $vmName
    }
}
#endregion

#region 8b. NTFS from the first session host ---------------------------------
#   WHAT   Apply the FSLogix ACL to the share root by running icacls inside the
#          first host via Run Command.
#   WHY    The host is in the VNet, so port 445 to the storage account works no
#          matter what the admin's ISP blocks. This is why it comes after region 8
#          and not with the rest of the share setup in region 6.
if ($DeployProfileStorage -and $SetNtfsPermissions -and $NtfsVia -eq 'SessionHost' -and $state.Hosts.Count -gt 0 -and -not $WhatIfPreference) {
    $firstHost = $state.Hosts[0]
    $null = Invoke-Step -Name "NTFS permissions on $ProfileShareName via $firstHost" -Action {
        $p = @{
            SubscriptionId         = $SubscriptionId
            ResourceGroupName      = $ResourceGroupName
            StorageAccountName     = $StorageAccountName
            ShareName              = $ProfileShareName
            SetNtfsPermissions     = $true
            NtfsVia                = 'SessionHost'
            ViaVMName              = $firstHost
            ViaVMResourceGroupName = $ResourceGroupName
            Verbose                = $verbose
        }
        $null = & $scripts.ShareAccess @p
    }
}
#endregion

#region 9. Backup (optional) --------------------------------------------------
#   WHAT   Vault, policies, protect the share and (Personal) hosts.
#   WHY    Tracked for rollback only so the rollback message can say "and there
#          is a vault you must remove by hand". Vaults refuse deletion while they
#          hold protected or soft-deleted items, and that is a feature.
if ($EnableBackup) {
    Register-Owned -Kind 'RecoveryServicesVault' -Name $VaultName -Order 200 `
        -Exists { Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroupName -Name $VaultName -ErrorAction SilentlyContinue } `
        -Remove { throw 'Vaults are not deleted automatically.' }

    $null = Invoke-Step -Name "Backup vault $VaultName" -Action {
        $p = @{
            SubscriptionId    = $SubscriptionId
            ResourceGroupName = $ResourceGroupName
            VaultName         = $VaultName
            Location          = $Location
            HostPoolName      = $HostPoolName
            Verbose           = $verbose
            WhatIf            = $WhatIfPreference
        }
        if ($DeployProfileStorage) {
            $p.ProfileStorageAccountName = $StorageAccountName
            $p.ProfileShareName          = $ProfileShareName
        }
        $null = & $scripts.Backup @p
    }
}
#endregion

#region 10. Output ------------------------------------------------------------
#   WHAT   What exists now and what a person still has to do.
[pscustomobject]@{
    Environment      = $Environment
    ResourceGroup    = $ResourceGroupName
    Location         = $Location
    SubnetId         = $state.SubnetId
    ProfileShareUnc  = $state.ProfileShareUnc
    Gallery          = if ($DeployGallery) { $GalleryName } else { $null }
    HostPool         = $HostPoolName
    Workspace        = $WorkspaceName
    SessionHosts     = $state.Hosts
    UserGroup        = $UserGroupObjectId
    CreatedByThisRun = @($owned | ForEach-Object { "$($_.Kind) $($_.Name)" })
    NextSteps        = @(
        if ($DeployProfileStorage -and -not $consentOk) { "Grant admin consent to '[Storage Account] $StorageAccountName.file.core.windows.net' (automatic grant did not succeed)." }
        if (-not $UserGroupObjectId) { 'Assign a user group: Desktop Virtualization User on the app group, Virtual Machine User Login on each VM.' }
        'Sign in with a user in the group from the Windows App and confirm a VHDX appears on the share.'
        'Attach a scaling plan to the host pool for autoscale.'
    )
}
#endregion
