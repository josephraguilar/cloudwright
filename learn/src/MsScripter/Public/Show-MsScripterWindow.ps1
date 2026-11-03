function Show-MsScripterWindow {
    <#
    .SYNOPSIS
        The graphical UI: a window with a task tree, drop-downs for each field, and a Generate button.
    .DESCRIPTION
        Windows only (WinForms). Same engine as the console: Get-MsTaskCatalog for the tree,
        Resolve-MsSource for drop-down contents (read-only lookups, loaded the first time a
        drop-down is opened), New-MsScript for the output. Nothing generated is ever run.

        Layout: tree on the left (areas > sections > tasks, plus Build paths). Pick a task
        and its fields appear on the right. Generate writes one-liners into the output box;
        tick "Explain steps" for the long form. Add to script appends instead of replacing.
    .PARAMETER CatalogRoot
        Defaults to the repo's catalog/ folder.
    .PARAMETER OutputDirectory
        Default folder for Save. Defaults to out/ (gitignored).
    .PARAMETER Contoso
        Start in Contoso mode (sample data, no sign-in). The toolbar button toggles it later.
    .EXAMPLE
        Show-MsScripterWindow
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [string]$CatalogRoot = $script:CatalogRoot,
        [Parameter()] [string]$OutputDirectory = (Join-Path (Join-Path (Join-Path $script:ModuleRoot '..') '..') 'out'),
        [Parameter()] [switch]$Contoso
    )

    #region 1. Preflight --------------------------------------------------------
    if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) { throw 'The window needs Windows (WinForms). Use Show-MsScripter for the console version.' }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $catalog = @(Get-MsTaskCatalog -CatalogRoot $CatalogRoot)
    if ($catalog.Count -eq 0) { throw "No tasks found under $CatalogRoot." }

    # Everything the event handlers need lives here, because handlers run later, outside this function's locals.
    $script:Win = @{
        Catalog   = $catalog
        Tasks     = @($catalog | Where-Object Kind -eq 'Task')
        Context   = @{}
        Current   = @()        # task objects currently shown
        Share     = @{}
        Controls  = @{}        # field Name -> control
        FieldDefs = @{}        # field Name -> field hashtable
        OutDir    = $OutputDirectory
    }
    #endregion

    #region 2. Build the window -------------------------------------------------
    $font = [System.Drawing.Font]::new('Segoe UI', 9)
    $mono = [System.Drawing.Font]::new('Consolas', 10)

    $form = [System.Windows.Forms.Form]::new()
    $form.Text = 'ms-scripter'
    $form.Font = $font
    $form.Size = [System.Drawing.Size]::new(1280, 820)
    $form.MinimumSize = [System.Drawing.Size]::new(900, 600)
    $form.StartPosition = 'CenterScreen'

    # Top bar: sign-in and subscription
    $top = [System.Windows.Forms.FlowLayoutPanel]::new()
    $top.Dock = 'Top'; $top.Height = 38; $top.Padding = [System.Windows.Forms.Padding]::new(6, 5, 6, 0); $top.WrapContents = $false

    $btnAz = [System.Windows.Forms.Button]::new(); $btnAz.Text = 'Sign in: Azure'; $btnAz.AutoSize = $true
    $btnMg = [System.Windows.Forms.Button]::new(); $btnMg.Text = 'Sign in: Graph (read-only)'; $btnMg.AutoSize = $true
    $cboSub = [System.Windows.Forms.ComboBox]::new(); $cboSub.Width = 320; $cboSub.DropDownStyle = 'DropDownList'; $cboSub.Enabled = $false
    $cboSub.DisplayMember = 'Display'
    $btnRefresh = [System.Windows.Forms.Button]::new(); $btnRefresh.Text = 'Refresh lists'; $btnRefresh.AutoSize = $true
    $lblStatus = [System.Windows.Forms.Label]::new(); $lblStatus.AutoSize = $true; $lblStatus.Padding = [System.Windows.Forms.Padding]::new(8, 6, 0, 0)
    $lblStatus.Text = 'Not signed in. Drop-downs accept typed values.'
    $chkContoso = [System.Windows.Forms.CheckBox]::new(); $chkContoso.Appearance = 'Button'; $chkContoso.Text = 'Contoso mode'; $chkContoso.AutoSize = $true
    $chkContoso.FlatStyle = 'System'; $chkContoso.Margin = [System.Windows.Forms.Padding]::new(12, 3, 3, 3)
    $tipContoso = [System.Windows.Forms.ToolTip]::new()
    $tipContoso.SetToolTip($chkContoso, 'Offline study mode. Drop-downs show a fictional Contoso tenant and fields pre-fill with examples. Nothing connects to anything.')
    foreach ($c in $btnAz, $btnMg, $cboSub, $btnRefresh, $chkContoso, $lblStatus) { $top.Controls.Add($c) }

    # Left: task tree
    $split = [System.Windows.Forms.SplitContainer]::new()
    $split.Dock = 'Fill'; $split.SplitterDistance = 300; $split.FixedPanel = 'Panel1'

    $tree = [System.Windows.Forms.TreeView]::new()
    $tree.Dock = 'Fill'; $tree.HideSelection = $false; $tree.Font = $font

    $searchBar = [System.Windows.Forms.Panel]::new(); $searchBar.Dock = 'Top'; $searchBar.Height = 30; $searchBar.Padding = [System.Windows.Forms.Padding]::new(4, 4, 4, 2)
    $txtSearch = [System.Windows.Forms.TextBox]::new(); $txtSearch.Dock = 'Fill'
    if ($txtSearch.PSObject.Properties['PlaceholderText']) { $txtSearch.PlaceholderText = 'Search tasks: name, cmdlet, section...' }   # .NET Core only
    $btnClearSearch = [System.Windows.Forms.Button]::new(); $btnClearSearch.Text = [string][char]0x2715; $btnClearSearch.Dock = 'Right'; $btnClearSearch.Width = 26; $btnClearSearch.FlatStyle = 'Flat'
    $btnClearSearch.FlatAppearance.BorderSize = 0; $btnClearSearch.TabStop = $false
    $searchBar.Controls.Add($txtSearch); $searchBar.Controls.Add($btnClearSearch)

    $split.Panel1.Controls.Add($tree); $split.Panel1.Controls.Add($searchBar)

    # Right: fields above, output below
    $right = [System.Windows.Forms.SplitContainer]::new()
    $right.Dock = 'Fill'; $right.Orientation = 'Horizontal'; $right.SplitterDistance = 380
    $split.Panel2.Controls.Add($right)

    $fieldsHost = [System.Windows.Forms.Panel]::new(); $fieldsHost.Dock = 'Fill'; $fieldsHost.AutoScroll = $true
    $fields = [System.Windows.Forms.TableLayoutPanel]::new()
    $fields.Dock = 'Top'; $fields.AutoSize = $true; $fields.AutoSizeMode = 'GrowAndShrink'; $fields.ColumnCount = 3
    $fields.Padding = [System.Windows.Forms.Padding]::new(8)
    $null = $fields.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 240))
    $null = $fields.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 360))
    $null = $fields.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
    $tips = [System.Windows.Forms.ToolTip]::new()
    $tips.InitialDelay = 150; $tips.AutoPopDelay = 30000; $tips.ReshowDelay = 100
    $fieldsHost.Controls.Add($fields)
    $right.Panel1.Controls.Add($fieldsHost)

    $bottom = [System.Windows.Forms.Panel]::new(); $bottom.Dock = 'Fill'
    $bar = [System.Windows.Forms.FlowLayoutPanel]::new(); $bar.Dock = 'Top'; $bar.Height = 36; $bar.Padding = [System.Windows.Forms.Padding]::new(6, 4, 6, 0); $bar.WrapContents = $false
    $btnGen = [System.Windows.Forms.Button]::new(); $btnGen.Text = 'Generate'; $btnGen.AutoSize = $true; $btnGen.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $btnAdd = [System.Windows.Forms.Button]::new(); $btnAdd.Text = 'Add to script'; $btnAdd.AutoSize = $true
    $chkExplain  = [System.Windows.Forms.CheckBox]::new(); $chkExplain.Text = 'Explain steps';     $chkExplain.AutoSize = $true; $chkExplain.Padding = [System.Windows.Forms.Padding]::new(10, 4, 0, 0)
    $chkContext  = [System.Windows.Forms.CheckBox]::new(); $chkContext.Text = 'Sign-in lines';     $chkContext.AutoSize = $true; $chkContext.Padding = [System.Windows.Forms.Padding]::new(6, 4, 0, 0)
    $chkVerify   = [System.Windows.Forms.CheckBox]::new(); $chkVerify.Text = 'Verify';             $chkVerify.AutoSize = $true;  $chkVerify.Padding = [System.Windows.Forms.Padding]::new(6, 4, 0, 0)
    $chkRollback = [System.Windows.Forms.CheckBox]::new(); $chkRollback.Text = 'Rollback (commented)'; $chkRollback.AutoSize = $true; $chkRollback.Padding = [System.Windows.Forms.Padding]::new(6, 4, 0, 0)
    $btnCopy  = [System.Windows.Forms.Button]::new(); $btnCopy.Text = 'Copy';  $btnCopy.AutoSize = $true; $btnCopy.Margin = [System.Windows.Forms.Padding]::new(16, 3, 3, 3)
    $btnSave  = [System.Windows.Forms.Button]::new(); $btnSave.Text = 'Save';  $btnSave.AutoSize = $true
    $btnClear = [System.Windows.Forms.Button]::new(); $btnClear.Text = 'Clear'; $btnClear.AutoSize = $true
    foreach ($c in $btnGen, $btnAdd, $chkExplain, $chkContext, $chkVerify, $chkRollback, $btnCopy, $btnSave, $btnClear) { $bar.Controls.Add($c) }

    $txtOut = [System.Windows.Forms.TextBox]::new()
    $txtOut.Multiline = $true; $txtOut.ScrollBars = 'Both'; $txtOut.WordWrap = $false; $txtOut.ReadOnly = $true
    $txtOut.Font = $mono; $txtOut.Dock = 'Fill'; $txtOut.BackColor = [System.Drawing.Color]::White
    $bottom.Controls.Add($txtOut); $bottom.Controls.Add($bar)
    $right.Panel2.Controls.Add($bottom)

    $form.Controls.Add($split); $form.Controls.Add($top)

    $script:Win.Form = $form; $script:Win.Tree = $tree; $script:Win.Fields = $fields; $script:Win.Out = $txtOut; $script:Win.Tips = $tips; $script:Win.Search = $txtSearch
    $script:Win.BtnAz = $btnAz; $script:Win.BtnMg = $btnMg; $script:Win.ChkContoso = $chkContoso
    $script:Win.Status = $lblStatus; $script:Win.Sub = $cboSub
    $script:Win.ChkExplain = $chkExplain; $script:Win.ChkContext = $chkContext; $script:Win.ChkVerify = $chkVerify; $script:Win.ChkRollback = $chkRollback
    #endregion

    #region 3. Fill the tree ----------------------------------------------------
    $tree.ShowNodeToolTips = $true
    Update-MsWindowTree
    #endregion

    #region 4. Event handlers ---------------------------------------------------
    $txtSearch.Add_TextChanged({ Update-MsWindowTree -Filter $script:Win.Search.Text })
    $txtSearch.Add_KeyDown({
        param($src, $evt)
        if ($evt.KeyCode -eq 'Escape') { $src.Clear(); $evt.SuppressKeyPress = $true }
        elseif ($evt.KeyCode -eq 'Down' -or $evt.KeyCode -eq 'Enter') { $script:Win.Tree.Focus() | Out-Null; if (-not $script:Win.Tree.SelectedNode -and $script:Win.Tree.Nodes.Count -gt 0) { $script:Win.Tree.SelectedNode = $script:Win.Tree.Nodes[0] }; $evt.SuppressKeyPress = $true }
    })
    $btnClearSearch.Add_Click({ $script:Win.Search.Clear(); $script:Win.Search.Focus() | Out-Null })
    $form.KeyPreview = $true
    $form.Add_KeyDown({
        param($src, $evt)
        if ($src -and $evt.Control -and $evt.KeyCode -eq 'F') { $script:Win.Search.Focus() | Out-Null; $script:Win.Search.SelectAll(); $evt.SuppressKeyPress = $true }
    })

    $chkContoso.Add_CheckedChanged({ param($src) Set-MsWindowContoso -On $src.Checked })

    $tree.Add_AfterSelect({
        param($src, $evt)
        if ($src -and $evt.Node.Tag) { Show-MsWindowTask -Entry $evt.Node.Tag }
    })

    $btnAz.Add_Click({
        $script:Win.Form.Cursor = 'WaitCursor'
        try {
            $ctx = Assert-MsAzContext
            if ($ctx) {
                $script:Win.Context.SubscriptionName = $ctx.Subscription.Name
                $script:Win.Context.SubscriptionId   = $ctx.Subscription.Id
                $script:Win.Context.TenantId         = $ctx.Tenant.Id
                $script:Win.Sub.Items.Clear()
                foreach ($s in (Get-AzSubscription -ErrorAction SilentlyContinue | Where-Object State -eq 'Enabled' | Sort-Object Name)) {
                    $null = $script:Win.Sub.Items.Add([pscustomobject]@{ Display = "$($s.Name)  ($($s.Id))"; Id = $s.Id; Name = $s.Name })
                }
                for ($i = 0; $i -lt $script:Win.Sub.Items.Count; $i++) { if ($script:Win.Sub.Items[$i].Id -eq $ctx.Subscription.Id) { $script:Win.Sub.SelectedIndex = $i } }
                $script:Win.Sub.Enabled = $true
                $script:Win.Status.Text = "Azure: $($ctx.Account.Id)"
            } else {
                $script:Win.Status.Text = 'Az.Accounts is not installed. Install-Module Az -Scope CurrentUser'
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Azure sign-in failed:`n$($_.Exception.Message)", 'ms-scripter') | Out-Null
        } finally { $script:Win.Form.Cursor = 'Default' }
    })

    $cboSub.Add_SelectionChangeCommitted({
        $pick = $script:Win.Sub.SelectedItem
        if (-not $pick) { return }
        $script:Win.Form.Cursor = 'WaitCursor'
        try {
            $ctx = Set-AzContext -Subscription $pick.Id
            $script:Win.Context.SubscriptionName = $ctx.Subscription.Name
            $script:Win.Context.SubscriptionId   = $ctx.Subscription.Id
            $script:SourceCache.Clear()
            $script:Win.Status.Text = "Azure: $($ctx.Account.Id) on '$($ctx.Subscription.Name)'"
        } finally { $script:Win.Form.Cursor = 'Default' }
    })

    $btnMg.Add_Click({
        $script:Win.Form.Cursor = 'WaitCursor'
        try {
            $ctx = Assert-MsGraphContext
            if ($ctx) {
                if (-not $script:Win.Context.ContainsKey('TenantId')) { $script:Win.Context.TenantId = $ctx.TenantId }
                $script:Win.Status.Text = ($script:Win.Status.Text -replace '^Not signed in.*$', '') + "  Graph: $($ctx.Account)"
            } else {
                $script:Win.Status.Text = 'Microsoft.Graph.Authentication is not installed.'
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Graph sign-in failed:`n$($_.Exception.Message)", 'ms-scripter') | Out-Null
        } finally { $script:Win.Form.Cursor = 'Default' }
    })

    $btnRefresh.Add_Click({ $script:SourceCache.Clear(); foreach ($c in $script:Win.Controls.Values) { if ($c -is [System.Windows.Forms.ComboBox]) { $c.Tag = $null } } })

    $btnGen.Add_Click({ Invoke-MsWindowGenerate -Append:$false })
    $btnAdd.Add_Click({ Invoke-MsWindowGenerate -Append:$true })
    $btnClear.Add_Click({ $script:Win.Out.Clear() })
    $btnCopy.Add_Click({
        if ($script:Win.Out.Text) { [System.Windows.Forms.Clipboard]::SetText($script:Win.Out.Text); $script:Win.Status.Text = 'Copied to clipboard. Nothing was executed.' }
    })
    $btnSave.Add_Click({
        if (-not $script:Win.Out.Text) { return }
        if (-not (Test-Path $script:Win.OutDir)) { $null = New-Item -ItemType Directory -Path $script:Win.OutDir }
        $dlg = [System.Windows.Forms.SaveFileDialog]::new()
        $dlg.InitialDirectory = (Resolve-Path $script:Win.OutDir).Path
        $dlg.Filter = 'PowerShell script (*.ps1)|*.ps1|All files (*.*)|*.*'
        $slug = if ($script:Win.Current.Count -gt 0) { (($script:Win.Current | ForEach-Object { ($_.Id -split '\.')[-1] }) -join '_') } else { 'script' }
        $dlg.FileName = "$slug-$(Get-Date -Format 'yyyyMMdd-HHmmss').ps1"
        if ($dlg.ShowDialog() -eq 'OK') {
            Set-Content -Path $dlg.FileName -Value $script:Win.Out.Text -Encoding utf8
            $script:Win.Status.Text = "Saved $($dlg.FileName)"
        }
    })
    #endregion

    #region 5. Show -------------------------------------------------------------
    if ($Contoso) { $chkContoso.Checked = $true }
    $form.Add_Shown({ $script:Win.Tree.Focus() | Out-Null })
    [void]$form.ShowDialog()
    $form.Dispose()
    #endregion
}

function Update-MsWindowTree {
    <#
    .SYNOPSIS
        (Re)build the task tree, optionally keeping only entries that match a search string.
    .DESCRIPTION
        Matches every word of the filter against title, Id, section, summary, and the cmdlet
        names the task emits, case-insensitively. All words must match. With a filter the
        tree is fully expanded so matches are visible; without one, only the top level is.
        The current selection is kept when it survives the filter.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Rebuilds a UI tree in memory. Changes nothing outside the window.')]
    [CmdletBinding()]
    param([Parameter()] [AllowEmptyString()] [string]$Filter = '')

    $tree = $script:Win.Tree
    $words = @($Filter.Trim() -split '\s+' | Where-Object { $_ })
    $selectedId = if ($tree.SelectedNode -and $tree.SelectedNode.Tag) { $tree.SelectedNode.Tag.Id } else { $null }

    $entries = foreach ($e in $script:Win.Catalog) {
        if ($words.Count -eq 0) { $e; continue }
        $hay = (@($e.Title, $e.Id, $e.Section, $e.Definition.Summary) + @(Get-MsEntryCmdlet -Entry $e)) -join ' '
        $ok = $true
        foreach ($w in $words) { if ($hay -notlike "*$w*") { $ok = $false; break } }
        if ($ok) { $e }
    }

    $tree.BeginUpdate()
    $tree.Nodes.Clear()
    $nodes = @{}
    $selectNode = $null
    foreach ($entry in ($entries | Sort-Object Section, Title)) {
        $parent = $null; $pathSoFar = ''
        foreach ($segment in ($entry.Section -split '/')) {
            $pathSoFar = if ($pathSoFar) { "$pathSoFar/$segment" } else { $segment }
            if (-not $nodes.ContainsKey($pathSoFar)) {
                $n = [System.Windows.Forms.TreeNode]::new($segment)
                if ($parent) { $null = $parent.Nodes.Add($n) } else { $null = $tree.Nodes.Add($n) }
                $nodes[$pathSoFar] = $n
            }
            $parent = $nodes[$pathSoFar]
        }
        $leaf = [System.Windows.Forms.TreeNode]::new($entry.Title)
        $leaf.Tag = $entry
        $leaf.ToolTipText = $entry.Definition.Summary
        $null = $parent.Nodes.Add($leaf)
        if ($entry.Id -eq $selectedId) { $selectNode = $leaf }
    }
    if ($words.Count -gt 0) { $tree.ExpandAll() } else { foreach ($n in $tree.Nodes) { $n.Expand() } }
    if ($selectNode) { $tree.SelectedNode = $selectNode }
    $tree.EndUpdate()

    $count = @($entries).Count
    if ($words.Count -gt 0) { $script:Win.Status.Text = "$count task(s) match '$($Filter.Trim())'." }
}

function Get-MsEntryCmdlet {
    <#
    .SYNOPSIS
        The cmdlet names a task emits (from Cmdlet steps and the first word of Raw lines), for search.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [object]$Entry)
    $d = $Entry.Definition
    if (-not $d.ContainsKey('Steps')) { return @() }
    $names = foreach ($st in @($d.Steps)) {
        if ($st.ContainsKey('Cmdlet')) { $st.Cmdlet }
        if ($st.ContainsKey('Raw')) { foreach ($line in @($st.Raw)) { foreach ($m in [regex]::Matches("$line", '\b[A-Z][a-z]+-[A-Z][A-Za-z]+\b')) { $m.Value } } }
    }
    return @($names | Select-Object -Unique)
}

function Set-MsWindowContoso {
    <#
    .SYNOPSIS
        Toggle Contoso mode in the window: sample data in, sign-in out, current task re-rendered.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Window state only.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [bool]$On)
    $w = $script:Win
    if ($On) {
        $w.Context = Set-MsContosoMode
        $w.BtnAz.Enabled = $false; $w.BtnMg.Enabled = $false; $w.Sub.Enabled = $false
        $w.Form.Text = 'ms-scripter  [Contoso mode: sample data, nothing is live]'
        $w.Form.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 240)
        $w.Status.Text = 'Contoso mode: fictional tenant contoso.com. Drop-downs are samples, fields are pre-filled with examples, nothing connects to anything.'
    } else {
        $null = Set-MsContosoMode -Off
        $w.Context = @{}
        $w.BtnAz.Enabled = $true; $w.BtnMg.Enabled = $true
        $w.Form.Text = 'ms-scripter'
        $w.Form.BackColor = [System.Drawing.SystemColors]::Control
        $w.Status.Text = 'Contoso mode off. Sign in for live drop-downs, or type values.'
    }
    $script:Remembered.Clear()
    foreach ($c in $w.Controls.Values) { if ($c -is [System.Windows.Forms.ComboBox]) { $c.Tag = $null } }
    if ($w.Tree.SelectedNode -and $w.Tree.SelectedNode.Tag) { Show-MsWindowTask -Entry $w.Tree.SelectedNode.Tag }
}

function Show-MsWindowTask {
    <#
    .SYNOPSIS
        Rebuild the fields panel for a task or build path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object]$Entry)

    $w = $script:Win
    $defs = @(); $share = @{}
    if ($Entry.Kind -eq 'Path') {
        foreach ($id in $Entry.Definition.Tasks) { $t = $w.Tasks | Where-Object Id -eq $id; if ($t) { $defs += $t } }
        if ($Entry.Definition.ContainsKey('Share')) { $share = $Entry.Definition.Share }
    } else { $defs = @($Entry) }
    $w.Current = $defs; $w.Share = $share; $w.Controls = @{}; $w.FieldDefs = @{}

    $panel = $w.Fields
    $panel.SuspendLayout()
    $panel.Controls.Clear(); $panel.RowStyles.Clear(); $panel.RowCount = 0

    $gray = [System.Drawing.Color]::DimGray
    $row = 0
    foreach ($t in $defs) {
        $d = $t.Definition
        $title = [System.Windows.Forms.Label]::new(); $title.Text = $d.Title; $title.AutoSize = $true
        $title.Font = [System.Drawing.Font]::new('Segoe UI', 11, [System.Drawing.FontStyle]::Bold); $title.Margin = [System.Windows.Forms.Padding]::new(0, 6, 0, 0)
        $panel.Controls.Add($title, 0, $row); $panel.SetColumnSpan($title, 3); $row++

        $summary = [System.Windows.Forms.Label]::new(); $summary.AutoSize = $true; $summary.MaximumSize = [System.Drawing.Size]::new(820, 0)
        $summary.Text = $d.Summary
        if ($d.ContainsKey('Learn')) { $summary.Text += "`n" + ((@($d.Learn) | ForEach-Object { "- $_" }) -join "`n") }
        $meta = @()
        if ($d.Requires.ContainsKey('Modules')) { $meta += "Needs: $($d.Requires.Modules -join ', ')" }
        if ($d.Requires.ContainsKey('Roles'))   { $meta += "Role: $($d.Requires.Roles -join '; ')" }
        if ($d.ContainsKey('Prerequisites') -and @($d.Prerequisites).Count -gt 0) {
            $names = foreach ($id in @($d.Prerequisites)) { $p = $w.Tasks | Where-Object Id -eq $id; if ($p) { $p.Title } else { $id } }
            $meta += "Do first: $($names -join '; ')"
        }
        $meta += "Status: $($d.Status)"
        $summary.Text += "`n" + ($meta -join '    ')
        $summary.ForeColor = $gray; $summary.Margin = [System.Windows.Forms.Padding]::new(0, 2, 0, 8)
        $panel.Controls.Add($summary, 0, $row); $panel.SetColumnSpan($summary, 3); $row++

        foreach ($f in @($d.Fields)) {
            if ($w.Controls.ContainsKey($f.Name)) { continue }                                   # same field name in an earlier task
            if ($share.ContainsKey($f.Name) -and $w.Controls.ContainsKey($share[$f.Name])) { continue }   # provided by an earlier task's answer
            $w.FieldDefs[$f.Name] = $f

            $lbl = [System.Windows.Forms.Label]::new(); $lbl.AutoSize = $true; $lbl.Margin = [System.Windows.Forms.Padding]::new(0, 7, 6, 0)
            $lbl.Text = $f.Label + $(if ($f.ContainsKey('Required') -and $f.Required) { ' *' } else { '' })
            $panel.Controls.Add($lbl, 0, $row)

            $ctl = New-MsWindowControl -Field $f
            if ($ctl) {
                $panel.Controls.Add($ctl, 1, $row)
                $w.Controls[$f.Name] = $ctl
            }

            $info = New-MsWindowInfoIcon -Field $f
            $panel.Controls.Add($info, 2, $row)
            $row++
        }
    }
    $panel.RowCount = $row
    $panel.ResumeLayout()
    $w.Status.Text = "$($defs.Count) task(s) selected. Fill the fields, then Generate."
}

function New-MsWindowControl {
    <#
    .SYNOPSIS
        One WinForms control for one field. Drop-downs load their list on first open.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates a UI control in memory. Changes nothing outside the window.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable]$Field)

    $remembered = if ($script:Remembered.ContainsKey($Field.Name)) { $script:Remembered[$Field.Name] } else { $null }
    $default = if ($null -ne $remembered) { $remembered } elseif ($Field.ContainsKey('Default')) { $Field.Default } else { $null }
    if ($null -eq $default -and $script:ContosoMode -and $Field.ContainsKey('Example')) { $default = $Field.Example }

    switch ($Field.Type) {
        'Secret'    { return $null }
        'Reference' { return $null }
        { $_ -in 'Bool', 'TrueFalse' } {
            $c = [System.Windows.Forms.CheckBox]::new(); $c.AutoSize = $true; $c.Margin = [System.Windows.Forms.Padding]::new(0, 6, 0, 0)
            $c.Checked = [bool]$(if ($default -is [bool]) { $default } else { "$default" -match '^(y|yes|true|1)$' })
            return $c
        }
        'Choice' {
            $c = [System.Windows.Forms.ComboBox]::new(); $c.Width = 350; $c.DropDownStyle = 'DropDown'
            $c.DisplayMember = 'Display'; $c.ValueMember = 'Value'; $c.Name = $Field.Name
            if ($Field.ContainsKey('Options')) {
                foreach ($item in (ConvertTo-MsWindowItem -Options $Field.Options)) { $null = $c.Items.Add($item) }
                $c.Tag = 'loaded'
            } elseif ($Field.ContainsKey('Source')) {
                if ($script:ContosoMode) {
                    # Offline: fill now from sample data and pre-select the first row (or the one matching the default).
                    $items = Get-MsWindowSourceItem -FieldName $Field.Name
                    if ($items) {
                        foreach ($i in $items) { $null = $c.Items.Add($i) }
                        $c.Tag = 'loaded'
                        $pick = if ($null -ne $default) { @($items | Where-Object { $_.Value -eq "$default" -or $_.Display -eq "$default" })[0] } else { $null }
                        if (-not $pick) { $pick = @($items)[0] }
                        $c.SelectedItem = $pick
                        return $c
                    }
                }
                $c.Add_DropDown({
                    param($src)
                    if ($src.Tag -eq 'loaded') { return }
                    $items = Get-MsWindowSourceItem -FieldName $src.Name
                    if ($items) {
                        $typed = $src.Text
                        $src.Items.Clear()
                        foreach ($i in $items) { $null = $src.Items.Add($i) }
                        $src.Tag = 'loaded'
                        $src.Text = $typed
                    }
                })
            }
            if ($null -ne $default) { $c.Text = "$default" }
            return $c
        }
        'MultiChoice' {
            # A panel: checked list on top (live or static items), free-text box underneath for extras.
            $p = [System.Windows.Forms.Panel]::new(); $p.Width = 350; $p.Height = 118; $p.Name = $Field.Name; $p.Tag = 'multi'
            $list = [System.Windows.Forms.CheckedListBox]::new(); $list.Width = 350; $list.Height = 90; $list.CheckOnClick = $true
            $list.DisplayMember = 'Display'; $list.ValueMember = 'Value'; $list.Name = $Field.Name
            $extra = [System.Windows.Forms.TextBox]::new(); $extra.Width = 350; $extra.Top = 92
            if ($extra.PSObject.Properties['PlaceholderText']) { $extra.PlaceholderText = 'extra values, comma separated' }   # .NET Core only
            if ($Field.ContainsKey('Options')) {
                foreach ($item in (ConvertTo-MsWindowItem -Options $Field.Options)) { $null = $list.Items.Add($item) }
                $list.Tag = 'loaded'
            } elseif ($Field.ContainsKey('Source') -and $script:ContosoMode) {
                $items = Get-MsWindowSourceItem -FieldName $Field.Name
                if ($items) { foreach ($i in $items) { $null = $list.Items.Add($i) }; $list.Tag = 'loaded'; if ($list.Items.Count -gt 0) { $list.SetItemChecked(0, $true) } }
            } elseif ($Field.ContainsKey('Source')) {
                $list.Add_Enter({
                    param($src)
                    if ($src.Tag -eq 'loaded') { return }
                    $items = Get-MsWindowSourceItem -FieldName $src.Name
                    if ($items) { foreach ($i in $items) { $null = $src.Items.Add($i) }; $src.Tag = 'loaded' }
                })
            }
            if ($default -is [array]) { $extra.Text = $default -join ', ' } elseif ($null -ne $default) { $extra.Text = "$default" }
            $p.Controls.Add($list); $p.Controls.Add($extra)
            return $p
        }
        default {
            $c = [System.Windows.Forms.TextBox]::new(); $c.Width = 350
            if ($null -ne $default) { $c.Text = $(if ($default -is [hashtable]) { ($default.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ' } else { "$default" }) }
            return $c
        }
    }
}

function New-MsWindowInfoIcon {
    <#
    .SYNOPSIS
        A small (i) icon next to a field. Hover for the description; click to read it in a box.
    .DESCRIPTION
        Text comes from the field's Help, plus the example and, for secrets, a note that the
        script prompts at run time. Every field has Help; the catalog test enforces it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates a UI control in memory.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable]$Field)

    $bits = @()
    if ($Field.ContainsKey('Help'))     { $bits += $Field.Help }
    if ($Field.ContainsKey('Example'))  { $bits += "Example: $($Field.Example)" }
    if ($Field.Type -eq 'Secret')       { $bits += 'Not asked here. The generated script prompts for it when you run it.' }
    if ($Field.Type -eq 'Reference')    { $bits += "Takes the same value as '$($Field.From)'." }
    if ($Field.ContainsKey('Source'))   { $bits += "List: $($Field.Source.Cmdlet) (needs sign-in). You can also type a value." }
    if ($Field.ContainsKey('Pattern'))  { $bits += "Format: $($Field.Pattern)" }
    $text = ($bits | ForEach-Object { Format-MsWrappedText -Text $_ -Width 95 }) -join "`n`n"

    $icon = [System.Windows.Forms.Label]::new()
    $icon.Text = [string][char]0x24D8          # circled i
    $icon.Font = [System.Drawing.Font]::new('Segoe UI', 11)
    $icon.ForeColor = [System.Drawing.Color]::SteelBlue
    $icon.AutoSize = $true
    $icon.Cursor = [System.Windows.Forms.Cursors]::Help
    $icon.Margin = [System.Windows.Forms.Padding]::new(6, 3, 0, 0)
    $icon.Tag = @{ Title = $Field.Label; Text = $text }
    $script:Win.Tips.SetToolTip($icon, $text)
    $icon.Add_Click({
        param($src)
        [System.Windows.Forms.MessageBox]::Show($src.Tag.Text, $src.Tag.Title, 'OK', 'Information') | Out-Null
    })
    return $icon
}

function Format-MsWrappedText {
    <#
    .SYNOPSIS
        Word-wrap a paragraph at a column, for tooltips (which do not wrap on their own).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Text, [Parameter()] [int]$Width = 95)
    $lines = [System.Collections.Generic.List[string]]::new()
    $line = ''
    foreach ($word in ($Text -split '\s+')) {
        if ($line.Length -gt 0 -and ($line.Length + 1 + $word.Length) -gt $Width) { $lines.Add($line); $line = $word }
        elseif ($line.Length -eq 0) { $line = $word }
        else { $line = "$line $word" }
    }
    if ($line) { $lines.Add($line) }
    return ($lines -join "`n")
}

function ConvertTo-MsWindowItem {
    <#
    .SYNOPSIS
        Static Options -> Display/Value objects for list controls.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]]$Options)
    foreach ($o in $Options) {
        if ($o -is [hashtable]) { [pscustomobject]@{ Display = $o.Display; Value = $o.Value } }
        else { [pscustomobject]@{ Display = "$o"; Value = "$o" } }
    }
}

function Get-MsWindowSourceItem {
    <#
    .SYNOPSIS
        Run a field's read-only lookup with the current answers, with a wait cursor and a status line.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$FieldName)
    $f = $script:Win.FieldDefs[$FieldName]
    $script:Win.Form.Cursor = 'WaitCursor'
    try {
        $answers = Get-MsWindowAnswer
        $items = Resolve-MsSource -Source $f.Source -Answers $answers -Fields @($script:Win.FieldDefs.Values)
        if ($items) { $script:Win.Status.Text = "$(@($items).Count) item(s) from $($f.Source.Cmdlet)." }
        else { $script:Win.Status.Text = "No list for '$($f.Label)': not signed in, or $($f.Source.Cmdlet) is unavailable. Type the value." }
        return $items
    } catch {
        $script:Win.Status.Text = "Lookup failed: $($_.Exception.Message)"
        return $null
    } finally { $script:Win.Form.Cursor = 'Default' }
}

function Get-MsWindowAnswer {
    <#
    .SYNOPSIS
        Read every field control into a Name -> value hashtable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $answers = @{}
    foreach ($name in $script:Win.Controls.Keys) {
        $c = $script:Win.Controls[$name]
        $f = $script:Win.FieldDefs[$name]
        $value = $null
        if ($c -is [System.Windows.Forms.CheckBox]) { $value = $c.Checked }
        elseif ($c -is [System.Windows.Forms.ComboBox]) {
            if ($c.SelectedItem -and $c.SelectedItem.Display -eq $c.Text) { $value = $c.SelectedItem.Value }
            else { $value = $c.Text.Trim() }
        }
        elseif ($c -is [System.Windows.Forms.Panel] -and $c.Tag -eq 'multi') {
            $list = $c.Controls[0]; $extra = $c.Controls[1]
            $value = @(@($list.CheckedItems | ForEach-Object { $_.Value }) + @(($extra.Text -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }))
        }
        else {
            $text = $c.Text.Trim()
            if ($text -and $f.Type -eq 'Hashtable') { $value = ConvertFrom-MsFieldText -Text $text -Type Hashtable } else { $value = $text }
        }
        $empty = $null -eq $value -or ($value -is [string] -and $value -eq '') -or ($value -is [array] -and $value.Count -eq 0)
        if (-not $empty) { $answers[$name] = $value; $script:Remembered[$name] = $value }
    }
    return $answers
}

function Invoke-MsWindowGenerate {
    <#
    .SYNOPSIS
        Generate the script for the current task(s) into the output box.
    #>
    [CmdletBinding()]
    param([Parameter()] [switch]$Append)
    $w = $script:Win
    if ($w.Current.Count -eq 0) { $w.Status.Text = 'Pick a task in the tree first.'; return }
    try {
        $answers = Get-MsWindowAnswer
        $style = if ($w.ChkExplain.Checked) { 'Explained' } else { 'OneLiner' }
        $text = New-MsScript -Task $w.Current -Answers $answers -Context $w.Context -Share $w.Share -Style $style `
            -WithContext:$w.ChkContext.Checked -WithVerify:$w.ChkVerify.Checked -WithRollback:$w.ChkRollback.Checked
        $text = $text -replace "(?<!`r)`n", "`r`n"
        if ($Append -and $w.Out.Text) { $w.Out.AppendText("`r`n" + $text) } else { $w.Out.Text = $text }
        $w.Status.Text = 'Generated. Review it, then copy into another window to run. Nothing was executed.'
    } catch {
        $w.Status.Text = 'Cannot generate. See message.'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'ms-scripter') | Out-Null
    }
}
