<#
.SYNOPSIS
    Timer-driven health check for an AVD host pool. Restarts sick hosts, drains the ones that stay sick, alerts.
.DESCRIPTION
    Meant to run on a schedule (every 15 to 30 minutes) in an Azure Automation account:

      1. Find hosts whose status is Unavailable or NeedsAssistance
      2. Skip any whose VM is deallocated (that is autoscale, not a fault)
      3. Restart the rest and wait -RecheckMinutes
      4. Any host still unhealthy is put in drain mode so no new users land on it
      5. Post a summary to -AlertWebhookUrl (Teams workflow, Logic App, anything that
         accepts JSON) and to the job output

    Reimaging is deliberately NOT done here. It needs credentials and image choices
    that should not live in an Automation account. The alert names the host and the
    exact Invoke-AvdHostReimage.ps1 call to run.

    This file is self-contained on purpose. Automation only has the modules you upload,
    so it uses Az cmdlets directly instead of AzHelpers/AvdHelpers.
.PARAMETER SubscriptionId
    Subscription containing the host pool.
.PARAMETER ResourceGroupName
    Resource group of the host pool.
.PARAMETER HostPoolName
    Host pool to check.
.PARAMETER RecheckMinutes
    Minutes to wait after a restart before rechecking. Default 5.
.PARAMETER AlertWebhookUrl
    HTTPS endpoint that accepts a JSON POST. Optional. Store it as an encrypted
    Automation variable and pass it in from the schedule.
.PARAMETER DrainUnhealthy
    Put hosts that stay unhealthy into drain mode. Default $true.
.NOTES
    Requires: Az.Accounts, Az.Compute, Az.Resources, Az.DesktopVirtualization (as Automation module assets)
    Status:   Untested
    Identity: The Automation account's system-assigned managed identity needs
              Desktop Virtualization Contributor on the host pool resource group and
              Virtual Machine Contributor on the VM resource group.
#>

#region 1. Parameters ---------------------------------------------------------
#   WHAT   Inputs come from the Automation schedule, not a person.
#   WHY    No SupportsShouldProcess: there is nobody to answer a prompt. Every action
#          is logged with Write-Output instead, which lands in the job history.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$HostPoolName,

    [Parameter()]
    [int]$RecheckMinutes = 5,

    [Parameter()]
    [string]$AlertWebhookUrl,

    [Parameter()]
    [bool]$DrainUnhealthy = $true
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Managed identity login, no interactive fallback.
#   WHY    Disable-AzContextAutosave stops Az from writing a context file into the
#          sandbox, which is the standard first line of every Automation runbook.
#          Connect-AzAccount -Identity uses the Automation account's own identity:
#          nothing to store, nothing to rotate.
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$null = Disable-AzContextAutosave -Scope Process
$null = Connect-AzAccount -Identity
$null = Set-AzContext -Subscription $SubscriptionId

$unhealthyStatuses = @('Unavailable', 'NeedsAssistance')
$started = Get-Date
Write-Output "Health check for $HostPoolName started $($started.ToUniversalTime().ToString('u'))."
#endregion

#region 3. Find unhealthy hosts -----------------------------------------------
#   WHAT   Hosts in a bad status whose VM is actually running.
#   WHY    A deallocated VM shows as Unavailable too. That is autoscale (or someone)
#          turning it off on purpose, and restarting it would fight the scaling plan
#          and cost money. Only a running VM with a sick agent is a fault.
$candidates = @()
foreach ($h in Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName) {
    if ($h.Status -notin $unhealthyStatuses) { continue }
    $shortName = ($h.Name -split '/')[-1]

    if (-not $h.ResourceId) {
        Write-Output "SKIP  $shortName is $($h.Status) but has no VM resource ID."
        continue
    }
    $vmRes = Get-AzResource -ResourceId $h.ResourceId
    $vmStatus = Get-AzVM -ResourceGroupName $vmRes.ResourceGroupName -Name $vmRes.Name -Status
    $power = ($vmStatus.Statuses | Where-Object Code -like 'PowerState/*' | Select-Object -First 1).Code

    if ($power -ne 'PowerState/running') {
        Write-Output "SKIP  $shortName is $($h.Status) and VM is $power. Likely autoscale. Not touching."
        continue
    }
    $candidates += [pscustomobject]@{
        SessionHost = $shortName
        Status      = $h.Status
        VmName      = $vmRes.Name
        VmRg        = $vmRes.ResourceGroupName
    }
}

if ($candidates.Count -eq 0) {
    Write-Output 'OK    No unhealthy running hosts.'
    return
}
#endregion

#region 4. Restart and recheck ------------------------------------------------
#   WHAT   Restart each candidate, wait, then read its status again.
#   WHY    A restart fixes most agent-level faults (stuck boot loader, failed update).
#          It is cheap and loses nothing on a host that already has no usable sessions.
#   GOTCHA Restart-AzVM is synchronous and can take a couple of minutes per host.
#          Automation jobs have a 3 hour limit, so a pool with dozens of sick hosts
#          at once should be looked at by a person, not this runbook.
foreach ($c in $candidates) {
    Write-Output "FIX   Restarting $($c.VmName) ($($c.Status))."
    try {
        $null = Restart-AzVM -ResourceGroupName $c.VmRg -Name $c.VmName
    } catch {
        Write-Output "ERR   Restart of $($c.VmName) failed: $($_.Exception.Message)"
    }
}

Write-Output "WAIT  $RecheckMinutes minute(s) before rechecking."
Start-Sleep -Seconds ($RecheckMinutes * 60)

$stillBad = @()
foreach ($c in $candidates) {
    $h = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -Name $c.SessionHost -ErrorAction SilentlyContinue
    $status = if ($h) { $h.Status } else { 'NotFound' }
    if ($status -in $unhealthyStatuses -or $status -eq 'NotFound') {
        Write-Output "BAD   $($c.SessionHost) still $status after restart."
        $stillBad += $c
    } else {
        Write-Output "OK    $($c.SessionHost) recovered: $status."
    }
}
#endregion

#region 5. Drain the ones that stayed bad ------------------------------------
#   WHAT   AllowNewSession = false on each host that did not recover.
#   WHY    Keeps the broker from sending new users to a host that cannot serve them.
#          Existing sessions (if any) are left alone; a person decides the next step.
if ($DrainUnhealthy) {
    foreach ($c in $stillBad) {
        try {
            $null = Update-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -Name $c.SessionHost -AllowNewSession:$false
            Write-Output "DRAIN $($c.SessionHost) set to drain mode."
        } catch {
            Write-Output "ERR   Drain of $($c.SessionHost) failed: $($_.Exception.Message)"
        }
    }
}
#endregion

#region 6. Alert --------------------------------------------------------------
#   WHAT   One JSON POST summarising what happened, plus the same text in job output.
#   WHY    A Teams workflow or Logic App turns this into a message. The payload names
#          the exact reimage command so the person on call does not have to look it up.
#   GOTCHA The webhook URL is a secret (anyone with it can post as you). Keep it in an
#          encrypted Automation variable, never in this file.
$summary = [pscustomobject]@{
    HostPool   = $HostPoolName
    CheckedUtc = $started.ToUniversalTime().ToString('u')
    Restarted  = @($candidates | ForEach-Object SessionHost)
    Recovered  = @($candidates | Where-Object { $_.SessionHost -notin ($stillBad | ForEach-Object SessionHost) } | ForEach-Object SessionHost)
    StillBad   = @($stillBad | ForEach-Object SessionHost)
    NextStep   = if ($stillBad.Count -gt 0) {
        "Run: ./scripts/powershell/avd/Invoke-AvdHostReimage.ps1 -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -SessionHostName <name> ... -Force"
    } else { 'None' }
}

if ($stillBad.Count -gt 0 -and $AlertWebhookUrl) {
    $payload = @{
        title = "AVD health: $($stillBad.Count) host(s) in $HostPoolName need attention"
        text  = ($summary | ConvertTo-Json -Depth 4)
    } | ConvertTo-Json -Depth 4
    try {
        $null = Invoke-RestMethod -Method Post -Uri $AlertWebhookUrl -Body $payload -ContentType 'application/json'
        Write-Output 'ALERT Sent to webhook.'
    } catch {
        Write-Output "ERR   Webhook post failed: $($_.Exception.Message)"
    }
}

$summary
#endregion
