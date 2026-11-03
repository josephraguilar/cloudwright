#region Module setup ----------------------------------------------------------
#   WHAT   Strict mode for the whole module. Requires Az.DesktopVirtualization at call
#          time (not import time) so the module and its tests load without Az.
#   WHY    These functions are the building blocks for every AVD script and for the
#          interactive console. Scripts stay thin; the logic that would end up in a
#          web app lives here.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'   # module functions do not inherit the caller's value
#endregion

#region Names -----------------------------------------------------------------
#   WHAT   AVD session host names come in two shapes: 'hostpool/vm.domain.local' from
#          Get-AzWvdSessionHost, and 'vm.domain.local' for Update/Remove cmdlets.
#          People usually just know the VM name. These two functions translate.
#   WHY    Every cmdlet that takes -Name wants the short form. Getting this wrong
#          produces a confusing 404, so it is handled in exactly one place.
function Resolve-AvdSessionHostName {
    <#
    .SYNOPSIS
        Strips the 'hostpool/' prefix from a session host name.
    .EXAMPLE
        Resolve-AvdSessionHostName 'hp-lab/avd-01.corp.local'   # avd-01.corp.local
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$SessionHostName
    )
    return ($SessionHostName -split '/')[-1]
}

function Find-AvdSessionHost {
    <#
    .SYNOPSIS
        Finds a session host in a pool by VM name, FQDN, or full 'pool/fqdn' name.
    .DESCRIPTION
        Returns the raw Get-AzWvdSessionHost object, or $null if nothing matches.
        Matches the short name exactly, or the hostname part before the first dot,
        so 'avd-01' finds 'hp-lab/avd-01.corp.local'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$HostPoolName,

        [Parameter(Mandatory)]
        [string]$Name
    )
    $wanted = Resolve-AvdSessionHostName -SessionHostName $Name
    Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName |
        Where-Object {
            $short = Resolve-AvdSessionHostName -SessionHostName $_.Name
            $short -eq $wanted -or ($short -split '\.')[0] -eq $wanted
        } |
        Select-Object -First 1
}
#endregion

#region Session host state ----------------------------------------------------
#   WHAT   Flattened view of a pool's hosts, and the drain toggle.
#   WHY    The raw session host object has 20+ properties with awkward names. One
#          flat shape (Name, Status, Sessions, Drain, VmResourceId) is what every
#          script and the console actually need.
#   GOTCHA "Drain mode" in the portal is AllowNewSession = $false in the API. The
#          flag is inverted here so the word means what the portal says.
function Get-AvdSessionHostInfo {
    <#
    .SYNOPSIS
        Lists session hosts in a pool as flat objects.
    .PARAMETER Name
        Optional VM name, FQDN, or 'pool/fqdn' to return one host.
    .PARAMETER IncludeVm
        Also look up each host's VM: power state, size, resource group. One
        Get-AzVM -Status call per resource group, so cheap even for big pools.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$HostPoolName,

        [Parameter()]
        [string]$Name,

        [Parameter()]
        [switch]$IncludeVm
    )
    $hosts = if ($Name) {
        Find-AvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -Name $Name
    } else {
        Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName
    }

    $vmByKey = @{}
    if ($IncludeVm) {
        $groups = @($hosts | ForEach-Object { (Split-AvdVmResourceId $_.ResourceId).ResourceGroupName } | Where-Object { $_ } | Sort-Object -Unique)
        foreach ($g in $groups) {
            try {
                foreach ($vm in @(Get-AzVM -ResourceGroupName $g -Status -ErrorAction Stop)) { $vmByKey["$g/$($vm.Name)".ToLowerInvariant()] = $vm }
            } catch { Write-Warning "Could not read VMs in ${g}: $($_.Exception.Message)" }
        }
    }

    foreach ($h in $hosts) {
        $row = [ordered]@{
            Name          = Resolve-AvdSessionHostName -SessionHostName $h.Name
            Status        = $h.Status
            Drain         = -not $h.AllowNewSession
            Sessions      = $h.Session
            AgentVersion  = $h.AgentVersion
            LastHeartBeat = $h.LastHeartBeat
            UpdateState   = $h.UpdateState
            VmResourceId  = $h.ResourceId
        }
        if ($IncludeVm) {
            $ref = Split-AvdVmResourceId $h.ResourceId
            $vm = if ($ref.ResourceGroupName) { $vmByKey["$($ref.ResourceGroupName)/$($ref.Name)".ToLowerInvariant()] } else { $null }
            $row.VMName            = $ref.Name
            $row.VMResourceGroup   = $ref.ResourceGroupName
            $row.PowerState        = if ($vm -and $vm.PowerState) { $vm.PowerState -replace '^VM ', '' } else { 'unknown' }
            $row.VMSize            = if ($vm) { $vm.HardwareProfile.VmSize } else { $null }
            $row.Location          = if ($vm) { $vm.Location } else { $null }
        }
        [pscustomobject]$row
    }
}

function Split-AvdVmResourceId {
    # /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/virtualMachines/<name>
    param([string]$ResourceId)
    if ($ResourceId -match '/resourceGroups/([^/]+)/providers/Microsoft\.Compute/virtualMachines/([^/]+)$') {
        return [pscustomobject]@{ ResourceGroupName = $Matches[1]; Name = $Matches[2] }
    }
    return [pscustomobject]@{ ResourceGroupName = $null; Name = $null }
}

function Set-AvdSessionHostDrain {
    <#
    .SYNOPSIS
        Turns drain mode on or off for one session host.
    .PARAMETER Enabled
        $true blocks new sessions (drain on). $false allows them (drain off).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$HostPoolName,

        [Parameter(Mandatory)]
        [string]$SessionHostName,

        [Parameter(Mandatory)]
        [bool]$Enabled
    )
    $name = Resolve-AvdSessionHostName -SessionHostName $SessionHostName
    $action = if ($Enabled) { 'Enable drain mode (block new sessions)' } else { 'Disable drain mode (allow new sessions)' }
    if ($PSCmdlet.ShouldProcess($name, $action)) {
        $null = Update-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
            -Name $name -AllowNewSession:(-not $Enabled)
    }
}
#endregion

#region User sessions ---------------------------------------------------------
#   WHAT   List, message, and log off the user sessions on one host.
#   WHY    Maintenance on a host is always: drain, tell the users, wait, log off the
#          stragglers. These three functions are those steps.
#   GOTCHA Messages only reach Active sessions. A Disconnected session has no screen
#          to show the popup on. Log-off works on both.
function Get-AvdUserSession {
    <#
    .SYNOPSIS
        Lists user sessions on one session host as flat objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$HostPoolName,

        [Parameter(Mandatory)]
        [string]$SessionHostName
    )
    $name = Resolve-AvdSessionHostName -SessionHostName $SessionHostName
    Get-AzWvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -SessionHostName $name |
        ForEach-Object {
            [pscustomobject]@{
                SessionId         = ($_.Name -split '/')[-1]
                SessionHost       = $name
                UserPrincipalName = $_.UserPrincipalName
                SessionState      = $_.SessionState
                ApplicationType   = $_.ApplicationType
                CreateTime        = $_.CreateTime
            }
        }
}

function Send-AvdUserMessage {
    <#
    .SYNOPSIS
        Sends a popup message to the active sessions on one host.
    .PARAMETER SessionId
        Limit to specific session IDs. Default is every Active session on the host.
    .OUTPUTS
        The sessions that were messaged.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$HostPoolName,

        [Parameter(Mandatory)]
        [string]$SessionHostName,

        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Body,

        [Parameter()]
        [string[]]$SessionId
    )
    $name = Resolve-AvdSessionHostName -SessionHostName $SessionHostName
    $sessions = @(Get-AvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -SessionHostName $name |
        Where-Object SessionState -eq 'Active')
    if ($SessionId) { $sessions = @($sessions | Where-Object { $_.SessionId -in $SessionId }) }

    foreach ($s in $sessions) {
        if ($PSCmdlet.ShouldProcess("$($s.UserPrincipalName) on $name", "Send message '$Title'")) {
            Send-AzWvdUserSessionMessage -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
                -SessionHostName $name -UserSessionId $s.SessionId -MessageTitle $Title -MessageBody $Body
            $s
        }
    }
}

function Remove-AvdUserSession {
    <#
    .SYNOPSIS
        Logs off user sessions on one host.
    .PARAMETER SessionId
        Limit to specific session IDs. Default is every session on the host.
    .PARAMETER Force
        Skip the confirmation prompt. -WhatIf still works.
    .OUTPUTS
        The sessions that were logged off.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$HostPoolName,

        [Parameter(Mandatory)]
        [string]$SessionHostName,

        [Parameter()]
        [string[]]$SessionId,

        [Parameter()]
        [switch]$Force
    )
    # Standard -Force pattern: suppress the ConfirmImpact=High prompt unless the
    # caller passed -Confirm explicitly. -WhatIf is unaffected.
    if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) {
        $ConfirmPreference = 'None'
    }

    $name = Resolve-AvdSessionHostName -SessionHostName $SessionHostName
    $sessions = @(Get-AvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -SessionHostName $name)
    if ($SessionId) { $sessions = @($sessions | Where-Object { $_.SessionId -in $SessionId }) }

    foreach ($s in $sessions) {
        if ($PSCmdlet.ShouldProcess("$($s.UserPrincipalName) on $name ($($s.SessionState))", 'Log off')) {
            Remove-AzWvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
                -SessionHostName $name -Id $s.SessionId -Force
            $s
        }
    }
}
#endregion

#region Waiting ---------------------------------------------------------------
#   WHAT   Poll until a host reaches a status, or until it has no sessions.
#   WHY    Provisioning and reimaging are sequences of "do X, wait for Y". Writing
#          the poll loop once with a timeout keeps the scripts readable and stops
#          them from spinning forever when something is stuck.
#   GOTCHA A brand-new host is not in the pool at all until the AVD agent registers,
#          so Wait-AvdSessionHostStatus tolerates "not found" and keeps polling.
function Wait-AvdSessionHostStatus {
    <#
    .SYNOPSIS
        Waits until a session host reports one of the given statuses.
    .PARAMETER Name
        VM name, FQDN, or 'pool/fqdn'. Resolved on every poll so a host that has not
        registered yet is found as soon as it appears.
    .PARAMETER RestartVmAfterMinutes
        If the host has registered but is still Unavailable after this many minutes,
        restart its VM once and keep waiting. 0 (default) never restarts. A freshly
        built host whose agent ran its first health checks too early is cured by a
        restart; this saves a person noticing.
    .OUTPUTS
        The flat session host object once it matches. Throws on timeout.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$HostPoolName,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [string[]]$Status = @('Available'),

        [Parameter()]
        [int]$TimeoutMinutes = 20,

        [Parameter()]
        [int]$PollSeconds = 30,

        [Parameter()]
        [int]$RestartVmAfterMinutes = 0
    )
    $started = Get-Date
    $deadline = $started.AddMinutes($TimeoutMinutes)
    $last = 'not registered'
    $restarted = $false
    do {
        $h = Get-AvdSessionHostInfo -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -Name $Name
        if ($h) {
            $last = $h.Status
            if ($h.Status -in $Status) { return $h }

            $stuckMinutes = ((Get-Date) - $started).TotalMinutes
            if ($RestartVmAfterMinutes -gt 0 -and -not $restarted -and $h.Status -eq 'Unavailable' -and $stuckMinutes -ge $RestartVmAfterMinutes -and $h.VmResourceId) {
                $vmRes = Get-AzResource -ResourceId $h.VmResourceId
                if ($PSCmdlet.ShouldProcess($vmRes.Name, "Restart VM (host Unavailable for $([int]$stuckMinutes) min)")) {
                    Write-Verbose "  $Name has been Unavailable for $([int]$stuckMinutes) minutes. Restarting the VM once."
                    $null = Restart-AzVM -ResourceGroupName $vmRes.ResourceGroupName -Name $vmRes.Name
                }
                $restarted = $true
            }
        }
        Write-Verbose "  $Name is $last. Waiting for $($Status -join '/')..."
        Start-Sleep -Seconds $PollSeconds
    } until ((Get-Date) -gt $deadline)

    throw "Session host $Name did not reach $($Status -join '/') within $TimeoutMinutes minutes (last: $last)."
}

function Wait-AvdSessionHostEmpty {
    <#
    .SYNOPSIS
        Waits until a session host has zero user sessions.
    .OUTPUTS
        $true when empty, $false on timeout. Does not throw, so the caller can decide
        whether to force log-off.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$HostPoolName,

        [Parameter(Mandatory)]
        [string]$SessionHostName,

        [Parameter()]
        [int]$TimeoutMinutes = 30,

        [Parameter()]
        [int]$PollSeconds = 60
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        $count = @(Get-AvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -SessionHostName $SessionHostName).Count
        if ($count -eq 0) { return $true }
        Write-Verbose "  $SessionHostName still has $count session(s). Waiting..."
        Start-Sleep -Seconds $PollSeconds
    } until ((Get-Date) -gt $deadline)
    return $false
}
#endregion

#region Registration token ----------------------------------------------------
#   WHAT   Return the pool's current registration token, generating one only when
#          there is none, it is about to expire, or -Force is set.
#   WHY    A pool has exactly one active token. Generating a new one invalidates the
#          old one, which breaks any session host build that is mid-flight. Reusing
#          a valid token is the safe default.
#   GOTCHA The token is a secret that lets any VM join the pool. It is returned in
#          plain text because the DSC extension needs it that way. Do not log it.
function Get-AvdRegistrationToken {
    <#
    .SYNOPSIS
        Gets a valid registration token for a host pool, creating one if needed.
    .PARAMETER ValidHours
        Lifetime of a newly generated token. 1 to 648 (27 days).
    .PARAMETER MinimumRemainingHours
        Reuse the existing token only if it has at least this long left.
    .PARAMETER Force
        Always generate a new token. Invalidates the previous one.
    .OUTPUTS
        Object with Token and ExpirationTime.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$HostPoolName,

        [Parameter()]
        [ValidateRange(1, 648)]
        [int]$ValidHours = 24,

        [Parameter()]
        [int]$MinimumRemainingHours = 1,

        [Parameter()]
        [switch]$Force
    )
    $nowUtc = (Get-Date).ToUniversalTime()
    $current = Get-AzWvdRegistrationInfo -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -ErrorAction SilentlyContinue

    $isValid = $current -and
        $current.Token -and
        $current.ExpirationTime -and
        ([datetime]$current.ExpirationTime).ToUniversalTime() -gt $nowUtc.AddHours($MinimumRemainingHours)

    if (-not $Force -and $isValid) {
        Write-Verbose "Reusing registration token for $HostPoolName (expires $($current.ExpirationTime))."
        return [pscustomobject]@{ Token = $current.Token; ExpirationTime = $current.ExpirationTime }
    }

    if ($PSCmdlet.ShouldProcess($HostPoolName, "Generate registration token valid $ValidHours h")) {
        Write-Verbose "Generating registration token for $HostPoolName (valid $ValidHours h)."
        $new = New-AzWvdRegistrationInfo -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
            -ExpirationTime $nowUtc.AddHours($ValidHours)
        return [pscustomobject]@{ Token = $new.Token; ExpirationTime = $new.ExpirationTime }
    }
}
#endregion

#region Host VM power ---------------------------------------------------------
#   WHAT   Start, stop (deallocate) and restart the VM behind a session host, by
#          session host name.
#   WHY    Day-to-day operations without the portal. Stop refuses while users are
#          signed in unless -Force, because deallocating a host with sessions is
#          how you lose someone's unsaved work. Deallocate (the default stop) is
#          what stops the compute bill; a stopped-but-provisioned VM still bills.
#   GOTCHA These are the VM lifecycle cmdlets, which take -Name. The extension and
#          Run Command cmdlets take -VMName. tests/Static.Tests.ps1 checks this.
function Get-AvdSessionHostVmReference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$HostPoolName,
        [Parameter(Mandatory)] [string]$SessionHostName
    )
    $sh = Find-AvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -Name $SessionHostName
    if (-not $sh) { throw "Session host '$SessionHostName' not found in $HostPoolName." }
    $ref = Split-AvdVmResourceId $sh.ResourceId
    if (-not $ref.Name) { throw "Session host '$SessionHostName' has no VM resource ID." }
    [pscustomobject]@{ SessionHost = (Resolve-AvdSessionHostName -SessionHostName $sh.Name); ResourceGroupName = $ref.ResourceGroupName; Name = $ref.Name; Sessions = $sh.Session }
}

function Start-AvdSessionHostVm {
    <#
    .SYNOPSIS
        Starts the VM behind a session host.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$HostPoolName,
        [Parameter(Mandatory)] [string]$SessionHostName
    )
    $vm = Get-AvdSessionHostVmReference -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -SessionHostName $SessionHostName
    if ($PSCmdlet.ShouldProcess($vm.Name, 'Start VM')) {
        Write-Verbose "Starting $($vm.Name)."
        $null = Start-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name
    }
    $vm
}

function Stop-AvdSessionHostVm {
    <#
    .SYNOPSIS
        Deallocates the VM behind a session host (stops billing). -StayProvisioned
        powers off without deallocating.
    .PARAMETER Force
        Stop even if users are signed in. Without it the function throws when the
        host has sessions; drain and log off first, or let a rolling restart do it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$HostPoolName,
        [Parameter(Mandatory)] [string]$SessionHostName,
        [Parameter()] [switch]$StayProvisioned,
        [Parameter()] [switch]$Force
    )
    $vm = Get-AvdSessionHostVmReference -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -SessionHostName $SessionHostName
    if ($vm.Sessions -gt 0 -and -not $Force) {
        throw "$($vm.SessionHost) has $($vm.Sessions) user session(s). Drain and log them off first, or pass -Force."
    }
    $what = if ($StayProvisioned) { 'Stop VM (stay provisioned, still billed)' } else { 'Deallocate VM' }
    if ($PSCmdlet.ShouldProcess($vm.Name, $what)) {
        Write-Verbose "$what $($vm.Name)."
        $null = Stop-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Force -StayProvisioned:$StayProvisioned
    }
    $vm
}

function Restart-AvdSessionHostVm {
    <#
    .SYNOPSIS
        Restarts the VM behind a session host. Same session warning as Stop.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$HostPoolName,
        [Parameter(Mandatory)] [string]$SessionHostName,
        [Parameter()] [switch]$Force
    )
    $vm = Get-AvdSessionHostVmReference -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -SessionHostName $SessionHostName
    if ($vm.Sessions -gt 0 -and -not $Force) {
        throw "$($vm.SessionHost) has $($vm.Sessions) user session(s). Drain and log them off first, or pass -Force."
    }
    if ($PSCmdlet.ShouldProcess($vm.Name, 'Restart VM')) {
        Write-Verbose "Restarting $($vm.Name)."
        $null = Restart-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name
    }
    $vm
}
#endregion

#region Price and overview ----------------------------------------------------
#   WHAT   Retail compute price per VM size, and one object that summarises a host
#          pool: settings, host counts, power states, attached scaling plans and
#          an estimated compute bill.
#   WHY    The overview is the first thing a person wants to see, and the two cost
#          numbers (running 24x7 versus business hours) are the argument for a
#          scaling plan in one line.
#   GOTCHA The Azure Retail Prices API is public and needs no sign-in. AVD session
#          hosts run under the Windows_Client license (covered by Microsoft 365), so
#          the compute-only rate, which the API lists without "Windows" in the
#          product name, is the one you pay. Disks, storage and egress are extra.
$script:PriceCache = @{}

function Get-AvdVmRetailPrice {
    <#
    .SYNOPSIS
        Pay-as-you-go compute price in USD per hour for a VM size in a region, or
        $null when the price list is unreachable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string]$VMSize
    )
    $key = "$Location/$VMSize".ToLowerInvariant()
    if ($script:PriceCache.ContainsKey($key)) { return $script:PriceCache[$key] }
    $filter = "serviceName eq 'Virtual Machines' and armRegionName eq '$Location' and armSkuName eq '$VMSize' and priceType eq 'Consumption'"
    $uri = 'https://prices.azure.com/api/retail/prices?$filter=' + [uri]::EscapeDataString($filter)
    $price = $null
    try {
        $items = @((Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop).Items |
            Where-Object { $_.productName -notmatch 'Windows' -and $_.skuName -notmatch 'Spot|Low Priority' -and $_.unitOfMeasure -eq '1 Hour' })
        if ($items.Count -gt 0) {
            $i = $items | Sort-Object retailPrice | Select-Object -First 1
            $price = [pscustomobject]@{ VMSize = $VMSize; Location = $Location; HourlyUsd = [double]$i.retailPrice; Product = $i.productName }
        } else {
            Write-Verbose "No retail price found for $VMSize in $Location."
        }
    } catch {
        Write-Warning "Could not read the Azure retail price list: $($_.Exception.Message)"
    }
    $script:PriceCache[$key] = $price
    return $price
}

function Get-AvdHostPoolOverview {
    <#
    .SYNOPSIS
        Everything about a host pool on one object: settings, host counts, power
        states, scaling plans and estimated monthly compute cost.
    .PARAMETER IncludePrice
        Look up retail prices (one public web call per distinct size). Off, the Cost
        block is empty.
    .OUTPUTS
        Pool, Counts, ScalingPlans, Cost, Hosts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$HostPoolName,
        [Parameter()] [switch]$IncludePrice
    )
    $pool  = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName -ErrorAction Stop
    $hosts = @(Get-AvdSessionHostInfo -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -IncludeVm | Sort-Object Name)

    $agentUpdate = if ("$($pool.AgentUpdateType)" -eq 'Scheduled' -and $pool.AgentUpdateMaintenanceWindow) {
        $w = @($pool.AgentUpdateMaintenanceWindow | ForEach-Object { "$($_.DayOfWeek) $('{0:d2}:00' -f [int]$_.Hour)" }) -join ', '
        $tz = if ($pool.AgentUpdateUseSessionHostLocalTime) { 'host local time' } else { "$($pool.AgentUpdateMaintenanceWindowTimeZone)" }
        "Scheduled: $w ($tz)"
    } else { 'Default (Microsoft decides)' }

    $plans = @()
    try {
        $plans = @(Get-AzWvdScalingPlan -ResourceGroupName $ResourceGroupName -ErrorAction Stop | ForEach-Object {
            $plan = $_
            $ref = @($plan.HostPoolReference | Where-Object { $_.HostPoolArmPath -eq $pool.Id })
            if ($ref.Count -gt 0) {
                $summary = @($plan.Schedule | ForEach-Object {
                    '{0} ({1}): up {2:d2}:{3:d2}, peak {4:d2}:{5:d2}, down {6:d2}:{7:d2}, off {8:d2}:{9:d2}, min {10}%/{11}%' -f $_.Name, (@($_.DaysOfWeek | ForEach-Object { "$_".Substring(0, 3) }) -join ' '),
                        $_.RampUpStartTimeHour, $_.RampUpStartTimeMinute, $_.PeakStartTimeHour, $_.PeakStartTimeMinute,
                        $_.RampDownStartTimeHour, $_.RampDownStartTimeMinute, $_.OffPeakStartTimeHour, $_.OffPeakStartTimeMinute,
                        $_.RampUpMinimumHostsPct, $_.RampDownMinimumHostsPct }) -join '; '
                [pscustomobject]@{ Name = $plan.Name; Enabled = [bool]$ref[0].ScalingPlanEnabled; TimeZone = $plan.TimeZone; Schedules = $summary }
            }
        })
    } catch { Write-Verbose "Scaling plans not read: $($_.Exception.Message)" }

    $cost = $null
    if ($IncludePrice) {
        $hourlyAll = 0.0; $hourlyRunning = 0.0; $priced = 0; $unpriced = @()
        foreach ($h in $hosts) {
            if (-not $h.VMSize -or -not $h.Location) { $unpriced += $h.Name; continue }
            $p = Get-AvdVmRetailPrice -Location $h.Location -VMSize $h.VMSize
            if (-not $p) { $unpriced += $h.Name; continue }
            $priced++
            $hourlyAll += $p.HourlyUsd
            if ($h.PowerState -eq 'running') { $hourlyRunning += $p.HourlyUsd }
        }
        $cost = [pscustomobject]@{
            PricedHosts            = $priced
            UnpricedHosts          = $unpriced
            HourlyRunningUsd       = [math]::Round($hourlyRunning, 3)
            Monthly24x7Usd         = [math]::Round($hourlyAll * 730, 0)            # every host, all month
            MonthlyBusinessHoursUsd = [math]::Round($hourlyAll * 10 * 21, 0)      # 10 h x 21 weekdays: what autoscale aims at
            MonthlyCurrentUsd      = [math]::Round($hourlyRunning * 730, 0)       # if what is running now kept running
            Note                   = 'Compute only, pay-as-you-go, Windows_Client license (M365) so compute-only rate. Disks and storage are extra.'
        }
    }

    [pscustomobject]@{
        Pool = [pscustomobject]@{
            Name = $pool.Name; ResourceGroupName = $ResourceGroupName; Location = $pool.Location; Id = $pool.Id
            Type = "$($pool.HostPoolType)"; LoadBalancer = "$($pool.LoadBalancerType)"; MaxSessionLimit = $pool.MaxSessionLimit
            StartVMOnConnect = [bool]$pool.StartVMOnConnect; ValidationEnvironment = [bool]$pool.ValidationEnvironment
            AgentUpdate = $agentUpdate; CustomRdpProperty = "$($pool.CustomRdpProperty)"
        }
        Counts = [pscustomobject]@{
            Total       = $hosts.Count
            Available   = @($hosts | Where-Object Status -eq 'Available').Count
            Unavailable = @($hosts | Where-Object Status -eq 'Unavailable').Count
            Other       = @($hosts | Where-Object { $_.Status -notin 'Available', 'Unavailable' }).Count
            Drained     = @($hosts | Where-Object Drain).Count
            Sessions    = [int](($hosts | ForEach-Object { [int]$_.Sessions } | Measure-Object -Sum).Sum ?? 0)
            Running     = @($hosts | Where-Object PowerState -eq 'running').Count
            Deallocated = @($hosts | Where-Object PowerState -eq 'deallocated').Count
            Stopped     = @($hosts | Where-Object PowerState -eq 'stopped').Count
            AgentVersions = @($hosts | Select-Object -ExpandProperty AgentVersion -Unique | Where-Object { $_ }) -join ', '
        }
        ScalingPlans = $plans
        Cost         = $cost
        Hosts        = $hosts
    }
}
#endregion

Export-ModuleMember -Function @(
    'Resolve-AvdSessionHostName'
    'Find-AvdSessionHost'
    'Get-AvdSessionHostInfo'
    'Set-AvdSessionHostDrain'
    'Get-AvdUserSession'
    'Send-AvdUserMessage'
    'Remove-AvdUserSession'
    'Wait-AvdSessionHostStatus'
    'Wait-AvdSessionHostEmpty'
    'Get-AvdRegistrationToken'
    'Start-AvdSessionHostVm'
    'Stop-AvdSessionHostVm'
    'Restart-AvdSessionHostVm'
    'Get-AvdVmRetailPrice'
    'Get-AvdHostPoolOverview'
)
