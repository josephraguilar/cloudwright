<#
.SYNOPSIS
    Create a daily backup policy, or change an existing one's run time or retention.
.DESCRIPTION
    A policy that does not exist is created (VM policies are Enhanced). For an
    existing one, only the values you pass change. Keeping fewer days makes Azure
    delete the older recovery points, so that needs -AllowShorterRetention.
.PARAMETER SubscriptionId
    Subscription of the vault.
.PARAMETER VaultId
    Resource ID of the Recovery Services vault.
.PARAMETER Name
    Policy name.
.PARAMETER Kind
    For a new policy: VM or FileShare.
.PARAMETER RetentionDays
    Days to keep daily recovery points.
.PARAMETER BackupTimeUtc
    HH:00 or HH:30 UTC.
.PARAMETER AllowShorterRetention
    Allow fewer days than now (older recovery points are deleted).
.EXAMPLE
    ./Set-BackupPolicy.ps1 -SubscriptionId <sub> -VaultId <vault-id> -Name vm-daily -RetentionDays 60
.NOTES
    Requires: Az.Accounts, Az.RecoveryServices
    Status:   Untested
    Roles:    Backup Contributor on the vault.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$VaultId,
    [Parameter(Mandatory)] [string]$Name,
    [Parameter()] [ValidateSet('VM', 'FileShare')] [string]$Kind = 'VM',
    [Parameter()] [ValidateRange(7, 9999)] [int]$RetentionDays,
    [Parameter()] [ValidatePattern('^$|^\d{2}:(00|30)$')] [string]$BackupTimeUtc,
    [Parameter()] [switch]$AllowShorterRetention
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'BackupAdmin' 'BackupAdmin.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId

$existing = Get-AzRecoveryServicesBackupProtectionPolicy -Name $Name -VaultId $VaultId -ErrorAction SilentlyContinue
if (-not $existing) {
    $p = @{ VaultId = $VaultId; Name = $Name; Kind = $Kind }
    if ($PSBoundParameters.ContainsKey('RetentionDays')) { $p.RetentionDays = $RetentionDays }
    if ($BackupTimeUtc) { $p.BackupTimeUtc = $BackupTimeUtc }
    $null = New-BackupDailyPolicy @p
} else {
    $p = @{ VaultId = $VaultId; Name = $Name; AllowShorterRetention = $AllowShorterRetention }
    if ($PSBoundParameters.ContainsKey('RetentionDays')) { $p.RetentionDays = $RetentionDays }
    if ($BackupTimeUtc) { $p.BackupTimeUtc = $BackupTimeUtc }
    $null = Set-BackupPolicySchedule @p
}
if ($WhatIfPreference) { return }
Get-BackupPolicyInfo -VaultId $VaultId | Where-Object Name -eq $Name
