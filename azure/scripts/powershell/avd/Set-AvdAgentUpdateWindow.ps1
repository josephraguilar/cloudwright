<#
.SYNOPSIS
    Pin the host pool's AVD agent updates to a weekly maintenance window, or hand
    the timing back to Microsoft.
.DESCRIPTION
    Agent and boot loader updates restart the agent and briefly take the host out
    of service. Scheduled mode runs them in the window you set (a two-hour slot
    starting at -Hour on -DayOfWeek). Default mode lets Microsoft pick.
.PARAMETER SubscriptionId
    Subscription containing the host pool.
.PARAMETER ResourceGroupName
    Resource group of the host pool.
.PARAMETER HostPoolName
    Host pool name.
.PARAMETER DayOfWeek
    Sunday..Saturday.
.PARAMETER Hour
    0..23, start of the two-hour window.
.PARAMETER TimeZone
    Windows time zone ID, e.g. 'Pacific Standard Time'. Default: this machine's.
.PARAMETER UseSessionHostLocalTime
    Use each host's own time zone instead of -TimeZone.
.PARAMETER Default
    Back to Microsoft's default timing.
.EXAMPLE
    ./Set-AvdAgentUpdateWindow.ps1 -SubscriptionId <sub> -ResourceGroupName rg-avd-lab -HostPoolName hp-lab -DayOfWeek Saturday -Hour 2
.EXAMPLE
    ./Set-AvdAgentUpdateWindow.ps1 ... -Default
.NOTES
    Requires: Az.Accounts, Az.DesktopVirtualization
    Status:   Untested
    Roles:    Desktop Virtualization Host Pool Contributor.
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Scheduled')]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$HostPoolName,

    [Parameter(ParameterSetName = 'Scheduled', Mandatory)]
    [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')]
    [string]$DayOfWeek,

    [Parameter(ParameterSetName = 'Scheduled', Mandatory)]
    [ValidateRange(0, 23)]
    [int]$Hour,

    [Parameter(ParameterSetName = 'Scheduled')]
    [string]$TimeZone = (Get-TimeZone).Id,

    [Parameter(ParameterSetName = 'Scheduled')]
    [switch]$UseSessionHostLocalTime,

    [Parameter(ParameterSetName = 'Default', Mandatory)]
    [switch]$Default
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AvdBuild' 'AvdBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
#endregion

#region 3. Apply --------------------------------------------------------------
$p = @{ ResourceGroupName = $ResourceGroupName; HostPoolName = $HostPoolName }
if ($Default) {
    $pool = Set-AvdHostPoolAgentUpdate @p -Default
} else {
    $pool = Set-AvdHostPoolAgentUpdate @p -DayOfWeek $DayOfWeek -Hour $Hour -TimeZone $TimeZone -UseSessionHostLocalTime:$UseSessionHostLocalTime
}
if ($pool) {
    [pscustomobject]@{
        HostPool        = $pool.Name
        AgentUpdateType = "$($pool.AgentUpdateType)"
        Window          = (@($pool.AgentUpdateMaintenanceWindow | ForEach-Object { "$($_.DayOfWeek) $('{0:d2}:00' -f [int]$_.Hour)" }) -join ', ')
        TimeZone        = if ($pool.AgentUpdateUseSessionHostLocalTime) { 'session host local time' } else { "$($pool.AgentUpdateMaintenanceWindowTimeZone)" }
    }
}
#endregion
