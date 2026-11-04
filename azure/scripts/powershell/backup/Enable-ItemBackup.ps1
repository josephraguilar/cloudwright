<#
.SYNOPSIS
    Protect VMs or a file share with Azure Backup, creating the vault and a daily
    policy first if they do not exist.
.DESCRIPTION
    The vault must be in the same region as what it protects. A new policy runs
    daily at -BackupTimeUtc and keeps -RetentionDays days. The first backup runs
    at the next scheduled time; use Start-ItemBackup.ps1 to take one now.
.PARAMETER SubscriptionId
    Subscription of the vault and items.
.PARAMETER VaultResourceGroupName
    Resource group of the vault.
.PARAMETER VaultName
    Recovery Services vault (created if missing).
.PARAMETER Location
    Region for a new vault. Defaults to the vault resource group's region.
.PARAMETER PolicyName
    Policy to use (created if missing). Default vm-daily or files-daily.
.PARAMETER RetentionDays
    For a new policy: days to keep. Default 30.
.PARAMETER BackupTimeUtc
    For a new policy: HH:00 or HH:30 UTC. Default 02:00.
.PARAMETER ResourceGroupName
    VMs: their resource group.
.PARAMETER VMName
    VMs to protect.
.PARAMETER StorageAccountName
    File share: its storage account.
.PARAMETER ShareName
    File share to protect.
.EXAMPLE
    ./Enable-ItemBackup.ps1 -SubscriptionId <sub> -VaultResourceGroupName rg-backup -VaultName rsv-servers -ResourceGroupName rg-servers -VMName dc01, sql01
.EXAMPLE
    ./Enable-ItemBackup.ps1 -SubscriptionId <sub> -VaultResourceGroupName rg-backup -VaultName rsv-files -StorageAccountName stfiles01 -ShareName profiles
.NOTES
    Requires: Az.Accounts, Az.RecoveryServices, Az.Compute, Az.Resources
    Status:   Untested
    Roles:    Backup Contributor on the vault; Virtual Machine Contributor on the VMs
              or Storage Account Backup Contributor on the storage account.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'VM')]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$VaultResourceGroupName,
    [Parameter(Mandatory)] [string]$VaultName,
    [Parameter()] [string]$Location,
    [Parameter()] [string]$PolicyName,
    [Parameter()] [ValidateRange(7, 9999)] [int]$RetentionDays = 30,
    [Parameter()] [ValidatePattern('^\d{2}:(00|30)$')] [string]$BackupTimeUtc = '02:00',
    [Parameter(Mandatory, ParameterSetName = 'VM')] [string]$ResourceGroupName,
    [Parameter(Mandatory, ParameterSetName = 'VM')] [string[]]$VMName,
    [Parameter(Mandatory, ParameterSetName = 'FileShare')] [string]$StorageAccountName,
    [Parameter(Mandatory, ParameterSetName = 'FileShare')] [string]$ShareName
)
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'BackupAdmin' 'BackupAdmin.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
$kind = $PSCmdlet.ParameterSetName
if (-not $Location) { $Location = (Get-AzResourceGroup -Name $VaultResourceGroupName -ErrorAction Stop).Location }
if (-not $PolicyName) { $PolicyName = if ($kind -eq 'VM') { 'vm-daily' } else { 'files-daily' } }

$vault = New-BackupVault -ResourceGroupName $VaultResourceGroupName -Name $VaultName -Location $Location
if (-not $vault) { Write-Verbose 'WhatIf: the vault does not exist yet, so the policy and protection are not previewed.'; return }
$null = New-BackupDailyPolicy -VaultId $vault.ID -Name $PolicyName -Kind $kind -RetentionDays $RetentionDays -BackupTimeUtc $BackupTimeUtc
if ($kind -eq 'VM') {
    foreach ($n in $VMName) {
        try { Enable-BackupVm -VaultId $vault.ID -PolicyName $PolicyName -ResourceGroupName $ResourceGroupName -VMName $n }
        catch { Write-Warning "$n`: $($_.Exception.Message)"; [pscustomobject]@{ Item = $n; Status = "Failed: $($_.Exception.Message)" } }
    }
} else {
    Enable-BackupFileShare -VaultId $vault.ID -PolicyName $PolicyName -StorageAccountName $StorageAccountName -ShareName $ShareName
}
