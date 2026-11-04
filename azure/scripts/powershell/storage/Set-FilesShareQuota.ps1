<#
.SYNOPSIS
    Change an Azure file share's quota.
.DESCRIPTION
    Refuses a quota below what the share holds, and below 100 GiB on premium.
    Takes effect at once, no downtime. Premium shares bill for the quota.
.PARAMETER SubscriptionId
    Subscription of the account.
.PARAMETER ResourceGroupName
    Resource group of the account.
.PARAMETER StorageAccountName
    Storage account.
.PARAMETER ShareName
    File share.
.PARAMETER QuotaGiB
    New quota.
.EXAMPLE
    ./Set-FilesShareQuota.ps1 -SubscriptionId <sub> -ResourceGroupName rg-files -StorageAccountName stfiles01 -ShareName profiles -QuotaGiB 1024
.NOTES
    Requires: Az.Accounts, Az.Storage
    Status:   Untested
    Roles:    Storage Account Contributor on the account.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$StorageAccountName,
    [Parameter(Mandatory)] [string]$ShareName,
    [Parameter(Mandatory)] [ValidateRange(1, 102400)] [int]$QuotaGiB
)
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'FilesAdmin' 'FilesAdmin.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
$null = Set-FilesShareQuota -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName -Name $ShareName -QuotaGiB $QuotaGiB
if ($WhatIfPreference) { return }
Get-FilesShareInfo -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName | Where-Object Name -eq $ShareName
