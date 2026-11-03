<#
    Application pages for Start-AvdGui.ps1: winget catalog, app groups, shell
    apps, certificates, MSIX app attach, deployments (saved) and deployment
    status. Dot-sourced by the main script; uses its helpers and $Gui.
    Everything that runs inside VMs goes through apps/*.ps1 and the AppDeploy
    module's Run Command runner. App groups, shell apps and deployments are kept
    in toolbox.local.json (gitignored). Nothing here uninstalls or deletes.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-*/Set-*/Update-* here build or refresh WPF controls. Changes go through the repo scripts, which support -WhatIf.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Handlers and OnDone callbacks have fixed signatures.')]
param()

# --- Shared: target picker, store, files ---------------------------------------
function New-TargetPicker {
    <#
    .SYNOPSIS
        Where an in-guest action runs: every host of the current pool, or VMs
        picked in a list. Returns @{ Card; Mode; Grid }.
    #>
    param([string]$Title = 'Run on')
    $picker = @{}
    $card = New-Card -Title $Title -Subtitle 'Only running VMs take part; the others are listed as skipped.'
    $picker.Mode = New-Combo -Margin '0,0,0,8'
    Add-ComboOption -Combo $picker.Mode -Options @(
        @{ Value = 'pool'; Label = 'Every session host of the current host pool' },
        @{ Value = 'vms'; Label = 'The VMs selected in the list below' }) -Default 'pool'
    $null = $card.Child.Children.Add($picker.Mode)
    $picker.Grid = New-DataGrid -Height 170
    $null = $card.Child.Children.Add($picker.Grid)
    $null = $card.Child.Children.Add((New-ButtonRow -Buttons @((New-Button -Text 'Load VMs' -Style 'GhostButton' -Context $picker -OnClick { param($pk) Start-TargetPickerLoad -Picker $pk }))))
    $picker.Card = $card
    return $picker
}

function Start-TargetPickerLoad {
    param([hashtable]$Picker)
    if (-not (Test-SignedIn)) { return }
    Start-Work -Name 'List VMs' -Context $Picker -Script {
        $ErrorActionPreference = 'Stop'
        Get-AzVM -Status | Sort-Object ResourceGroupName, Name | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; ResourceGroup = $_.ResourceGroupName; Power = ("$($_.PowerState)" -replace '^VM ', ''); Location = $_.Location; Os = "$($_.StorageProfile.OsDisk.OsType)" }
        }
    } -OnDone {
        param($result, $failure, $pk)
        if ($failure) { return }
        $pk.Grid.ItemsSource = (ConvertTo-DataTable -Rows @($result) -Columns @('Name', 'ResourceGroup', 'Power', 'Location', 'Os')).DefaultView
    }
}

function Get-TargetPickerParameter {
    # The target part of a script's parameters, or $null (after saying why).
    param([hashtable]$Picker)
    if ((Get-ComboValue $Picker.Mode) -eq 'pool') {
        if (-not (Test-PoolSelected)) { return $null }
        return @{ HostPoolName = $Gui.State.Pool.Name; HostPoolResourceGroupName = $Gui.State.Pool.ResourceGroupName }
    }
    $sel = Get-GridSelection $Picker.Grid
    if ($sel.Count -eq 0) { Show-Message 'Select one or more VMs in the list (Load VMs first), or switch to the host pool.' 'Targets' 'Warning'; return $null }
    return @{ VM = @($sel | ForEach-Object { "$($_.ResourceGroup)/$($_.Name)" }) }
}

function Save-ToolboxItem {
    # Write one definition to toolbox.local.json in the worker; OnDone(context) after.
    param([string]$Kind, [string]$Name, [hashtable]$Value, [scriptblock]$OnDone, [object]$Context)
    if ($Name -notmatch '^[\w .()-]{1,60}$') { Show-Message 'Names may use letters, digits, spaces, dots, dashes and brackets (60 at most).' 'Name' 'Warning'; return }
    Start-Work -Name "Save $Kind '$Name'" -Argument @{ Kind = $Kind; Name = $Name; Value = $Value } -Context @{ OnDone = $OnDone; Context = $Context } -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        Set-ToolboxStoreItem -Kind $Job.Kind -Name $Job.Name -Value $Job.Value -Confirm:$false
    } -OnDone {
        param($result, $failure, $c)
        if ($failure) { return }
        Write-GuiLog 'Saved in toolbox.local.json (next to the scripts, not in git). To drop an entry, edit that file.' 'info'
        if ($c.OnDone) { & $c.OnDone $c.Context }
    }
}

function Start-ToolboxStoreLoad {
    # Read the local store in the worker; OnDone($store, $context).
    param([scriptblock]$OnDone, [object]$Context)
    Start-Work -Name 'Read toolbox.local.json' -Context @{ OnDone = $OnDone; Context = $Context } -Script {
        $ErrorActionPreference = 'Stop'
        Get-ToolboxStore
    } -OnDone {
        param($result, $failure, $c)
        if ($failure) { return }
        & $c.OnDone (@($result)[-1]) $c.Context
    }
}

function ConvertTo-StoreRow {
    # Flatten store entries into grid rows; lists become comma text.
    param([hashtable]$Section, [string[]]$Fields)
    foreach ($name in @($Section.Keys | Sort-Object)) {
        $e = $Section[$name]
        $row = [ordered]@{ Name = $name }
        foreach ($f in $Fields) { $v = if ($e -is [System.Collections.IDictionary] -and $e.Contains($f)) { $e[$f] } else { '' }; $row[$f] = (@($v) -join ', ') }
        [pscustomobject]$row
    }
}

function Show-OpenFileDialog {
    param([string]$Filter = 'All files (*.*)|*.*', [string]$Title = 'Choose a file')
    $d = [Microsoft.Win32.OpenFileDialog]::new()
    $d.Filter = $Filter; $d.Title = $Title
    if ($d.ShowDialog($Gui.Window)) { return $d.FileName }
    return $null
}

function Show-InGuestResult {
    # Put Run Command result rows into a grid; warn about the ones that did not succeed.
    param($Grid, [object[]]$Result, [string]$First = '')
    $rows = @($Result | Where-Object { $null -ne $_ -and $_ -isnot [string] -and $_.PSObject.Properties['VM'] })
    $cols = @(); if ($First) { $cols += $First }; $cols += 'VM', 'State', 'ExitCode', 'Output', 'Error'
    $Grid.ItemsSource = (ConvertTo-DataTable -Rows $rows -Columns $cols).DefaultView
    $bad = @($rows | Where-Object { $_.State -notlike 'Skipped*' -and ($_.State -ne 'Succeeded' -or ($_.ExitCode -and $_.ExitCode -ne '0')) })
    if ($bad.Count -gt 0) { Write-GuiLog "Did not succeed on: $(@($bad | ForEach-Object VM | Select-Object -Unique) -join ', '). See the Output and Error columns." 'warn' }
}

# --- winget catalog -------------------------------------------------------------
function New-WingetPage {
    $page = @{ Key = 'NavWinget'; Form = New-Form }
    $form = $page.Form
    $root = New-PageRoot -Title 'Winget catalog' -Lead 'Search the winget catalog (it runs on a VM you pick, so it takes a minute), collect package IDs, then install them machine-wide on hosts or VMs. Windows 11 and 10 multi-session have winget; Windows Server needs App Installer.'
    $search = New-FormSection -Form $form -Title 'Search' -Fields @(
        @{ Name = 'RefVm'; Label = 'Search on (a running VM with winget)'; Type = 'combo'; Required = $true; Span = 2 }
        @{ Name = 'Query'; Label = 'Search for'; Required = $true; Default = 'chrome' }
    )
    $null = $search.Child.Children.Add((New-ButtonRow -Buttons @((New-Button -Text 'Search' -Style 'PrimaryButton' -Context $page -OnClick { param($pg) Invoke-WingetSearch -Page $pg }))))
    $null = $root.Children.Add($search)
    $page.ResultGrid = New-DataGrid -Height 200
    $add = @(@{ Text = 'Add to the install list'; Context = $page; Handler = { param($pg) Add-WingetSelection -Page $pg } })
    Set-GridRowMenu -Grid $page.ResultGrid -Items $add
    Add-ControlHandler -Control $page.ResultGrid -EventName DoubleClick -Context $page -Handler { param($pg) Add-WingetSelection -Page $pg }
    $null = $root.Children.Add((New-TableCard -Title 'Search results' -Grid $page.ResultGrid -Tools @((New-MenuButton -Text 'Add' -Items $add)) -Note 'Double-click a row to add its ID to the install list.'))
    $null = $root.Children.Add((New-FormSection -Form $form -Title 'Install list' -Fields @(
        @{ Name = 'Ids'; Label = 'winget package IDs (one per line)'; Type = 'multiline'; Span = 2; Help = 'Exact IDs, for example Google.Chrome or 7zip.7zip.' }
    )))
    $page.Targets = New-TargetPicker
    $null = $root.Children.Add($page.Targets.Card)
    $null = $root.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Install' -Style 'PrimaryButton' -Context @{ Page = $page; Upgrade = $false; DryRun = $false } -OnClick { param($c) Invoke-WingetInstall -Page $c.Page -Upgrade:$c.Upgrade -DryRun:$c.DryRun }),
        (New-Button -Text 'Upgrade' -Context @{ Page = $page; Upgrade = $true; DryRun = $false } -OnClick { param($c) Invoke-WingetInstall -Page $c.Page -Upgrade:$c.Upgrade -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; Upgrade = $false; DryRun = $true } -OnClick { param($c) Invoke-WingetInstall -Page $c.Page -Upgrade:$c.Upgrade -DryRun:$c.DryRun }),
        (New-Button -Text 'Save list as an app group...' -Style 'GhostButton' -Context $page -OnClick { param($pg) Invoke-WingetSaveGroup -Page $pg }))))
    $page.Grid = New-DataGrid -Height 200
    $null = $root.Children.Add((New-TableCard -Title 'Results' -Grid $page.Grid))
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Start-WingetVmLoad -Page $pg } }
    $page.Root = $root
    return $page
}

function Start-WingetVmLoad {
    param([hashtable]$Page)
    Start-Work -Name 'List running VMs' -Context $Page -Script {
        $ErrorActionPreference = 'Stop'
        Get-AzVM -Status | Where-Object { "$($_.PowerState)" -eq 'VM running' -and "$($_.StorageProfile.OsDisk.OsType)" -eq 'Windows' } | Sort-Object Name |
            ForEach-Object { [pscustomobject]@{ Value = "$($_.ResourceGroupName)/$($_.Name)"; Label = "$($_.Name)  ($($_.ResourceGroupName))" } }
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $c = $pg.Form.Controls['RefVm']
        Add-ComboOption -Combo $c -Options @(@($result) | ForEach-Object { @{ Value = $_.Value; Label = $_.Label } }) -Default (Get-ComboValue $c)
        if ($c.SelectedIndex -lt 0 -and $c.Items.Count -gt 0) { $c.SelectedIndex = 0 }
        Start-TargetPickerLoad -Picker $pg.Targets
    }
}

function Invoke-WingetSearch {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    if (-not (Test-FormRequired -Form $Page.Form -Only @('RefVm', 'Query'))) { return }
    Start-Work -Name "winget search '$(Get-FormValue $Page.Form 'Query')'" -Argument @{ Vm = (Get-FormValue $Page.Form 'RefVm'); Query = (Get-FormValue $Page.Form 'Query') } -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        $t = @(Resolve-GuestTarget -VM @($Job.Vm))[0]
        Find-WingetPackage -Target $t -Query $Job.Query
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.ResultGrid.ItemsSource = (ConvertTo-DataTable -Rows @($result) -Columns @('Name', 'Id', 'Version', 'Source')).DefaultView
        Write-GuiLog "$(@($result).Count) package(s) found." 'info'
    }
}

function Add-WingetSelection {
    param([hashtable]$Page)
    $sel = Get-GridSelection $Page.ResultGrid
    if ($sel.Count -eq 0) { return }
    $now = @(Split-CommaList (Get-FormValue $Page.Form 'Ids'))
    $all = @($now + @($sel | ForEach-Object { $_.Id })) | Where-Object { $_ } | Select-Object -Unique
    $Page.Form.Controls['Ids'].Text = ($all -join [Environment]::NewLine)
}

function Invoke-WingetInstall {
    param([hashtable]$Page, [switch]$Upgrade, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $ids = @(Split-CommaList (Get-FormValue $Page.Form 'Ids'))
    if ($ids.Count -eq 0) { Show-Message 'Add at least one package ID to the install list.' 'winget' 'Warning'; return }
    $t = Get-TargetPickerParameter -Picker $Page.Targets
    if (-not $t) { return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; WingetId = $ids } + $t
    if ($Upgrade) { $p.Upgrade = $true }
    Invoke-RepoScript -Name "$(if ($Upgrade) { 'Upgrade' } else { 'Install' }) $($ids.Count) package(s)" -Path $Gui.Scripts.AppInstall -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Show-InGuestResult -Grid $pg.Grid -Result @($result) -First 'App' }
    }
}

function Invoke-WingetSaveGroup {
    param([hashtable]$Page)
    $ids = @(Split-CommaList (Get-FormValue $Page.Form 'Ids'))
    if ($ids.Count -eq 0) { Show-Message 'The install list is empty.' 'App group' 'Warning'; return }
    $name = Show-InputDialog -Title 'Save as app group' -Text 'Name for this app group (an existing name is replaced).' -OkText 'Save'
    if (-not $name) { return }
    Save-ToolboxItem -Kind 'AppGroups' -Name $name -Value @{ WingetId = $ids; ShellApp = @() }
}

# --- App groups -----------------------------------------------------------------
function New-AppGroupsPage {
    $page = @{ Key = 'NavAppGroups'; Form = New-Form }
    $form = $page.Form
    $root = New-PageRoot -Title 'App groups' -Lead 'Named sets of winget packages and shell apps, deployed together. Kept in toolbox.local.json next to the scripts (not in git).'
    $page.ListGrid = New-DataGrid -Height 180
    $page.ListGrid.SelectionMode = 'Single'
    Add-ControlHandler -Control $page.ListGrid -EventName SelectionChanged -Context $page -Handler { param($pg) Update-AppGroupForm -Page $pg }
    $null = $root.Children.Add((New-TableCard -Title 'App groups' -Grid $page.ListGrid -Tools @((New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Start-AppGroupLoad -Page $pg }))))
    $edit = New-FormSection -Form $form -Title 'App group' -Subtitle 'Select one above to edit it, or fill in a new name. Saving an existing name replaces it.' -Fields @(
        @{ Name = 'Name'; Label = 'Name'; Required = $true }
        @{ Name = 'WingetId'; Label = 'winget package IDs (one per line)'; Type = 'multiline' }
        @{ Name = 'ShellApp'; Label = 'Shell apps (names, one per line)'; Type = 'multiline' }
    )
    $null = $edit.Child.Children.Add((New-ButtonRow -Buttons @((New-Button -Text 'Save group' -Style 'PrimaryButton' -Context $page -OnClick { param($pg) Invoke-AppGroupSave -Page $pg }))))
    $null = $root.Children.Add($edit)
    $page.Targets = New-TargetPicker -Title 'Deploy to'
    $null = $root.Children.Add($page.Targets.Card)
    $null = $root.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Deploy group' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-AppGroupDeploy -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-AppGroupDeploy -Page $c.Page -DryRun:$c.DryRun }))))
    $page.Grid = New-DataGrid -Height 200
    $null = $root.Children.Add((New-TableCard -Title 'Results' -Grid $page.Grid))
    $page.OnShow = { param($pg) if (-not $Gui.State.Busy) { Start-AppGroupLoad -Page $pg } }
    $page.Root = $root
    return $page
}

function Start-AppGroupLoad {
    param([hashtable]$Page)
    Start-ToolboxStoreLoad -Context $Page -OnDone {
        param($store, $pg)
        $pg.Store = $store
        $pg.ListGrid.ItemsSource = (ConvertTo-DataTable -Rows @(ConvertTo-StoreRow -Section $store.AppGroups -Fields @('WingetId', 'ShellApp', 'Saved')) -Columns @('Name', 'WingetId', 'ShellApp', 'Saved')).DefaultView
        if ($Gui.State.Account -and $pg.Targets.Grid.Items.Count -eq 0) { Start-TargetPickerLoad -Picker $pg.Targets }
    }
}

function Update-AppGroupForm {
    param([hashtable]$Page)
    $sel = Get-GridSelection $Page.ListGrid
    if ($sel.Count -ne 1 -or -not $Page.ContainsKey('Store')) { return }
    $g = $Page.Store.AppGroups[$sel[0].Name]
    Set-FormValue $Page.Form 'Name' $sel[0].Name
    Set-FormValue $Page.Form 'WingetId' ((@($g['WingetId']) | Where-Object { $_ }) -join [Environment]::NewLine)
    Set-FormValue $Page.Form 'ShellApp' ((@($g['ShellApp']) | Where-Object { $_ }) -join [Environment]::NewLine)
}

function Invoke-AppGroupSave {
    param([hashtable]$Page)
    if (-not (Test-FormRequired -Form $Page.Form -Only @('Name'))) { return }
    $v = @{ WingetId = @(Split-CommaList (Get-FormValue $Page.Form 'WingetId')); ShellApp = @(Split-CommaList (Get-FormValue $Page.Form 'ShellApp')) }
    if ($v.WingetId.Count + $v.ShellApp.Count -eq 0) { Show-Message 'Add at least one package or shell app.' 'App group' 'Warning'; return }
    Save-ToolboxItem -Kind 'AppGroups' -Name (Get-FormValue $Page.Form 'Name') -Value $v -Context $Page -OnDone { param($pg) Start-AppGroupLoad -Page $pg }
}

function Invoke-AppGroupDeploy {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $sel = Get-GridSelection $Page.ListGrid
    if ($sel.Count -ne 1) { Show-Message 'Select a saved app group (save it first if it is new).' 'App group' 'Warning'; return }
    $t = Get-TargetPickerParameter -Picker $Page.Targets
    if (-not $t) { return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; AppGroup = @($sel[0].Name) } + $t
    Invoke-RepoScript -Name "Deploy app group $($sel[0].Name)" -Path $Gui.Scripts.AppInstall -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Show-InGuestResult -Grid $pg.Grid -Result @($result) -First 'App' }
    }
}

# --- Shell apps -----------------------------------------------------------------
function New-ShellAppsPage {
    $page = @{ Key = 'NavShellApps'; Form = New-Form }
    $form = $page.Form
    $root = New-PageRoot -Title 'Shell apps' -Lead 'Apps that are not in winget: your own install script plus a detection check. Detection runs first (already installed = nothing to do) and again after the install. Scripts run as SYSTEM in Windows PowerShell 5.1.'
    $page.ListGrid = New-DataGrid -Height 160
    $page.ListGrid.SelectionMode = 'Single'
    Add-ControlHandler -Control $page.ListGrid -EventName SelectionChanged -Context $page -Handler { param($pg) Update-ShellAppForm -Page $pg }
    $null = $root.Children.Add((New-TableCard -Title 'Shell apps' -Grid $page.ListGrid -Tools @((New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Start-ShellAppLoad -Page $pg }))))
    $edit = New-FormSection -Form $form -Title 'Shell app' -Subtitle 'Saving an existing name replaces it. Download from a URL in the install script (Invoke-WebRequest) or from a share the VMs can reach.' -Fields @(
        @{ Name = 'Name'; Label = 'Name'; Required = $true }
        @{ Name = 'Notes'; Label = 'Notes' }
        @{ Name = 'Detect'; Label = 'Detection (returns $true when installed)'; Type = 'multiline'; Span = 2; Default = "Test-Path 'C:\Program Files\Vendor\App\app.exe'" }
        @{ Name = 'Install'; Label = 'Install script'; Type = 'multiline'; Span = 2; Default = "`$msi = Join-Path `$env:TEMP 'app.msi'`r`nInvoke-WebRequest -Uri 'https://example.com/app.msi' -OutFile `$msi -UseBasicParsing`r`nStart-Process msiexec.exe -ArgumentList '/i', `$msi, '/qn', '/norestart' -Wait" }
    )
    $null = $edit.Child.Children.Add((New-ButtonRow -Buttons @((New-Button -Text 'Save shell app' -Style 'PrimaryButton' -Context $page -OnClick { param($pg) Invoke-ShellAppSave -Page $pg }))))
    $null = $root.Children.Add($edit)
    $page.Targets = New-TargetPicker -Title 'Install on'
    $null = $root.Children.Add($page.Targets.Card)
    $null = $root.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Install selected shell app' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-ShellAppDeploy -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-ShellAppDeploy -Page $c.Page -DryRun:$c.DryRun }))))
    $page.Grid = New-DataGrid -Height 200
    $null = $root.Children.Add((New-TableCard -Title 'Results' -Grid $page.Grid))
    $page.OnShow = { param($pg) if (-not $Gui.State.Busy) { Start-ShellAppLoad -Page $pg } }
    $page.Root = $root
    return $page
}

function Start-ShellAppLoad {
    param([hashtable]$Page)
    Start-ToolboxStoreLoad -Context $Page -OnDone {
        param($store, $pg)
        $pg.Store = $store
        $pg.ListGrid.ItemsSource = (ConvertTo-DataTable -Rows @(ConvertTo-StoreRow -Section $store.ShellApps -Fields @('Notes', 'Saved')) -Columns @('Name', 'Notes', 'Saved')).DefaultView
        if ($Gui.State.Account -and $pg.Targets.Grid.Items.Count -eq 0) { Start-TargetPickerLoad -Picker $pg.Targets }
    }
}

function Update-ShellAppForm {
    param([hashtable]$Page)
    $sel = Get-GridSelection $Page.ListGrid
    if ($sel.Count -ne 1 -or -not $Page.ContainsKey('Store')) { return }
    $a = $Page.Store.ShellApps[$sel[0].Name]
    Set-FormValue $Page.Form 'Name' $sel[0].Name
    foreach ($k in 'Notes', 'Detect', 'Install') { Set-FormValue $Page.Form $k $(if ($a.Contains($k)) { $a[$k] } else { '' }) }
}

function Invoke-ShellAppSave {
    param([hashtable]$Page)
    if (-not (Test-FormRequired -Form $Page.Form -Only @('Name'))) { return }
    $f = $Page.Form
    $install = $f.Controls['Install'].Text
    if (-not $install.Trim()) { Show-Message 'The install script is empty.' 'Shell app' 'Warning'; return }
    foreach ($k in 'Detect', 'Install') {
        $errs = $null; $null = [System.Management.Automation.Language.Parser]::ParseInput($f.Controls[$k].Text, [ref]$null, [ref]$errs)
        if (@($errs).Count -gt 0) { Show-Message "The $k script does not parse: $($errs[0].Message)" 'Shell app' 'Warning'; return }
    }
    Save-ToolboxItem -Kind 'ShellApps' -Name (Get-FormValue $f 'Name') -Value @{ Detect = $f.Controls['Detect'].Text; Install = $install; Notes = (Get-FormValue $f 'Notes') } -Context $Page -OnDone { param($pg) Start-ShellAppLoad -Page $pg }
}

function Invoke-ShellAppDeploy {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $sel = Get-GridSelection $Page.ListGrid
    if ($sel.Count -ne 1) { Show-Message 'Select a saved shell app.' 'Shell app' 'Warning'; return }
    $t = Get-TargetPickerParameter -Picker $Page.Targets
    if (-not $t) { return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ShellApp = @($sel[0].Name) } + $t
    Invoke-RepoScript -Name "Install $($sel[0].Name)" -Path $Gui.Scripts.AppInstall -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Show-InGuestResult -Grid $pg.Grid -Result @($result) -First 'App' }
    }
}

# --- Certificates ---------------------------------------------------------------
function New-CertificatesPage {
    $page = @{ Key = 'NavCerts'; Form = New-Form }
    $form = $page.Form
    $root = New-PageRoot -Title 'Certificates' -Lead 'Key Vault certificates by expiry, a PFX import into a vault, and putting a certificate from this computer into VMs'' machine stores (an MSIX signing certificate goes to Trusted Publisher). Files and passwords travel as protected parameters.'
    $page.Grid = New-DataGrid -Height 220
    $null = $root.Children.Add((New-TableCard -Title 'Key Vault certificates (soonest expiry first)' -Grid $page.Grid -Tools @((New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Start-CertLoad -Page $pg })) -Note 'Vaults that refuse the listing (no data-plane access) are named in the log.'))
    $imp = New-FormSection -Form $form -Title 'Import a PFX into a Key Vault' -Subtitle 'An existing name gets a new version; the old one stays.' -Fields @(
        @{ Name = 'KvVault'; Label = 'Key Vault'; Type = 'combo'; Required = $true }
        @{ Name = 'KvName'; Label = 'Certificate name (letters, digits, hyphens)'; Required = $true }
        @{ Name = 'KvFile'; Label = 'PFX file'; Required = $true; Span = 2 }
        @{ Name = 'KvPassword'; Label = 'PFX password'; Type = 'password' }
    )
    $null = $imp.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Browse...' -Style 'GhostButton' -Context @{ Page = $page; Field = 'KvFile' } -OnClick { param($c) $f = Show-OpenFileDialog -Filter 'PFX (*.pfx;*.p12)|*.pfx;*.p12'; if ($f) { Set-FormValue $c.Page.Form $c.Field $f } }),
        (New-Button -Text 'Import' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-CertImport -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-CertImport -Page $c.Page -DryRun:$c.DryRun }))))
    $null = $root.Children.Add($imp)
    $inst = New-FormSection -Form $form -Title 'Install on VMs' -Subtitle 'A .cer needs no password. Files over 120 KB are refused.' -Fields @(
        @{ Name = 'GuestFile'; Label = 'Certificate file (.pfx, .p12 or .cer)'; Required = $true; Span = 2 }
        @{ Name = 'GuestPassword'; Label = 'PFX password'; Type = 'password' }
        @{ Name = 'GuestStore'; Label = 'Store'; Type = 'combo'; Default = 'My'; Options = @(@{ Value = 'My'; Label = 'Personal (My)' }, @{ Value = 'Root'; Label = 'Trusted Root' }, @{ Value = 'CA'; Label = 'Intermediate (CA)' }, @{ Value = 'TrustedPublisher'; Label = 'Trusted Publisher (MSIX signing)' }) }
    )
    $null = $inst.Child.Children.Add((New-ButtonRow -Buttons @((New-Button -Text 'Browse...' -Style 'GhostButton' -Context @{ Page = $page; Field = 'GuestFile' } -OnClick { param($c) $f = Show-OpenFileDialog -Filter 'Certificates (*.pfx;*.p12;*.cer)|*.pfx;*.p12;*.cer'; if ($f) { Set-FormValue $c.Page.Form $c.Field $f } }))))
    $null = $root.Children.Add($inst)
    $page.Targets = New-TargetPicker -Title 'Install on'
    $null = $root.Children.Add($page.Targets.Card)
    $null = $root.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Install certificate' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-CertInstall -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-CertInstall -Page $c.Page -DryRun:$c.DryRun }))))
    $page.ResultGrid = New-DataGrid -Height 160
    $null = $root.Children.Add((New-TableCard -Title 'Results' -Grid $page.ResultGrid))
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Start-CertLoad -Page $pg } }
    $page.Root = $root
    return $page
}

function Start-CertLoad {
    param([hashtable]$Page)
    Start-Work -Name 'List Key Vault certificates' -Context $Page -Script {
        $ErrorActionPreference = 'Stop'
        [pscustomobject]@{ Certs = @(Get-KvCertificateInfo); Vaults = @(Get-AzKeyVault | Sort-Object VaultName | ForEach-Object { $_.VaultName }) }
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $r = @($result)[-1]
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows @($r.Certs) -Columns @('Status', 'DaysLeft', 'Expires', 'Name', 'Vault', 'Enabled', 'Thumbprint')).DefaultView
        Add-ComboOption -Combo $pg.Form.Controls['KvVault'] -Options @($r.Vaults) -Default (Get-ComboValue $pg.Form.Controls['KvVault'])
        $soon = @($r.Certs | Where-Object { $_.Status -in 'EXPIRED', 'Expiring soon' })
        if ($soon.Count -gt 0) { Write-GuiLog "$($soon.Count) certificate(s) expired or expiring within 30 days: $(@($soon | ForEach-Object Name) -join ', ')." 'warn' }
        if ($pg.Targets.Grid.Items.Count -eq 0) { Start-TargetPickerLoad -Picker $pg.Targets }
    }
}

function Invoke-CertImport {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    if (-not (Test-FormRequired -Form $Page.Form -Only @('KvVault', 'KvName', 'KvFile'))) { return }
    $f = $Page.Form
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; VaultName = (Get-FormValue $f 'KvVault'); Name = (Get-FormValue $f 'KvName'); FilePath = (Get-FormValue $f 'KvFile'); Password = $f.Controls['KvPassword'].SecurePassword }
    Invoke-RepoScript -Name "Import $($p.Name) into $($p.VaultName)" -Path $Gui.Scripts.KvImport -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { $pg.Form.Controls['KvPassword'].Clear(); Start-CertLoad -Page $pg }
    }
}

function Invoke-CertInstall {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    if (-not (Test-FormRequired -Form $Page.Form -Only @('GuestFile'))) { return }
    $t = Get-TargetPickerParameter -Picker $Page.Targets
    if (-not $t) { return }
    $f = $Page.Form
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; FilePath = (Get-FormValue $f 'GuestFile'); StoreName = (Get-FormValue $f 'GuestStore') } + $t
    if ($f.Controls['GuestPassword'].SecurePassword.Length -gt 0) { $p.Password = $f.Controls['GuestPassword'].SecurePassword }
    Invoke-RepoScript -Name 'Install certificate' -Path $Gui.Scripts.CertInstall -Params $p -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Show-InGuestResult -Grid $pg.ResultGrid -Result @($result) }
    }
}

# --- MSIX app attach --------------------------------------------------------------
function New-MsixPage {
    $page = @{ Key = 'NavMsix'; Form = New-Form; Packages = @() }
    $form = $page.Form
    $root = New-PageRoot -PoolBanner -Title 'MSIX app attach' -Lead 'App attach packages mount an app per user at sign-in instead of installing it on every host. Add an image from a file share for the current host pool, then give a group access. The signing certificate must be trusted on the hosts (Certificates page, Trusted Publisher).'
    $page.Grid = New-DataGrid -Height 220
    $page.Grid.SelectionMode = 'Single'
    $actions = @(
        @{ Text = 'Activate';                Context = @{ Page = $page; Active = 'true' };  Handler = { param($c) Invoke-MsixSet -Page $c.Page -Active $c.Active } }
        @{ Text = 'Deactivate';              Context = @{ Page = $page; Active = 'false' }; Handler = { param($c) Invoke-MsixSet -Page $c.Page -Active $c.Active } }
        @{ Text = 'Register at sign-in';     Context = @{ Page = $page; Reg = 'true' };     Handler = { param($c) Invoke-MsixSet -Page $c.Page -Register $c.Reg } }
        @{ Text = 'Register on demand';      Context = @{ Page = $page; Reg = 'false' };    Handler = { param($c) Invoke-MsixSet -Page $c.Page -Register $c.Reg } }
        @{ Separator = $true }
        @{ Text = 'Assign to the current host pool'; Context = $page; Handler = { param($pg) Invoke-MsixAssignPool -Page $pg } }
        @{ Text = 'Give a group access...';  Context = $page; Handler = { param($pg) Invoke-MsixGrant -Page $pg } }
    )
    Set-GridRowMenu -Grid $page.Grid -Items $actions
    $null = $root.Children.Add((New-TableCard -Title 'Packages' -Grid $page.Grid -Tools @(
        (New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Start-MsixLoad -Page $pg }),
        (New-MenuButton -Items $actions))))
    $add = New-FormSection -Form $form -Title 'Add a package for the current host pool' -Subtitle 'A running session host reads the image, so the hosts'' computer accounts need read access to the share.' -Fields @(
        @{ Name = 'Path'; Label = 'Image path (UNC to .vhdx, .cim or .appv)'; Required = $true; Span = 2 }
        @{ Name = 'Name'; Label = 'Package name'; Required = $true }
        @{ Name = 'DisplayName'; Label = 'Name users see'; Required = $true }
        @{ Name = 'PackageFullName'; Label = 'Package full name (only if the image holds several)'; Span = 2 }
        @{ Name = 'Inactive'; Label = 'Add it inactive'; Type = 'check'; Default = $false }
        @{ Name = 'RegisterAtSignIn'; Label = 'Register at sign-in (otherwise on demand)'; Type = 'check'; Default = $false }
    )
    $page.Group = New-GroupPicker -Purpose 'access to the package (optional)'
    $null = $add.Child.Children.Add($page.Group.Panel)
    $null = $add.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Add package' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-MsixAdd -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-MsixAdd -Page $c.Page -DryRun:$c.DryRun }))))
    $null = $root.Children.Add($add)
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Start-MsixLoad -Page $pg } }
    $page.Root = $root
    return $page
}

function Start-MsixLoad {
    param([hashtable]$Page)
    Start-Work -Name 'List app attach packages' -Context $Page -Script {
        $ErrorActionPreference = 'Stop'
        Get-AppAttachPackageInfo
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.Packages = @($result)
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows $pg.Packages -Columns @('Name', 'DisplayName', 'Version', 'Active', 'Registration', 'HostPools', 'Path', 'ResourceGroupName')).DefaultView
    }
}

function Get-MsixSelected {
    param([hashtable]$Page)
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -ne 1) { Show-Message 'Select one package.' 'App attach' 'Warning'; return $null }
    return ($Page.Packages | Where-Object { $_.Name -eq $sel[0].Name -and $_.ResourceGroupName -eq $sel[0].ResourceGroupName } | Select-Object -First 1)
}

function Invoke-MsixSet {
    param([hashtable]$Page, [string]$Active, [string]$Register)
    if (-not (Test-SignedIn)) { return }
    $pkg = Get-MsixSelected -Page $Page
    if (-not $pkg) { return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = $pkg.ResourceGroupName; Name = $pkg.Name }
    if ($Active) { $p.Active = [bool]::Parse($Active) }
    if ($Register) { $p.RegisterAtSignIn = [bool]::Parse($Register) }
    Invoke-RepoScript -Name "Change $($pkg.Name)" -Path $Gui.Scripts.MsixSet -Params $p -Context $Page -OnDone { param($result, $failure, $pg) if (-not $failure) { Start-MsixLoad -Page $pg } }
}

function Invoke-MsixAssignPool {
    param([hashtable]$Page)
    if (-not (Test-PoolSelected)) { return }
    $pkg = Get-MsixSelected -Page $Page
    if (-not $pkg) { return }
    $poolId = "/subscriptions/$($Gui.State.SubscriptionId)/resourceGroups/$($Gui.State.Pool.ResourceGroupName)/providers/Microsoft.DesktopVirtualization/hostPools/$($Gui.State.Pool.Name)"
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = $pkg.ResourceGroupName; Name = $pkg.Name; AddHostPoolId = $poolId }
    Invoke-RepoScript -Name "Assign $($pkg.Name) to $($Gui.State.Pool.Name)" -Path $Gui.Scripts.MsixSet -Params $p -Context $Page -OnDone { param($result, $failure, $pg) if (-not $failure) { Start-MsixLoad -Page $pg } }
}

function Invoke-MsixGrant {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    $pkg = Get-MsixSelected -Page $Page
    if (-not $pkg) { return }
    Start-EntraGroupChoice -Context @{ Page = $Page; Pkg = $pkg } -OnChosen {
        param($groupId, $c)
        Invoke-RepoScript -Name "Give a group access to $($c.Pkg.Name)" -Path $Gui.Scripts.MsixSet -Params @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = $c.Pkg.ResourceGroupName; Name = $c.Pkg.Name; GrantObjectId = $groupId }
    }
}

function Invoke-MsixAdd {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-PoolSelected)) { return }
    if (-not (Test-FormRequired -Form $Page.Form -Only @('Path', 'Name', 'DisplayName'))) { return }
    $f = $Page.Form
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; HostPoolResourceGroupName = $Gui.State.Pool.ResourceGroupName; HostPoolName = $Gui.State.Pool.Name }
    Add-FormParameter -Params $p -Form $f -Names @('Path', 'Name', 'DisplayName', 'PackageFullName', 'Inactive', 'RegisterAtSignIn')
    $gid = Get-GroupPickerId $Page.Group; if ($gid) { $p.GroupObjectId = $gid }
    Invoke-RepoScript -Name "Add app attach package $($p.Name)" -Path $Gui.Scripts.MsixNew -Params $p -DryRun:$DryRun -Context $Page -OnDone { param($result, $failure, $pg) if (-not $failure) { Start-MsixLoad -Page $pg } }
}

# --- Deployments (saved) and status ---------------------------------------------
function New-DeploymentsPage {
    $page = @{ Key = 'NavDeployPolicies'; Form = New-Form }
    $form = $page.Form
    $root = New-PageRoot -Title 'Deployment policies' -Lead 'A saved deployment is targets plus apps (winget IDs, shell apps, app groups), run again whenever you want: after adding hosts, or after an image update. They run on demand from here; they are not scheduled.'
    $page.ListGrid = New-DataGrid -Height 180
    $page.ListGrid.SelectionMode = 'Single'
    Add-ControlHandler -Control $page.ListGrid -EventName SelectionChanged -Context $page -Handler { param($pg) Update-DeploymentForm -Page $pg }
    $null = $root.Children.Add((New-TableCard -Title 'Saved deployments' -Grid $page.ListGrid -Tools @((New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Start-DeploymentLoad -Page $pg }))))
    $edit = New-FormSection -Form $form -Title 'Deployment' -Subtitle 'Target either a host pool (resource group and name) or a list of VMs. Saving an existing name replaces it.' -Fields @(
        @{ Name = 'Name'; Label = 'Name'; Required = $true }
        @{ Name = 'UsePool'; Label = 'Target the current host pool (fills the two fields below)'; Type = 'check'; Default = $true }
        @{ Name = 'HostPoolResourceGroupName'; Label = 'Host pool resource group' }
        @{ Name = 'HostPoolName'; Label = 'Host pool name' }
        @{ Name = 'VM'; Label = 'Or VMs (resource-group/name, one per line)'; Type = 'multiline'; Span = 2 }
        @{ Name = 'WingetId'; Label = 'winget IDs'; Type = 'multiline' }
        @{ Name = 'ShellApp'; Label = 'Shell apps'; Type = 'multiline' }
        @{ Name = 'AppGroup'; Label = 'App groups'; Type = 'multiline'; Span = 2 }
    )
    $null = $edit.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Save deployment' -Style 'PrimaryButton' -Context $page -OnClick { param($pg) Invoke-DeploymentSave -Page $pg }),
        (New-Button -Text 'Run selected now' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-DeploymentRun -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-DeploymentRun -Page $c.Page -DryRun:$c.DryRun }))))
    $null = $root.Children.Add($edit)
    $page.Grid = New-DataGrid -Height 200
    $null = $root.Children.Add((New-TableCard -Title 'Results' -Grid $page.Grid))
    $page.OnShow = { param($pg) if (-not $Gui.State.Busy) { Start-DeploymentLoad -Page $pg } }
    $page.Root = $root
    return $page
}

function Start-DeploymentLoad {
    param([hashtable]$Page)
    Start-ToolboxStoreLoad -Context $Page -OnDone {
        param($store, $pg)
        $pg.Store = $store
        $pg.ListGrid.ItemsSource = (ConvertTo-DataTable -Rows @(ConvertTo-StoreRow -Section $store.Deployments -Fields @('HostPoolName', 'VM', 'WingetId', 'ShellApp', 'AppGroup', 'Saved')) -Columns @('Name', 'HostPoolName', 'VM', 'WingetId', 'ShellApp', 'AppGroup', 'Saved')).DefaultView
        if ($Gui.State.Pool -and (Get-FormValue $pg.Form 'UsePool')) { Set-FormValue $pg.Form 'HostPoolResourceGroupName' $Gui.State.Pool.ResourceGroupName; Set-FormValue $pg.Form 'HostPoolName' $Gui.State.Pool.Name }
    }
}

function Update-DeploymentForm {
    param([hashtable]$Page)
    $sel = Get-GridSelection $Page.ListGrid
    if ($sel.Count -ne 1 -or -not $Page.ContainsKey('Store')) { return }
    $d = $Page.Store.Deployments[$sel[0].Name]
    Set-FormValue $Page.Form 'Name' $sel[0].Name
    Set-FormValue $Page.Form 'UsePool' $false
    foreach ($k in 'HostPoolResourceGroupName', 'HostPoolName') { Set-FormValue $Page.Form $k $(if ($d.Contains($k)) { $d[$k] } else { '' }) }
    foreach ($k in 'VM', 'WingetId', 'ShellApp', 'AppGroup') { Set-FormValue $Page.Form $k ($(if ($d.Contains($k)) { @($d[$k]) | Where-Object { $_ } } else { @() }) -join [Environment]::NewLine) }
}

function Invoke-DeploymentSave {
    param([hashtable]$Page)
    if (-not (Test-FormRequired -Form $Page.Form -Only @('Name'))) { return }
    $f = $Page.Form
    if ((Get-FormValue $f 'UsePool') -and $Gui.State.Pool) { Set-FormValue $f 'HostPoolResourceGroupName' $Gui.State.Pool.ResourceGroupName; Set-FormValue $f 'HostPoolName' $Gui.State.Pool.Name }
    $v = @{
        HostPoolResourceGroupName = (Get-FormValue $f 'HostPoolResourceGroupName'); HostPoolName = (Get-FormValue $f 'HostPoolName')
        VM = @(Split-CommaList (Get-FormValue $f 'VM')); WingetId = @(Split-CommaList (Get-FormValue $f 'WingetId'))
        ShellApp = @(Split-CommaList (Get-FormValue $f 'ShellApp')); AppGroup = @(Split-CommaList (Get-FormValue $f 'AppGroup'))
    }
    if (-not $v.HostPoolName -and $v.VM.Count -eq 0) { Show-Message 'Give a host pool or at least one VM.' 'Deployment' 'Warning'; return }
    if ($v.WingetId.Count + $v.ShellApp.Count + $v.AppGroup.Count -eq 0) { Show-Message 'Add at least one app.' 'Deployment' 'Warning'; return }
    Save-ToolboxItem -Kind 'Deployments' -Name (Get-FormValue $f 'Name') -Value $v -Context $Page -OnDone { param($pg) Start-DeploymentLoad -Page $pg }
}

function Invoke-DeploymentRun {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $sel = Get-GridSelection $Page.ListGrid
    if ($sel.Count -ne 1) { Show-Message 'Select a saved deployment.' 'Deployment' 'Warning'; return }
    Invoke-RepoScript -Name "Run deployment $($sel[0].Name)" -Path $Gui.Scripts.AppInstall -Params @{ SubscriptionId = $Gui.State.SubscriptionId; Deployment = $sel[0].Name } -DryRun:$DryRun -Context $Page -OnDone {
        param($result, $failure, $pg) if (-not $failure) { Show-InGuestResult -Grid $pg.Grid -Result @($result) -First 'App' }
    }
}

function New-DeploymentStatusPage {
    $page = @{ Key = 'NavDeployStatus' }
    $root = New-PageRoot -PoolBanner -Title 'Deployment status' -Lead 'What ran inside the VMs through this toolbox (and any other managed Run Command): last state, exit code, times and the last line of output, per VM. Opens on the current host pool.'
    $page.Targets = New-TargetPicker -Title 'Show for'
    $null = $root.Children.Add($page.Targets.Card)
    $null = $root.Children.Add((New-ButtonRow -Buttons @((New-Button -Text 'Load status' -Style 'PrimaryButton' -Context $page -OnClick { param($pg) Start-DeploymentStatusLoad -Page $pg }))))
    $page.Grid = New-DataGrid -Height 320
    $null = $root.Children.Add((New-TableCard -Title 'Run commands' -Grid $page.Grid))
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy -and $Gui.State.Pool -and (Get-ComboValue $pg.Targets.Mode) -eq 'pool') { Start-DeploymentStatusLoad -Page $pg } }
    $page.Root = $root
    return $page
}

function Start-DeploymentStatusLoad {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    $t = Get-TargetPickerParameter -Picker $Page.Targets
    if (-not $t) { return }
    Start-Work -Name 'Load run command status' -Argument $t -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        $p = @{}; foreach ($k in 'VM', 'HostPoolName', 'HostPoolResourceGroupName') { if ($Job.ContainsKey($k)) { $p[$k] = $Job[$k] } }
        Get-GuestRunCommandInfo -Target @(Resolve-GuestTarget @p)
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows @($result) -Columns @('VM', 'RunCommand', 'State', 'ExitCode', 'Started', 'Ended', 'LastLine')).DefaultView
    }
}
