<#
.SYNOPSIS
    Restore a VM or file share recovery point to a new place. Never overwrites.
.DESCRIPTION
    VM, -TargetVMName given: a new VM in the target resource group and subnet.
    VM, no -TargetVMName: managed disks in the target resource group, plus the VM
    configuration and a deployment template in the staging storage account.
    File share, AlternateLocation: into another share and folder.
    File share, OriginalLocation: back into the same share, skipping every file
    that still exists, so only missing files come back.
    The original VM or share is never replaced.
.PARAMETER SubscriptionId
    Subscription of the vault.
.PARAMETER VaultId
    Resource ID of the Recovery Services vault.
.PARAMETER Kind
    VM or FileShare.
.PARAMETER ItemName
    Backup item name (ItemName column of Get-BackupItemInfo).
.PARAMETER RecoveryPointId
    Recovery point ID (Get-BackupRecoveryPointInfo).
.PARAMETER StagingStorageAccountName
    VM: a Standard storage account in the vault's region for configuration files.
.PARAMETER StagingStorageAccountResourceGroupName
    VM: its resource group.
.PARAMETER TargetResourceGroupName
    VM: where the disks or the new VM go.
.PARAMETER TargetVMName
    VM: name of the new VM. Leave out to restore disks only.
.PARAMETER TargetVNetName
    VM, new VM: virtual network.
.PARAMETER TargetVNetResourceGroupName
    VM, new VM: resource group of the virtual network.
.PARAMETER TargetSubnetName
    VM, new VM: subnet.
.PARAMETER Mode
    File share: AlternateLocation or OriginalLocation.
.PARAMETER SourcePath
    File share: a file or folder to restore, relative to the share root. Empty = all.
.PARAMETER SourceType
    File share: File or Directory.
.PARAMETER TargetStorageAccountName
    File share, AlternateLocation: storage account.
.PARAMETER TargetShareName
    File share, AlternateLocation: share.
.PARAMETER TargetFolder
    File share, AlternateLocation: folder to restore into (created).
.EXAMPLE
    ./Restore-ItemBackup.ps1 -SubscriptionId <sub> -VaultId <vault-id> -Kind VM -ItemName <item> -RecoveryPointId <rp> -StagingStorageAccountName stbackupstage -StagingStorageAccountResourceGroupName rg-backup -TargetResourceGroupName rg-restore -TargetVMName dc01-restored -TargetVNetName vnet-lab -TargetVNetResourceGroupName rg-net -TargetSubnetName snet-restore
.EXAMPLE
    ./Restore-ItemBackup.ps1 -SubscriptionId <sub> -VaultId <vault-id> -Kind FileShare -ItemName <item> -RecoveryPointId <rp> -Mode OriginalLocation -SourcePath 'Profiles/user1' -SourceType Directory
.NOTES
    Requires: Az.Accounts, Az.RecoveryServices
    Status:   Untested
    Roles:    Backup Operator on the vault; Contributor on the target resource group.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$VaultId,
    [Parameter(Mandatory)] [ValidateSet('VM', 'FileShare')] [string]$Kind,
    [Parameter(Mandatory)] [string]$ItemName,
    [Parameter(Mandatory)] [string]$RecoveryPointId,
    [Parameter()] [string]$StagingStorageAccountName,
    [Parameter()] [string]$StagingStorageAccountResourceGroupName,
    [Parameter()] [string]$TargetResourceGroupName,
    [Parameter()] [string]$TargetVMName,
    [Parameter()] [string]$TargetVNetName,
    [Parameter()] [string]$TargetVNetResourceGroupName,
    [Parameter()] [string]$TargetSubnetName,
    [Parameter()] [ValidateSet('AlternateLocation', 'OriginalLocation')] [string]$Mode = 'AlternateLocation',
    [Parameter()] [string]$SourcePath,
    [Parameter()] [ValidateSet('File', 'Directory')] [string]$SourceType = 'Directory',
    [Parameter()] [string]$TargetStorageAccountName,
    [Parameter()] [string]$TargetShareName,
    [Parameter()] [string]$TargetFolder
)
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'BackupAdmin' 'BackupAdmin.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId

if ($Kind -eq 'VM') {
    foreach ($n in 'StagingStorageAccountName', 'StagingStorageAccountResourceGroupName', 'TargetResourceGroupName') {
        if (-not $PSBoundParameters[$n]) { throw "A VM restore needs -$n." }
    }
    $p = @{
        VaultId = $VaultId; ItemName = $ItemName; RecoveryPointId = $RecoveryPointId
        StagingStorageAccountName = $StagingStorageAccountName; StagingStorageAccountResourceGroupName = $StagingStorageAccountResourceGroupName
        TargetResourceGroupName = $TargetResourceGroupName
    }
    if ($TargetVMName) { $p.TargetVMName = $TargetVMName; $p.TargetVNetName = $TargetVNetName; $p.TargetVNetResourceGroupName = $TargetVNetResourceGroupName; $p.TargetSubnetName = $TargetSubnetName }
    Restore-BackupVmToNew @p
} else {
    $p = @{ VaultId = $VaultId; ItemName = $ItemName; RecoveryPointId = $RecoveryPointId; Mode = $Mode; SourceType = $SourceType }
    foreach ($n in 'SourcePath', 'TargetStorageAccountName', 'TargetShareName', 'TargetFolder') { if ($PSBoundParameters[$n]) { $p[$n] = $PSBoundParameters[$n] } }
    Restore-BackupFileShareItem @p
}
