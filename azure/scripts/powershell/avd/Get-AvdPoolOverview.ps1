<#
.SYNOPSIS
    One screen about a host pool: settings, host counts, power states, scaling
    plans and an estimated monthly compute bill.
.DESCRIPTION
    The command-line face of Get-AvdHostPoolOverview. The GUI's Overview page and
    the console's status option show the same object. Prices come from the public
    Azure Retail Prices API (no sign-in needed); pass -NoPrice to skip that call.
.PARAMETER SubscriptionId
    Subscription containing the host pool.
.PARAMETER ResourceGroupName
    Resource group of the host pool.
.PARAMETER HostPoolName
    Host pool name.
.PARAMETER NoPrice
    Skip the retail price lookup.
.EXAMPLE
    ./Get-AvdPoolOverview.ps1 -SubscriptionId <sub> -ResourceGroupName rg-avd-lab -HostPoolName hp-lab
.NOTES
    Requires: Az.Accounts, Az.DesktopVirtualization, Az.Compute
    Status:   Untested
    Roles:    Reader on the host pool's and the VMs' resource groups.
#>

#region 1. Parameters ---------------------------------------------------------
#   WHAT   Pool to describe, and whether to price it.
#   WHY    The price call leaves your tenant (public Microsoft endpoint, no auth).
#          -NoPrice is for air-gapped or just impatient runs.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$HostPoolName,

    [Parameter()]
    [switch]$NoPrice
)
#endregion

#region 2. Setup --------------------------------------------------------------
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AvdHelpers' 'AvdHelpers.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
#endregion

#region 3. Overview -----------------------------------------------------------
#   WHAT   One module call; print the summary, return the object for scripting.
#   WHY    Verbose carries the human-readable lines; the pipeline carries the data.
$o = Get-AvdHostPoolOverview -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -IncludePrice:(-not $NoPrice)

Write-Verbose ("{0} ({1}, {2}, max {3} sessions/host) in {4}. Start VM On Connect: {5}. Agent updates: {6}." -f
    $o.Pool.Name, $o.Pool.Type, $o.Pool.LoadBalancer, $o.Pool.MaxSessionLimit, $o.Pool.Location, $o.Pool.StartVMOnConnect, $o.Pool.AgentUpdate)
Write-Verbose ("Hosts: {0} total, {1} available, {2} unavailable, {3} drained. Sessions: {4}. Running: {5}, deallocated: {6}." -f
    $o.Counts.Total, $o.Counts.Available, $o.Counts.Unavailable, $o.Counts.Drained, $o.Counts.Sessions, $o.Counts.Running, $o.Counts.Deallocated)
if ($o.ScalingPlans.Count -gt 0) {
    foreach ($p in $o.ScalingPlans) { Write-Verbose "Scaling plan $($p.Name): $(if ($p.Enabled) { 'enabled' } else { 'attached but disabled' }), $($p.TimeZone)." }
} else {
    Write-Verbose 'No scaling plan attached. Hosts run until someone stops them.'
}
if ($o.Cost) {
    Write-Verbose ("Compute estimate: {0:C0}/month if every host runs 24x7, {1:C0}/month at 10 hours on weekdays (what autoscale targets). {2}" -f
        $o.Cost.Monthly24x7Usd, $o.Cost.MonthlyBusinessHoursUsd, $o.Cost.Note)
}
$o
#endregion
