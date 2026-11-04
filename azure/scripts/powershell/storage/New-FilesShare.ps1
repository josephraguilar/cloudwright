<#
.SYNOPSIS
    Create an Azure file share, and the storage account for it if it does not exist.
.DESCRIPTION
    A new account gets secure defaults: HTTPS only, TLS 1.2, no anonymous blob
    access. Premium (FileStorage, SSD) suits FSLogix profiles; Standard (StorageV2)
    suits general file storage. Existing accounts and shares are reused untouched.
    For FSLogix permissions (Entra Kerberos, share role, NTFS) run
    Set-AvdProfileShareAccess.ps1 afterwards.
.PARAMETER SubscriptionId
    Subscription for the account.
.PARAMETER ResourceGroupName
    Resource group of the account (must exist).
.PARAMETER StorageAccountName
    3 to 24 lower-case letters and digits, unique in Azure.
.PARAMETER ShareName
    3 to 63 lower-case letters, digits and single hyphens.
.PARAMETER QuotaGiB
    Share size limit. Premium starts at 100 and bills for it.
.PARAMETER Performance
    For a new account: Premium (default) or Standard.
.PARAMETER Redundancy
    For a new account: LRS (default) or ZRS.
.PARAMETER AccessTier
    Standard shares only: TransactionOptimized, Hot or Cool.
.PARAMETER Location
    For a new account. Defaults to the resource group's region.
.EXAMPLE
    ./New-FilesShare.ps1 -SubscriptionId <sub> -ResourceGroupName rg-files -StorageAccountName stfiles01 -ShareName profiles -QuotaGiB 512
.NOTES
    Requires: Az.Accounts, Az.Storage, Az.Resources
    Status:   Untested
    Roles:    Storage Account Contributor on the resource group.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$StorageAccountName,
    [Parameter(Mandatory)] [string]$ShareName,
    [Parameter()] [ValidateRange(1, 102400)] [int]$QuotaGiB = 100,
    [Parameter()] [ValidateSet('Premium', 'Standard')] [string]$Performance = 'Premium',
    [Parameter()] [ValidateSet('LRS', 'ZRS')] [string]$Redundancy = 'LRS',
    [Parameter()] [ValidateSet('', 'TransactionOptimized', 'Hot', 'Cool')] [string]$AccessTier = '',
    [Parameter()] [string]$Location
)
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'FilesAdmin' 'FilesAdmin.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
if (-not $Location) { $Location = (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop).Location }

$sa = New-FilesStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -Location $Location -Performance $Performance -Redundancy $Redundancy
if (-not $sa) { Write-Verbose 'WhatIf: the account does not exist yet, so the share is not previewed.'; return }
$null = New-FilesShare -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName -Name $ShareName -QuotaGiB $QuotaGiB -AccessTier $AccessTier
if ($WhatIfPreference) { return }
Get-FilesShareInfo -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName | Where-Object Name -eq $ShareName
