<#
    Operations pages for Start-AvdGui.ps1: Insights (AVD dashboard, reports),
    FinOps (cost management, estimated against actual) and Settings
    (integrations, Azure portal links, logs). Dot-sourced by the main script;
    uses its helpers and $Gui. Read-mostly; the changes (diagnostic settings, a
    Log Analytics workspace, a report file) go through scripts under insights/.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-*/Set-*/Update-* here build or refresh WPF controls. Changes go through the repo scripts, which support -WhatIf.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Handlers and OnDone callbacks have fixed signatures.')]
param()

# --- AVD dashboard ------------------------------------------------------------------
function New-AvdDashboardPage {
    $page = @{ Key = 'NavDashboardAvd'; Tiles = @{}; Form = New-Form; Pools = @() }
    $root = New-PageRoot -Title 'AVD dashboard' -Lead 'Every host pool at a glance, and connection history from Log Analytics for pools that send diagnostics there (Settings, Integrations turns that on).'
    $tiles = [System.Windows.Controls.WrapPanel]::new(); $tiles.Margin = ConvertTo-Thickness '0,0,0,4'
    foreach ($t in @(@('Pools', 'host pools'), @('Hosts', 'session hosts'), @('Available', 'available'), @('Unavailable', 'unavailable'), @('Active', 'active sessions'), @('Disconnected', 'disconnected sessions'))) {
        $tile = New-StatTile -Label $t[1]; $page.Tiles[$t[0]] = $tile.Value; $null = $tiles.Children.Add($tile.Card)
    }
    $null = $root.Children.Add($tiles)
    $page.Grid = New-DataGrid -Height 220
    $page.Grid.SelectionMode = 'Single'
    $actions = @(
        @{ Text = 'Show connection history'; Context = $page; Handler = { param($pg) Invoke-DashboardInsight -Page $pg } }
        @{ Text = 'Open its Home page'; Context = $page; Handler = { param($pg) $s = Get-GridSelection $pg.Grid; if ($s.Count -eq 1) { $i = $Gui.Ui.PoolCombo.Items | Where-Object { "$($_.Tag)".StartsWith("$($s[0].ResourceGroup)|$($s[0].Pool)|") } | Select-Object -First 1; if ($i) { $Gui.Ui.PoolCombo.SelectedItem = $i }; Show-Page 'NavOverview' } } }
    )
    Set-GridRowMenu -Grid $page.Grid -Items $actions
    Add-ControlHandler -Control $page.Grid -EventName DoubleClick -Context $page -Handler { param($pg) Invoke-DashboardInsight -Page $pg }
    $null = $root.Children.Add((New-TableCard -Title 'Host pools' -Grid $page.Grid -Tools @(
        (New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Start-DashboardLoad -Page $pg }),
        (New-MenuButton -Items $actions)) -Note 'Double-click a pool with diagnostics on to load its connection history below.'))
    $null = $root.Children.Add((New-FormSection -Form $page.Form -Title 'History window' -Fields @(
        @{ Name = 'Hours'; Label = 'Look back'; Type = 'combo'; Default = '24'; Options = @(@{ Value = '24'; Label = '24 hours' }, @{ Value = '72'; Label = '3 days' }, @{ Value = '168'; Label = '7 days' }, @{ Value = '720'; Label = '30 days' }) }
    )))
    $page.HourGrid = New-DataGrid -Height 180
    $null = $root.Children.Add((New-TableCard -Title 'Connections per hour' -Grid $page.HourGrid))
    $page.OutcomeGrid = New-DataGrid -Height 90
    $null = $root.Children.Add((New-TableCard -Title 'Connection attempts' -Grid $page.OutcomeGrid -Note '"Never connected" attempts are the ones users saw fail; the errors below say why.'))
    $page.ErrorGrid = New-DataGrid -Height 180
    $null = $root.Children.Add((New-TableCard -Title 'Top errors' -Grid $page.ErrorGrid))
    $page.UserGrid = New-DataGrid -Height 180
    $null = $root.Children.Add((New-TableCard -Title 'Busiest users' -Grid $page.UserGrid))
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Start-DashboardLoad -Page $pg } }
    $page.Root = $root
    return $page
}

function Start-DashboardLoad {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    Start-Work -Name 'Load AVD dashboard' -Context $Page -Script {
        $ErrorActionPreference = 'Stop'
        [pscustomobject]@{ Pools = @(Get-OpsAvdSummary); Workspaces = @(Get-OpsLogWorkspaceInfo) }
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $r = @($result)[-1]
        $pg.Pools = @($r.Pools); $pg.Workspaces = @($r.Workspaces)
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows $pg.Pools -Columns @('Pool', 'Type', 'Hosts', 'Available', 'Unavailable', 'Other', 'Drained', 'Active', 'Disconnected', 'Diagnostics', 'ResourceGroup')).DefaultView
        $sum = { param($n) [int](($pg.Pools | ForEach-Object { [int]$_.$n } | Measure-Object -Sum).Sum ?? 0) }
        $pg.Tiles['Pools'].Text = "$($pg.Pools.Count)"
        foreach ($k in 'Hosts', 'Available', 'Unavailable', 'Active', 'Disconnected') { $pg.Tiles[$k].Text = "$(& $sum $k)" }
        $first = $pg.Pools | Where-Object { $_.Diagnostics -ne 'off' } | Select-Object -First 1
        if ($first) { $pg.Grid.SelectedIndex = [array]::IndexOf(@($pg.Pools), $first); Invoke-DashboardInsight -Page $pg }
        elseif ($pg.Pools.Count -gt 0) { Write-GuiLog 'No host pool sends diagnostics to Log Analytics yet, so there is no connection history. Settings, Integrations turns it on.' 'info' }
    }
}

function Invoke-DashboardInsight {
    param([hashtable]$Page)
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -ne 1) { return }
    if ($sel[0].Diagnostics -eq 'off') { Show-Message "$($sel[0].Pool) sends no diagnostics to Log Analytics. Turn it on in Settings, Integrations." 'AVD dashboard' 'Information'; return }
    $wsName = ($sel[0].Diagnostics -split ',\s*')[0]
    $ws = $Page.Workspaces | Where-Object Name -eq $wsName | Select-Object -First 1
    if (-not $ws) { Write-GuiLog "Workspace $wsName is not visible in this subscription." 'warn'; return }
    Start-Work -Name "Connection history of $($sel[0].Pool)" -Argument @{ WorkspaceId = $ws.WorkspaceId; Pool = $sel[0].Pool; Hours = [int](Get-FormValue $Page.Form 'Hours') } -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        Get-OpsAvdInsight -WorkspaceId $Job.WorkspaceId -HostPoolName $Job.Pool -Hours $Job.Hours
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $r = @($result)[-1]
        $pg.HourGrid.ItemsSource = (ConvertTo-DataTable -Rows @($r.Hourly) -Columns @('Hour', 'Connections', 'Users')).DefaultView
        $pg.OutcomeGrid.ItemsSource = (ConvertTo-DataTable -Rows @($r.Outcome) -Columns @('Outcome', 'Attempts')).DefaultView
        $pg.ErrorGrid.ItemsSource = (ConvertTo-DataTable -Rows @($r.Errors) -Columns @('CodeSymbolic', 'Source', 'Count', 'Users')).DefaultView
        $pg.UserGrid.ItemsSource = (ConvertTo-DataTable -Rows @($r.Users) -Columns @('UserName', 'Connections', 'Hosts')).DefaultView
        if (@($r.Hourly).Count -eq 0) { Write-GuiLog 'No connections in that window (or diagnostics were turned on less than 15 minutes ago).' 'info' }
    }
}

# --- Reports --------------------------------------------------------------------------
function New-ReportsPage {
    $page = @{ Key = 'NavReports'; Form = New-Form }
    $default = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'AzureToolbox' 'reports'
    $root = New-PageRoot -Title 'Reports' -Lead 'One HTML page (and a CSV per table) with the subscription''s host pools, VMs, backups, file shares, networks, cost this month and recent changes. Written to a folder on this computer; keep reports out of git, they hold tenant data.'
    $null = $root.Children.Add((New-FormSection -Form $page.Form -Title 'Report' -Fields @(
        @{ Name = 'Path'; Label = 'Folder'; Default = $default; Span = 2 }
        @{ Name = 'Avd'; Label = 'Host pools'; Type = 'check'; Default = $true }
        @{ Name = 'Vms'; Label = 'Virtual machines'; Type = 'check'; Default = $true }
        @{ Name = 'Backup'; Label = 'Backups'; Type = 'check'; Default = $true }
        @{ Name = 'Storage'; Label = 'File shares'; Type = 'check'; Default = $true }
        @{ Name = 'Network'; Label = 'Networks and public IPs'; Type = 'check'; Default = $true }
        @{ Name = 'Cost'; Label = 'Cost this month'; Type = 'check'; Default = $true }
        @{ Name = 'Changes'; Label = 'Changes (Activity Log)'; Type = 'check'; Default = $true }
        @{ Name = 'ChangeHours'; Label = 'Changes: hours back'; Type = 'int'; Default = 168 }
    )))
    $null = $root.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Generate report' -Style 'PrimaryButton' -Context $page -OnClick { param($pg) Invoke-ReportRun -Page $pg }),
        (New-Button -Text 'Open folder' -Style 'GhostButton' -Context $page -OnClick { param($pg) $d = Get-FormValue $pg.Form 'Path'; if (-not (Test-Path $d)) { $null = New-Item -ItemType Directory -Path $d -Force }; Start-Process explorer.exe $d }))))
    $page.Grid = New-DataGrid -Height 200
    $page.Grid.SelectionMode = 'Single'
    Add-ControlHandler -Control $page.Grid -EventName DoubleClick -Context $page -Handler { param($pg) $s = Get-GridSelection $pg.Grid; if ($s.Count -eq 1) { Start-Process $s[0].Path } }
    $null = $root.Children.Add((New-TableCard -Title 'Reports in the folder' -Grid $page.Grid -Note 'Double-click to open in the browser.'))
    $page.OnShow = { param($pg) Update-ReportList -Page $pg }
    $page.Local = $true
    $page.Root = $root
    return $page
}

function Update-ReportList {
    param([hashtable]$Page)
    $d = Get-FormValue $Page.Form 'Path'
    $rows = @(if (Test-Path $d) { Get-ChildItem $d -Filter 'toolbox-report-*.html' | Sort-Object LastWriteTime -Descending | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Written = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm'); SizeKB = [math]::Round($_.Length / 1KB, 0); Path = $_.FullName } } })
    $Page.Grid.ItemsSource = (ConvertTo-DataTable -Rows $rows -Columns @('Name', 'Written', 'SizeKB', 'Path')).DefaultView
}

function Invoke-ReportRun {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    $f = $Page.Form
    $sections = @('Avd', 'Vms', 'Backup', 'Storage', 'Network', 'Cost', 'Changes' | Where-Object { Get-FormValue $f $_ })
    if ($sections.Count -eq 0) { Show-Message 'Tick at least one section.' 'Report' 'Warning'; return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; Path = (Get-FormValue $f 'Path'); Section = $sections }
    $h = Get-FormValue $f 'ChangeHours'; if ($h) { $p.ChangeHours = $h }
    Invoke-RepoScript -Name 'Generate report' -Path $Gui.Scripts.Report -Params $p -Context $Page -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        Update-ReportList -Page $pg
        $r = @($result | Where-Object { $_ -and $_.PSObject.Properties['Report'] })[-1]
        if ($r) { Start-Process $r.Report }
    }
}

# --- Cost management ----------------------------------------------------------------
function New-CostPage {
    $page = @{ Key = 'NavCosts'; Form = New-Form }
    $root = New-PageRoot -Title 'Cost management' -Lead 'Actual cost from Azure Cost Management for the subscription in the top bar. It lags by up to a day. Needs Cost Management Reader (or Reader) on the subscription.'
    $page.Total = New-StatTile -Label 'total for the period'
    $null = $root.Children.Add($page.Total.Card)
    $null = $root.Children.Add((New-FormSection -Form $page.Form -Title 'Query' -Fields @(
        @{ Name = 'Timeframe'; Label = 'Period'; Type = 'combo'; Default = 'MonthToDate'; Options = @(@{ Value = 'MonthToDate'; Label = 'This month so far' }, @{ Value = 'TheLastMonth'; Label = 'Last month' }) }
        @{ Name = 'GroupBy'; Label = 'Group by'; Type = 'combo'; Default = 'ResourceGroupName'; Options = @(@{ Value = 'ResourceGroupName'; Label = 'Resource group' }, @{ Value = 'ServiceName'; Label = 'Service' }, @{ Value = 'ResourceType'; Label = 'Resource type' }, @{ Value = 'ResourceId'; Label = 'Resource' }) }
    )))
    $null = $root.Children.Add((New-ButtonRow -Buttons @((New-Button -Text 'Run query' -Style 'PrimaryButton' -Context $page -OnClick { param($pg) Start-CostLoad -Page $pg }))))
    $page.Grid = New-DataGrid -Height 260
    $null = $root.Children.Add((New-TableCard -Title 'Cost by group, highest first' -Grid $page.Grid))
    $page.DayGrid = New-DataGrid -Height 220
    $null = $root.Children.Add((New-TableCard -Title 'Cost per day' -Grid $page.DayGrid))
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Start-CostLoad -Page $pg } }
    $page.Root = $root
    return $page
}

function Start-CostLoad {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    Start-Work -Name 'Query Cost Management' -Argument @{ Sub = $Gui.State.SubscriptionId; Timeframe = (Get-FormValue $Page.Form 'Timeframe'); GroupBy = (Get-FormValue $Page.Form 'GroupBy') } -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        [pscustomobject]@{
            Groups = @(Get-OpsCost -SubscriptionId $Job.Sub -Timeframe $Job.Timeframe -GroupBy $Job.GroupBy | Sort-Object Cost -Descending)
            Days   = @(Get-OpsCost -SubscriptionId $Job.Sub -Timeframe $Job.Timeframe -GroupBy Day | Sort-Object Item)
        }
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $r = @($result)[-1]
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows @($r.Groups) -Columns @('Item', 'Cost', 'Currency')).DefaultView
        $pg.DayGrid.ItemsSource = (ConvertTo-DataTable -Rows @($r.Days) -Columns @('Item', 'Cost', 'Currency')).DefaultView
        $total = [math]::Round([double](($r.Groups | ForEach-Object { [double]$_.Cost } | Measure-Object -Sum).Sum ?? 0), 2)
        $cur = @($r.Groups | ForEach-Object Currency | Where-Object { $_ }) | Select-Object -First 1
        $pg.Total.Value.Text = "$total $cur".Trim()
    }
}

function New-CostComparisonPage {
    $page = @{ Key = 'NavCostDiff' }
    $root = New-PageRoot -Title 'Estimated vs deployed' -Lead 'Per host pool: the retail compute estimate (all day, and 10 hours on weekdays as autoscale aims for) against the actual cost so far this month of the resource groups its hosts live in, and that projected to the month''s end. Actual includes disks, storage and networking in those groups, so it sits above a compute-only estimate.'
    $page.Grid = New-DataGrid -Height 280
    $null = $root.Children.Add((New-TableCard -Title 'Host pools' -Grid $page.Grid -Tools @((New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Start-CostComparisonLoad -Page $pg }))))
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Start-CostComparisonLoad -Page $pg } }
    $page.Root = $root
    return $page
}

function Start-CostComparisonLoad {
    param([hashtable]$Page)
    Start-Work -Name 'Compare estimate and actual' -Argument @{ Sub = $Gui.State.SubscriptionId } -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        Get-OpsCostComparison -SubscriptionId $Job.Sub
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows @($result) -Columns @('Pool', 'EstimateAllDayUsd', 'EstimateBusinessHoursUsd', 'ActualMonthToDate', 'ProjectedMonth', 'Currency', 'ResourceGroups')).DefaultView
    }
}

# --- Integrations (diagnostics) -------------------------------------------------------
function New-IntegrationsPage {
    $page = @{ Key = 'NavIntegrations'; Form = New-Form; Workspaces = @() }
    $form = $page.Form
    $root = New-PageRoot -Title 'Integrations' -Lead 'Where AVD sends its diagnostics. With host pools, workspaces and application groups sending to Log Analytics, the AVD dashboard and Azure''s AVD Insights have connection history and errors. The toolbox itself needs nothing else: it talks to Azure with your sign-in.'
    $page.Grid = New-DataGrid -Height 240
    $null = $root.Children.Add((New-TableCard -Title 'AVD resources and their diagnostics' -Grid $page.Grid -Tools @((New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Start-IntegrationLoad -Page $pg })) -Note 'Select rows to configure only those, or leave none selected to configure every AVD resource.'))
    $page.WsGrid = New-DataGrid -Height 140
    $null = $root.Children.Add((New-TableCard -Title 'Log Analytics workspaces' -Grid $page.WsGrid))
    $send = New-FormSection -Form $form -Title 'Send diagnostics' -Subtitle 'Adds a setting named toolbox-avd with every log category; existing settings stay. Pick a workspace, or name a new one.' -Fields @(
        @{ Name = 'Workspace'; Label = 'Existing workspace'; Type = 'combo'; Span = 2 }
        @{ Name = 'NewRg'; Label = 'Or create one in resource group'; Type = 'combo' }
        @{ Name = 'NewName'; Label = 'New workspace name' }
    )
    $Gui.RgCombos.Add($form.Controls['NewRg'])
    $null = $send.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Send diagnostics' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-IntegrationRun -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-IntegrationRun -Page $c.Page -DryRun:$c.DryRun }))))
    $null = $root.Children.Add($send)
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Update-ResourceGroupList -Context $pg -OnDone { param($p) Start-IntegrationLoad -Page $p } } }
    $page.Root = $root
    return $page
}

function Start-IntegrationLoad {
    param([hashtable]$Page)
    Start-Work -Name 'Read diagnostic settings' -Context $Page -Script {
        $ErrorActionPreference = 'Stop'
        [pscustomobject]@{ Resources = @(Get-OpsDiagnosticInfo); Workspaces = @(Get-OpsLogWorkspaceInfo) }
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $r = @($result)[-1]
        $pg.Resources = @($r.Resources); $pg.Workspaces = @($r.Workspaces)
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows $pg.Resources -Columns @('Name', 'Type', 'Workspace', 'Settings', 'ResourceGroupName')).DefaultView
        $pg.WsGrid.ItemsSource = (ConvertTo-DataTable -Rows $pg.Workspaces -Columns @('Name', 'ResourceGroupName', 'Location', 'Sku', 'RetentionDays', 'WorkspaceId')).DefaultView
        Add-ComboOption -Combo $pg.Form.Controls['Workspace'] -Options (@(@{ Value = ''; Label = '(create a new one below)' }) + @($pg.Workspaces | ForEach-Object { @{ Value = $_.Id; Label = "$($_.Name)  ($($_.ResourceGroupName), $($_.Location))" } })) -Default (Get-ComboValue $pg.Form.Controls['Workspace'])
        $off = @($pg.Resources | Where-Object { -not $_.Workspace })
        if ($off.Count -gt 0) { Write-GuiLog "$($off.Count) AVD resource(s) send no diagnostics to Log Analytics." 'info' }
    }
}

function Invoke-IntegrationRun {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $f = $Page.Form
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId }
    $ws = Get-FormValue $f 'Workspace'
    if ($ws) { $p.LogWorkspaceResourceId = $ws }
    else {
        $rg = Get-FormValue $f 'NewRg'; $n = Get-FormValue $f 'NewName'
        if (-not ($rg -and $n)) { Show-Message 'Pick a workspace, or a resource group and a name for a new one.' 'Diagnostics' 'Warning'; return }
        $p.WorkspaceResourceGroupName = $rg; $p.WorkspaceName = $n
    }
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -gt 0) {
        $p.ResourceId = @($sel | ForEach-Object { $s = $_; ($Page.Resources | Where-Object { $_.Name -eq $s.Name -and $_.Type -eq $s.Type -and $_.ResourceGroupName -eq $s.ResourceGroupName } | Select-Object -First 1).ResourceId })
    } else { $p.AllAvdResources = $true }
    Invoke-RepoScript -Name 'Send AVD diagnostics to Log Analytics' -Path $Gui.Scripts.AvdDiagnostic -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Start-IntegrationLoad -Page $pg }
    }
}

# --- Azure portal -----------------------------------------------------------------------
function New-PortalPage {
    $page = @{ Key = 'NavPortal'; Local = $true }
    $root = New-PageRoot -Title 'Azure portal' -Lead 'Shortcuts into the portal for what this window has open: the subscription, the host pool and its resource group, and the portal pages for the things this toolbox leaves to a person (deletes, for one).'
    $page.Body = [System.Windows.Controls.WrapPanel]::new()
    $null = $root.Children.Add($page.Body)
    $page.OnShow = { param($pg) Update-PortalLinkList -Page $pg }
    $page.Root = $root
    return $page
}

function Update-PortalLinkList {
    param([hashtable]$Page)
    $Page.Body.Children.Clear()
    $t = $Gui.State.TenantId; $s = $Gui.State.SubscriptionId
    $base = if ($t) { "https://portal.azure.com/#@$t" } else { 'https://portal.azure.com/#' }
    $groups = [ordered]@{
        'This subscription' = @(
            @{ L = 'Overview'; U = $(if ($s) { "$base/resource/subscriptions/$s/overview" } else { '' }) }
            @{ L = 'Cost analysis'; U = $(if ($s) { "$base/resource/subscriptions/$s/costByResource" } else { '' }) }
            @{ L = 'Activity log'; U = "$base/view/Microsoft_Azure_ActivityLog/ActivityLogBlade" }
            @{ L = 'Resource groups'; U = "$base/browse/resourcegroups" }
        )
        'Current host pool' = @(
            @{ L = 'Host pool'; U = $(if ($s -and $Gui.State.Pool) { "$base/resource/subscriptions/$s/resourceGroups/$($Gui.State.Pool.ResourceGroupName)/providers/Microsoft.DesktopVirtualization/hostPools/$($Gui.State.Pool.Name)/overview" } else { '' }) }
            @{ L = 'Its resource group'; U = $(if ($s -and $Gui.State.Pool) { "$base/resource/subscriptions/$s/resourceGroups/$($Gui.State.Pool.ResourceGroupName)/overview" } else { '' }) }
            @{ L = 'AVD Insights'; U = "$base/view/Microsoft_Azure_WVD/WvdManagerMenuBlade/~/insights" }
        )
        'Admin centers' = @(
            @{ L = 'Azure Virtual Desktop'; U = "$base/view/Microsoft_Azure_WVD/WvdManagerMenuBlade/~/overview" }
            @{ L = 'Entra admin center'; U = 'https://entra.microsoft.com' }
            @{ L = 'Intune (Windows 365)'; U = 'https://intune.microsoft.com' }
            @{ L = 'Backup center'; U = "$base/view/Microsoft_Azure_DataProtection/BackupCenterMenuBlade/~/overview" }
        )
    }
    foreach ($g in $groups.Keys) {
        $card = New-Card -Title $g
        $card.Width = 300; $card.Margin = ConvertTo-Thickness '0,0,16,16'; $card.VerticalAlignment = 'Top'
        foreach ($l in $groups[$g]) {
            $b = New-Button -Text $l.L -Style 'LinkButton' -Context $l.U -OnClick { param($u) Start-Process $u }
            if (-not $l.U) { $b.IsEnabled = $false; $b.ToolTip = 'Sign in and pick a host pool first' } else { $b.ToolTip = $l.U }
            $null = $card.Child.Children.Add($b)
        }
        $null = $Page.Body.Children.Add($card)
    }
}

# --- Logs -----------------------------------------------------------------------------------
function New-LogsPage {
    $page = @{ Key = 'NavLogs'; Form = New-Form }
    $root = New-PageRoot -Title 'Logs' -Lead 'Two logs: this window''s own (the pane at the bottom; save it to a file here), and Azure''s Activity Log of changes in the subscription: who did what, when, and whether it worked.'
    $null = $root.Children.Add((New-ButtonRow -Buttons @((New-Button -Text 'Save the session log to a file...' -Context $page -OnClick { param($pg) Save-SessionLog }))))
    $null = $root.Children.Add((New-FormSection -Form $page.Form -Title 'Activity Log' -Fields @(
        @{ Name = 'Hours'; Label = 'Look back'; Type = 'combo'; Default = '24'; Options = @(@{ Value = '4'; Label = '4 hours' }, @{ Value = '24'; Label = '24 hours' }, @{ Value = '72'; Label = '3 days' }, @{ Value = '168'; Label = '7 days' }, @{ Value = '720'; Label = '30 days' }) }
        @{ Name = 'Rg'; Label = 'Resource group (optional)'; Type = 'combo' }
        @{ Name = 'Caller'; Label = 'Caller (sign-in name, optional)' }
        @{ Name = 'Failed'; Label = 'Failed operations only'; Type = 'check'; Default = $false }
    )))
    $Gui.RgCombos.Add($page.Form.Controls['Rg'])
    $null = $root.Children.Add((New-ButtonRow -Buttons @((New-Button -Text 'Load' -Style 'PrimaryButton' -Context $page -OnClick { param($pg) Start-ActivityLogLoad -Page $pg }))))
    $page.Grid = New-DataGrid -Height 360
    $null = $root.Children.Add((New-TableCard -Title 'Changes (write, delete and action operations)' -Grid $page.Grid))
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Update-ResourceGroupList -Context $pg -OnDone { param($p) Start-ActivityLogLoad -Page $p } } }
    $page.Root = $root
    return $page
}

function Save-SessionLog {
    $d = [Microsoft.Win32.SaveFileDialog]::new()
    $d.Filter = 'Text (*.txt)|*.txt'; $d.FileName = "toolbox-log-$((Get-Date).ToString('yyyyMMdd-HHmm')).txt"
    if ($d.ShowDialog($Gui.Window)) { Set-Content -Path $d.FileName -Value $Gui.Ui.LogBox.Text -Encoding utf8; Write-GuiLog "Log saved to $($d.FileName)." 'ok' }
}

function Start-ActivityLogLoad {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    $f = $Page.Form
    $arg = @{ Hours = [int](Get-FormValue $f 'Hours'); Failed = [bool](Get-FormValue $f 'Failed') }
    $rg = Get-FormValue $f 'Rg'; if ($rg) { $arg.Rg = $rg }
    $c = Get-FormValue $f 'Caller'; if ($c) { $arg.Caller = $c }
    Start-Work -Name 'Read the Activity Log' -Argument $arg -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        $p = @{ Hours = $Job.Hours; FailedOnly = $Job.Failed }
        if ($Job.ContainsKey('Rg')) { $p.ResourceGroupName = $Job.Rg }
        if ($Job.ContainsKey('Caller')) { $p.Caller = $Job.Caller }
        Get-OpsActivityLog @p
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows @($result) -Columns @('Time', 'Caller', 'Operation', 'Status', 'ResourceGroup', 'Resource', 'Level')).DefaultView
        Write-GuiLog "$(@($result).Count) change(s)." 'info'
    }
}
