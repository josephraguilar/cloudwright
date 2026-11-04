<#
.SYNOPSIS
    Read-only Azure and AVD console: sign in to one tenant, pick a subscription, view reports.
.DESCRIPTION
    Cloudwright safe mode for Azure. Every menu option reads; none starts, stops, changes or
    deletes anything. The sign-in stays in this PowerShell process and is not saved for later
    sessions. Your account keeps its own Azure permissions, so prefer one with the Reader role.
    No logic lives here: every option is one AzureReadOnly function you can also call yourself.
.PARAMETER TenantId
    Directory (tenant) ID to sign in to. Prompted for when omitted.
.PARAMETER SubscriptionId
    Subscription to open. When omitted, choose from the subscriptions the account can read.
.PARAMETER UseDeviceAuthentication
    Sign in with a device code instead of a browser window.
.EXAMPLE
    cloudwright azure -TenantId 00000000-0000-0000-0000-000000000000
    # Preferred: the launcher runs this in a fresh PowerShell process that exits afterwards.
.EXAMPLE
    pwsh -NoProfile -File ./Start-AzureReadOnly.ps1 -TenantId 00000000-0000-0000-0000-000000000000
.NOTES
    Requires: Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.DesktopVirtualization
    Status:   Untested
    Roles:    Reader on the subscription.
#>

#region 1. Parameters ---------------------------------------------------------
#   WHAT   Optional tenant and subscription, and the device-code switch.
#   WHY    GUIDs only, so the context Azure selects can be compared exactly.
#          Write-Host is normally flagged by PSScriptAnalyzer because it bypasses
#          the pipeline. A console that talks to a human is the one place it is
#          correct, so the rule is suppressed for this file only.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console. Output is for the operator, not the pipeline.')]
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$TenantId,

    [Parameter()]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [switch]$UseDeviceAuthentication
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Strict mode, fail fast, and the read-only module. Nothing else.
#   GOTCHA The legacy Azure modules stay blocked; this console never loads them.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AzureReadOnly' 'AzureReadOnly.psd1') -Force
$guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
#endregion

#region 3. Console helpers ------------------------------------------------------
#   WHAT   Select-Item (numbered picker), Show-Table (titled table), and the
#          sign-in summary with the account's access level.
function Select-Item {
    param([string]$Title, [object[]]$Items, [string[]]$Labels)
    Write-Host ''
    Write-Host $Title -ForegroundColor White
    for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ("  {0,2}. {1}" -f ($i + 1), $Labels[$i]) }
    Write-Host '   0. Back'
    while ($true) {
        $answer = "$(Read-Host 'Choice')".Trim()
        if ($answer -eq '0' -or -not $answer) { return $null }
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $Items.Count) { return $Items[[int]$answer - 1] }
    }
}

function Show-Table {
    param([string]$Title, [object[]]$Rows, [string[]]$Property, [string]$Empty = 'None found.')
    Write-Host ''
    Write-Host $Title -ForegroundColor White
    $items = @($Rows | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) { Write-Host "  $Empty"; return }
    $table = if ($Property) { $items | Format-Table -Property $Property -AutoSize -Wrap } else { $items | Format-Table -AutoSize -Wrap }
    Write-Host ($table | Out-String -Width 220).TrimEnd()
}

function Show-SessionSummary {
    $s = Get-AzReadOnlySession
    Write-Host ''
    Write-Host "Account:      $($s.AccountId)"
    Write-Host "Tenant:       $($s.TenantId)"
    if (-not $s.SubscriptionId) { Write-Host 'Subscription: none selected (option 2)' -ForegroundColor Yellow; return }
    Write-Host "Subscription: $($s.SubscriptionName) ($($s.SubscriptionId))"
    if ($s.SubscriptionHomeTenantId -and $s.SubscriptionHomeTenantId -ne $s.TenantId) {
        Write-Host "              Owned by tenant $($s.SubscriptionHomeTenantId); you reach it through delegated access." -ForegroundColor Yellow
    }
    try { $access = Get-AzReadOnlyAccess } catch {
        Write-Host "Access:       not checked: $($_.Exception.Message)" -ForegroundColor Yellow
        return
    }
    if (-not $access.Checked) {
        Write-Host "Access:       not checked. $($access.Note)" -ForegroundColor Yellow
    } elseif ($access.CanChange) {
        Write-Host 'Access:       this account can CHANGE resources or use data access here, for example:' -ForegroundColor Yellow
        foreach ($a in $access.Examples | Select-Object -First 5) { Write-Host "                $a" -ForegroundColor Yellow }
        Write-Host '              Cloudwright only reads, but prefer an account with the Reader role.' -ForegroundColor Yellow
        Write-Host "              $($access.Note)"
    } elseif ($null -eq $access.CanChange) {
        Write-Host 'Access:       no change permissions on the first page of results; the rest were not checked.' -ForegroundColor Yellow
        Write-Host "              $($access.Note)"
    } else {
        Write-Host 'Access:       no change or data permissions found.'
        Write-Host "              $($access.Note)"
    }
}

function Select-Subscription {
    $subs = @(Get-AzReadOnlySubscription)
    if ($subs.Count -eq 0) { Write-Host 'This account cannot read any subscription in this tenant.' -ForegroundColor Yellow; return }
    $tenant = (Get-AzReadOnlySession).TenantId
    $labels = @($subs | ForEach-Object { "$($_.Name) ($($_.Id))$(if ($_.HomeTenantId -ne $tenant) { " - owned by tenant $($_.HomeTenantId)" })$(if ($_.Selected) { ' - current' })" })
    $choice = Select-Item 'Subscription' $subs $labels
    if ($choice) {
        $null = Select-AzReadOnlySubscription -SubscriptionId $choice.Id
        Show-SessionSummary
    }
}

function Select-HostPool {
    $pools = @(Get-AzReadOnlyAvdEnvironment)
    if ($pools.Count -eq 0) { Write-Host ''; Write-Host '  No host pools in this subscription.'; return $null }
    Select-Item 'Host pool' $pools @($pools | ForEach-Object { "$($_.HostPool) ($($_.ResourceGroupName), $($_.Type))" })
}
#endregion

#region 4. Sign in ------------------------------------------------------------
#   WHAT   Check the Az modules, ask for the tenant, sign in for this process only.
#   WHY    Missing modules are reported, not installed: installing software is the
#          operator's choice.
Write-Host ''
Write-Host 'Cloudwright Azure and AVD  -  SAFE MODE: read-only' -ForegroundColor Cyan
Write-Host '  Every option only reads. Nothing is started, stopped, changed or deleted.'
Write-Host '  Your account keeps its own Azure permissions: prefer an account with the Reader role.'
Write-Host '  Az keeps this sign-in in this PowerShell window only. On Windows the sign-in broker remembers the account; device-code sign-in avoids it.'
$missing = @(Get-AzReadOnlyMissingModule)
if ($missing.Count) {
    throw "Install the missing Az modules, then run cloudwright azure again:`n  Install-Module $($missing -join ', ') -Scope CurrentUser"
}
while (-not $TenantId) {
    $answer = "$(Read-Host 'Directory (tenant) ID, a GUID (blank to quit)')".Trim()
    if (-not $answer) { return }
    if ($answer -match $guid) { $TenantId = $answer } else { Write-Host '  Enter the tenant ID GUID from Entra ID > Overview.' }
}
$connect = @{ TenantId = $TenantId }
if ($SubscriptionId) { $connect.SubscriptionId = $SubscriptionId }
if ($UseDeviceAuthentication) { $connect.UseDeviceAuthentication = $true }
$null = Connect-AzReadOnly @connect
if (-not (Get-AzReadOnlySession).SubscriptionId) { Select-Subscription }
Show-SessionSummary
#endregion

#region 5. Menu ---------------------------------------------------------------
#   WHAT   One option per report. A failed read prints its error and returns here.
#   WHY    A permission error on one resource group should not end the session.
while ($true) {
    Write-Host ''
    Write-Host 'Azure and AVD (read-only)' -ForegroundColor Cyan
    Write-Host '   1. Subscriptions this account can read'
    Write-Host '   2. Switch subscription'
    Write-Host '   3. Resource groups'
    Write-Host '   4. Virtual machines and power state'
    Write-Host '   5. AVD environments: host pools, app groups, workspaces'
    Write-Host '   6. AVD host pool details and session hosts'
    Write-Host '   7. AVD user sessions'
    Write-Host '   8. AVD health check'
    Write-Host '   9. Networks and security groups'
    Write-Host '  10. Sign-in and access summary'
    Write-Host '   Q. Quit'
    $choice = "$(Read-Host 'Choose')".Trim().ToLowerInvariant()
    if ($choice -in 'q', 'quit', 'exit') {
        Write-Host "Az's sign-in ends when this PowerShell process exits; on Windows the sign-in broker still remembers the account. If you ran this script in an existing window, close it."
        break
    }
    try {
        switch ($choice) {
            '1' { Show-Table 'Subscriptions' @(Get-AzReadOnlySubscription) Name, Id, State, HomeTenantId, Selected }
            '2' { Select-Subscription }
            '3' { Show-Table 'Resource groups' @(Get-AzReadOnlyResourceGroup) }
            '4' { Show-Table 'Virtual machines' @(Get-AzReadOnlyVm) }
            '5' { Show-Table 'AVD host pools' @(Get-AzReadOnlyAvdEnvironment) -Empty 'No host pools in this subscription.' }
            '6' {
                $pool = Select-HostPool
                if ($pool) {
                    $d = Get-AzReadOnlyHostPool -ResourceGroupName $pool.ResourceGroupName -HostPoolName $pool.HostPool
                    $p = $d.Pool; $c = $d.Counts
                    Write-Host ''
                    Write-Host ("{0} in {1} ({2}): {3}, {4}, max {5} sessions per host. Start VM On Connect: {6}. Validation pool: {7}." -f
                        $p.Name, $p.ResourceGroupName, $p.Location, $p.Type, $p.LoadBalancer, $p.MaxSessionLimit, $p.StartVMOnConnect, $p.ValidationEnvironment)
                    Write-Host ("Hosts: {0} total, {1} available, {2} unavailable, {3} other, {4} drained. Sessions: {5}. Running VMs: {6}." -f
                        $c.Total, $c.Available, $c.Unavailable, $c.Other, $c.Drained, $c.Sessions, $c.Running)
                    Show-Table 'Session hosts' $d.Hosts Name, Status, Drain, Sessions, PowerState, VMSize, AgentVersion, UpdateState, FailedChecks
                    Show-Table 'Application groups' @($d.AppGroups | Select-Object Name, Type, @{ Name = 'Workspaces'; Expression = { $_.Workspaces -join ', ' } })
                    Show-Table 'Scaling plans' $d.ScalingPlans -Empty 'No scaling plan: hosts run until someone stops them.'
                }
            }
            '7' {
                $pool = Select-HostPool
                if ($pool) { Show-Table "User sessions in $($pool.HostPool)" @(Get-AzReadOnlyUserSession -ResourceGroupName $pool.ResourceGroupName -HostPoolName $pool.HostPool) -Empty 'Nobody is signed in.' }
            }
            '8' { Show-Table 'AVD health' @(Get-AzReadOnlyAvdHealth) Severity, HostPool, SessionHost, Finding -Empty 'No problems or warnings found.' }
            '9' {
                $n = Get-AzReadOnlyNetwork
                Show-Table 'Virtual networks' $n.VirtualNetworks
                Show-Table 'Subnets' $n.Subnets
                Show-Table 'Network security groups (OpenToInternet: inbound Allow rules from any internet source; priority and Deny rules not evaluated)' $n.SecurityGroups
            }
            '10' { Show-SessionSummary }
            default { Write-Host 'Choose 1-10 or Q.' }
        }
    } catch {
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    }
}
#endregion
