<#
.SYNOPSIS
    Change an existing scaling plan: schedule times, host percentages, ramp-down
    behaviour, weekend schedule, time zone, exclusion tag. Only what you pass changes.
.DESCRIPTION
    Edits the plan's 'weekdays' schedule in place and writes the schedule list back
    (the API replaces the list as a whole, so the script carries the untouched
    schedules along). Pooled plans only. Nothing here deletes a plan.
.PARAMETER SubscriptionId
    Subscription containing the plan.
.PARAMETER ResourceGroupName
    Resource group of the plan.
.PARAMETER Name
    Scaling plan name.
.PARAMETER TimeZone
    Windows time zone ID the schedule is read in.
.PARAMETER ExclusionTag
    VMs with this tag name are left alone by the plan. Empty string clears it.
.PARAMETER Days
    Days the weekday schedule applies. The weekend schedule, if present, takes the rest.
.PARAMETER RampUpStart
    HH:mm hosts start powering on ahead of users.
.PARAMETER PeakStart
    HH:mm full capacity.
.PARAMETER RampDownStart
    HH:mm consolidation starts.
.PARAMETER OffPeakStart
    HH:mm minimum hosts.
.PARAMETER RampUpMinimumHostsPct
    Percent of hosts on during ramp-up.
.PARAMETER RampUpCapacityThresholdPct
    Percent of capacity used before another host starts, ramp-up.
.PARAMETER RampDownMinimumHostsPct
    Percent of hosts on during ramp-down and off-peak.
.PARAMETER RampDownCapacityThresholdPct
    Threshold during ramp-down.
.PARAMETER RampDownWaitTimeMinutes
    Warning minutes before users on a host chosen for shutdown are signed out.
.PARAMETER RampDownForceLogoff
    $true signs out users who ignore the warning; $false leaves hosts on until they leave.
.PARAMETER RampDownMessage
    The warning text.
.PARAMETER RampDownStopHostsWhen
    ZeroSessions (default when created) or ZeroActiveSessions (disconnected sessions do not keep a host on).
.PARAMETER WeekendOffPeak
    $true adds the all-day off-peak weekend schedule, $false removes it.
.EXAMPLE
    ./Set-AvdScalingPlan.ps1 -SubscriptionId <sub> -ResourceGroupName rg-avd-lab -Name sp-hp-lab -RampDownStart '17:30' -RampDownForceLogoff $true -Verbose
.NOTES
    Requires: Az.Accounts, Az.DesktopVirtualization
    Status:   Untested
    Roles:    Desktop Virtualization Contributor on the resource group.
#>

#region 1. Parameters ---------------------------------------------------------
#   WHAT   Every schedule knob, all optional. Unbound = unchanged.
#   WHY    $PSBoundParameters is what makes "only what you pass" work, which is why
#          booleans are [bool] not [switch]: a switch cannot express "set to false".
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter()] [string]$TimeZone,
    [Parameter()] [string]$ExclusionTag,
    [Parameter()] [string[]]$Days,
    [Parameter()] [string]$RampUpStart,
    [Parameter()] [string]$PeakStart,
    [Parameter()] [string]$RampDownStart,
    [Parameter()] [string]$OffPeakStart,
    [Parameter()] [ValidateRange(0, 100)] [int]$RampUpMinimumHostsPct,
    [Parameter()] [ValidateRange(1, 100)] [int]$RampUpCapacityThresholdPct,
    [Parameter()] [ValidateRange(0, 100)] [int]$RampDownMinimumHostsPct,
    [Parameter()] [ValidateRange(1, 100)] [int]$RampDownCapacityThresholdPct,
    [Parameter()] [ValidateRange(0, 120)] [int]$RampDownWaitTimeMinutes,
    [Parameter()] [bool]$RampDownForceLogoff,
    [Parameter()] [string]$RampDownMessage,
    [Parameter()] [ValidateSet('ZeroSessions', 'ZeroActiveSessions')] [string]$RampDownStopHostsWhen,
    [Parameter()] [bool]$WeekendOffPeak
)
#endregion

#region 2. Setup --------------------------------------------------------------
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AvdBuild' 'AvdBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
#endregion

#region 3. Update -------------------------------------------------------------
#   WHAT   Pass through exactly the parameters that were given.
$p = @{ ResourceGroupName = $ResourceGroupName; Name = $Name; Verbose = ($VerbosePreference -eq 'Continue') }
foreach ($k in $PSBoundParameters.Keys) {
    if ($k -in 'SubscriptionId', 'ResourceGroupName', 'Name', 'Verbose', 'WhatIf', 'Confirm', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable', 'ProgressAction') { continue }
    $p[$k] = $PSBoundParameters[$k]
}
$null = Set-AvdScalingPlanResource @p
Get-AvdScalingPlanSchedule -ResourceGroupName $ResourceGroupName -Name $Name
#endregion
