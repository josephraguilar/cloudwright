<#
.SYNOPSIS
    Write an HTML report (and a CSV per section) of the subscription: host pools,
    VMs, backups, storage, network, cost and recent changes.
.DESCRIPTION
    Read-only against Azure; writes files to -Path only. Sections that fail (no
    permission, no data) are reported in the warning stream and left empty, so
    one gap does not stop the report. Keep reports out of git: they hold
    tenant data.
.PARAMETER SubscriptionId
    Subscription to report on.
.PARAMETER Path
    Folder for the files. Default: Documents\AzureToolbox\reports.
.PARAMETER Section
    Any of Avd, Vms, Backup, Storage, Network, Cost, Changes. Default all.
.PARAMETER ChangeHours
    How far back the changes section looks. Default 168 (a week).
.EXAMPLE
    ./Export-ToolboxReport.ps1 -SubscriptionId <sub>
.NOTES
    Requires: Az.Accounts, Az.Compute, Az.DesktopVirtualization, Az.Network,
              Az.RecoveryServices, Az.Storage, Az.Monitor
    Status:   Untested
    Roles:    Reader on the subscription (Cost Management Reader for cost).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter()] [string]$Path = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'AzureToolbox' 'reports'),
    [Parameter()] [ValidateSet('Avd', 'Vms', 'Backup', 'Storage', 'Network', 'Cost', 'Changes')] [string[]]$Section = @('Avd', 'Vms', 'Backup', 'Storage', 'Network', 'Cost', 'Changes'),
    [Parameter()] [ValidateRange(1, 2160)] [int]$ChangeHours = 168
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($m in 'AzHelpers', 'OpsAdmin', 'BackupAdmin', 'FilesAdmin', 'NetworkBuild') {
    Import-Module (Join-Path $PSScriptRoot '..' 'modules' $m "$m.psd1") -Force -Verbose:$false
}
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$ctx = Assert-AzContext -SubscriptionId $SubscriptionId

#region Gather -----------------------------------------------------------------
#   WHY    Each section in its own try: a missing permission empties that table
#          and says so, instead of losing the whole report.
$data = [ordered]@{}
function Add-ReportSection {
    param([string]$Title, [scriptblock]$Get)
    Write-Verbose "Collecting $Title."
    try { $data[$Title] = @(& $Get) } catch { Write-Warning "$Title`: $($_.Exception.Message)"; $data[$Title] = @() }
}
if ('Avd' -in $Section)     { Add-ReportSection 'Host pools' { Get-OpsAvdSummary | Select-Object Pool, ResourceGroup, Type, Hosts, Available, Unavailable, Drained, Active, Disconnected, Diagnostics } }
if ('Vms' -in $Section)     { Add-ReportSection 'Virtual machines' { Get-AzVM -Status | Sort-Object ResourceGroupName, Name | ForEach-Object { [pscustomobject]@{ Name = $_.Name; ResourceGroup = $_.ResourceGroupName; Size = $_.HardwareProfile.VmSize; Power = ("$($_.PowerState)" -replace '^VM ', ''); Os = "$($_.StorageProfile.OsDisk.OsType)"; Location = $_.Location } } } }
if ('Backup' -in $Section)  {
    Add-ReportSection 'Backed-up VMs' { Get-BackupItemInfo -Kind VM | Select-Object Name, Source, LastBackup, LastStatus, Health, Policy, Vault }
    Add-ReportSection 'Backed-up file shares' { Get-BackupItemInfo -Kind FileShare | Select-Object Name, Source, LastBackup, LastStatus, Health, Policy, Vault }
}
if ('Storage' -in $Section) {
    Add-ReportSection 'File shares' { foreach ($a in Get-FilesAccountInfo) { Get-FilesShareInfo -ResourceGroupName $a.ResourceGroupName -StorageAccountName $a.Name | Select-Object Account, Name, QuotaGiB, UsedGiB, PercentUsed, Tier } }
}
if ('Network' -in $Section) {
    Add-ReportSection 'Virtual networks' { Get-NetVirtualNetworkInfo | Select-Object Name, ResourceGroupName, Location, AddressSpace, DnsServers, Subnets, Peerings }
    Add-ReportSection 'Public IPs' { Get-NetPublicIpInfo | Select-Object Name, Address, AttachedTo, ResourceGroupName, Sku }
}
if ('Cost' -in $Section)    { Add-ReportSection 'Cost this month by resource group' { Get-OpsCost -SubscriptionId $SubscriptionId -Timeframe MonthToDate -GroupBy ResourceGroupName | Sort-Object Cost -Descending } }
if ('Changes' -in $Section) { Add-ReportSection "Changes, last $ChangeHours hours" { Get-OpsActivityLog -Hours $ChangeHours -Max 2000 } }
#endregion

#region Write ------------------------------------------------------------------
$stamp = (Get-Date).ToString('yyyyMMdd-HHmm')
$base = Join-Path $Path "toolbox-report-$stamp"
if (-not $PSCmdlet.ShouldProcess($Path, "Write $base.html and one CSV per section")) { return }
$null = New-Item -ItemType Directory -Path $Path -Force
$html = ConvertTo-OpsHtmlReport -Title 'Azure toolbox report' -Subtitle "Subscription $($ctx.Subscription.Name), $((Get-Date).ToString('yyyy-MM-dd HH:mm'))" -Section $data
Set-Content -Path "$base.html" -Value $html -Encoding utf8
foreach ($k in $data.Keys) {
    if (@($data[$k]).Count -eq 0) { continue }
    $data[$k] | Export-Csv -Path "$base-$(($k -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLower()).csv" -NoTypeInformation -Encoding utf8
}
Write-Verbose "Report written to $base.html"
[pscustomobject]@{ Report = "$base.html"; Sections = $data.Count; Rows = (@($data.Values | ForEach-Object { @($_).Count }) | Measure-Object -Sum).Sum }
#endregion
