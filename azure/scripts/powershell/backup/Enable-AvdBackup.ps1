<#
.SYNOPSIS
    Sets up Azure Backup for an AVD deployment: vault, policies, FSLogix share, personal hosts.
.DESCRIPTION
    Idempotent. Creates what is missing and leaves what exists alone:

      1. Recovery Services vault (with the chosen storage redundancy)
      2. A daily VM backup policy and a daily Azure Files policy
      3. Protects the FSLogix profile share, if -ProfileStorageAccountName/-ProfileShareName given
      4. Protects every session host VM in the pool, if the pool is Personal

    Pooled hosts are never backed up. They are stateless by design: the user data is in
    FSLogix on the share, and a broken pooled host is reimaged, not restored.
.PARAMETER SubscriptionId
    Subscription for everything.
.PARAMETER ResourceGroupName
    Resource group for the vault.
.PARAMETER VaultName
    Recovery Services vault name.
.PARAMETER Location
    Region for the vault. Must match the region of the VMs and storage account it protects.
.PARAMETER StorageRedundancy
    LocallyRedundant, ZoneRedundant, or GeoRedundant. Can only be set before the first
    item is protected. Default LocallyRedundant.
.PARAMETER HostPoolName
    Host pool whose Personal hosts should be protected. Optional.
.PARAMETER HostPoolResourceGroupName
    Resource group of the host pool. Defaults to -ResourceGroupName.
.PARAMETER ProfileStorageAccountName
    Storage account holding the FSLogix share. Optional.
.PARAMETER ProfileShareName
    File share name inside that account. Required with -ProfileStorageAccountName.
.PARAMETER RetentionDays
    Daily retention for both policies. Default 30.
.PARAMETER BackupTimeUtc
    Daily backup time, HH:mm, UTC, on a 30-minute boundary. Default 02:00.
.EXAMPLE
    ./Enable-AvdBackup.ps1 -SubscriptionId <sub> -ResourceGroupName rg-avd-lab -VaultName rsv-avd-lab -Location westus3 `
        -HostPoolName hp-personal -ProfileStorageAccountName stavdlab -ProfileShareName profiles -Verbose
.NOTES
    Requires: Az.Accounts, Az.Resources, Az.RecoveryServices, Az.DesktopVirtualization
    Status:   Untested
    Roles:    Backup Contributor on the vault resource group. Contributor (or
              Virtual Machine Contributor) on the VMs. Storage Account Backup
              Contributor on the storage account.
#>

#region 1. Parameters ---------------------------------------------------------
#   WHAT   Vault settings, plus two optional things to protect.
#   WHY    You might set up the vault before any hosts exist, so both protection
#          targets are optional. Re-run later and it just adds the new items.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$VaultName,

    [Parameter(Mandatory)]
    [string]$Location,

    [Parameter()]
    [ValidateSet('LocallyRedundant', 'ZoneRedundant', 'GeoRedundant')]
    [string]$StorageRedundancy = 'LocallyRedundant',

    [Parameter()]
    [string]$HostPoolName,

    [Parameter()]
    [string]$HostPoolResourceGroupName = $ResourceGroupName,

    [Parameter()]
    [string]$ProfileStorageAccountName,

    [Parameter()]
    [string]$ProfileShareName,

    [Parameter()]
    [ValidateRange(7, 9999)]
    [int]$RetentionDays = 30,

    [Parameter()]
    [ValidatePattern('^\d{2}:(00|30)$')]
    [string]$BackupTimeUtc = '02:00'
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Strict mode, fail fast, modules, context, cross-parameter checks.
#   WHY    Same opening as every script. The share parameters travel as a pair.
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AvdHelpers' 'AvdHelpers.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId

if (($ProfileStorageAccountName -and -not $ProfileShareName) -or ($ProfileShareName -and -not $ProfileStorageAccountName)) {
    throw '-ProfileStorageAccountName and -ProfileShareName must be given together.'
}

# Azure Backup schedules are UTC DateTime values on a 30-minute boundary. Build one
# for today at the requested time; only the time-of-day part is used by the policy.
$runTimeUtc = [datetime]::ParseExact("$((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')) $BackupTimeUtc", 'yyyy-MM-dd HH:mm', $null)
$runTimeUtc = [datetime]::SpecifyKind($runTimeUtc, [System.DateTimeKind]::Utc)
#endregion

#region 3. Vault --------------------------------------------------------------
#   WHAT   Get or create the Recovery Services vault and set its storage redundancy.
#   WHY    The vault is the container for policies and protected items. Redundancy is
#          a one-way door: once anything is protected it cannot be changed, so it is
#          set immediately after creation and only then.
#   GOTCHA A vault can only protect VMs in its own region. One vault per region.
$vault = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroupName -Name $VaultName -ErrorAction SilentlyContinue
if (-not $vault) {
    if ($PSCmdlet.ShouldProcess($VaultName, "Create Recovery Services vault ($StorageRedundancy)")) {
        Write-Verbose "Creating vault $VaultName in $Location."
        $vault = New-AzRecoveryServicesVault -Name $VaultName -ResourceGroupName $ResourceGroupName -Location $Location
        $null = Set-AzRecoveryServicesBackupProperty -Vault $vault -BackupStorageRedundancy $StorageRedundancy
    }
} else {
    Write-Verbose "Vault $VaultName exists."
}

if ($WhatIfPreference -and -not $vault) {
    Write-Verbose 'WhatIf: vault does not exist yet, so policies and protection cannot be previewed further.'
    return
}
$vaultId = $vault.ID
#endregion

#region 4. Policies -----------------------------------------------------------
#   WHAT   One daily policy for VMs, one for Azure Files, both with the same
#          retention. Created only if missing.
#   WHY    Az.RecoveryServices builds a policy from two template objects (schedule +
#          retention) that you edit then submit. The Enhanced VM policy subtype is
#          used because Trusted Launch VMs require it.
#   GOTCHA Retention times must equal the schedule times or the API rejects the
#          policy. Existing policies are not modified; change them in the portal or
#          delete and re-run. The nested function declares SupportsShouldProcess so
#          it has its own $PSCmdlet; -WhatIf still flows in from the script because
#          $WhatIfPreference is inherited.
function Get-OrCreatePolicy {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Name,
        [string]$WorkloadType,
        [string]$BackupManagementType,
        [string]$PolicySubType,
        [string]$VaultId,
        [datetime]$RunTimeUtc,
        [int]$RetentionDays,
        [string]$BackupTimeUtc
    )
    $existing = Get-AzRecoveryServicesBackupProtectionPolicy -Name $Name -VaultId $VaultId -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Verbose "Policy $Name exists."
        return $existing
    }

    $schedParams = @{ WorkloadType = $WorkloadType; BackupManagementType = $BackupManagementType; ScheduleRunFrequency = 'Daily' }
    if ($PolicySubType) { $schedParams.PolicySubType = $PolicySubType }
    $schedule = Get-AzRecoveryServicesBackupSchedulePolicyObject @schedParams
    $schedule.ScheduleRunTimes.Clear()
    $schedule.ScheduleRunTimes.Add($RunTimeUtc)

    $retention = Get-AzRecoveryServicesBackupRetentionPolicyObject -WorkloadType $WorkloadType -BackupManagementType $BackupManagementType
    $retention.IsDailyScheduleEnabled = $true
    $retention.DailySchedule.DurationCountInDays = $RetentionDays
    $retention.DailySchedule.RetentionTimes = $schedule.ScheduleRunTimes
    foreach ($p in 'IsWeeklyScheduleEnabled', 'IsMonthlyScheduleEnabled', 'IsYearlyScheduleEnabled') {
        if ($retention.PSObject.Properties[$p]) { $retention.$p = $false }
    }

    if ($PSCmdlet.ShouldProcess($Name, "Create $WorkloadType backup policy (daily $BackupTimeUtc UTC, keep $RetentionDays days)")) {
        Write-Verbose "Creating policy $Name."
        return New-AzRecoveryServicesBackupProtectionPolicy -Name $Name -WorkloadType $WorkloadType -BackupManagementType $BackupManagementType `
            -SchedulePolicy $schedule -RetentionPolicy $retention -VaultId $VaultId
    }
}

$policyCommon = @{ VaultId = $vaultId; RunTimeUtc = $runTimeUtc; RetentionDays = $RetentionDays; BackupTimeUtc = $BackupTimeUtc }
$vmPolicy    = Get-OrCreatePolicy @policyCommon -Name 'avd-personal-daily' -WorkloadType 'AzureVM'    -BackupManagementType 'AzureVM'      -PolicySubType 'Enhanced'
$filesPolicy = Get-OrCreatePolicy @policyCommon -Name 'avd-profiles-daily' -WorkloadType 'AzureFiles' -BackupManagementType 'AzureStorage' -PolicySubType ''
#endregion

#region 5. Protect the FSLogix share -----------------------------------------
#   WHAT   Enable backup on the profile share if asked and not already protected.
#   WHY    The share IS the user data for pooled hosts. This is the one backup that
#          matters most in a pooled deployment.
#   GOTCHA Enable-AzRecoveryServicesBackupProtection registers the storage account
#          with the vault on first use. A storage account can be registered to only
#          one vault. If it is already registered elsewhere this step fails.
$protectedShare = $null
if ($ProfileShareName -and $filesPolicy) {
    $existing = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureStorage -WorkloadType AzureFiles `
        -Name $ProfileShareName -VaultId $vaultId -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Verbose "Share $ProfileShareName already protected."
        $protectedShare = $existing
    } elseif ($PSCmdlet.ShouldProcess("$ProfileStorageAccountName/$ProfileShareName", 'Enable Azure Files backup')) {
        Write-Verbose "Protecting share $ProfileShareName in $ProfileStorageAccountName."
        $null = Enable-AzRecoveryServicesBackupProtection -Policy $filesPolicy -Name $ProfileShareName `
            -StorageAccountName $ProfileStorageAccountName -VaultId $vaultId
        $protectedShare = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureStorage -WorkloadType AzureFiles `
            -Name $ProfileShareName -VaultId $vaultId -ErrorAction SilentlyContinue
    }
}
#endregion

#region 6. Protect personal session hosts -----------------------------------
#   WHAT   For a Personal pool, enable VM backup on every session host VM.
#   WHY    Personal hosts carry state: the user's apps, local files, and settings
#          live on that one VM. Pooled hosts carry nothing, so they are skipped with
#          a warning rather than silently.
#   GOTCHA VMs must be in the vault's region. A host in another region fails here
#          and the script stops. Create a vault in that region and re-run for it.
$protectedVms = @()
if ($HostPoolName -and $vmPolicy) {
    $pool = Get-AzWvdHostPool -ResourceGroupName $HostPoolResourceGroupName -Name $HostPoolName
    if ($pool.HostPoolType -ne 'Personal') {
        Write-Warning "Host pool $HostPoolName is $($pool.HostPoolType). Pooled hosts are stateless and are not backed up. Skipping VMs."
    } else {
        $hosts = Get-AvdSessionHostInfo -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName
        foreach ($h in $hosts) {
            if (-not $h.VmResourceId) { Write-Warning "Host $($h.Name) has no VM resource ID. Skipping."; continue }
            $vmRes = Get-AzResource -ResourceId $h.VmResourceId

            $existing = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM `
                -Name $vmRes.Name -VaultId $vaultId -ErrorAction SilentlyContinue
            if ($existing) {
                Write-Verbose "VM $($vmRes.Name) already protected."
                $protectedVms += $vmRes.Name
            } elseif ($PSCmdlet.ShouldProcess($vmRes.Name, 'Enable VM backup')) {
                Write-Verbose "Protecting VM $($vmRes.Name)."
                $null = Enable-AzRecoveryServicesBackupProtection -Policy $vmPolicy -Name $vmRes.Name `
                    -ResourceGroupName $vmRes.ResourceGroupName -VaultId $vaultId
                $protectedVms += $vmRes.Name
            }
        }
    }
}
#endregion

#region 7. Output -------------------------------------------------------------
#   WHAT   What is protected now.
#   WHY    Lets the console show a summary and lets you diff two runs.
[pscustomobject]@{
    Vault          = $vault.Name
    Redundancy     = $StorageRedundancy
    VmPolicy       = if ($vmPolicy) { $vmPolicy.Name } else { $null }
    FilesPolicy    = if ($filesPolicy) { $filesPolicy.Name } else { $null }
    ProtectedShare = if ($protectedShare) { $ProfileShareName } else { $null }
    ProtectedVms   = $protectedVms
}
#endregion
