<#
.SYNOPSIS
    WPF front end for the toolkit: module list on the left, one view at a time, a shared Review-and-run panel at the bottom.
.DESCRIPTION
    Windows only (WPF). Loads gui/Theme.xaml (the Genesis design tokens, see docs/gui/design-reference.md)
    and the views under gui/Views/. No tenant logic lives here: every action calls a module
    function or composes a task-script command line.

    Plan, then run: the GUI never executes a change by itself.
      1. Prepare composes the task-script command (the same line you could type in a
         terminal) into the review panel at the bottom.
      2. Dry run executes it with -WhatIf and lists, in plain words plus the exact
         Exchange/Graph command, every change it would make and in which tenant. Nothing
         changes. Run stays disabled until this has happened for the exact text shown.
      3. Run asks for confirmation with that list, then runs the command with the list as
         its approved plan: any change that is not on the list is refused before it runs.
    Read-only tasks run with an empty approved plan, so they cannot change anything even if
    one were mislabelled. Sign-in, inspect and status polling run directly.

    Views:
      GDAP Management   guided workflow (GdapView.xaml) over GdapHelpers
      every other area  generic TaskView: the scripts in that folder, discovered by
                        ToolkitHelpers, each rendered as a form from its parameters
    Graph and Exchange calls run on one background runspace so the window never freezes and
    the session persists between clicks. Scripts sign in themselves (Assert-M365Graph /
    Assert-M365Exchange) when run from the panel.

    Customer approval for GDAP opens on this machine: an in-app WebView2 window with an
    isolated profile when the assemblies are in gui/lib/webview2, else a private browser.
.PARAMETER Module
    Open on this module. Default GDAP.
.EXAMPLE
    pwsh -STA ./scripts/powershell/gui/Start-M365Gui.ps1
.NOTES
    Requires: Windows, PowerShell 7 (STA), Microsoft.Graph.Identity.Partner, Microsoft.Graph.Groups
    Status:   Untested (cannot run WPF off Windows; XAML is well-formedness checked in CI)
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Module = 'GDAP'
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   WPF assemblies, theme, modules, settings, catalog. STA is required by WPF.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The GUI needs Windows (WPF). Use Start-M365Console.ps1 or the scripts directly elsewhere.' }
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'Run with: pwsh -STA ./scripts/powershell/gui/Start-M365Gui.ps1' }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$guiRoot = $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $guiRoot '..' '..' '..')).Path
$modules = Join-Path $guiRoot '..' 'modules'
foreach ($m in 'M365Helpers', 'GdapHelpers', 'ToolkitHelpers') { Import-Module (Join-Path $modules $m "$m.psd1") -Force }
try { $settings = Get-M365Settings } catch { throw "Setup has not been run on this machine. From the repo folder run: .\Start-Toolkit.ps1  ($($_.Exception.Message))" }
$partnerTenant = $settings.msp.homeTenantId
$template = try { Get-GdapTemplate -Settings $settings } catch { $null }
$templateError = if (-not $template) { $Error[0].Exception.Message } else { $null }
$runsDir = [IO.Path]::GetFullPath((Join-Path $repoRoot 'runs'))
$webView2Dir = Join-Path $guiRoot 'lib' 'webview2'
$script:WebView2Available = @('Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.Wpf.dll', 'WebView2Loader.dll') |
    ForEach-Object { Test-Path (Join-Path $webView2Dir $_) } | Where-Object { -not $_ } | Measure-Object | ForEach-Object { $_.Count -eq 0 }
$catalog = @(Get-M365Task)
$clients = @(Get-ChildItem (Join-Path $repoRoot 'config' 'clients') -Filter '*.local.json' -ErrorAction SilentlyContinue | ForEach-Object {
        try { Get-M365ClientConfig -Path $_.FullName -Settings $settings } catch { Write-Warning "Skipping client config $($_.Name): $($_.Exception.Message)"; $null }
    } | Where-Object { $_ })

$themePath = Join-Path $guiRoot 'Theme.xaml'
function Import-Xaml {
    <#
    .SYNOPSIS
        Loads a XAML file; -InjectTheme merges the theme into the root before parsing so StaticResource resolves.
    #>
    param([string]$Path, [switch]$InjectTheme)
    [xml]$xml = Get-Content -Path $Path -Raw
    if ($InjectTheme) {
        $root = $xml.DocumentElement; $ns = $root.NamespaceURI
        $resources = $xml.CreateElement("$($root.LocalName).Resources", $ns)
        $dict = $xml.CreateElement('ResourceDictionary', $ns)
        $merged = $xml.CreateElement('ResourceDictionary.MergedDictionaries', $ns)
        $themeRef = $xml.CreateElement('ResourceDictionary', $ns)
        $themeRef.SetAttribute('Source', ([Uri]$themePath).AbsoluteUri)
        $null = $merged.AppendChild($themeRef); $null = $dict.AppendChild($merged); $null = $resources.AppendChild($dict)
        $null = $root.PrependChild($resources)
    }
    try {
        return [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xml))
    } catch {
        $e = $_.Exception; $chain = @()
        while ($e) { $chain += $e.Message; $e = $e.InnerException }
        $pos = if ($_.Exception.PSObject.Properties.Name -contains 'LineNumber') { " (line $($_.Exception.LineNumber), position $($_.Exception.LinePosition))" } else { '' }
        throw "XAML load failed for $(Split-Path $Path -Leaf)$pos`: $($chain -join ' <- ')"
    }
}
$theme = Import-Xaml -Path $themePath

$fontDir = Join-Path $guiRoot 'fonts'
if (Get-ChildItem $fontDir -Include '*.ttf', '*.otf' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1) {
    $baseUri = [Uri]::new(($fontDir.TrimEnd('\', '/') + '\'))
    $theme['DisplayFontFamily'] = [Windows.Media.FontFamily]::new($baseUri, './#General Sans, Segoe UI Variable Display, Segoe UI')
    $theme['BodyFontFamily'] = [Windows.Media.FontFamily]::new($baseUri, './#DM Sans, Segoe UI Variable Text, Segoe UI')
    $theme['CodeFontFamily'] = [Windows.Media.FontFamily]::new($baseUri, './#JetBrains Mono, Cascadia Mono, Consolas')
}
#endregion

#region 3. Background worker ------------------------------------------------------
#   WHAT   One persistent runspace; jobs run one at a time; a DispatcherTimer hands results back.
#   WHY    One runspace so the Graph/Exchange sessions a script creates are reused by the next.
$script:Worker = [ordered]@{ Runspace = $null; Current = $null; Queue = [System.Collections.Queue]::new() }
$script:Worker.Runspace = [runspacefactory]::CreateRunspace([System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault())
$script:Worker.Runspace.ApartmentState = 'MTA'; $script:Worker.Runspace.ThreadOptions = 'ReuseThread'; $script:Worker.Runspace.Open()
$boot = [powershell]::Create(); $boot.Runspace = $script:Worker.Runspace
#   GOTCHA $ConfirmPreference = 'None': the worker has no console, so a script's own
#          High-impact confirmation would throw. The GUI's confirmation (with the plan) replaces it.
$bootScript = "Set-StrictMode -Version Latest; `$ConfirmPreference = 'None'; foreach (`$m in 'M365Helpers','GdapHelpers') { Import-Module (Join-Path '$modules' `$m (`$m + '.psd1')) -Force }; Set-Location '$repoRoot'"
$null = $boot.AddScript($bootScript).Invoke()
$boot.Dispose()

function Invoke-GuiJob {
    #   GOTCHA OnComplete runs later, from the timer, when the caller's local variables are
    #          gone. Anything it needs from the caller goes in -Context; it arrives as the
    #          second argument: param($out, $context).
    param([string]$Name, [scriptblock]$Script, [hashtable]$Arguments = @{}, [scriptblock]$OnComplete, [scriptblock]$OnError, $Context)
    $script:Worker.Queue.Enqueue([pscustomobject]@{ Name = $Name; Script = $Script; Arguments = $Arguments; OnComplete = $OnComplete; OnError = $OnError; Context = $Context })
    Invoke-NextJob
}
function Invoke-NextJob {
    if ($script:Worker.Current -or $script:Worker.Queue.Count -eq 0) { return }
    $job = $script:Worker.Queue.Dequeue()
    $ps = [powershell]::Create(); $ps.Runspace = $script:Worker.Runspace
    $null = $ps.AddScript($job.Script.ToString()).AddParameters($job.Arguments)
    $job | Add-Member -NotePropertyName PowerShell -NotePropertyValue $ps
    $job | Add-Member -NotePropertyName Handle -NotePropertyValue $ps.BeginInvoke()
    $script:Worker.Current = $job
    Write-Activity "Working: $($job.Name)"
    Show-DockState
}
function Complete-CurrentJob {
    $job = $script:Worker.Current
    if (-not $job -or -not $job.Handle.IsCompleted) { return }
    $script:Worker.Current = $null
    try {
        $output = @($job.PowerShell.EndInvoke($job.Handle))
        foreach ($w in $job.PowerShell.Streams.Warning) { Write-Activity "warning: $($w.Message)" }
        if ($job.PowerShell.Streams.Error.Count -gt 0) { throw $job.PowerShell.Streams.Error[0].Exception }
        if ($job.OnComplete) { & $job.OnComplete $output $job.Context }
    } catch {
        Write-Activity "error: $($_.Exception.Message)"
        if ($job.OnError) { & $job.OnError $_.Exception.Message }
    } finally { $job.PowerShell.Dispose() }
    Invoke-NextJob
    Show-DockState
}
#endregion

#region 4. Shell window with the Review-and-run dock -----------------------------------
$shellXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="365-MGMT" Width="1360" Height="920" MinWidth="1024" MinHeight="700"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource BackgroundBrush}"
        FontFamily="{DynamicResource BodyFontFamily}" TextOptions.TextFormattingMode="Ideal" UseLayoutRounding="True">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="56"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Border Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="0,0,0,1" Padding="24,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock VerticalAlignment="Center" FontFamily="{DynamicResource DisplayFontFamily}" FontSize="18" FontWeight="Bold" Foreground="{DynamicResource TextPrimaryBrush}" Text="365-MGMT"/>
        <TextBlock x:Name="NavTenant" Grid.Column="2" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextSecondaryBrush}" Text=""/>
      </Grid>
    </Border>
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="240"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Border Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="0,0,1,0" Padding="12,16">
        <StackPanel>
          <TextBlock Style="{DynamicResource OverlineText}" Margin="12,0,0,8" Text="Modules"/>
          <ListBox x:Name="ModuleList" BorderThickness="0" Background="Transparent" ItemContainerStyle="{DynamicResource NavItem}"/>
        </StackPanel>
      </Border>
      <ContentControl x:Name="ViewHost" Grid.Column="1"/>
    </Grid>
    <Border Grid.Row="2" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="0,1,0,0" Padding="24,16">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="3*"/>
          <ColumnDefinition Width="2*"/>
        </Grid.ColumnDefinitions>
        <StackPanel Margin="0,0,20,0">
          <Grid Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Style="{DynamicResource CardTitle}" Margin="0" Text="Review and run"/>
            <Border x:Name="CommandChip" Grid.Column="1" Style="{DynamicResource Chip}"><TextBlock x:Name="CommandChipText" Style="{DynamicResource ChipText}" Text="Nothing prepared"/></Border>
          </Grid>
          <TextBox x:Name="CommandBox" Style="{DynamicResource Input}" FontFamily="{DynamicResource CodeFontFamily}" FontSize="13" IsReadOnly="True"
                   AcceptsReturn="True" TextWrapping="Wrap" Height="72" VerticalScrollBarVisibility="Auto"/>
          <TextBlock x:Name="PlanTitle" Style="{DynamicResource CaptionText}" Margin="0,10,0,4" Text="Changes it will make: run the dry run to see them."/>
          <TextBox x:Name="PlanBox" Style="{DynamicResource Input}" FontFamily="{DynamicResource CodeFontFamily}" FontSize="12" IsReadOnly="True"
                   AcceptsReturn="True" TextWrapping="NoWrap" Height="150" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
          <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
            <Button x:Name="DryRunButton" Style="{DynamicResource SecondaryButton}" Content="1. Dry run: show the changes" IsEnabled="False"/>
            <Button x:Name="RunCommandButton" Style="{DynamicResource PrimaryButton}" Margin="12,0,0,0" Content="2. Make these changes" IsEnabled="False"/>
            <Button x:Name="CopyCommandButton" Style="{DynamicResource SecondaryButton}" Margin="12,0,0,0" Content="Copy" IsEnabled="False"/>
            <Button x:Name="ClearCommandButton" Style="{DynamicResource GhostButton}" Margin="12,0,0,0" Content="Clear" IsEnabled="False"/>
            <TextBlock x:Name="DockHint" Style="{DynamicResource CaptionText}" Margin="16,0,0,0" VerticalAlignment="Center" TextWrapping="Wrap" MaxWidth="420" Text="Nothing runs until you choose. A dry run lists every change first."/>
          </StackPanel>
        </StackPanel>
        <StackPanel Grid.Column="1">
          <TextBlock Style="{DynamicResource CardTitle}" Margin="0,0,0,8" Text="Activity"/>
          <TextBox x:Name="LogBox" Style="{DynamicResource Input}" FontFamily="{DynamicResource CodeFontFamily}" FontSize="12" IsReadOnly="True"
                   AcceptsReturn="True" TextWrapping="Wrap" Height="300" VerticalScrollBarVisibility="Auto"/>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
'@
[xml]$shellXml = $shellXaml
$window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($shellXml))
$window.Resources.MergedDictionaries.Add($theme)
$ui = @{}
foreach ($name in 'NavTenant', 'ModuleList', 'ViewHost', 'CommandChip', 'CommandChipText', 'CommandBox', 'PlanTitle', 'PlanBox', 'RunCommandButton', 'DryRunButton', 'CopyCommandButton', 'ClearCommandButton', 'DockHint', 'LogBox') { $ui[$name] = $window.FindName($name) }
$ui.NavTenant.Text = "Partner tenant: $partnerTenant   |   $($catalog.Count) tasks"

function Write-Activity {
    param([string]$Text)
    if (-not $ui.LogBox) { return }
    $ui.LogBox.AppendText("$(Get-Date -Format HH:mm:ss)  $Text`r`n"); $ui.LogBox.ScrollToEnd()
}
function Show-Chip {
    param($Border, $TextBlock, [string]$Text, [ValidateSet('Neutral', 'Success', 'Warning', 'Error', 'Active')][string]$Kind = 'Neutral')
    $Border.Style = $theme[$(switch ($Kind) { 'Success' { 'ChipSuccess' } 'Warning' { 'ChipWarning' } 'Error' { 'ChipError' } 'Active' { 'ChipActive' } default { 'Chip' } })]
    $TextBlock.Style = $theme[$(if ($Kind -eq 'Neutral') { 'ChipText' } else { 'ChipTextOnColor' })]
    $TextBlock.Text = $Text
}

#   WHAT   The dock: Show-Command fills it; Invoke-PreparedCommand runs exactly its text as a
#          dry run (collects the plan) or as a run (enforces the plan).
#   WHY    One place for the plan-then-run rule, shared by every view.
#   GOTCHA The job wrapper catches errors and returns the change records with them, so a
#          failure halfway still shows what was planned, done, refused or failed.
$script:Command = $null
$script:CommandJob = {
    param($Text, $Mode, $Plan)
    $ErrorActionPreference = 'Stop'
    switch ($Mode) {
        'DryRun' { Start-M365ChangeRecording }
        'Run' { Start-M365ChangeRecording -ApprovedPlan @($Plan) }
        default { Start-M365ChangeRecording -ApprovedPlan @() }
    }
    $out = @(); $failure = $null
    try { $out = @(& ([scriptblock]::Create($Text)) 2>&1) } catch { $failure = $_.Exception.Message }
    $records = Stop-M365ChangeRecording
    [pscustomobject]@{ PSTypeName = 'M365.GuiResult'; Output = $out; Records = @($records); Failure = $failure }
}
function Format-PlanText {
    param([object[]]$Records)
    $n = 0
    (@($Records | ForEach-Object { $n++; "{0,2}. [{1}] {2}`r`n      {3}" -f $n, $_.Tenant, $_.Action, $_.Command }) -join "`r`n")
}
function Test-CommandInteractive {
    #   WHAT   A task that prompts at the keyboard cannot run in the GUI worker. Its .NOTES line
    #          can name the switch that avoids the prompt ("... unless -GeneratePassword"), and
    #          a prepared command that already carries that switch is not interactive.
    param($TaskInfo, [System.Collections.IDictionary]$Values)
    if (-not $TaskInfo.IsInteractive) { return $false }
    $avoid = @([regex]::Matches("$($TaskInfo.InteractiveNote)", '(?i)unless\s+-(\w+)') | ForEach-Object { $_.Groups[1].Value })
    foreach ($a in $avoid) { if ($Values.Contains($a) -and $Values[$a]) { return $false } }
    return $true
}
function Show-DockState {
    $has = -not [string]::IsNullOrWhiteSpace($ui.CommandBox.Text)
    $idle = -not $script:Worker.Current
    $cmd = $script:Command
    $interactive = [bool]($cmd -and $cmd.Interactive)
    $planReady = [bool]($cmd -and $cmd.IsWrite -and $null -ne $cmd.Plan -and $cmd.PlannedText -eq $ui.CommandBox.Text)
    $ui.DryRunButton.IsEnabled = $has -and $idle -and $cmd -and $cmd.IsWrite
    $ui.RunCommandButton.IsEnabled = $has -and $idle -and -not $interactive -and $cmd -and ((-not $cmd.IsWrite) -or $planReady)
    $ui.RunCommandButton.Content = if ($cmd -and -not $cmd.IsWrite) { 'Run (read-only)' } else { '2. Make these changes' }
    $ui.DockHint.Text = if ($interactive) { 'This script asks for a password at the keyboard. The dry run works here; to run it, Copy it into a PowerShell 7 terminal in the repo folder.' }
    elseif ($cmd -and $cmd.IsWrite -and -not $planReady) { 'Run the dry run first: it lists every change, and only those changes can then be made.' }
    elseif ($planReady) { 'Read the list above. Make these changes runs exactly that list; anything else is refused.' }
    else { 'Nothing runs until you choose.' }
    $ui.CopyCommandButton.IsEnabled = $has
    $ui.ClearCommandButton.IsEnabled = $has
    if ($cmd) { Show-Chip $ui.CommandChip $ui.CommandChipText $(if ($cmd.IsWrite) { 'Changes something' } else { 'Read-only' }) $(if ($cmd.IsWrite) { 'Warning' } else { 'Success' }) }
    else { Show-Chip $ui.CommandChip $ui.CommandChipText 'Nothing prepared' 'Neutral' }
    if (Get-Command Show-GdapButtonState -ErrorAction SilentlyContinue) { Show-GdapButtonState }
}
function Show-Command {
    param([string[]]$Lines, [string]$Purpose, [bool]$IsWrite = $true, [bool]$Interactive = $false, [scriptblock]$OnDone)
    $script:Command = [pscustomobject]@{ Lines = @($Lines); Purpose = $Purpose; IsWrite = $IsWrite; Interactive = $Interactive; OnDone = $OnDone; Plan = $null; PlannedText = $null }
    $ui.CommandBox.Text = ($Lines -join [Environment]::NewLine)
    $ui.PlanBox.Text = ''
    $ui.PlanTitle.Text = if ($IsWrite) { 'Changes it will make: run the dry run to see them.' } else { 'Read-only: this task cannot change anything.' }
    Write-Activity "Prepared: $Purpose. $(if ($IsWrite) { 'Next: 1. Dry run.' } else { 'Read-only; Run when ready.' })"
    Show-DockState
}
function Show-JobResult {
    param($Result)
    $shown = 0
    foreach ($o in @($Result.Output)) {
        if ($null -eq $o) { continue }
        $shown++
        if ($shown -gt 40) { Write-Activity "  ... $(@($Result.Output).Count - 40) more row(s); use Copy and run in a terminal for the full output"; break }
        if ($o -is [System.Management.Automation.ErrorRecord]) { Write-Activity "  error: $($o.Exception.Message)"; continue }
        if ($o -is [string]) { Write-Activity "  $o"; continue }
        $props = $o.PSObject.Properties | Where-Object { $null -ne $_.Value -and "$($_.Value)" -ne '' } | Select-Object -First 8
        Write-Activity ("  " + (($props | ForEach-Object { "$($_.Name)=$($_.Value -join ',')" }) -join '  '))
    }
    if ($shown -eq 0) { Write-Activity '  (no output)' }
    if ($Result.Failure) { Write-Activity "STOPPED: $($Result.Failure)" }
}
function Invoke-PreparedCommand {
    param([ValidateSet('DryRun', 'Run')][string]$Mode)
    $cmd = $script:Command
    if (-not $cmd) { return }
    $text = $ui.CommandBox.Text
    $lines = @($cmd.Lines | Where-Object { $_ -notmatch '^\s*#' })
    $jobMode = if ($Mode -eq 'DryRun') { 'DryRun' } elseif ($cmd.IsWrite) { 'Run' } else { 'Read' }
    if ($jobMode -eq 'Run') {
        if ($cmd.PlannedText -ne $text -or $null -eq $cmd.Plan) { Write-Activity 'Run the dry run first.'; return }
        $planList = @($cmd.Plan)
        $shownPlan = if ($planList.Count -gt 25) { (Format-PlanText ($planList | Select-Object -First 25)) + "`r`n  ... and $($planList.Count - 25) more (see the list in the window)" } else { Format-PlanText $planList }
        $msg = if ($planList.Count -eq 0) {
            "The dry run found nothing to change. Run it anyway to see its output? It will not be allowed to change anything.`n`n$($lines -join "`n")"
        } else {
            "Make these $($planList.Count) change(s)?`n`n$shownPlan`n`nOnly these changes are allowed; anything else is refused before it runs.`n`nCommand:`n$($lines -join "`n")"
        }
        if ([Windows.MessageBox]::Show($window, $msg, 'Make these changes', 'OKCancel', 'Warning') -ne 'OK') { Write-Activity 'Cancelled. Nothing was changed.'; return }
    }
    $runLines = if ($jobMode -eq 'DryRun') { @($lines | ForEach-Object { "$_ -WhatIf" }) } else { $lines }
    Write-Activity "$(switch ($jobMode) { 'DryRun' { 'Dry run' } 'Run' { 'Running' } default { 'Running (read-only)' } }): $($runLines -join ' ; ')"
    Invoke-GuiJob -Name "$jobMode $($cmd.Purpose)" -Arguments @{ Text = ($runLines -join [Environment]::NewLine); Mode = $jobMode; Plan = @($cmd.Plan) } -Script $script:CommandJob `
        -Context ([pscustomobject]@{ Mode = $jobMode; Command = $cmd }) -OnComplete {
        param($out, $context)
        $jobMode = $context.Mode; $cmd = $context.Command
        $result = @($out | Where-Object { $_ -and $_.PSObject.TypeNames -contains 'M365.GuiResult' }) | Select-Object -Last 1
        if (-not $result) { Write-Activity 'No result came back from the worker.'; return }
        Show-JobResult $result
        $records = @($result.Records)
        if ($jobMode -eq 'DryRun') {
            $planned = @($records | Where-Object Status -eq 'Planned')
            if ($result.Failure) {
                $ui.PlanTitle.Text = 'The dry run stopped before it finished, so there is no complete list. Nothing was changed.'
                $ui.PlanBox.Text = "$(Format-PlanText $planned)`r`n`r`nSTOPPED: $($result.Failure)"
                $cmd.Plan = $null; $cmd.PlannedText = $null
            } else {
                $tenants = @($planned | ForEach-Object Tenant | Sort-Object -Unique)
                $ui.PlanTitle.Text = if ($planned.Count -eq 0) { 'The dry run found nothing to change.' } else { "Changes it will make: $($planned.Count), in $($tenants -join ', ')" }
                $ui.PlanBox.Text = if ($planned.Count -eq 0) { '(no changes)' } else { Format-PlanText $planned }
                $cmd.Plan = $planned; $cmd.PlannedText = $ui.CommandBox.Text
                Write-Activity "Dry run finished: $($planned.Count) change(s) planned. Nothing was changed."
            }
            Show-DockState
            return
        }
        foreach ($r in $records) { Write-Activity ("  {0,-8} [{1}] {2}{3}" -f $r.Status.ToUpperInvariant(), $r.Tenant, $r.Action, $(if ($r.Error) { " -- $($r.Error)" } else { '' })) }
        $count = { param($s) @($records | Where-Object Status -eq $s).Count }
        Write-Activity "$(if ($result.Failure) { 'Stopped' } else { 'Finished' }): $($cmd.Purpose). Done $(& $count 'Done'), failed $(& $count 'Failed'), refused $(& $count 'Refused')."
        if ($cmd.OnDone -and -not $result.Failure) { & $cmd.OnDone @($result.Output) }
        $script:Command = $null; $ui.CommandBox.Text = ''; $ui.PlanBox.Text = ''; $ui.PlanTitle.Text = 'Changes it will make: run the dry run to see them.'
        Show-DockState
    }
}
$ui.RunCommandButton.Add_Click({ Invoke-PreparedCommand -Mode Run })
$ui.DryRunButton.Add_Click({ Invoke-PreparedCommand -Mode DryRun })
$ui.CopyCommandButton.Add_Click({ [Windows.Clipboard]::SetText($ui.CommandBox.Text); Write-Activity 'Command copied. Paste it into a PowerShell 7 window in the repo folder; add -WhatIf first to see the changes.' })
$ui.ClearCommandButton.Add_Click({ $script:Command = $null; $ui.CommandBox.Text = ''; $ui.PlanBox.Text = ''; Show-DockState })
#endregion

#region 5. GDAP view -----------------------------------------------------------------
$gdapView = Import-Xaml -Path (Join-Path $guiRoot 'Views' 'GdapView.xaml') -InjectTheme
$g = @{}
foreach ($name in 'SignInChip', 'SignInChipText', 'SignInAccount', 'SignInButton', 'CustomerInput', 'PickCustomerButton', 'InspectButton', 'CustomerResolved',
    'RelationshipList', 'RelationshipEmpty', 'StateChip', 'StateChipText', 'ComplianceSummary', 'ActionList', 'ActionEmpty', 'WarningList',
    'CreateRequestButton', 'RepairAssignmentsButton', 'ApprovalChip', 'ApprovalChipText', 'ApprovalUrl', 'CopyUrlButton', 'OpenUrlButton',
    'WatchButton', 'StopWatchButton', 'WatchStatus') { $g[$name] = $gdapView.FindName($name) }
$script:Gdap = @{ SignedIn = $false; Account = $null; CustomerTenantId = $null; CustomerName = $null; Assessment = $null; PendingId = $null }

function Get-StatusChipStyle {
    param([string]$Status)
    switch ($Status) { 'active' { $theme['ChipSuccess'] } 'expiring' { $theme['ChipWarning'] } 'approvalPending' { $theme['ChipWarning'] } 'created' { $theme['ChipWarning'] } 'approved' { $theme['ChipActive'] } 'activating' { $theme['ChipActive'] } default { $theme['ChipError'] } }
}
function Show-GdapButtonState {
    $a = $script:Gdap.Assessment
    $g.InspectButton.IsEnabled = $script:Gdap.SignedIn -and -not [string]::IsNullOrWhiteSpace($g.CustomerInput.Text)
    $g.PickCustomerButton.IsEnabled = $script:Gdap.SignedIn
    $g.CreateRequestButton.IsEnabled = [bool]$a -and $a.State -in 'NoRelationship', 'Expired', 'MissingRoles' -and [bool]$template
    $g.RepairAssignmentsButton.IsEnabled = [bool]$a -and $a.MissingAssignments.Count -gt 0
    $hasUrl = -not [string]::IsNullOrWhiteSpace($g.ApprovalUrl.Text)
    $g.CopyUrlButton.IsEnabled = $hasUrl; $g.OpenUrlButton.IsEnabled = $hasUrl
    $g.WatchButton.IsEnabled = [bool]$script:Gdap.PendingId -and -not $script:Watch.IsEnabled
    $g.StopWatchButton.IsEnabled = $script:Watch.IsEnabled
}
function Show-Assessment {
    param($Assessment, $Relationships)
    $script:Gdap.Assessment = $Assessment
    $rows = foreach ($r in $Relationships) {
        [pscustomobject]@{
            DisplayName = $r.DisplayName; Status = $r.Status; ChipStyle = Get-StatusChipStyle -Status $r.Status
            Summary     = "$($r.RoleIds.Count) role(s) | $(if ($r.EndDateTime) { "ends $($r.EndDateTime.ToString('yyyy-MM-dd')) ($($r.DaysToExpiry) d)" } else { 'no end date yet' }) | auto-extend $($r.AutoExtend) | $($r.Assignments.Count) assignment(s)"
        }
    }
    $g.RelationshipList.ItemsSource = @($rows)
    $g.RelationshipEmpty.Visibility = if (@($rows).Count -eq 0) { 'Visible' } else { 'Collapsed' }
    $kind = switch ($Assessment.State) { 'Compliant' { 'Success' } 'PendingApproval' { 'Warning' } 'MissingAssignments' { 'Warning' } 'MissingRoles' { 'Warning' } default { 'Error' } }
    Show-Chip $g.StateChip $g.StateChipText $Assessment.State $kind
    $g.ComplianceSummary.Text = "Template '$($Assessment.TemplateName)': $($Assessment.CoveredRoles.Count) role(s) covered, $($Assessment.MissingRoles.Count) missing, $($Assessment.MissingAssignments.Count) group assignment(s) to create. Active: $($Assessment.ActiveCount); pending: $($Assessment.PendingCount); expired: $($Assessment.ExpiredCount)."
    $g.ActionList.ItemsSource = @($Assessment.ProposedActions | Select-Object Action, Detail)
    $g.ActionEmpty.Visibility = if ($Assessment.ProposedActions.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    $g.WarningList.ItemsSource = @($Assessment.Warnings)
    $pending = $Assessment.Pending | Select-Object -First 1
    if ($pending) { $script:Gdap.PendingId = $pending.Id; $g.ApprovalUrl.Text = $pending.ApprovalUrl; Show-Chip $g.ApprovalChip $g.ApprovalChipText 'Awaiting customer approval' 'Warning' }
    elseif ($Assessment.ActiveCount -gt 0) { $script:Gdap.PendingId = $null; Show-Chip $g.ApprovalChip $g.ApprovalChipText 'Active' 'Success' }
    else { $script:Gdap.PendingId = $null; $g.ApprovalUrl.Text = ''; Show-Chip $g.ApprovalChip $g.ApprovalChipText 'No request' 'Neutral' }
    Show-GdapButtonState
}
function Invoke-Inspect {
    $customerText = $g.CustomerInput.Text.Trim()
    if (-not $customerText) { return }
    $templatePath = if ($template) { $template.Path } else { $null }
    Invoke-GuiJob -Name "Inspect $customerText" -Arguments @{ CustomerText = $customerText; TemplatePath = $templatePath } -Script {
        param($CustomerText, $TemplatePath)
        $tid = Resolve-M365TenantId -TenantId $CustomerText
        $tpl = if ($TemplatePath) { Get-GdapTemplate -Path $TemplatePath } else { $null }
        $rels = @(Get-GdapRelationship -CustomerTenantId $tid -IncludeAssignments)
        $customer = Get-GdapCustomer -TenantId $tid | Select-Object -First 1
        #   WHY    Show whose tenant this really is (its own name and default domain), so a
        #          mistyped domain is visible before anything is requested.
        $info = try { Get-GdapTenantInfo -TenantId $tid } catch { $null }
        $assessment = if ($tpl) { Compare-GdapRelationship -Relationships $rels -Template $tpl } else { $null }
        if ($assessment) { $assessment | Add-Member -NotePropertyName TemplateName -NotePropertyValue $tpl.name -Force }
        [pscustomobject]@{ TenantId = $tid; Name = if ($customer) { $customer.DisplayName } elseif ($info) { $info.DisplayName } elseif ($rels.Count -gt 0) { $rels[0].Customer } else { $null }; Info = $info; Relationships = $rels; Assessment = $assessment }
    } -OnComplete {
        param($out)
        $r = $out[0]
        $script:Gdap.CustomerTenantId = $r.TenantId; $script:Gdap.CustomerName = $r.Name
        $g.CustomerResolved.Text = "Tenant $($r.TenantId)$(if ($r.Info) { " | $($r.Info.DisplayName) ($($r.Info.DefaultDomainName))" } elseif ($r.Name) { " | $($r.Name)" } else { ' | tenant name not available' })$(if (-not @($r.Relationships).Count) { ' | not yet a GDAP customer' })"
        if ($r.Assessment) { Show-Assessment -Assessment $r.Assessment -Relationships $r.Relationships } else { Write-Activity "No template loaded: $templateError"; $g.RelationshipList.ItemsSource = @(); Show-GdapButtonState }
        Write-Activity "Inspected $($r.TenantId): $(@($r.Relationships).Count) relationship(s)$(if ($r.Assessment) { ", state $($r.Assessment.State)" })."
    }
}
$g.SignInButton.Add_Click({
        Invoke-GuiJob -Name 'Partner sign-in' -Arguments @{ Tenant = $partnerTenant } -Script {
            param($Tenant)
            $ctx = Assert-M365Graph -TenantId $Tenant -Scopes 'DelegatedAdminRelationship.ReadWrite.All', 'Group.Read.All', 'RoleManagement.Read.Directory', 'CrossTenantInformation.ReadBasic.All'
            [pscustomobject]@{ Account = $ctx.Account; TenantId = $ctx.TenantId }
        } -OnComplete {
            param($out)
            $script:Gdap.SignedIn = $true; $script:Gdap.Account = $out[0].Account
            Show-Chip $g.SignInChip $g.SignInChipText 'Signed in' 'Success'
            $g.SignInAccount.Text = "$($out[0].Account) | $($out[0].TenantId)"
            Write-Activity "Signed in as $($out[0].Account)."
            if ($templateError) { Write-Activity "Template problem: $templateError" }
            Show-GdapButtonState
        } -OnError { Show-Chip $g.SignInChip $g.SignInChipText 'Sign-in failed' 'Error' }
    })
$g.CustomerInput.Add_TextChanged({ Show-GdapButtonState })
$g.InspectButton.Add_Click({ Invoke-Inspect })
$g.CustomerInput.Add_KeyDown({ if ($args[1].Key -eq 'Return' -and $g.InspectButton.IsEnabled) { Invoke-Inspect } })
$g.PickCustomerButton.Add_Click({
        Invoke-GuiJob -Name 'List GDAP customers' -Script { Get-GdapCustomer | Sort-Object DisplayName } -OnComplete {
            param($out)
            if (@($out).Count -eq 0) { Write-Activity 'No customers with GDAP yet.'; return }
            $pick = [Windows.Window]::new(); $pick.Title = 'Pick a customer'; $pick.Width = 480; $pick.Height = 520; $pick.Owner = $window; $pick.WindowStartupLocation = 'CenterOwner'
            $pick.Background = $theme['BackgroundBrush']; $pick.Resources.MergedDictionaries.Add($theme)
            $list = [Windows.Controls.ListBox]::new(); $list.Margin = '24'; $list.BorderThickness = '1'; $list.BorderBrush = $theme['BorderBrush']; $list.Background = $theme['SurfaceBrush']; $list.ItemContainerStyle = $theme['NavItem']
            foreach ($c in $out) { $item = [Windows.Controls.ListBoxItem]::new(); $item.Content = "$($c.DisplayName)  |  $($c.TenantId)"; $item.Tag = $c.TenantId; $null = $list.Items.Add($item) }
            $list.Add_MouseDoubleClick({ if ($list.SelectedItem) { $g.CustomerInput.Text = $list.SelectedItem.Tag; $pick.Close(); Invoke-Inspect } })
            $pick.Content = $list; $null = $pick.ShowDialog()
        }
    })
$g.CreateRequestButton.Add_Click({
        $a = $script:Gdap.Assessment
        if (-not $a -or -not $template) { return }
        $name = if ($script:Gdap.CustomerName) { $script:Gdap.CustomerName } else { $g.CustomerInput.Text.Trim() }
        $purpose = if ($a.State -eq 'MissingRoles') { "supplementary GDAP request for $name ($($a.MissingRoleIds.Count) missing roles)" } else { "GDAP request for $name ($($template.RoleIds.Count) roles)" }
        $line = Format-M365CommandLine -ScriptPath (Join-Path $repoRoot 'scripts' 'powershell' 'partner' 'New-M365GdapRequest.ps1') -Values ([ordered]@{ CustomerTenantId = $script:Gdap.CustomerTenantId; CustomerName = $name; NoBrowser = [switch]::new($true) })
        Show-Command -Lines @("# $purpose; the script re-checks existing relationships before creating", $line) -Purpose $purpose -OnDone {
            param($out)
            $withUrl = $out | Where-Object { $_ -and $_.PSObject.Properties.Name -contains 'ApprovalUrl' -and $_.ApprovalUrl } | Select-Object -Last 1
            if ($withUrl) { $script:Gdap.PendingId = $withUrl.Id; $g.ApprovalUrl.Text = $withUrl.ApprovalUrl; Show-Chip $g.ApprovalChip $g.ApprovalChipText 'Awaiting customer approval' 'Warning'; Show-ApprovalWindow -Url $withUrl.ApprovalUrl }
            Invoke-Inspect
        }
    })
$g.RepairAssignmentsButton.Add_Click({
        $a = $script:Gdap.Assessment
        if (-not $a -or $a.MissingAssignments.Count -eq 0) { return }
        $lines = @('# assign template security groups on the active relationship(s); existing assignments are left alone')
        foreach ($group in $a.MissingAssignments | Group-Object RelationshipId) {
            $lines += Format-M365CommandLine -ScriptPath (Join-Path $repoRoot 'scripts' 'powershell' 'partner' 'Set-M365GdapAccessAssignment.ps1') -Values ([ordered]@{ RelationshipId = $group.Name; GroupName = @($group.Group | ForEach-Object { $_.GroupName } | Sort-Object -Unique) })
        }
        Show-Command -Lines $lines -Purpose "group assignments for $($script:Gdap.CustomerName) ($($a.MissingAssignments.Count) missing)" -OnDone { Invoke-Inspect }
    })

$script:ApprovalWindow = $null
function Show-ApprovalWindow {
    param([string]$Url)
    if (-not $script:WebView2Available) {
        $opened = Open-GdapApprovalPage -Url $Url
        Write-Activity "WebView2 assemblies not in gui/lib/webview2; opened the approval page in $($opened.Browser)$(if ($opened.Private) { ' (private window)' }). Sign in with your admin account in the customer tenant."
        return
    }
    try {
        Add-Type -Path (Join-Path $webView2Dir 'Microsoft.Web.WebView2.Core.dll') -ErrorAction Stop
        Add-Type -Path (Join-Path $webView2Dir 'Microsoft.Web.WebView2.Wpf.dll') -ErrorAction Stop
        $userData = Join-Path $runsDir 'webview2' ([guid]::NewGuid().ToString('N')); $null = New-Item -ItemType Directory -Path $userData -Force
        $win = [Windows.Window]::new()
        $win.Title = "Approve GDAP for $($script:Gdap.CustomerName) | sign in as a Global Administrator of the customer tenant"
        $win.Width = 1100; $win.Height = 820; $win.Owner = $window; $win.WindowStartupLocation = 'CenterOwner'
        $win.Background = $theme['BackgroundBrush']; $win.Resources.MergedDictionaries.Add($theme)
        $grid = [Windows.Controls.Grid]::new()
        $r0 = [Windows.Controls.RowDefinition]::new(); $r0.Height = [Windows.GridLength]::Auto
        $r1 = [Windows.Controls.RowDefinition]::new(); $r1.Height = [Windows.GridLength]::new(1, 'Star')
        $grid.RowDefinitions.Add($r0); $grid.RowDefinitions.Add($r1)
        $banner = [Windows.Controls.Border]::new(); $banner.Background = $theme['SurfaceBrush']; $banner.BorderBrush = $theme['BorderBrush']; $banner.BorderThickness = '0,0,0,1'; $banner.Padding = '24,12'
        $text = [Windows.Controls.TextBlock]::new(); $text.Style = $theme['SecondaryText']
        $text.Text = 'This is Microsoft''s approval page in an isolated browser profile. Sign in with your admin account in the customer tenant, review the roles, approve. The window closes itself once the relationship is active.'
        $banner.Child = $text
        $wv = [Microsoft.Web.WebView2.Wpf.WebView2]::new()
        $props = [Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties]::new(); $props.UserDataFolder = $userData
        $wv.CreationProperties = $props; $wv.Source = [Uri]$Url
        [Windows.Controls.Grid]::SetRow($banner, 0); [Windows.Controls.Grid]::SetRow($wv, 1)
        $null = $grid.Children.Add($banner); $null = $grid.Children.Add($wv)
        $win.Content = $grid
        $win.Add_Closed({
                try { $wv.Dispose() } catch { Write-Verbose "WebView2 dispose: $($_.Exception.Message)" }
                try { Remove-Item -Path $userData -Recurse -Force -ErrorAction SilentlyContinue } catch { Write-Verbose "Profile cleanup: $($_.Exception.Message)" }
                $script:ApprovalWindow = $null
            })
        $script:ApprovalWindow = $win; $win.Show()
        Write-Activity 'Approval page opened in-app with an isolated profile. Sign in there with your customer-tenant admin account.'
        if (-not $script:Watch.IsEnabled) { $script:Watch.Start(); $g.WatchStatus.Text = "Checking every $pollSeconds s"; Show-GdapButtonState }
    } catch {
        Write-Activity "WebView2 failed to load ($($_.Exception.Message)); falling back to a private browser window."
        $opened = Open-GdapApprovalPage -Url $Url
        Write-Activity "Opened in $($opened.Browser)$(if ($opened.Private) { ' (private window)' })."
    }
}
$g.CopyUrlButton.Add_Click({ [Windows.Clipboard]::SetText($g.ApprovalUrl.Text); Write-Activity 'Approval link copied.' })
$g.OpenUrlButton.Add_Click({ Show-ApprovalWindow -Url $g.ApprovalUrl.Text })

$script:Watch = [Windows.Threading.DispatcherTimer]::new()
$pollSeconds = if ($settings.PSObject.Properties.Name -contains 'partner' -and $settings.partner.approvalPollSeconds) { [int]$settings.partner.approvalPollSeconds } else { 20 }
$script:Watch.Interval = [TimeSpan]::FromSeconds($pollSeconds)
$script:Watch.Add_Tick({
        if (-not $script:Gdap.PendingId -or $script:Worker.Current) { return }
        Invoke-GuiJob -Name 'Check approval status' -Arguments @{ Id = $script:Gdap.PendingId } -Script { param($Id) Get-GdapRelationship -RelationshipId $Id | Select-Object -First 1 } -OnComplete {
            param($out)
            $r = $out[0]
            $g.WatchStatus.Text = "Status $($r.Status) at $(Get-Date -Format HH:mm:ss)"
            switch ($r.Status) {
                'active' { Show-Chip $g.ApprovalChip $g.ApprovalChipText 'Approved / Active' 'Success'; $script:Watch.Stop(); Write-Activity 'Approved. Relationship is active; prepare the group assignments next.'; if ($script:ApprovalWindow) { $script:ApprovalWindow.Close() }; Invoke-Inspect }
                { $_ -in 'approved', 'activating' } { Show-Chip $g.ApprovalChip $g.ApprovalChipText 'Approved, activating' 'Active' }
                { $_ -in 'expired', 'terminated', 'terminating', 'terminationRequested' } { Show-Chip $g.ApprovalChip $g.ApprovalChipText "Rejected / $($r.Status)" 'Error'; $script:Watch.Stop(); Write-Activity "Request ended as $($r.Status)." }
                default { Show-Chip $g.ApprovalChip $g.ApprovalChipText 'Awaiting customer approval' 'Warning' }
            }
            Show-GdapButtonState
        } -OnError { Show-Chip $g.ApprovalChip $g.ApprovalChipText 'Error / Requires attention' 'Error'; $script:Watch.Stop(); Show-GdapButtonState }
    })
$g.WatchButton.Add_Click({ $script:Watch.Start(); $g.WatchStatus.Text = "Checking every $pollSeconds s"; Write-Activity 'Watching for approval. Stop any time; the request stays as it is.'; Show-GdapButtonState })
$g.StopWatchButton.Add_Click({ $script:Watch.Stop(); $g.WatchStatus.Text = 'Stopped. Re-inspect later to resume.'; Show-GdapButtonState })
#endregion

#region 6. Generic task view --------------------------------------------------------
#   WHAT   One view for every non-GDAP area: task list from the catalog, a form built from
#          the script's parameters, Prepare composes the command into the dock.
#   WHY    Adding a script to an area folder is all it takes to get it here.
$taskView = Import-Xaml -Path (Join-Path $guiRoot 'Views' 'TaskView.xaml') -InjectTheme
$t = @{}
foreach ($name in 'AreaTitle', 'AreaSubtitle', 'TaskList', 'ClientPicker', 'DetailCard', 'TaskTitle', 'StatusChip', 'StatusChipText', 'TaskSynopsis', 'TaskDescription', 'TaskRequires', 'FormCard', 'FormHost', 'PrepareButton', 'ExampleButton', 'FormHint') { $t[$name] = $taskView.FindName($name) }
$script:Task = @{ Areas = @(); Current = $null; Fields = @{} }

#   WHAT   Client picker: no client, our own tenant, then every client config.
#   WHY    Every task names its tenant explicitly. With no client picked the tenant fields
#          stay empty and Prepare refuses; our own tenant is a deliberate choice, not a default.
$homeTarget = [pscustomobject]@{ name = "Our tenant ($($settings.msp.name))"; tenantId = $settings.msp.homeTenantId; onmicrosoftDomain = $settings.msp.homeTenantId; primaryDomain = $null; shortName = $null; configPath = $null; huduCompanyId = $null; IsHome = $true }
$pickerTargets = @($homeTarget) + @($clients)
$null = $t.ClientPicker.Items.Add('(pick the tenant to work in)')
foreach ($c in $pickerTargets) { $null = $t.ClientPicker.Items.Add("$($c.name)  |  $($c.onmicrosoftDomain)") }
$t.ClientPicker.SelectedIndex = 0
function Get-SelectedClient { if ($t.ClientPicker.SelectedIndex -le 0) { return $null }; return $pickerTargets[$t.ClientPicker.SelectedIndex - 1] }
function Get-ClientPrefill {
    param($Client, [string]$ParameterName)
    if (-not $Client) { return $null }
    $isHome = $Client.PSObject.Properties.Name -contains 'IsHome'
    switch ($ParameterName) {
        'TenantId' { $Client.tenantId }
        'CustomerTenantId' { if ($isHome) { $null } else { $Client.tenantId } }
        'Organization' { $Client.onmicrosoftDomain }
        'Domain' { $Client.primaryDomain }
        'CustomerName' { if ($isHome) { $null } else { $Client.name } }
        'Client' { $Client.shortName }
        'ConfigPath' { $Client.configPath }
        'HuduCompanyId' { if ($Client.huduCompanyId) { "$($Client.huduCompanyId)" } else { $null } }
        default { $null }
    }
}
function Show-TaskArea {
    param([string[]]$Areas, [string]$Label)
    $script:Task.Areas = $Areas
    $t.AreaTitle.Text = $Label
    $items = foreach ($task in $catalog | Where-Object { $Areas -contains $_.Area }) {
        [pscustomobject]@{
            Name = $task.Name; Synopsis = $task.Synopsis; Task = $task
            Kind = if ($task.IsWrite) { 'write' } else { 'read' }
            ChipStyle = if ($task.IsWrite) { $theme['ChipWarning'] } else { $theme['ChipSuccess'] }
            ChipTextStyle = $theme['ChipTextOnColor']
        }
    }
    $t.TaskList.ItemsSource = @($items)
    $t.AreaSubtitle.Text = "$(@($items).Count) task(s). Green = read-only, amber = changes something."
    $t.FormCard.Visibility = 'Collapsed'; $t.TaskTitle.Text = 'Pick a task'; $t.TaskSynopsis.Text = 'Every script in this area is listed on the left. Pick one, fill in the form, and Prepare writes the exact command into the review box below.'; $t.TaskDescription.Text = ''; $t.TaskRequires.Text = ''
    Show-Chip $t.StatusChip $t.StatusChipText '' 'Neutral'; $t.StatusChip.Visibility = 'Collapsed'
    $script:Task.Current = $null
}
function Show-TaskForm {
    param($TaskInfo)
    $script:Task.Current = $TaskInfo; $script:Task.Fields = @{}
    $t.TaskTitle.Text = $TaskInfo.Name
    $t.TaskSynopsis.Text = $TaskInfo.Synopsis
    $t.TaskDescription.Text = $TaskInfo.Description
    $t.TaskRequires.Text = "Status: $($TaskInfo.Status)$(if ($TaskInfo.Requires) { "  |  Requires: $($TaskInfo.Requires)" })$(if ($TaskInfo.GraphScopes.Count -gt 0) { "  |  Graph scopes: $($TaskInfo.GraphScopes -join ', ')" })$(if ($TaskInfo.IsInteractive) { "  |  Interactive: $($TaskInfo.InteractiveNote)" })"
    $t.StatusChip.Visibility = 'Visible'
    Show-Chip $t.StatusChip $t.StatusChipText $(if ($TaskInfo.IsWrite) { 'Write' } else { 'Read-only' }) $(if ($TaskInfo.IsWrite) { 'Warning' } else { 'Success' })
    $t.FormHost.Children.Clear()
    $client = Get-SelectedClient
    foreach ($p in $TaskInfo.Parameters) {
        $label = [Windows.Controls.TextBlock]::new(); $label.Style = $theme['BodyText']; $label.FontWeight = 'Medium'; $label.FontSize = 14; $label.Margin = '0,12,0,2'
        $label.Text = "$($p.Name)$(if ($p.Mandatory) { ' *' })"
        $null = $t.FormHost.Children.Add($label)
        if ($p.Help) { $help = [Windows.Controls.TextBlock]::new(); $help.Style = $theme['CaptionText']; $help.Margin = '0,0,0,4'; $help.Text = $p.Help; $null = $t.FormHost.Children.Add($help) }
        $prefill = Get-ClientPrefill -Client $client -ParameterName $p.Name
        if ($p.IsSwitch -or $p.Type -eq 'Boolean') {
            $cb = [Windows.Controls.CheckBox]::new(); $cb.Content = 'Yes'; $cb.Margin = '0,4,0,0'; $cb.FontSize = 14
            if ($p.Default -eq '$true') { $cb.IsChecked = $true }
            $null = $t.FormHost.Children.Add($cb); $script:Task.Fields[$p.Name] = $cb
        } elseif ($p.ValidateSet.Count -gt 0) {
            $combo = [Windows.Controls.ComboBox]::new(); $combo.MinHeight = 38; $combo.FontSize = 14
            $null = $combo.Items.Add(''); foreach ($v in $p.ValidateSet) { $null = $combo.Items.Add("$v") }
            $combo.SelectedItem = $(if ($p.Default) { ($p.Default -replace "^'|'$", '') } else { '' })
            $null = $t.FormHost.Children.Add($combo); $script:Task.Fields[$p.Name] = $combo
        } else {
            $tb = [Windows.Controls.TextBox]::new(); $tb.Style = $theme['Input']
            if ($prefill) { $tb.Text = "$prefill" } elseif ($p.Default -and $p.Default -notmatch '^\$|^@\(\)$') { $tb.Text = ($p.Default -replace "^'|'$", '') }
            if ($p.IsArray) { $tb.ToolTip = 'Comma-separated list' }
            $null = $t.FormHost.Children.Add($tb); $script:Task.Fields[$p.Name] = $tb
        }
    }
    $t.FormCard.Visibility = 'Visible'
}
function Read-TaskForm {
    #   WHAT   Form -> values in the script's declared order. Switches are [switch] (left out
    #          when off); [bool] parameters always carry $true/$false so the line is explicit.
    $values = [ordered]@{}; $missing = @()
    foreach ($p in $script:Task.Current.Parameters) {
        $ctl = $script:Task.Fields[$p.Name]
        $text = if ($ctl -is [Windows.Controls.CheckBox]) { $(if ($ctl.IsChecked) { 'true' } else { '' }) } elseif ($ctl -is [Windows.Controls.ComboBox]) { "$($ctl.SelectedItem)" } else { $ctl.Text }
        $v = ConvertTo-M365TaskValue -Text $text -Parameter $p
        if ($p.Mandatory -and -not $p.IsSwitch -and $p.Type -ne 'Boolean' -and ($null -eq $v -or ($v -is [string] -and -not $v) -or ($v -is [array] -and $v.Count -eq 0))) { $missing += $p.Name }
        if ($v -is [switch]) { if ($v.IsPresent) { $values[$p.Name] = $v }; continue }
        if ($null -ne $v) { $values[$p.Name] = $v }
    }
    [pscustomobject]@{ Values = $values; Missing = $missing }
}
$t.TaskList.Add_SelectionChanged({ if ($t.TaskList.SelectedItem) { Show-TaskForm -TaskInfo $t.TaskList.SelectedItem.Task } })
$t.ClientPicker.Add_SelectionChanged({ if ($script:Task.Current) { Show-TaskForm -TaskInfo $script:Task.Current } })
$t.PrepareButton.Add_Click({
        $task = $script:Task.Current
        if (-not $task) { return }
        $form = Read-TaskForm
        if ($form.Missing.Count -gt 0) { Write-Activity "Fill in: $($form.Missing -join ', ')$(if (-not (Get-SelectedClient)) { ' (or pick the tenant at the top)' })"; return }
        $line = Format-M365CommandLine -ScriptPath $task.Path -Values $form.Values
        Show-Command -Lines @("# $($task.Synopsis)", $line) -Purpose $task.Name -IsWrite $task.IsWrite -Interactive (Test-CommandInteractive -TaskInfo $task -Values $form.Values)
    })
$t.ExampleButton.Add_Click({ if ($script:Task.Current) { foreach ($ex in $script:Task.Current.Examples) { Write-Activity "  example: $ex" } } })
#endregion

#region 7. Module list and view switching -------------------------------------------
$moduleDefs = @(
    @{ Name = 'GDAP Management'; Key = 'GDAP'; Enabled = $true }
    @{ Name = 'Client Onboarding'; Key = 'onboarding'; Areas = @('onboarding'); Enabled = $true }
    @{ Name = 'Entra ID'; Key = 'entra'; Areas = @('entra'); Enabled = $true }
    @{ Name = 'Exchange Online'; Key = 'exchange'; Areas = @('exchange', 'mailauth'); Enabled = $true }
    @{ Name = 'Security Baselines'; Key = 'security'; Areas = @('security'); Enabled = $true }
    @{ Name = 'Reporting'; Key = 'reports'; Areas = @('reports'); Enabled = $true }
    @{ Name = 'User Lifecycle'; Key = 'lifecycle'; Areas = @('lifecycle'); Enabled = $true }
    @{ Name = 'GDAP & Partner tasks'; Key = 'partner'; Areas = @('partner'); Enabled = $true }
    @{ Name = 'Intune & Devices'; Key = 'intune'; Enabled = $false }
    @{ Name = 'Azure & AVD'; Key = 'azure'; Enabled = $false }
)
foreach ($m in $moduleDefs) {
    $item = [Windows.Controls.ListBoxItem]::new()
    $item.Content = if ($m.Enabled) { $m.Name } else { "$($m.Name)  (soon)" }
    $item.IsEnabled = $m.Enabled; $item.Tag = $m
    $null = $ui.ModuleList.Items.Add($item)
}
$ui.ModuleList.Add_SelectionChanged({
        $def = $ui.ModuleList.SelectedItem.Tag
        if (-not $def) { return }
        if ($def.Key -eq 'GDAP') { $ui.ViewHost.Content = $gdapView }
        else { Show-TaskArea -Areas $def.Areas -Label $def.Name; $ui.ViewHost.Content = $taskView }
    })
$startIndex = [array]::IndexOf(@($moduleDefs | ForEach-Object Key), $Module)
$ui.ModuleList.SelectedIndex = $(if ($startIndex -ge 0) { $startIndex } else { 0 })

$pump = [Windows.Threading.DispatcherTimer]::new(); $pump.Interval = [TimeSpan]::FromMilliseconds(200); $pump.Add_Tick({ Complete-CurrentJob }); $pump.Start()
$window.Add_Closed({ $pump.Stop(); $script:Watch.Stop(); if ($script:Worker.Runspace) { $script:Worker.Runspace.Dispose() } })

Write-Activity "Ready. $($catalog.Count) tasks in $(@(Get-M365TaskArea).Count) areas. GDAP template: $(if ($template) { "$($template.name) ($($template.RoleIds.Count) roles, $($template.Groups.Count) groups)" } else { "not loaded: $templateError" })"
Write-Activity "Approval method: $(if ($script:WebView2Available) { 'in-app WebView2 window (isolated profile)' } else { 'private browser window (add WebView2 assemblies to gui/lib/webview2 for in-app)' })"
Show-DockState
#endregion

#region 8. Run -----------------------------------------------------------------------------
$null = $window.ShowDialog()
#endregion
