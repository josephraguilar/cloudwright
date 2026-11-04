<#
.SYNOPSIS
    Restart session hosts one at a time without dropping users: drain, message,
    wait for sessions to end, restart, wait for Available, undrain.
.DESCRIPTION
    The patch-window routine, done properly, per host:

      1. Drain (no new sessions land here)
      2. Message every active session
      3. Wait up to -WaitMinutes for the host to empty
         - still busy and no -ForceLogoff: skip this host (drain is turned back
           off), report it, continue with the next
         - still busy and -ForceLogoff: log the remaining sessions off
      4. Restart the VM
      5. Wait for the host to report Available again
      6. Undrain

    Hosts are processed in name order, so capacity drops by one host at a time.
    Hosts that are not Available to begin with are skipped unless -IncludeUnavailable.
.PARAMETER SubscriptionId
    Subscription containing the host pool.
.PARAMETER ResourceGroupName
    Resource group of the host pool.
.PARAMETER HostPoolName
    Host pool name.
.PARAMETER SessionHostName
    Hosts to restart. Default: every host in the pool.
.PARAMETER WaitMinutes
    How long to wait for users to leave each host. Default 30.
.PARAMETER MessageBody
    What active users see. Mention the time.
.PARAMETER ForceLogoff
    Log off whoever is left when the wait runs out. Without it, the host is skipped.
.PARAMETER IncludeUnavailable
    Also restart hosts that are not Available (sometimes that is the point).
.PARAMETER TimeoutMinutes
    How long to wait for a host to come back Available after the restart. Default 15.
.EXAMPLE
    ./Invoke-AvdRollingRestart.ps1 -SubscriptionId <sub> -ResourceGroupName rg-avd-lab -HostPoolName hp-lab -WaitMinutes 15 -Verbose
.NOTES
    Requires: Az.Accounts, Az.DesktopVirtualization, Az.Compute
    Status:   Untested
    Roles:    Desktop Virtualization Session Host Operator and User Session Operator
              on the pool, Virtual Machine Contributor on the VMs. Contributor covers all.
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
    [string[]]$SessionHostName,

    [Parameter()]
    [ValidateRange(0, 480)]
    [int]$WaitMinutes = 30,

    [Parameter()]
    [string]$MessageBody = 'This desktop will restart for maintenance in 30 minutes. Please save your work and sign out.',

    [Parameter()]
    [switch]$ForceLogoff,

    [Parameter()]
    [switch]$IncludeUnavailable,

    [Parameter()]
    [ValidateRange(1, 120)]
    [int]$TimeoutMinutes = 15
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

$all = @(Get-AvdSessionHostInfo -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName | Sort-Object Name)
$targets = if ($SessionHostName) {
    foreach ($n in $SessionHostName) {
        $m = $all | Where-Object { $_.Name -eq $n -or $_.Name -like "$n.*" } | Select-Object -First 1
        if (-not $m) { throw "Session host '$n' not found in $HostPoolName." }
        $m
    }
} else { $all }
$targets = @($targets)
if ($targets.Count -eq 0) { throw "No session hosts in $HostPoolName." }
#endregion

#region 3. Roll ---------------------------------------------------------------
#   WHAT   The six steps above, per host, with one result row each.
#   WHY    Drain is undone on every exit path so a skipped host is not left
#          refusing sessions. The whole run is -WhatIf aware: with it, the module
#          calls print what they would do and the waits are skipped.
#   GOTCHA Wait-AvdSessionHostStatus restarts the VM again if it stays Unavailable
#          past -RestartVmAfterMinutes; that is left off here because we just did.
$common = @{ ResourceGroupName = $ResourceGroupName; HostPoolName = $HostPoolName }
foreach ($h in $targets) {
    $name = $h.Name
    if ($h.Status -ne 'Available' -and -not $IncludeUnavailable) {
        Write-Warning "$name is $($h.Status); skipped (use -IncludeUnavailable to restart it anyway)."
        [pscustomobject]@{ SessionHost = $name; Result = "Skipped: status $($h.Status)" }
        continue
    }
    $result = 'Restarted'
    try {
        Write-Verbose "[$name] 1/6 drain on"
        Set-AvdSessionHostDrain @common -SessionHostName $name -Enabled $true

        $active = @(Get-AvdUserSession @common -SessionHostName $name)
        if ($active.Count -gt 0 -and -not $WhatIfPreference) {
            Write-Verbose "[$name] 2/6 messaging $($active.Count) session(s)"
            $null = Send-AvdUserMessage @common -SessionHostName $name -Title 'Maintenance' -Body $MessageBody
            Write-Verbose "[$name] 3/6 waiting up to $WaitMinutes minute(s) for users to leave"
            $empty = Wait-AvdSessionHostEmpty @common -SessionHostName $name -TimeoutMinutes $WaitMinutes
            if (-not $empty) {
                if ($ForceLogoff) {
                    Write-Verbose "[$name] users still signed in; logging them off (-ForceLogoff)"
                    $null = Remove-AvdUserSession @common -SessionHostName $name -Force
                } else {
                    Write-Warning "[$name] users still signed in after $WaitMinutes minute(s); skipped. Re-run with -ForceLogoff to sign them out."
                    Set-AvdSessionHostDrain @common -SessionHostName $name -Enabled $false
                    [pscustomobject]@{ SessionHost = $name; Result = 'Skipped: users still signed in' }
                    continue
                }
            }
        } else {
            Write-Verbose "[$name] 2/6, 3/6 no active sessions"
        }

        Write-Verbose "[$name] 4/6 restart"
        $null = Restart-AvdSessionHostVm @common -SessionHostName $name -Force

        if (-not $WhatIfPreference) {
            Write-Verbose "[$name] 5/6 waiting for Available"
            $null = Wait-AvdSessionHostStatus @common -Name $name -Status 'Available' -TimeoutMinutes $TimeoutMinutes
        }
    } catch {
        $result = "Failed: $($_.Exception.Message)"
        Write-Warning "[$name] $result"
    } finally {
        Write-Verbose "[$name] 6/6 drain off"
        try { Set-AvdSessionHostDrain @common -SessionHostName $name -Enabled $false } catch { Write-Warning "[$name] could not turn drain off: $($_.Exception.Message)" }
    }
    [pscustomobject]@{ SessionHost = $name; Result = $result }
}
#endregion
