<#
    Scripting pages for Start-AvdGui.ps1: Windows scripts (the in-guest library),
    script groups, Azure runbooks and runbook groups. Dot-sourced by the main
    script; uses its helpers, $Gui and the shared target picker from Apps.ps1.
    Scripts run through apps/Invoke-GuestScript.ps1; runbooks through
    automation/*.ps1. Groups live in toolbox.local.json. Nothing here deletes.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-*/Set-*/Update-* here build or refresh WPF controls. Changes go through the repo scripts, which support -WhatIf.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Handlers and OnDone callbacks have fixed signatures.')]
param()

# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

function ConvertFrom-ParameterText {
    # "Name = value" per line (or name=value) into a hashtable; blank lines and # comments skipped.
    param([string]$Text)
    $h = @{}
    foreach ($line in ($Text -split "`r?`n")) {
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        $i = $l.IndexOf('=')
        if ($i -lt 1) { throw "Parameter line '$l' needs the form Name = value." }
        $h[$l.Substring(0, $i).Trim()] = $l.Substring($i + 1).Trim()
    }
    return $h
}

# --- Windows scripts --------------------------------------------------------------
function New-WindowsScriptsPage {
    $page = @{ Key = 'NavScripts'; Form = New-Form; Library = @() }
    $root = New-PageRoot -Title 'Windows scripts' -Lead 'Scripts that run inside VMs as SYSTEM through a managed Run Command, on every target at once. The list is scripts/powershell/library: windows/ ships with the repo, local/ is yours (gitignored).'
    $page.Grid = New-DataGrid -Height 220
    $page.Grid.SelectionMode = 'Single'
    Add-ControlHandler -Control $page.Grid -EventName SelectionChanged -Context $page -Handler { param($pg) Update-ScriptParameterHint -Page $pg }
    $null = $root.Children.Add((New-TableCard -Title 'Script library' -Grid $page.Grid -Tools @(
        (New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Start-ScriptLibraryLoad -Page $pg }),
        (New-ToolButton -Text 'Open local folder' -ToolTip 'Your own scripts go here' -OnClick { $d = Join-Path $Gui.GuiDir '..' 'library' 'local'; if (-not (Test-Path $d)) { $null = New-Item -ItemType Directory -Path $d }; Start-Process explorer.exe (Resolve-Path $d) }))))
    $null = $root.Children.Add((New-FormSection -Form $page.Form -Title 'Parameters' -Subtitle 'One per line, Name = value. Selecting a script fills in its parameters and defaults.' -Fields @(
        @{ Name = 'Params'; Label = 'Parameters'; Type = 'multiline'; Span = 2 }
    )))
    $page.Targets = New-TargetPicker
    $null = $root.Children.Add($page.Targets.Card)
    $null = $root.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Run script' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-WindowsScriptRun -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-WindowsScriptRun -Page $c.Page -DryRun:$c.DryRun }))))
    $page.ResultGrid = New-DataGrid -Height 240
    $null = $root.Children.Add((New-TableCard -Title 'Results' -Grid $page.ResultGrid -Note 'The last 4 KB of output per VM. The full output is in the log pane.'))
    $page.OnShow = { param($pg) if (-not $Gui.State.Busy) { Start-ScriptLibraryLoad -Page $pg } }
    $page.Root = $root
    return $page
}

function Start-ScriptLibraryLoad {
    param([hashtable]$Page)
    Start-Work -Name 'Read the script library' -Context $Page -Script {
        $ErrorActionPreference = 'Stop'
        Get-GuestScriptLibrary
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.Library = @($result)
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows $pg.Library -Columns @('Name', 'Synopsis', 'Parameters', 'Source')).DefaultView
        if ($Gui.State.Account -and $pg.ContainsKey('Targets') -and $pg.Targets.Grid.Items.Count -eq 0) { Start-TargetPickerLoad -Picker $pg.Targets }
    }
}

function Update-ScriptParameterHint {
    param([hashtable]$Page)
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -ne 1) { return }
    $lines = @(Split-CommaList $sel[0].Parameters | ForEach-Object { if ($_ -match '=') { $_ -replace '=', ' = ' } else { "$_ = " } })
    Set-FormValue $Page.Form 'Params' ($lines -join [Environment]::NewLine)
}

function Invoke-WindowsScriptRun {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -ne 1) { Show-Message 'Select one script.' 'Scripts' 'Warning'; return }
    try { $params = ConvertFrom-ParameterText (Get-FormValue $Page.Form 'Params') } catch { Show-Message $_.Exception.Message 'Parameters' 'Warning'; return }
    foreach ($k in @($params.Keys)) { if ("$($params[$k])" -eq '') { $params.Remove($k) } }
    $t = Get-TargetPickerParameter -Picker $Page.Targets
    if (-not $t) { return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ScriptName = $sel[0].Name; Parameter = $params } + $t
    Invoke-RepoScript -Name "Run $($sel[0].Name)" -Path $Gui.Scripts.GuestScript -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Show-InGuestResult -Grid $pg.ResultGrid -Result @($result) -First 'Script' }
    }
}

# --- Script groups ----------------------------------------------------------------
function New-ScriptGroupsPage {
    $page = @{ Key = 'NavScriptGroups'; Form = New-Form }
    $root = New-PageRoot -Title 'Script groups' -Lead 'Library scripts run in order, each on every target, stopping at the first script that fails on any VM. Scripts run with their default parameters. Kept in toolbox.local.json.'
    $page.ListGrid = New-DataGrid -Height 180
    $page.ListGrid.SelectionMode = 'Single'
    Add-ControlHandler -Control $page.ListGrid -EventName SelectionChanged -Context $page -Handler { param($pg) Update-ScriptGroupForm -Page $pg }
    $null = $root.Children.Add((New-TableCard -Title 'Script groups' -Grid $page.ListGrid -Tools @((New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Start-ScriptGroupLoad -Page $pg }))))
    $edit = New-FormSection -Form $page.Form -Title 'Script group' -Subtitle 'Script names from the Windows scripts page, one per line, in running order.' -Fields @(
        @{ Name = 'Name'; Label = 'Name'; Required = $true }
        @{ Name = 'Scripts'; Label = 'Scripts in order'; Type = 'multiline'; Required = $true; Span = 2 }
    )
    $null = $edit.Child.Children.Add((New-ButtonRow -Buttons @((New-Button -Text 'Save group' -Style 'PrimaryButton' -Context $page -OnClick { param($pg) Invoke-ScriptGroupSave -Page $pg }))))
    $null = $root.Children.Add($edit)
    $page.Targets = New-TargetPicker
    $null = $root.Children.Add($page.Targets.Card)
    $null = $root.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Run group' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-ScriptGroupRun -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-ScriptGroupRun -Page $c.Page -DryRun:$c.DryRun }))))
    $page.Grid = New-DataGrid -Height 240
    $null = $root.Children.Add((New-TableCard -Title 'Results' -Grid $page.Grid))
    $page.OnShow = { param($pg) if (-not $Gui.State.Busy) { Start-ScriptGroupLoad -Page $pg } }
    $page.Root = $root
    return $page
}

function Start-ScriptGroupLoad {
    param([hashtable]$Page)
    Start-ToolboxStoreLoad -Context $Page -OnDone {
        param($store, $pg)
        $pg.Store = $store
        $pg.ListGrid.ItemsSource = (ConvertTo-DataTable -Rows @(ConvertTo-StoreRow -Section $store.ScriptGroups -Fields @('Scripts', 'Saved')) -Columns @('Name', 'Scripts', 'Saved')).DefaultView
        if ($Gui.State.Account -and $pg.Targets.Grid.Items.Count -eq 0) { Start-TargetPickerLoad -Picker $pg.Targets }
    }
}

function Update-ScriptGroupForm {
    param([hashtable]$Page)
    $sel = Get-GridSelection $Page.ListGrid
    if ($sel.Count -ne 1 -or -not $Page.ContainsKey('Store')) { return }
    Set-FormValue $Page.Form 'Name' $sel[0].Name
    Set-FormValue $Page.Form 'Scripts' ((@($Page.Store.ScriptGroups[$sel[0].Name]['Scripts']) | Where-Object { $_ }) -join [Environment]::NewLine)
}

function Invoke-ScriptGroupSave {
    param([hashtable]$Page)
    if (-not (Test-FormRequired -Form $Page.Form)) { return }
    Save-ToolboxItem -Kind 'ScriptGroups' -Name (Get-FormValue $Page.Form 'Name') -Value @{ Scripts = @(Split-CommaList (Get-FormValue $Page.Form 'Scripts')) } -Context $Page -OnDone { param($pg) Start-ScriptGroupLoad -Page $pg }
}

function Invoke-ScriptGroupRun {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $sel = Get-GridSelection $Page.ListGrid
    if ($sel.Count -ne 1) { Show-Message 'Select a saved script group.' 'Script groups' 'Warning'; return }
    $t = Get-TargetPickerParameter -Picker $Page.Targets
    if (-not $t) { return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ScriptGroup = $sel[0].Name } + $t
    Invoke-RepoScript -Name "Run script group $($sel[0].Name)" -Path $Gui.Scripts.GuestScript -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Show-InGuestResult -Grid $pg.Grid -Result @($result) -First 'Script' }
    }
}

# --- Runbooks ---------------------------------------------------------------------
function New-RunbooksPage {
    $page = @{ Key = 'NavRunbooks'; Form = New-Form; Accounts = @() }
    $form = $page.Form
    $root = New-PageRoot -Title 'Azure runbooks' -Lead 'Runbooks in an Automation account, the last jobs and their output. Start one now (waiting for the output if you like), or import one of the repo''s runbooks/ as a new runbook.'
    $pick = New-FormSection -Form $form -Title 'Automation account' -Fields @(@{ Name = 'Account'; Label = 'Account'; Type = 'combo'; Span = 2 })
    Add-ControlHandler -Control $form.Controls['Account'] -EventName SelectionChanged -Context $page -Handler { param($pg) if (-not $Gui.State.SuppressEvents -and -not $Gui.State.Busy -and (Get-FormValue $pg.Form 'Account')) { Start-RunbookLoad -Page $pg } }
    $null = $root.Children.Add($pick)
    $page.Grid = New-DataGrid -Height 200
    $page.Grid.SelectionMode = 'Single'
    $null = $root.Children.Add((New-TableCard -Title 'Runbooks' -Grid $page.Grid -Tools @((New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Start-RunbookLoad -Page $pg }))))
    $page.JobGrid = New-DataGrid -Height 180
    $page.JobGrid.SelectionMode = 'Single'
    $jobActions = @(@{ Text = 'Show output in the log'; Context = $page; Handler = { param($pg) Invoke-RunbookJobOutput -Page $pg } })
    Set-GridRowMenu -Grid $page.JobGrid -Items $jobActions
    Add-ControlHandler -Control $page.JobGrid -EventName DoubleClick -Context $page -Handler { param($pg) Invoke-RunbookJobOutput -Page $pg }
    $null = $root.Children.Add((New-TableCard -Title 'Jobs, last 72 hours' -Grid $page.JobGrid -Tools @((New-MenuButton -Items $jobActions)) -Note 'Double-click a job to see its output in the log.'))
    $start = New-FormSection -Form $form -Title 'Start the selected runbook' -Fields @(
        @{ Name = 'RbParams'; Label = 'Parameters (Name = value per line)'; Type = 'multiline'; Span = 2 }
        @{ Name = 'RbWait'; Label = 'Wait for it and show the output'; Type = 'check'; Default = $true }
    )
    $null = $start.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Start runbook' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-RunbookStart -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-RunbookStart -Page $c.Page -DryRun:$c.DryRun }))))
    $null = $root.Children.Add($start)
    $runbookDir = Join-Path $Gui.GuiDir '..' '..' '..' 'runbooks'
    $files = @(if (Test-Path $runbookDir) { Get-ChildItem $runbookDir -Filter '*.ps1' | ForEach-Object { @{ Value = $_.FullName; Label = "runbooks/$($_.Name)" } } })
    $imp = New-FormSection -Form $form -Title 'Import a runbook' -Subtitle 'As a new PowerShell 7.2 runbook, published. An existing name is refused, not overwritten.' -Fields @(
        @{ Name = 'ImpFile'; Label = 'File'; Type = 'combo'; Editable = $true; Options = $files; Span = 2 }
        @{ Name = 'ImpName'; Label = 'Runbook name (empty = file name)' }
    )
    $null = $imp.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Browse...' -Style 'GhostButton' -Context $page -OnClick { param($pg) $f = Show-OpenFileDialog -Filter 'PowerShell (*.ps1)|*.ps1'; if ($f) { Set-FormValue $pg.Form 'ImpFile' $f } }),
        (New-Button -Text 'Import' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-RunbookImport -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-RunbookImport -Page $c.Page -DryRun:$c.DryRun }))))
    $null = $root.Children.Add($imp)
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Start-RunbookAccountLoad -Page $pg } }
    $page.Root = $root
    return $page
}

function Start-RunbookAccountLoad {
    param([hashtable]$Page)
    Start-Work -Name 'List Automation accounts' -Context $Page -Script {
        $ErrorActionPreference = 'Stop'
        Get-RunbookAccountInfo
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.Accounts = @($result)
        $c = $pg.Form.Controls['Account']
        $Gui.State.SuppressEvents = $true
        try { Add-ComboOption -Combo $c -Options @($pg.Accounts | ForEach-Object { @{ Value = $_.Id; Label = "$($_.Name)  ($($_.ResourceGroupName), $($_.Location))" } }) -Default (Get-ComboValue $c) }
        finally { $Gui.State.SuppressEvents = $false }
        if ($pg.Accounts.Count -eq 0) { Write-GuiLog 'No Automation accounts in this subscription.' 'warn'; return }
        if ($c.SelectedIndex -lt 0) { $Gui.State.SuppressEvents = $true; $c.SelectedIndex = 0; $Gui.State.SuppressEvents = $false }
        Start-RunbookLoad -Page $pg
    }
}

function Start-RunbookLoad {
    param([hashtable]$Page)
    $acct = Get-FormValue $Page.Form 'Account'
    if (-not $acct) { return }
    Start-Work -Name 'List runbooks and jobs' -Argument @{ AccountId = $acct } -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        [pscustomobject]@{ Runbooks = @(Get-RunbookInfo -AccountId $Job.AccountId); Jobs = @(Get-RunbookJobInfo -AccountId $Job.AccountId -Hours 72) }
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $r = @($result)[-1]
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows @($r.Runbooks) -Columns @('Name', 'Type', 'State', 'LastModified', 'Description')).DefaultView
        $pg.JobGrid.ItemsSource = (ConvertTo-DataTable -Rows @($r.Jobs) -Columns @('Runbook', 'Status', 'Started', 'Ended', 'RunOn', 'JobId')).DefaultView
        $failed = @($r.Jobs | Where-Object { $_.Status -in 'Failed', 'Suspended', 'Stopped' })
        if ($failed.Count -gt 0) { Write-GuiLog "$($failed.Count) job(s) failed, stopped or suspended in the last 72 hours." 'warn' }
    }
}

function Invoke-RunbookJobOutput {
    param([hashtable]$Page)
    $sel = Get-GridSelection $Page.JobGrid
    if ($sel.Count -ne 1) { return }
    Start-Work -Name "Output of $($sel[0].Runbook)" -Argument @{ AccountId = (Get-FormValue $Page.Form 'Account'); JobId = $sel[0].JobId } -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        Get-RunbookJobOutput -AccountId $Job.AccountId -JobId $Job.JobId
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        foreach ($o in @($result)) { Write-GuiLog "[$($o.Stream)] $($o.Text)" $(if ($o.Stream -match 'Error') { 'error' } elseif ($o.Stream -match 'Warning') { 'warn' } else { 'verbose' }) }
        if (@($result).Count -eq 0) { Write-GuiLog 'That job wrote no output.' 'info' }
    }
}

function Invoke-RunbookStart {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -ne 1) { Show-Message 'Select one runbook.' 'Runbooks' 'Warning'; return }
    try { $params = ConvertFrom-ParameterText (Get-FormValue $Page.Form 'RbParams') } catch { Show-Message $_.Exception.Message 'Parameters' 'Warning'; return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; AccountId = (Get-FormValue $Page.Form 'Account'); Name = $sel[0].Name; Parameter = $params }
    if (Get-FormValue $Page.Form 'RbWait') { $p.Wait = $true }
    Invoke-RepoScript -Name "Start runbook $($sel[0].Name)" -Path $Gui.Scripts.RunbookStart -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Start-RunbookLoad -Page $pg }
    }
}

function Invoke-RunbookImport {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $acct = Get-FormValue $Page.Form 'Account'
    $file = Get-FormValue $Page.Form 'ImpFile'
    if (-not $acct -or -not $file) { Show-Message 'Pick the account and the file.' 'Import' 'Warning'; return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; AccountId = $acct; Path = $file }
    $n = Get-FormValue $Page.Form 'ImpName'; if ($n) { $p.Name = $n }
    Invoke-RepoScript -Name "Import runbook $(Split-Path $file -Leaf)" -Path $Gui.Scripts.RunbookImport -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Start-RunbookLoad -Page $pg }
    }
}

# --- Runbook groups -----------------------------------------------------------------
function New-RunbookGroupsPage {
    $page = @{ Key = 'NavRunbookGroups'; Form = New-Form; Accounts = @() }
    $root = New-PageRoot -Title 'Runbook groups' -Lead 'Runbooks of one Automation account run in order, each waited for, stopping at the first that does not complete. Kept in toolbox.local.json.'
    $page.ListGrid = New-DataGrid -Height 180
    $page.ListGrid.SelectionMode = 'Single'
    Add-ControlHandler -Control $page.ListGrid -EventName SelectionChanged -Context $page -Handler { param($pg) Update-RunbookGroupForm -Page $pg }
    $null = $root.Children.Add((New-TableCard -Title 'Runbook groups' -Grid $page.ListGrid -Tools @((New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Start-RunbookGroupLoad -Page $pg }))))
    $edit = New-FormSection -Form $page.Form -Title 'Runbook group' -Fields @(
        @{ Name = 'Name'; Label = 'Name'; Required = $true }
        @{ Name = 'AccountId'; Label = 'Automation account'; Type = 'combo'; Required = $true }
        @{ Name = 'Runbooks'; Label = 'Runbooks in order (one per line)'; Type = 'multiline'; Required = $true; Span = 2 }
    )
    $null = $edit.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Save group' -Style 'PrimaryButton' -Context $page -OnClick { param($pg) Invoke-RunbookGroupSave -Page $pg }),
        (New-Button -Text 'Run selected group' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-RunbookGroupRun -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-RunbookGroupRun -Page $c.Page -DryRun:$c.DryRun }))))
    $null = $root.Children.Add($edit)
    $page.Grid = New-DataGrid -Height 200
    $null = $root.Children.Add((New-TableCard -Title 'Results' -Grid $page.Grid))
    $page.OnShow = { param($pg) if (-not $Gui.State.Busy) { Start-RunbookGroupLoad -Page $pg } }
    $page.Root = $root
    return $page
}

function Start-RunbookGroupLoad {
    param([hashtable]$Page)
    Start-ToolboxStoreLoad -Context $Page -OnDone {
        param($store, $pg)
        $pg.Store = $store
        $pg.ListGrid.ItemsSource = (ConvertTo-DataTable -Rows @(ConvertTo-StoreRow -Section $store.RunbookGroups -Fields @('Runbooks', 'AccountId', 'Saved')) -Columns @('Name', 'Runbooks', 'AccountId', 'Saved')).DefaultView
        if (-not $Gui.State.Account) { return }
        Start-Work -Name 'List Automation accounts' -Context $pg -Script { $ErrorActionPreference = 'Stop'; Get-RunbookAccountInfo } -OnDone {
            param($result, $failure, $p)
            if ($failure) { return }
            $c = $p.Form.Controls['AccountId']
            Add-ComboOption -Combo $c -Options @(@($result) | ForEach-Object { @{ Value = $_.Id; Label = "$($_.Name)  ($($_.ResourceGroupName))" } }) -Default (Get-ComboValue $c)
        }
    }
}

function Update-RunbookGroupForm {
    param([hashtable]$Page)
    $sel = Get-GridSelection $Page.ListGrid
    if ($sel.Count -ne 1 -or -not $Page.ContainsKey('Store')) { return }
    $g = $Page.Store.RunbookGroups[$sel[0].Name]
    Set-FormValue $Page.Form 'Name' $sel[0].Name
    Set-FormValue $Page.Form 'AccountId' $g['AccountId']
    Set-FormValue $Page.Form 'Runbooks' ((@($g['Runbooks']) | Where-Object { $_ }) -join [Environment]::NewLine)
}

function Invoke-RunbookGroupSave {
    param([hashtable]$Page)
    if (-not (Test-FormRequired -Form $Page.Form)) { return }
    Save-ToolboxItem -Kind 'RunbookGroups' -Name (Get-FormValue $Page.Form 'Name') -Value @{ AccountId = (Get-FormValue $Page.Form 'AccountId'); Runbooks = @(Split-CommaList (Get-FormValue $Page.Form 'Runbooks')) } -Context $Page -OnDone { param($pg) Start-RunbookGroupLoad -Page $pg }
}

function Invoke-RunbookGroupRun {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $sel = Get-GridSelection $Page.ListGrid
    if ($sel.Count -ne 1) { Show-Message 'Select a saved runbook group.' 'Runbook groups' 'Warning'; return }
    Invoke-RepoScript -Name "Run runbook group $($sel[0].Name)" -Path $Gui.Scripts.RunbookStart -Params @{ SubscriptionId = $Gui.State.SubscriptionId; RunbookGroup = $sel[0].Name } -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Show-ResultGrid -Grid $pg.Grid -Result @($result) -Columns @('Runbook', 'Status', 'JobId', 'Output') }
    }
}
