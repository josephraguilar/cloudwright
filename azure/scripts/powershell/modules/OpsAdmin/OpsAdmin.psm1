#region Module setup ----------------------------------------------------------
#   WHAT   The read-mostly operations views: every host pool at a glance, AVD
#          Insights data from Log Analytics, which AVD resources send diagnostics
#          where, invoiced cost from Cost Management, the retail estimate against
#          that cost, the Activity Log, and an HTML report.
#   WHY    These answer "is everything healthy, what changed, what does it cost"
#          without opening five portal blades.
#   GOTCHA AVD Insights only has data once diagnostics flow to a Log Analytics
#          workspace (Set-OpsAvdDiagnostic); the first rows take about 15 minutes.
#          Cost Management lags by up to a day and throttles hard; queries retry
#          on 429. Nothing here deletes a workspace, a setting or anything else.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:CostApi = '2023-03-01'

function Get-OpsProp {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}
#endregion

#region AVD across pools ------------------------------------------------------
function Get-OpsAvdSummary {
    <#
    .SYNOPSIS
        One row per host pool: hosts by status, drained, active and disconnected
        sessions, and whether diagnostics reach a workspace.
    #>
    [CmdletBinding()]
    param()
    $diag = @{}
    try { foreach ($d in @(Get-OpsDiagnosticInfo)) { if ($d.Type -eq 'Host pool') { $diag[$d.ResourceId] = $d.Workspace } } }
    catch { Write-Verbose "Diagnostic settings not read: $($_.Exception.Message)" }
    foreach ($pool in @(Get-AzWvdHostPool) | Sort-Object Name) {
        $rg = ($pool.Id -split '/')[4]
        $hosts = @(Get-AzWvdSessionHost -ResourceGroupName $rg -HostPoolName $pool.Name -ErrorAction SilentlyContinue)
        $sessions = @(Get-AzWvdUserSession -ResourceGroupName $rg -HostPoolName $pool.Name -ErrorAction SilentlyContinue)
        [pscustomobject]@{
            Pool         = $pool.Name
            ResourceGroup = $rg
            Type         = "$($pool.HostPoolType)"
            Hosts        = $hosts.Count
            Available    = @($hosts | Where-Object { "$($_.Status)" -eq 'Available' }).Count
            Unavailable  = @($hosts | Where-Object { "$($_.Status)" -eq 'Unavailable' }).Count
            Other        = @($hosts | Where-Object { "$($_.Status)" -notin 'Available', 'Unavailable' }).Count
            Drained      = @($hosts | Where-Object { -not $_.AllowNewSession }).Count
            Active       = @($sessions | Where-Object { "$($_.SessionState)" -eq 'Active' }).Count
            Disconnected = @($sessions | Where-Object { "$($_.SessionState)" -eq 'Disconnected' }).Count
            Diagnostics  = $(if ($diag.ContainsKey($pool.Id) -and $diag[$pool.Id]) { $diag[$pool.Id] } else { 'off' })
            Location     = $pool.Location
            Id           = $pool.Id
        }
    }
}
#endregion

#region Diagnostics and Log Analytics -------------------------------------------
function Get-OpsLogWorkspaceInfo {
    <#
    .SYNOPSIS
        Log Analytics workspaces with retention and the workspace (customer) ID.
    #>
    [CmdletBinding()]
    param()
    foreach ($w in @(Get-AzOperationalInsightsWorkspace) | Sort-Object ResourceGroupName, Name) {
        [pscustomobject]@{
            Name = $w.Name; ResourceGroupName = $w.ResourceGroupName; Location = $w.Location
            Sku = "$($w.Sku)"; RetentionDays = $w.RetentionInDays; WorkspaceId = "$($w.CustomerId)"; Id = $w.ResourceId
        }
    }
}

function Get-OpsDiagnosticInfo {
    <#
    .SYNOPSIS
        Every AVD host pool, workspace and application group with the Log
        Analytics workspace its diagnostics go to (empty = none).
    #>
    [CmdletBinding()]
    param()
    $types = @(
        @{ Type = 'Host pool'; Rt = 'Microsoft.DesktopVirtualization/hostPools' }
        @{ Type = 'Workspace'; Rt = 'Microsoft.DesktopVirtualization/workspaces' }
        @{ Type = 'Application group'; Rt = 'Microsoft.DesktopVirtualization/applicationGroups' }
    )
    foreach ($t in $types) {
        foreach ($r in @(Get-AzResource -ResourceType $t.Rt -ErrorAction SilentlyContinue) | Sort-Object ResourceGroupName, Name) {
            $settings = @(try { Get-AzDiagnosticSetting -ResourceId $r.ResourceId -ErrorAction Stop } catch { @() })
            $ws = @($settings | Where-Object { Get-OpsProp $_ 'WorkspaceId' } | ForEach-Object { ((Get-OpsProp $_ 'WorkspaceId') -split '/')[-1] })
            [pscustomobject]@{
                Name = $r.Name; Type = $t.Type; ResourceGroupName = $r.ResourceGroupName
                Workspace = ($ws -join ', '); Settings = (@($settings | ForEach-Object { $_.Name }) -join ', '); ResourceId = $r.ResourceId
            }
        }
    }
}

function New-OpsLogWorkspace {
    <#
    .SYNOPSIS
        A pay-as-you-go Log Analytics workspace. Returns the existing one untouched.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{2,61}[A-Za-z0-9]$')] [string]$Name,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter()] [ValidateRange(30, 730)] [int]$RetentionDays = 30
    )
    $w = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
    if ($w) { Write-Verbose "Workspace $Name exists."; return $w }
    if (-not $PSCmdlet.ShouldProcess($Name, "Create Log Analytics workspace (PerGB2018, $RetentionDays days)")) { return }
    Write-Verbose "Creating workspace $Name."
    return New-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $Name -Location $Location -Sku PerGB2018 -RetentionInDays $RetentionDays
}

function Set-OpsAvdDiagnostic {
    <#
    .SYNOPSIS
        Send every log category of an AVD host pool, workspace or application group
        to a Log Analytics workspace (a diagnostic setting named toolbox-avd).
        Other settings on the resource stay as they are.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceId,
        [Parameter(Mandatory)] [ValidatePattern('/providers/Microsoft\.OperationalInsights/workspaces/')] [string]$LogWorkspaceResourceId,
        [Parameter()] [string]$Name = 'toolbox-avd'
    )
    if (-not $PSCmdlet.ShouldProcess(($ResourceId -split '/')[-1], "Send all logs to $(($LogWorkspaceResourceId -split '/')[-1])")) { return }
    $log = New-AzDiagnosticSettingLogSettingsObject -Enabled $true -CategoryGroup 'allLogs'
    Write-Verbose "Diagnostic setting $Name on $(($ResourceId -split '/')[-1])."
    $null = New-AzDiagnosticSetting -Name $Name -ResourceId $ResourceId -WorkspaceId $LogWorkspaceResourceId -Log $log
    [pscustomobject]@{ Resource = ($ResourceId -split '/')[-1]; Setting = $Name; Workspace = ($LogWorkspaceResourceId -split '/')[-1] }
}

function Invoke-OpsLogQuery {
    param([string]$WorkspaceId, [string]$Query)
    $r = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $Query -ErrorAction Stop
    return @($r.Results)
}

function Get-OpsAvdInsight {
    <#
    .SYNOPSIS
        AVD Insights from a Log Analytics workspace: connections per hour, top
        errors, busiest users, and connection success, for the last -Hours hours.
        -HostPoolName narrows it to one pool.
    .PARAMETER WorkspaceId
        The workspace (customer) ID, a GUID; Get-OpsLogWorkspaceInfo lists it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [guid]$WorkspaceId,
        [Parameter()] [ValidateRange(1, 720)] [int]$Hours = 24,
        [Parameter()] [ValidatePattern('^[A-Za-z0-9._-]*$')] [string]$HostPoolName
    )
    $pool = if ($HostPoolName) { "| where _ResourceId has '/hostpools/$($HostPoolName.ToLower())'" } else { '' }
    $since = "ago($($Hours)h)"
    $ws = "$WorkspaceId"
    [pscustomobject]@{
        Hourly = @(Invoke-OpsLogQuery $ws "WVDConnections | where TimeGenerated > $since $pool | where State == 'Connected' | summarize Connections = dcount(CorrelationId), Users = dcount(UserName) by Hour = bin(TimeGenerated, 1h) | order by Hour asc")
        Errors = @(Invoke-OpsLogQuery $ws "WVDErrors | where TimeGenerated > $since $pool | summarize Count = count(), Users = dcount(UserName) by CodeSymbolic, Source | top 15 by Count desc")
        Users  = @(Invoke-OpsLogQuery $ws "WVDConnections | where TimeGenerated > $since $pool | where State == 'Connected' | summarize Connections = dcount(CorrelationId), Hosts = make_set(SessionHostName, 5) by UserName | top 15 by Connections desc")
        Outcome = @(Invoke-OpsLogQuery $ws "WVDConnections | where TimeGenerated > $since $pool | summarize States = make_set(State) by CorrelationId | extend Outcome = iff(States has 'Connected', 'Connected', 'Never connected') | summarize Attempts = count() by Outcome")
    }
}
#endregion

#region Cost ------------------------------------------------------------------
function Invoke-OpsCostQuery {
    <#
    .SYNOPSIS
        One Cost Management query on a scope (subscription or resource group ID),
        returned as rows with one property per column. Retries when throttled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Scope,
        [Parameter(Mandatory)] [hashtable]$Body
    )
    $path = "$($Scope.TrimEnd('/'))/providers/Microsoft.CostManagement/query?api-version=$script:CostApi"
    $rows = [System.Collections.Generic.List[object]]::new()
    $attempt = 0
    while ($path) {
        $resp = Invoke-AzRestMethod -Method POST -Path $path -Payload ($Body | ConvertTo-Json -Depth 10 -Compress)
        if ($resp.StatusCode -eq 429 -and $attempt -lt 4) { $attempt++; Write-Verbose 'Cost Management is throttling; waiting 20 seconds.'; Start-Sleep -Seconds 20; continue }
        if ($resp.StatusCode -ge 300) {
            $msg = $resp.Content; try { $msg = ($resp.Content | ConvertFrom-Json).error.message } catch { Write-Verbose 'Error body was not JSON.' }
            throw "Cost query returned $($resp.StatusCode): $msg"
        }
        $data = $resp.Content | ConvertFrom-Json
        $cols = @($data.properties.columns | ForEach-Object { $_.name })
        foreach ($r in @($data.properties.rows)) {
            $o = [ordered]@{}
            for ($i = 0; $i -lt $cols.Count; $i++) { $o[$cols[$i]] = $r[$i] }
            $rows.Add([pscustomobject]$o)
        }
        $next = Get-OpsProp $data.properties 'nextLink'
        $path = if ($next) { ([uri]$next).PathAndQuery } else { $null }
    }
    return $rows.ToArray()
}

function Get-OpsCost {
    <#
    .SYNOPSIS
        Actual (invoiced) cost for a subscription or resource group: by resource
        group, service or resource, or per day.
    .PARAMETER Timeframe
        MonthToDate, TheLastMonth, or Custom with -From and -To.
    .PARAMETER GroupBy
        ResourceGroupName, ServiceName, ResourceType, ResourceId, or Day.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter()] [string]$ResourceGroupName,
        [Parameter()] [ValidateSet('MonthToDate', 'TheLastMonth', 'Custom')] [string]$Timeframe = 'MonthToDate',
        [Parameter()] [datetime]$From,
        [Parameter()] [datetime]$To,
        [Parameter()] [ValidateSet('ResourceGroupName', 'ServiceName', 'ResourceType', 'ResourceId', 'Day')] [string]$GroupBy = 'ResourceGroupName'
    )
    $scope = "/subscriptions/$SubscriptionId" + $(if ($ResourceGroupName) { "/resourceGroups/$ResourceGroupName" } else { '' })
    $dataset = @{ granularity = $(if ($GroupBy -eq 'Day') { 'Daily' } else { 'None' }); aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } } }
    if ($GroupBy -ne 'Day') { $dataset.grouping = @(@{ type = 'Dimension'; name = $GroupBy }) }
    $body = @{ type = 'ActualCost'; timeframe = $Timeframe; dataset = $dataset }
    if ($Timeframe -eq 'Custom') {
        if (-not $From -or -not $To) { throw 'Custom needs -From and -To.' }
        $body.timePeriod = @{ from = $From.ToString('yyyy-MM-ddT00:00:00Z'); to = $To.ToString('yyyy-MM-ddT23:59:59Z') }
    }
    try { $rows = @(Invoke-OpsCostQuery -Scope $scope -Body $body) }
    catch {
        # Some agreement types name the column PreTaxCost.
        if ($_.Exception.Message -notmatch ' 400') { throw }
        $dataset.aggregation = @{ totalCost = @{ name = 'PreTaxCost'; function = 'Sum' } }
        $rows = @(Invoke-OpsCostQuery -Scope $scope -Body $body)
    }
    foreach ($r in $rows) {
        $cost = [double](Get-OpsProp $r 'Cost' (Get-OpsProp $r 'PreTaxCost' 0))
        $key = if ($GroupBy -eq 'Day') { $d = "$(Get-OpsProp $r 'UsageDate' '')"; if ($d.Length -eq 8) { "$($d.Substring(0,4))-$($d.Substring(4,2))-$($d.Substring(6,2))" } else { $d } } else { "$(Get-OpsProp $r $GroupBy '')" }
        if ($GroupBy -eq 'ResourceId') { $key = ($key -split '/')[-1] }
        [pscustomobject]@{ Item = $(if ($key) { $key } else { '(none)' }); Cost = [math]::Round($cost, 2); Currency = "$(Get-OpsProp $r 'Currency' '')" }
    }
}

function Get-OpsCostComparison {
    <#
    .SYNOPSIS
        Per host pool: the retail compute estimate against the actual month-to-date
        cost of the resource groups its hosts live in, and that actual projected to
        a full month. Needs AvdHelpers loaded (Get-AvdHostPoolOverview).
    .NOTES
        The actual figure covers everything in those resource groups (disks,
        storage, networking), so it is expected to sit above the compute estimate.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$SubscriptionId)
    if (-not (Get-Command Get-AvdHostPoolOverview -ErrorAction SilentlyContinue)) { throw 'Import AvdHelpers first: the estimate comes from Get-AvdHostPoolOverview.' }
    $byRg = @{}
    foreach ($c in @(Get-OpsCost -SubscriptionId $SubscriptionId -Timeframe MonthToDate -GroupBy ResourceGroupName)) { $byRg[$c.Item.ToLower()] = $c }
    $now = Get-Date
    $daysIn = [datetime]::DaysInMonth($now.Year, $now.Month)
    $elapsed = [math]::Max(1, $now.Day - 1 + $now.TimeOfDay.TotalDays)
    foreach ($pool in @(Get-AzWvdHostPool) | Sort-Object Name) {
        $rg = ($pool.Id -split '/')[4]
        $o = Get-AvdHostPoolOverview -ResourceGroupName $rg -HostPoolName $pool.Name -IncludePrice
        $rgs = @(@($rg) + @($o.Hosts | ForEach-Object { Get-OpsProp $_ 'VMResourceGroup' } | Where-Object { $_ }) | ForEach-Object { $_.ToLower() } | Select-Object -Unique)
        $actual = [double](($rgs | ForEach-Object { if ($byRg.ContainsKey($_)) { $byRg[$_].Cost } else { 0 } } | Measure-Object -Sum).Sum ?? 0)
        $currency = @($rgs | Where-Object { $byRg.ContainsKey($_) } | ForEach-Object { $byRg[$_].Currency }) | Select-Object -First 1
        [pscustomobject]@{
            Pool                  = $pool.Name
            ResourceGroups        = ($rgs -join ', ')
            EstimateAllDayUsd     = $(if ($o.Cost) { $o.Cost.Monthly24x7Usd } else { $null })
            EstimateBusinessHoursUsd = $(if ($o.Cost) { $o.Cost.MonthlyBusinessHoursUsd } else { $null })
            ActualMonthToDate     = [math]::Round($actual, 2)
            ProjectedMonth        = [math]::Round($actual / $elapsed * $daysIn, 2)
            Currency              = $(if ($currency) { $currency } else { '' })
        }
    }
}
#endregion

#region Activity log and reports ----------------------------------------------
function Get-OpsActivityLog {
    <#
    .SYNOPSIS
        Who changed what: Activity Log write and delete operations of the last
        -Hours hours, newest first. Filters by resource group, caller, failures.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [ValidateRange(1, 2160)] [int]$Hours = 24,
        [Parameter()] [string]$ResourceGroupName,
        [Parameter()] [string]$Caller,
        [Parameter()] [switch]$FailedOnly,
        [Parameter()] [ValidateRange(10, 5000)] [int]$Max = 500
    )
    $p = @{ StartTime = (Get-Date).AddHours(-$Hours); EndTime = (Get-Date); MaxRecord = $Max; WarningAction = 'SilentlyContinue' }
    if ($ResourceGroupName) { $p.ResourceGroupName = $ResourceGroupName }
    if ($Caller) { $p.Caller = $Caller }
    foreach ($e in @(Get-AzActivityLog @p)) {
        $op = "$(Get-OpsProp (Get-OpsProp $e 'OperationName') 'LocalizedValue' (Get-OpsProp $e 'OperationName' ''))"
        $opId = "$(Get-OpsProp (Get-OpsProp $e 'OperationName') 'Value' '')"
        if ($opId -and $opId -notmatch '/(write|delete|action)$') { continue }
        $status = "$(Get-OpsProp (Get-OpsProp $e 'Status') 'Value' (Get-OpsProp $e 'Status' ''))"
        if ($FailedOnly -and $status -ne 'Failed') { continue }
        if ($status -in 'Started', 'Accepted') { continue }
        $ts = Get-OpsProp $e 'EventTimestamp'
        [pscustomobject]@{
            Time = $(if ($ts) { ([datetime]$ts).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } else { '' })
            Caller = "$(Get-OpsProp $e 'Caller' '')"; Operation = $op; Status = $status
            ResourceGroup = "$(Get-OpsProp $e 'ResourceGroupName' '')"; Resource = ("$(Get-OpsProp $e 'ResourceId' '')" -split '/')[-1]
            Level = "$(Get-OpsProp $e 'Level' '')"
        }
    }
}

function ConvertTo-OpsHtmlReport {
    <#
    .SYNOPSIS
        A self-contained HTML page from named tables. Values are HTML-encoded.
    .PARAMETER Section
        Ordered hashtable: section title -> rows (objects).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a string; changes nothing.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Section,
        [Parameter()] [string]$Subtitle
    )
    $enc = { param($v) [System.Net.WebUtility]::HtmlEncode("$v") }
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.Append("<!doctype html><html lang='en'><head><meta charset='utf-8'><title>$(& $enc $Title)</title><style>")
    $null = $sb.Append('body{font-family:Segoe UI,Arial,sans-serif;color:#1e293b;margin:24px;background:#f8fafc}h1{margin:0 0 4px}p.sub{color:#475569;margin:0 0 24px}')
    $null = $sb.Append('h2{margin:28px 0 8px;font-size:18px}table{border-collapse:collapse;width:100%;background:#fff;font-size:13px}th{background:#1e9db8;color:#fff;text-align:left;padding:6px 8px}')
    $null = $sb.Append('td{border-top:1px solid #e2e8f0;padding:5px 8px;vertical-align:top}p.none{color:#64748b}</style></head><body>')
    $null = $sb.Append("<h1>$(& $enc $Title)</h1><p class='sub'>$(& $enc $Subtitle)</p>")
    foreach ($k in $Section.Keys) {
        $rows = @($Section[$k] | Where-Object { $null -ne $_ })
        $null = $sb.Append("<h2>$(& $enc $k) ($($rows.Count))</h2>")
        if ($rows.Count -eq 0) { $null = $sb.Append("<p class='none'>None.</p>"); continue }
        $cols = @($rows[0].PSObject.Properties.Name)
        $null = $sb.Append('<table><tr>')
        foreach ($c in $cols) { $null = $sb.Append("<th>$(& $enc $c)</th>") }
        $null = $sb.Append('</tr>')
        foreach ($r in $rows) {
            $null = $sb.Append('<tr>')
            foreach ($c in $cols) { $v = $r.PSObject.Properties[$c]; $null = $sb.Append("<td>$(& $enc $(if ($v) { (@($v.Value) -join ', ') } else { '' }))</td>") }
            $null = $sb.Append('</tr>')
        }
        $null = $sb.Append('</table>')
    }
    $null = $sb.Append('</body></html>')
    return $sb.ToString()
}
#endregion
