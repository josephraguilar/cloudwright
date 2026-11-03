<#
.SYNOPSIS
    Create a native AVD scaling plan for a pooled host pool and switch it on:
    the service starts hosts before people arrive and deallocates them after.
.DESCRIPTION
    Three things, in order, each one idempotent:

      1. Grant the Azure Virtual Desktop service principal the role
         "Desktop Virtualization Power On Off Contributor" on the subscription
         (or the resource group with -RoleScope ResourceGroup). Without it the
         plan exists but cannot touch VMs.
      2. Create the plan in the host pool's region with one weekday schedule:
         ramp-up, peak, ramp-down, off-peak. Optionally a weekend schedule that is
         off-peak all day.
      3. Attach it to the pool, enabled (or not, with -Enable:$false).

    Defaults are a sensible office day: hosts start coming up at 07:00, full
    capacity from 09:00, consolidate from 18:00 with a 30 minute warning, minimum
    from 20:00. Change the times to match the people.

    Nothing here deletes anything. To remove a plan, do it in the portal.
.PARAMETER SubscriptionId
    Subscription containing the host pool.
.PARAMETER ResourceGroupName
    Resource group of the host pool. The plan is created there too.
.PARAMETER HostPoolName
    Pooled host pool to attach the plan to.
.PARAMETER Name
    Plan name. Default sp-<host pool name>.
.PARAMETER TimeZone
    Windows time zone ID the schedule is read in. Default: this machine's.
.PARAMETER RoleScope
    Subscription (default, Microsoft's recommendation) or ResourceGroup.
.PARAMETER RampUpStart
    HH:mm when hosts start being powered on ahead of users. Default 07:00.
.PARAMETER PeakStart
    HH:mm when the plan keeps full capacity. Default 09:00.
.PARAMETER RampDownStart
    HH:mm when the plan starts consolidating users and stopping empty hosts. Default 18:00.
.PARAMETER OffPeakStart
    HH:mm when the plan keeps only the minimum. Default 20:00.
.PARAMETER RampUpMinimumHostsPct
    Percent of hosts kept on during ramp-up. Default 20.
.PARAMETER RampUpCapacityThresholdPct
    Percent of session capacity used before another host starts, ramp-up. Default 60.
.PARAMETER RampDownMinimumHostsPct
    Percent of hosts kept on during ramp-down and off-peak. Default 10.
.PARAMETER RampDownCapacityThresholdPct
    Threshold during ramp-down. Default 90.
.PARAMETER RampDownWaitTimeMinutes
    Warning time before users on a host chosen for shutdown are signed out. Default 30.
.PARAMETER RampDownForceLogoff
    Sign out users who ignore the warning. Off by default.
.PARAMETER RampDownMessage
    The warning text.
.PARAMETER Days
    Days the weekday schedule applies. Default Monday to Friday.
.PARAMETER WeekendOffPeak
    Add a schedule for the remaining days that is off-peak all day (minimum hosts 0).
.PARAMETER ExclusionTag
    VMs with this tag name are left alone by the plan.
.PARAMETER Enable
    Attach enabled. Default $true.
.PARAMETER SkipRoleGrant
    Do not touch role assignments (someone already did).
.EXAMPLE
    ./New-AvdScalingPlan.ps1 -SubscriptionId <sub> -ResourceGroupName rg-avd-lab -HostPoolName hp-lab -WeekendOffPeak -Verbose
.NOTES
    Requires: Az.Accounts, Az.Resources, Az.DesktopVirtualization
    Status:   Untested
    Roles:    User Access Administrator or Owner at -RoleScope for step 1,
              Desktop Virtualization Contributor on the resource group for 2 and 3.
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$HostPoolName,

    [Parameter()]
    [string]$Name,

    [Parameter()]
    [string]$TimeZone = (Get-TimeZone).Id,

    [Parameter()]
    [ValidateSet('Subscription', 'ResourceGroup')]
    [string]$RoleScope = 'Subscription',

    [Parameter()] [string]$RampUpStart = '07:00',
    [Parameter()] [string]$PeakStart = '09:00',
    [Parameter()] [string]$RampDownStart = '18:00',
    [Parameter()] [string]$OffPeakStart = '20:00',
    [Parameter()] [ValidateRange(0, 100)] [int]$RampUpMinimumHostsPct = 20,
    [Parameter()] [ValidateRange(1, 100)] [int]$RampUpCapacityThresholdPct = 60,
    [Parameter()] [ValidateRange(0, 100)] [int]$RampDownMinimumHostsPct = 10,
    [Parameter()] [ValidateRange(1, 100)] [int]$RampDownCapacityThresholdPct = 90,
    [Parameter()] [ValidateRange(0, 120)] [int]$RampDownWaitTimeMinutes = 30,
    [Parameter()] [switch]$RampDownForceLogoff,
    [Parameter()] [string]$RampDownMessage = 'This desktop will shut down for the night in 30 minutes. Please save your work and sign out.',
    [Parameter()] [string[]]$Days = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'),
    [Parameter()] [switch]$WeekendOffPeak,
    [Parameter()] [string]$ExclusionTag,
    [Parameter()] [bool]$Enable = $true,
    [Parameter()] [switch]$SkipRoleGrant
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Modules, context, the pool (for its ID, region and type).
#   WHY    Plan region must equal pool region, and only Pooled pools take this
#          schedule shape, so both are checked before anything is created.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AvdBuild' 'AvdBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
$verbose = $VerbosePreference -eq 'Continue'

$pool = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName -ErrorAction Stop
if ("$($pool.HostPoolType)" -ne 'Pooled') { throw "Host pool $HostPoolName is $($pool.HostPoolType). This script builds Pooled schedules; Personal plans use a different schedule shape." }
if (-not $Name) { $Name = "sp-$HostPoolName" }

$others = @(Get-AvdScalingPlan -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName | Where-Object { $_.EnabledForPool -and $_.Name -ne $Name })
if ($Enable -and $others.Count -gt 0) {
    throw "Host pool $HostPoolName already has scaling plan '$($others[0].Name)' enabled. A pool takes one enabled plan at a time; disable that one first (Set-AvdScalingPlanEnabled) or attach this one with -Enable:`$false."
}
#endregion

#region 3. Role ---------------------------------------------------------------
if (-not $SkipRoleGrant) {
    $roleRg = if ($RoleScope -eq 'ResourceGroup') { $ResourceGroupName } else { $null }
    if (Test-AvdAutoscaleRole -SubscriptionId $SubscriptionId -ResourceGroupName $roleRg) {
        Write-Verbose 'The Azure Virtual Desktop service already holds the power on/off role.'
    } else {
        $null = Grant-AvdAutoscaleRole -SubscriptionId $SubscriptionId -ResourceGroupName $roleRg -Verbose:$verbose
    }
}
#endregion

#region 4. Plan ---------------------------------------------------------------
$planParams = @{
    ResourceGroupName = $ResourceGroupName; Name = $Name; Location = $pool.Location; HostPoolId = $pool.Id; TimeZone = $TimeZone
    Days = $Days; RampUpStart = $RampUpStart; PeakStart = $PeakStart; RampDownStart = $RampDownStart; OffPeakStart = $OffPeakStart
    RampUpMinimumHostsPct = $RampUpMinimumHostsPct; RampUpCapacityThresholdPct = $RampUpCapacityThresholdPct
    RampDownMinimumHostsPct = $RampDownMinimumHostsPct; RampDownCapacityThresholdPct = $RampDownCapacityThresholdPct
    RampDownWaitTimeMinutes = $RampDownWaitTimeMinutes; RampDownForceLogoff = $RampDownForceLogoff; RampDownMessage = $RampDownMessage
    WeekendOffPeak = $WeekendOffPeak; Enable = $Enable; Verbose = $verbose
}
if ($ExclusionTag) { $planParams.ExclusionTag = $ExclusionTag }
$plan = New-AvdScalingPlanResource @planParams

# An existing plan is returned untouched by the create step; make sure it is attached the way asked.
if ($plan -and -not $WhatIfPreference) {
    $mine = @($plan.HostPoolReference | Where-Object { $_.HostPoolArmPath -eq $pool.Id })
    if ($mine.Count -eq 0 -or [bool]$mine[0].ScalingPlanEnabled -ne $Enable) {
        $plan = Set-AvdScalingPlanEnabled -ResourceGroupName $ResourceGroupName -Name $Name -HostPoolId $pool.Id -Enabled $Enable -Verbose:$verbose
    }
}
#endregion

#region 5. Result -------------------------------------------------------------
if ($plan) {
    [pscustomobject]@{
        ScalingPlan = $plan.Name
        HostPool    = $HostPoolName
        Enabled     = $Enable
        TimeZone    = $TimeZone
        Weekdays    = "$($Days -join '/'): ramp-up $RampUpStart, peak $PeakStart, ramp-down $RampDownStart, off-peak $OffPeakStart"
        Weekend     = if ($WeekendOffPeak) { 'off-peak all day' } else { 'no schedule (hosts stay as they are)' }
        Note        = 'The plan acts on the next phase boundary. Hosts it should never touch get the exclusion tag.'
    }
}
#endregion
