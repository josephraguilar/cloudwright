#region Module setup ----------------------------------------------------------
#   WHAT   Azure Backup for VMs and file shares in Recovery Services vaults: what
#          is protected and how it is doing, recent jobs, recovery points, an
#          on-demand backup, protecting something new, restoring, and the daily
#          policies behind it all.
#   WHY    "Is it backed up, and when did it last work" is the question; the item
#          list answers it in one table. Restores are where mistakes hurt, so
#          they only ever write somewhere new.
#   GOTCHA Restores never overwrite: a VM restores as a new VM (or as disks in a
#          resource group), a share restores to another share or folder, or to its
#          own place skipping every file that still exists. Shortening a policy's
#          retention makes Azure prune older recovery points, which is a delete,
#          so it is refused unless asked for by name. Stopping protection is not
#          offered at all; do that in the portal.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
#endregion

#region Helpers ---------------------------------------------------------------
function Get-BkProp {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Get-BkKindMap {
    param([ValidateSet('VM', 'FileShare')] [string]$Kind)
    if ($Kind -eq 'VM') { return @{ Management = 'AzureVM'; Workload = 'AzureVM' } }
    return @{ Management = 'AzureStorage'; Workload = 'AzureFiles' }
}

function Get-BkVault {
    param([string]$VaultId)
    $p = $VaultId -split '/'
    return Get-AzRecoveryServicesVault -ResourceGroupName $p[4] -Name $p[-1]
}

function Get-BkRunTime {
    # Policy schedule times live in different places for standard and enhanced policies.
    param($Policy)
    $sp = Get-BkProp $Policy 'SchedulePolicy'
    $times = @(Get-BkProp $sp 'ScheduleRunTimes' @())
    if ($times.Count -eq 0) { $times = @(Get-BkProp (Get-BkProp $sp 'DailySchedule') 'ScheduleRunTimes' @()) }
    if ($times.Count -eq 0) { return '' }
    return ([datetime]$times[0]).ToUniversalTime().ToString('HH:mm') + ' UTC'
}
#endregion

#region Lookups ---------------------------------------------------------------
function Get-BackupVaultInfo {
    <#
    .SYNOPSIS
        Recovery Services vaults with region and storage redundancy.
    #>
    [CmdletBinding()]
    param()
    foreach ($v in @(Get-AzRecoveryServicesVault) | Sort-Object ResourceGroupName, Name) {
        $red = try { "$((Get-AzRecoveryServicesBackupProperty -Vault $v).BackupStorageRedundancy)" } catch { '' }
        [pscustomobject]@{ Name = $v.Name; ResourceGroupName = $v.ResourceGroupName; Location = $v.Location; Redundancy = $red; Id = $v.ID }
    }
}

function Get-BackupItemInfo {
    <#
    .SYNOPSIS
        Protected VMs or file shares across every vault (or one), with last backup
        time and status, health and policy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('VM', 'FileShare')] [string]$Kind,
        [Parameter()] [string]$VaultId
    )
    $m = Get-BkKindMap $Kind
    $vaults = if ($VaultId) { @(Get-BkVault $VaultId) } else { @(Get-AzRecoveryServicesVault) }
    foreach ($v in $vaults) {
        foreach ($i in @(Get-AzRecoveryServicesBackupItem -BackupManagementType $m.Management -WorkloadType $m.Workload -VaultId $v.ID -ErrorAction SilentlyContinue)) {
            $source = if ($Kind -eq 'VM') { "$(Get-BkProp $i 'VirtualMachineId' '')" } else { "$(Get-BkProp $i 'ContainerName' '')" }
            $display = if ($Kind -eq 'VM') { ($source -split '/')[-1] } else { "$(Get-BkProp $i 'FriendlyName' $i.Name)" }
            $last = Get-BkProp $i 'LastBackupTime'
            [pscustomobject]@{
                Name         = $display
                Source       = $(if ($Kind -eq 'VM') { ($source -split '/')[4] } else { ($source -split ';')[-1] })
                LastBackup   = $(if ($last) { ([datetime]$last).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { 'never' })
                LastStatus   = "$(Get-BkProp $i 'LastBackupStatus' '')"
                Health       = "$(Get-BkProp $i 'HealthStatus' (Get-BkProp $i 'ProtectionStatus' ''))"
                State        = "$(Get-BkProp $i 'ProtectionState' '')"
                Policy       = "$(Get-BkProp $i 'ProtectionPolicyName' '')"
                Vault        = $v.Name
                VaultId      = $v.ID
                ItemName     = $i.Name
                Kind         = $Kind
            }
        }
    }
}

function Get-BackupItemObject {
    <#
    .SYNOPSIS
        The Az backup item object for a row from Get-BackupItemInfo (VaultId + ItemName).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$VaultId,
        [Parameter(Mandatory)] [ValidateSet('VM', 'FileShare')] [string]$Kind,
        [Parameter(Mandatory)] [string]$ItemName
    )
    $m = Get-BkKindMap $Kind
    $item = @(Get-AzRecoveryServicesBackupItem -BackupManagementType $m.Management -WorkloadType $m.Workload -VaultId $VaultId) | Where-Object Name -eq $ItemName | Select-Object -First 1
    if (-not $item) { throw "No $Kind backup item '$ItemName' in vault $(($VaultId -split '/')[-1])." }
    return $item
}

function Get-BackupRecoveryPointInfo {
    <#
    .SYNOPSIS
        Recovery points of one item in the last -Days days, newest first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$VaultId,
        [Parameter(Mandatory)] [ValidateSet('VM', 'FileShare')] [string]$Kind,
        [Parameter(Mandatory)] [string]$ItemName,
        [Parameter()] [ValidateRange(1, 90)] [int]$Days = 30
    )
    $item = Get-BackupItemObject -VaultId $VaultId -Kind $Kind -ItemName $ItemName
    $end = (Get-Date).ToUniversalTime()
    $points = [System.Collections.Generic.List[object]]::new()
    # The service answers at most 30 days per call.
    for ($from = $end.AddDays(-$Days); $from -lt $end; $from = $from.AddDays(30)) {
        $to = if ($from.AddDays(30) -lt $end) { $from.AddDays(30) } else { $end }
        foreach ($rp in @(Get-AzRecoveryServicesBackupRecoveryPoint -Item $item -StartDate $from -EndDate $to -VaultId $VaultId -ErrorAction SilentlyContinue)) { $points.Add($rp) }
    }
    foreach ($rp in $points | Sort-Object RecoveryPointTime -Descending) {
        [pscustomobject]@{
            Time  = ([datetime]$rp.RecoveryPointTime).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
            Type  = "$(Get-BkProp $rp 'RecoveryPointType' '')"
            Tier  = "$(Get-BkProp $rp 'RecoveryPointTier' '')"
            Id    = $rp.RecoveryPointId
        }
    }
}

function Get-BackupJobInfo {
    <#
    .SYNOPSIS
        Backup and restore jobs of the last -Hours hours across every vault (or one).
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [string]$VaultId,
        [Parameter()] [ValidateRange(1, 720)] [int]$Hours = 48
    )
    $vaults = if ($VaultId) { @(Get-BkVault $VaultId) } else { @(Get-AzRecoveryServicesVault) }
    $from = (Get-Date).ToUniversalTime().AddHours(-$Hours)
    $rows = foreach ($v in $vaults) {
        foreach ($j in @(Get-AzRecoveryServicesBackupJob -VaultId $v.ID -From $from -ErrorAction SilentlyContinue)) {
            $start = Get-BkProp $j 'StartTime'; $end = Get-BkProp $j 'EndTime'
            [pscustomobject]@{
                Item      = "$(Get-BkProp $j 'WorkloadName' '')"
                Operation = "$(Get-BkProp $j 'Operation' '')"
                Status    = "$(Get-BkProp $j 'Status' '')"
                Started   = $(if ($start) { ([datetime]$start).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '' })
                Duration  = $(if ($start -and $end) { '{0:hh\:mm\:ss}' -f ([datetime]$end - [datetime]$start) } else { '' })
                Vault     = $v.Name
                StartedAt = $start
            }
        }
    }
    $rows | Sort-Object StartedAt -Descending | Select-Object Item, Operation, Status, Started, Duration, Vault
}

function Get-BackupPolicyInfo {
    <#
    .SYNOPSIS
        VM and file share policies of every vault (or one): schedule and daily retention.
    #>
    [CmdletBinding()]
    param([Parameter()] [string]$VaultId)
    $vaults = if ($VaultId) { @(Get-BkVault $VaultId) } else { @(Get-AzRecoveryServicesVault) }
    foreach ($v in $vaults) {
        foreach ($wl in 'AzureVM', 'AzureFiles') {
            foreach ($p in @(Get-AzRecoveryServicesBackupProtectionPolicy -WorkloadType $wl -VaultId $v.ID -ErrorAction SilentlyContinue)) {
                $rp = Get-BkProp $p 'RetentionPolicy'
                $daily = Get-BkProp $rp 'DailySchedule'
                [pscustomobject]@{
                    Name          = $p.Name
                    Workload      = $(if ($wl -eq 'AzureVM') { 'VM' } else { 'File share' })
                    Subtype       = "$(Get-BkProp $p 'PolicySubType' '')"
                    RunsAt        = Get-BkRunTime $p
                    KeepDays      = $(if ($daily) { [int](Get-BkProp $daily 'DurationCountInDays' 0) } else { 0 })
                    Weekly        = [bool](Get-BkProp $rp 'IsWeeklyScheduleEnabled' $false)
                    Monthly       = [bool](Get-BkProp $rp 'IsMonthlyScheduleEnabled' $false)
                    Vault         = $v.Name
                    VaultId       = $v.ID
                }
            }
        }
    }
}
#endregion

#region Create and protect ----------------------------------------------------
function New-BackupVault {
    <#
    .SYNOPSIS
        A Recovery Services vault. Redundancy can only be set before the first
        item is protected. Returns the existing vault untouched if the name is taken.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter()] [ValidateSet('LocallyRedundant', 'ZoneRedundant', 'GeoRedundant')] [string]$StorageRedundancy = 'LocallyRedundant'
    )
    $v = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
    if ($v) { Write-Verbose "Vault $Name exists."; return $v }
    if (-not $PSCmdlet.ShouldProcess($Name, "Create Recovery Services vault ($StorageRedundancy)")) { return }
    Write-Verbose "Creating vault $Name in $Location."
    $v = New-AzRecoveryServicesVault -Name $Name -ResourceGroupName $ResourceGroupName -Location $Location
    $null = Set-AzRecoveryServicesBackupProperty -Vault $v -BackupStorageRedundancy $StorageRedundancy
    return $v
}

function New-BackupDailyPolicy {
    <#
    .SYNOPSIS
        A daily policy for VMs (enhanced) or file shares, run time in UTC on the
        hour or half hour, keep N days. Returns the existing policy if the name is taken.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$VaultId,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [ValidateSet('VM', 'FileShare')] [string]$Kind,
        [Parameter()] [ValidateRange(7, 9999)] [int]$RetentionDays = 30,
        [Parameter()] [ValidatePattern('^\d{2}:(00|30)$')] [string]$BackupTimeUtc = '02:00'
    )
    $existing = Get-AzRecoveryServicesBackupProtectionPolicy -Name $Name -VaultId $VaultId -ErrorAction SilentlyContinue
    if ($existing) { Write-Verbose "Policy $Name exists."; return $existing }
    $m = Get-BkKindMap $Kind
    $runTime = [datetime]::SpecifyKind([datetime]::ParseExact("$((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')) $BackupTimeUtc", 'yyyy-MM-dd HH:mm', $null), [System.DateTimeKind]::Utc)
    $sp = @{ WorkloadType = $m.Workload; BackupManagementType = $m.Management; ScheduleRunFrequency = 'Daily' }
    if ($Kind -eq 'VM') { $sp.PolicySubType = 'Enhanced' }
    $schedule = Get-AzRecoveryServicesBackupSchedulePolicyObject @sp
    if ($schedule.PSObject.Properties['DailySchedule'] -and $schedule.DailySchedule) {
        $schedule.DailySchedule.ScheduleRunTimes.Clear(); $schedule.DailySchedule.ScheduleRunTimes.Add($runTime)
        $times = $schedule.DailySchedule.ScheduleRunTimes
    } else {
        $schedule.ScheduleRunTimes.Clear(); $schedule.ScheduleRunTimes.Add($runTime)
        $times = $schedule.ScheduleRunTimes
    }
    $retention = Get-AzRecoveryServicesBackupRetentionPolicyObject -WorkloadType $m.Workload -BackupManagementType $m.Management
    $retention.IsDailyScheduleEnabled = $true
    $retention.DailySchedule.DurationCountInDays = $RetentionDays
    $retention.DailySchedule.RetentionTimes = $times
    foreach ($p in 'IsWeeklyScheduleEnabled', 'IsMonthlyScheduleEnabled', 'IsYearlyScheduleEnabled') { if ($retention.PSObject.Properties[$p]) { $retention.$p = $false } }
    if (-not $PSCmdlet.ShouldProcess($Name, "Create $Kind backup policy (daily $BackupTimeUtc UTC, keep $RetentionDays days)")) { return }
    Write-Verbose "Creating policy $Name."
    return New-AzRecoveryServicesBackupProtectionPolicy -Name $Name -WorkloadType $m.Workload -BackupManagementType $m.Management -SchedulePolicy $schedule -RetentionPolicy $retention -VaultId $VaultId
}

function Set-BackupPolicySchedule {
    <#
    .SYNOPSIS
        Change a daily policy's run time or how many days it keeps. Keeping fewer
        days makes Azure prune older recovery points, so that needs
        -AllowShorterRetention.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$VaultId,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter()] [ValidateRange(7, 9999)] [int]$RetentionDays,
        [Parameter()] [ValidatePattern('^\d{2}:(00|30)$')] [string]$BackupTimeUtc,
        [Parameter()] [switch]$AllowShorterRetention
    )
    $p = Get-AzRecoveryServicesBackupProtectionPolicy -Name $Name -VaultId $VaultId
    $changes = @()
    if ($PSBoundParameters.ContainsKey('RetentionDays')) {
        $now = [int]$p.RetentionPolicy.DailySchedule.DurationCountInDays
        if ($RetentionDays -lt $now -and -not $AllowShorterRetention) {
            throw "Going from $now to $RetentionDays days deletes the recovery points older than $RetentionDays days. Pass -AllowShorterRetention if that is intended."
        }
        if ($RetentionDays -ne $now) { $p.RetentionPolicy.DailySchedule.DurationCountInDays = $RetentionDays; $changes += "keep $now -> $RetentionDays days" }
    }
    if ($BackupTimeUtc) {
        $runTime = [datetime]::SpecifyKind([datetime]::ParseExact("$((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')) $BackupTimeUtc", 'yyyy-MM-dd HH:mm', $null), [System.DateTimeKind]::Utc)
        $sp = $p.SchedulePolicy
        $times = if ($sp.PSObject.Properties['DailySchedule'] -and $sp.DailySchedule) { $sp.DailySchedule.ScheduleRunTimes } else { $sp.ScheduleRunTimes }
        $times.Clear(); $times.Add($runTime)
        $p.RetentionPolicy.DailySchedule.RetentionTimes = $times
        $changes += "run at $BackupTimeUtc UTC"
    }
    if ($changes.Count -eq 0) { Write-Verbose "Nothing to change on $Name."; return $p }
    if (-not $PSCmdlet.ShouldProcess($Name, ($changes -join ', '))) { return }
    Write-Verbose "Updating policy $Name`: $($changes -join ', ')."
    $null = Set-AzRecoveryServicesBackupProtectionPolicy -Policy $p -SchedulePolicy $p.SchedulePolicy -RetentionPolicy $p.RetentionPolicy -VaultId $VaultId
    return Get-AzRecoveryServicesBackupProtectionPolicy -Name $Name -VaultId $VaultId
}

function Enable-BackupVm {
    <#
    .SYNOPSIS
        Protect a VM with a policy. The vault must be in the VM's region.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$VaultId,
        [Parameter(Mandatory)] [string]$PolicyName,
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$VMName
    )
    $vault = Get-BkVault $VaultId
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
    if ($vm.Location -ne $vault.Location) { throw "$VMName is in $($vm.Location) but the vault is in $($vault.Location). Use a vault in the VM's region." }
    $policy = Get-AzRecoveryServicesBackupProtectionPolicy -Name $PolicyName -VaultId $VaultId
    if (-not $PSCmdlet.ShouldProcess($VMName, "Protect with $PolicyName in $($vault.Name)")) { return }
    Write-Verbose "Protecting $VMName with $PolicyName."
    $job = Enable-AzRecoveryServicesBackupProtection -Policy $policy -Name $VMName -ResourceGroupName $ResourceGroupName -VaultId $VaultId
    [pscustomobject]@{ Item = $VMName; Policy = $PolicyName; Vault = $vault.Name; Status = "$(Get-BkProp $job 'Status' 'Submitted')" }
}

function Enable-BackupFileShare {
    <#
    .SYNOPSIS
        Protect a file share with a policy. The vault must be in the account's region.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$VaultId,
        [Parameter(Mandatory)] [string]$PolicyName,
        [Parameter(Mandatory)] [string]$StorageAccountName,
        [Parameter(Mandatory)] [string]$ShareName
    )
    $vault = Get-BkVault $VaultId
    $policy = Get-AzRecoveryServicesBackupProtectionPolicy -Name $PolicyName -VaultId $VaultId
    if (-not $PSCmdlet.ShouldProcess("$StorageAccountName/$ShareName", "Protect with $PolicyName in $($vault.Name)")) { return }
    Write-Verbose "Protecting $StorageAccountName/$ShareName with $PolicyName."
    $job = Enable-AzRecoveryServicesBackupProtection -Policy $policy -Name $ShareName -StorageAccountName $StorageAccountName -VaultId $VaultId
    [pscustomobject]@{ Item = "$StorageAccountName/$ShareName"; Policy = $PolicyName; Vault = $vault.Name; Status = "$(Get-BkProp $job 'Status' 'Submitted')" }
}

function Start-BackupItemNow {
    <#
    .SYNOPSIS
        An on-demand backup, kept for -KeepDays days. Returns once Azure has the job.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$VaultId,
        [Parameter(Mandatory)] [ValidateSet('VM', 'FileShare')] [string]$Kind,
        [Parameter(Mandatory)] [string]$ItemName,
        [Parameter()] [ValidateRange(1, 99)] [int]$KeepDays = 30
    )
    $item = Get-BackupItemObject -VaultId $VaultId -Kind $Kind -ItemName $ItemName
    $label = "$(Get-BkProp $item 'FriendlyName' $ItemName)"
    if (-not $PSCmdlet.ShouldProcess($label, "Back up now (keep $KeepDays days)")) { return }
    Write-Verbose "Starting an on-demand backup of $label."
    $job = Backup-AzRecoveryServicesBackupItem -Item $item -VaultId $VaultId -ExpiryDateTimeUTC (Get-Date).ToUniversalTime().AddDays($KeepDays)
    [pscustomobject]@{ Item = $label; Operation = 'Backup'; Status = "$(Get-BkProp $job 'Status' 'Submitted')"; JobId = "$(Get-BkProp $job 'JobId' '')" }
}
#endregion

#region Restore ---------------------------------------------------------------
function Get-BkRecoveryPoint {
    param($Item, [string]$VaultId, [string]$RecoveryPointId)
    $rp = Get-AzRecoveryServicesBackupRecoveryPoint -Item $Item -RecoveryPointId $RecoveryPointId -VaultId $VaultId
    if (-not $rp) { throw "Recovery point $RecoveryPointId not found." }
    return $rp
}

function Restore-BackupVmToNew {
    <#
    .SYNOPSIS
        Restore a VM recovery point as a new VM (-TargetVMName with network), or
        as managed disks in a resource group (no -TargetVMName). The original VM is
        not touched. The staging storage account (same region as the vault) holds
        the VM configuration and a template.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$VaultId,
        [Parameter(Mandatory)] [string]$ItemName,
        [Parameter(Mandatory)] [string]$RecoveryPointId,
        [Parameter(Mandatory)] [string]$StagingStorageAccountName,
        [Parameter(Mandatory)] [string]$StagingStorageAccountResourceGroupName,
        [Parameter(Mandatory)] [string]$TargetResourceGroupName,
        [Parameter()] [string]$TargetVMName,
        [Parameter()] [string]$TargetVNetName,
        [Parameter()] [string]$TargetVNetResourceGroupName,
        [Parameter()] [string]$TargetSubnetName
    )
    $item = Get-BackupItemObject -VaultId $VaultId -Kind VM -ItemName $ItemName
    $source = ("$(Get-BkProp $item 'VirtualMachineId' '')" -split '/')
    if ($TargetVMName) {
        if (-not ($TargetVNetName -and $TargetVNetResourceGroupName -and $TargetSubnetName)) { throw 'A new VM needs -TargetVNetName, -TargetVNetResourceGroupName and -TargetSubnetName.' }
        if ($source.Count -ge 9 -and $source[-1] -eq $TargetVMName -and $source[4] -eq $TargetResourceGroupName) { throw "The new VM must not have the name of the original ($TargetVMName in $TargetResourceGroupName)." }
        if (Get-AzVM -ResourceGroupName $TargetResourceGroupName -Name $TargetVMName -ErrorAction SilentlyContinue) { throw "A VM named $TargetVMName already exists in $TargetResourceGroupName." }
    }
    $rp = Get-BkRecoveryPoint -Item $item -VaultId $VaultId -RecoveryPointId $RecoveryPointId
    $what = if ($TargetVMName) { "Restore as new VM $TargetVMName in $TargetResourceGroupName" } else { "Restore disks into $TargetResourceGroupName" }
    if (-not $PSCmdlet.ShouldProcess("$($source[-1]) at $($rp.RecoveryPointTime)", $what)) { return }
    $p = @{
        RecoveryPoint = $rp; VaultId = $VaultId; VaultLocation = (Get-BkVault $VaultId).Location
        StorageAccountName = $StagingStorageAccountName; StorageAccountResourceGroupName = $StagingStorageAccountResourceGroupName
        TargetResourceGroupName = $TargetResourceGroupName
    }
    if ($TargetVMName) { $p.TargetVMName = $TargetVMName; $p.TargetVNetName = $TargetVNetName; $p.TargetVNetResourceGroup = $TargetVNetResourceGroupName; $p.TargetSubnetName = $TargetSubnetName }
    Write-Verbose $what
    $job = Restore-AzRecoveryServicesBackupItem @p
    [pscustomobject]@{ Item = $source[-1]; Operation = $what; Status = "$(Get-BkProp $job 'Status' 'Submitted')"; JobId = "$(Get-BkProp $job 'JobId' '')" }
}

function Restore-BackupFileShareItem {
    <#
    .SYNOPSIS
        Restore a share (or one file or folder in it) from a recovery point.
        AlternateLocation writes into another share and folder; OriginalLocation
        writes back to the same share but skips every file that still exists.
        Nothing is ever overwritten.
    .PARAMETER SourcePath
        A file or folder inside the share, relative to its root. Empty = whole share.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$VaultId,
        [Parameter(Mandatory)] [string]$ItemName,
        [Parameter(Mandatory)] [string]$RecoveryPointId,
        [Parameter(Mandatory)] [ValidateSet('AlternateLocation', 'OriginalLocation')] [string]$Mode,
        [Parameter()] [string]$SourcePath,
        [Parameter()] [ValidateSet('File', 'Directory')] [string]$SourceType = 'Directory',
        [Parameter()] [string]$TargetStorageAccountName,
        [Parameter()] [string]$TargetShareName,
        [Parameter()] [string]$TargetFolder
    )
    $item = Get-BackupItemObject -VaultId $VaultId -Kind FileShare -ItemName $ItemName
    $label = "$(Get-BkProp $item 'FriendlyName' $ItemName)"
    if ($Mode -eq 'AlternateLocation' -and -not ($TargetStorageAccountName -and $TargetShareName -and $TargetFolder)) {
        throw 'AlternateLocation needs -TargetStorageAccountName, -TargetShareName and -TargetFolder (a new folder keeps restored files apart).'
    }
    $rp = Get-BkRecoveryPoint -Item $item -VaultId $VaultId -RecoveryPointId $RecoveryPointId
    $what = if ($Mode -eq 'AlternateLocation') { "Restore $(if ($SourcePath) { $SourcePath } else { 'the whole share' }) to $TargetStorageAccountName/$TargetShareName/$TargetFolder" }
            else { "Restore $(if ($SourcePath) { $SourcePath } else { 'the whole share' }) in place, skipping files that exist" }
    if (-not $PSCmdlet.ShouldProcess("$label at $($rp.RecoveryPointTime)", $what)) { return }
    $p = @{ RecoveryPoint = $rp; VaultId = $VaultId; ResolveConflict = 'Skip' }
    if ($SourcePath) { $p.SourceFilePath = $SourcePath; $p.SourceFileType = $SourceType }
    if ($Mode -eq 'AlternateLocation') { $p.TargetStorageAccountName = $TargetStorageAccountName; $p.TargetFileShareName = $TargetShareName; $p.TargetFolder = $TargetFolder }
    Write-Verbose $what
    $job = Restore-AzRecoveryServicesBackupItem @p
    [pscustomobject]@{ Item = $label; Operation = $what; Status = "$(Get-BkProp $job 'Status' 'Submitted')"; JobId = "$(Get-BkProp $job 'JobId' '')" }
}
#endregion
