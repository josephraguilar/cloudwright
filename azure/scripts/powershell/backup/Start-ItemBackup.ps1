<#
.SYNOPSIS
    Take an on-demand backup of protected VMs or file shares.
.DESCRIPTION
    Returns once Azure has queued each job; progress shows in the backup jobs list.
.PARAMETER SubscriptionId
    Subscription of the vault.
.PARAMETER VaultId
    Resource ID of the Recovery Services vault.
.PARAMETER Kind
    VM or FileShare.
.PARAMETER ItemName
    Backup item names as Get-BackupItemInfo lists them (ItemName column).
.PARAMETER KeepDays
    How long to keep these recovery points. Default 30.
.EXAMPLE
    ./Start-ItemBackup.ps1 -SubscriptionId <sub> -VaultId <vault-id> -Kind VM -ItemName <item-name>
.NOTES
    Requires: Az.Accounts, Az.RecoveryServices
    Status:   Untested
    Roles:    Backup Operator on the vault.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$VaultId,
    [Parameter(Mandatory)] [ValidateSet('VM', 'FileShare')] [string]$Kind,
    [Parameter(Mandatory)] [string[]]$ItemName,
    [Parameter()] [ValidateRange(1, 99)] [int]$KeepDays = 30
)
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'BackupAdmin' 'BackupAdmin.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
foreach ($i in $ItemName) {
    try { Start-BackupItemNow -VaultId $VaultId -Kind $Kind -ItemName $i -KeepDays $KeepDays }
    catch { Write-Warning "$i`: $($_.Exception.Message)"; [pscustomobject]@{ Item = $i; Status = "Failed: $($_.Exception.Message)" } }
}
