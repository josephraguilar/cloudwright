<#
.SYNOPSIS
    Drain mode, session listing, user messaging, and log-off for one session host.
.DESCRIPTION
    The maintenance toolkit for a single host, one action per run:

      DrainOn       Block new sessions. Existing sessions are untouched.
      DrainOff      Allow new sessions again.
      ListSessions  Show who is on the host and whether they are Active or Disconnected.
      Message       Popup to every Active session (or the ones in -SessionId).
      LogOff        Log off every session (or the ones in -SessionId). Prompts unless -Force.

    The real work is in the AvdHelpers module. This script is the command-line face of it.
.PARAMETER SubscriptionId
    Subscription containing the host pool.
.PARAMETER ResourceGroupName
    Resource group of the host pool.
.PARAMETER HostPoolName
    Host pool name.
.PARAMETER SessionHostName
    VM name, FQDN, or 'pool/fqdn'. Resolved by Find-AvdSessionHost.
.PARAMETER Action
    One of DrainOn, DrainOff, ListSessions, Message, LogOff.
.PARAMETER MessageTitle
    Title for the popup. Default "Maintenance".
.PARAMETER MessageBody
    Body for the popup. Required for Message.
.PARAMETER SessionId
    Limit Message or LogOff to these session IDs (from ListSessions).
.PARAMETER Force
    LogOff without the confirmation prompt.
.EXAMPLE
    ./Set-AvdHostDrain.ps1 -SubscriptionId <sub> -ResourceGroupName rg-avd-lab -HostPoolName hp-lab -SessionHostName avd-lab-01 -Action DrainOn
.EXAMPLE
    ./Set-AvdHostDrain.ps1 ... -SessionHostName avd-lab-01 -Action Message -MessageBody 'Please save your work. This host restarts in 15 minutes.'
.EXAMPLE
    ./Set-AvdHostDrain.ps1 ... -SessionHostName avd-lab-01 -Action LogOff -Force
.NOTES
    Requires: Az.Accounts, Az.DesktopVirtualization
    Status:   Untested
    Roles:    Desktop Virtualization Session Host Operator on the host pool (drain) and
              Desktop Virtualization User Session Operator (message, log off).
              Contributor covers both.
#>

#region 1. Parameters ---------------------------------------------------------
#   WHAT   One host, one action. Message and LogOff take optional session filters.
#   WHY    A single script with -Action beats five tiny scripts because the setup is
#          identical and the console can drive it with one code path.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$HostPoolName,

    [Parameter(Mandatory)]
    [string]$SessionHostName,

    [Parameter(Mandatory)]
    [ValidateSet('DrainOn', 'DrainOff', 'ListSessions', 'Message', 'LogOff')]
    [string]$Action,

    [Parameter()]
    [string]$MessageTitle = 'Maintenance',

    [Parameter()]
    [string]$MessageBody,

    [Parameter()]
    [string[]]$SessionId,

    [Parameter()]
    [switch]$Force
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Strict mode, fail fast, modules, Azure context, resolve the host.
#   WHY    Resolving the host here means every action below works with a known-good
#          short name and fails early with a clear message if the host is not in the pool.
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AvdHelpers' 'AvdHelpers.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId

$sessionHost = Get-AvdSessionHostInfo -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -Name $SessionHostName
if (-not $sessionHost) {
    throw "Session host '$SessionHostName' not found in host pool $HostPoolName."
}
$name = $sessionHost.Name

if ($Action -eq 'Message' -and -not $MessageBody) {
    throw 'Action Message requires -MessageBody.'
}
#endregion

#region 3. Action -------------------------------------------------------------
#   WHAT   Dispatch to the matching AvdHelpers function.
#   WHY    Each branch is one call. If you need the logic somewhere else (a runbook,
#          the console, an app), call the module function directly.
#   GOTCHA -WhatIf flows into the module functions automatically because they
#          declare SupportsShouldProcess and are called from a script that does too.
$common = @{
    ResourceGroupName = $ResourceGroupName
    HostPoolName      = $HostPoolName
    SessionHostName   = $name
}

switch ($Action) {
    'DrainOn' {
        Set-AvdSessionHostDrain @common -Enabled $true
        Get-AvdSessionHostInfo -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -Name $name
    }
    'DrainOff' {
        Set-AvdSessionHostDrain @common -Enabled $false
        Get-AvdSessionHostInfo -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -Name $name
    }
    'ListSessions' {
        Get-AvdUserSession @common
    }
    'Message' {
        $sent = @(Send-AvdUserMessage @common -Title $MessageTitle -Body $MessageBody -SessionId $SessionId)
        Write-Verbose "Messaged $($sent.Count) active session(s) on $name."
        $sent
    }
    'LogOff' {
        $gone = @(Remove-AvdUserSession @common -SessionId $SessionId -Force:$Force)
        Write-Verbose "Logged off $($gone.Count) session(s) on $name."
        $gone
    }
}
#endregion
