<#
.SYNOPSIS
    Desktop front end for the AVD scripts in this repo. Same actions as the console,
    as a window: sign in, build, operate hosts and sessions, tear down.
.DESCRIPTION
    One PowerShell file, two XAML files, no compiler. The same trick Chris Titus's
    WinUtil uses: load a WPF window from XAML, find the named controls, attach handlers
    that are plain PowerShell.

      gui/Shell.xaml   the window: sidebar, header, page host, log pane, status bar
      gui/Theme.xaml   every colour, font and control style (docs/design/ember-studio.md)

    This window never deletes anything. No tear down, no reimage, no rollback, and
    the build it starts does not delete directory objects either: a stale Entra
    device record stops the build with its name for you to remove in the portal.
    Deleting is done in the Azure portal, on purpose, by a person.

    No logic lives here. Every button ends in one of the scripts under avd/, storage/
    or backup/, or a function in the modules. If the GUI can do it, the command line
    can do it the same way. Long work runs in a background runspace so the window
    stays responsive; the script's verbose, warning and error streams land in the
    log pane.
.PARAMETER TenantId
    Optional. Normally discovered and remembered in console.local.json (shared with
    the console, gitignored). Pass to force a tenant.
.PARAMETER SubscriptionId
    Optional. Same.
.EXAMPLE
    ./Start-AvdGui.ps1
.NOTES
    Requires: Windows (WPF), PowerShell 7, Az.Accounts and the modules each script needs.
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
#   WHAT   Optional shortcuts and the theme. Everything else is asked for in the window.
#   WHY    Write-Host is banned in this repo, but this file never needs it: the log
#          pane is the console. Nothing here prints to the terminal.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-*/Set-*/Update-* here build or refresh WPF controls. Azure changes go through the repo scripts, which support -WhatIf.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Handlers and OnDone callbacks have fixed signatures; not every one uses every argument.')]
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$', ErrorMessage = 'TenantId must be a GUID.')]
    [string]$TenantId,

    [Parameter()]
    [string]$SubscriptionId,

    # Ember (docs/design/ember-studio.md, the default) or Teal (a management-console look).
    [Parameter()]
    [ValidateSet('Ember', 'Teal')]
    [string]$Theme = 'Ember'
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Platform check, WPF assemblies, paths, remembered config, the $Gui bag.
#   WHY    WPF exists only on Windows. Failing with a sentence beats a wall of
#          type-not-found errors. The UI thread never loads Az: every Azure call
#          runs in the worker runspace (region 4) so sign-in and context live in
#          exactly one place.
#   GOTCHA Everything shared lives in one hashtable, $Gui, never in $script:
#          variables, and no handler uses GetNewClosure(). A closure is bound to a
#          throwaway module that cannot see this script's functions or $script:
#          scope when the script is run from a prompt (it only works dot-sourced).
#          Event handlers instead get their context from the sender's Tag
#          ($this.Tag) and reach shared state through $Gui by dynamic scoping.
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
throw 'Cloudwright safe release: Azure/AVD administration is disabled pending a reviewed read-only implementation.'

if (-not $IsWindows) { throw 'Start-AvdGui.ps1 needs Windows (WPF). On other platforms use Start-AvdConsole.ps1.' }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$Gui = @{
    GuiDir          = Join-Path $PSScriptRoot 'gui'
    Modules         = @(
        (Join-Path $PSScriptRoot 'modules' 'AzHelpers'  'AzHelpers.psd1'),
        (Join-Path $PSScriptRoot 'modules' 'AvdHelpers' 'AvdHelpers.psd1'),
        (Join-Path $PSScriptRoot 'modules' 'AvdBuild'   'AvdBuild.psd1'),
        (Join-Path $PSScriptRoot 'modules' 'ServerBuild' 'ServerBuild.psd1'),
        (Join-Path $PSScriptRoot 'modules' 'NetworkBuild' 'NetworkBuild.psd1'),
        (Join-Path $PSScriptRoot 'modules' 'EntraAdmin' 'EntraAdmin.psd1'),
        (Join-Path $PSScriptRoot 'modules' 'ImageBuild' 'ImageBuild.psd1'),
        (Join-Path $PSScriptRoot 'modules' 'FilesAdmin' 'FilesAdmin.psd1'),
        (Join-Path $PSScriptRoot 'modules' 'BackupAdmin' 'BackupAdmin.psd1'),
        (Join-Path $PSScriptRoot 'modules' 'AppDeploy' 'AppDeploy.psd1'),
        (Join-Path $PSScriptRoot 'modules' 'AutomationAdmin' 'AutomationAdmin.psd1'),
        (Join-Path $PSScriptRoot 'modules' 'OpsAdmin' 'OpsAdmin.psd1')
    )
    Scripts         = @{
        Environment = Join-Path $PSScriptRoot 'avd' 'New-AvdEnvironment.ps1'
        NewHost     = Join-Path $PSScriptRoot 'avd' 'New-AvdSessionHost.ps1'
        Drain       = Join-Path $PSScriptRoot 'avd' 'Set-AvdHostDrain.ps1'
        Repair      = Join-Path $PSScriptRoot 'avd' 'Repair-AvdSessionHost.ps1'
        ShareAccess = Join-Path $PSScriptRoot 'storage' 'Set-AvdProfileShareAccess.ps1'
        Backup      = Join-Path $PSScriptRoot 'backup' 'Enable-AvdBackup.ps1'
        Power       = Join-Path $PSScriptRoot 'avd' 'Set-AvdHostPower.ps1'
        Rolling     = Join-Path $PSScriptRoot 'avd' 'Invoke-AvdRollingRestart.ps1'
        AgentWindow = Join-Path $PSScriptRoot 'avd' 'Set-AvdAgentUpdateWindow.ps1'
        ScalingPlan = Join-Path $PSScriptRoot 'avd' 'New-AvdScalingPlan.ps1'
        ScalingPlanEdit = Join-Path $PSScriptRoot 'avd' 'Set-AvdScalingPlan.ps1'
        ServerPower = Join-Path $PSScriptRoot 'servers' 'Set-ServerPower.ps1'
        ServerNew   = Join-Path $PSScriptRoot 'servers' 'New-Server.ps1'
        ServerRole  = Join-Path $PSScriptRoot 'servers' 'Install-ServerRole.ps1'
        RdpGrant    = Join-Path $PSScriptRoot 'servers' 'Grant-ServerRdpAccess.ps1'
        RdpRevoke   = Join-Path $PSScriptRoot 'servers' 'Revoke-ServerRdpAccess.ps1'
        NetVNetNew  = Join-Path $PSScriptRoot 'network' 'New-NetVirtualNetwork.ps1'
        NetVNetSet  = Join-Path $PSScriptRoot 'network' 'Set-NetVirtualNetwork.ps1'
        NetSubnetNew = Join-Path $PSScriptRoot 'network' 'New-NetSubnet.ps1'
        NetSubnetSet = Join-Path $PSScriptRoot 'network' 'Set-NetSubnet.ps1'
        NetNsgNew   = Join-Path $PSScriptRoot 'network' 'New-NetSecurityGroup.ps1'
        EntraUserNew  = Join-Path $PSScriptRoot 'entra' 'New-EntraUser.ps1'
        EntraGroupNew = Join-Path $PSScriptRoot 'entra' 'New-EntraGroup.ps1'
        EntraMember   = Join-Path $PSScriptRoot 'entra' 'Add-EntraGroupMember.ps1'
        EntraUserSet  = Join-Path $PSScriptRoot 'entra' 'Set-EntraUser.ps1'
        ImageDefinition = Join-Path $PSScriptRoot 'images' 'New-ImageDefinition.ps1'
        ImageBuilder    = Join-Path $PSScriptRoot 'images' 'New-ImageBuilderVm.ps1'
        ImageCapture    = Join-Path $PSScriptRoot 'images' 'Invoke-ImageCapture.ps1'
        W365Image       = Join-Path $PSScriptRoot 'images' 'New-W365Image.ps1'
        FilesShareNew   = Join-Path $PSScriptRoot 'storage' 'New-FilesShare.ps1'
        FilesQuota      = Join-Path $PSScriptRoot 'storage' 'Set-FilesShareQuota.ps1'
        BackupEnable    = Join-Path $PSScriptRoot 'backup' 'Enable-ItemBackup.ps1'
        BackupNow       = Join-Path $PSScriptRoot 'backup' 'Start-ItemBackup.ps1'
        BackupRestore   = Join-Path $PSScriptRoot 'backup' 'Restore-ItemBackup.ps1'
        BackupPolicy    = Join-Path $PSScriptRoot 'backup' 'Set-BackupPolicy.ps1'
        NetRule         = Join-Path $PSScriptRoot 'network' 'Set-NetSecurityRule.ps1'
        NetPip          = Join-Path $PSScriptRoot 'network' 'New-NetPublicIp.ps1'
        NetNat          = Join-Path $PSScriptRoot 'network' 'New-NetNatGateway.ps1'
        NetNatSubnet    = Join-Path $PSScriptRoot 'network' 'Set-NetSubnetNatGateway.ps1'
        NetVpnGateway   = Join-Path $PSScriptRoot 'network' 'New-NetVpnGateway.ps1'
        NetVpnSite      = Join-Path $PSScriptRoot 'network' 'New-NetVpnSite.ps1'
        GuestScript     = Join-Path $PSScriptRoot 'apps' 'Invoke-GuestScript.ps1'
        AppInstall      = Join-Path $PSScriptRoot 'apps' 'Install-App.ps1'
        CertInstall     = Join-Path $PSScriptRoot 'apps' 'Install-GuestCertificate.ps1'
        KvImport        = Join-Path $PSScriptRoot 'apps' 'Import-KvCertificate.ps1'
        MsixNew         = Join-Path $PSScriptRoot 'apps' 'New-AppAttachPackage.ps1'
        MsixSet         = Join-Path $PSScriptRoot 'apps' 'Set-AppAttachPackage.ps1'
        RunbookStart    = Join-Path $PSScriptRoot 'automation' 'Start-ToolboxRunbook.ps1'
        RunbookImport   = Join-Path $PSScriptRoot 'automation' 'Import-ToolboxRunbook.ps1'
        AvdDiagnostic   = Join-Path $PSScriptRoot 'insights' 'Set-AvdDiagnostic.ps1'
        Report          = Join-Path $PSScriptRoot 'insights' 'Export-ToolboxReport.ps1'
    }
    LocalConfigPath = Join-Path $PSScriptRoot 'console.local.json'   # *.local.* is gitignored; shared with the console
    State           = @{
        Account = $null; TenantId = $TenantId; SubscriptionId = $SubscriptionId; Subscriptions = @()
        Pool = $null; Hosts = @(); Busy = $false; SuppressEvents = $false; LastEnv = 'lab'; ResourceGroups = @()
        PageKey = ''; SectionKey = ''; PreferredImage = ''
    }
    Ui              = @{}
    Pages           = @{}
    PoolBanners     = [System.Collections.Generic.List[object]]::new()   # the 'Host pool: ...' line on each page that works on the current pool
    HostCombos      = [System.Collections.Generic.List[object]]::new()
    RgCombos        = [System.Collections.Generic.List[object]]::new()
    Jit             = [System.Collections.Generic.List[object]]::new()   # open RDP grants this session made: @{ Rg; Vm; Expires }
    Job             = $null
    PendingSkuLoad  = $null
    PendingShow     = $null   # page key whose on-open load was skipped because a job was running
}

function Get-LocalConfig {
    if (Test-Path $Gui.LocalConfigPath) {
        try { return Get-Content $Gui.LocalConfigPath -Raw | ConvertFrom-Json } catch { return $null }
    }
    return $null
}
function Save-LocalConfig {
    param([string]$Account, [string]$TenantId, [string]$SubscriptionId, [string]$SubscriptionName)
    [pscustomobject]@{
        account = $Account; tenantId = $TenantId; subscriptionId = $SubscriptionId
        subscriptionName = $SubscriptionName; savedAt = (Get-Date).ToString('u')
    } | ConvertTo-Json | Set-Content $Gui.LocalConfigPath
}
$saved = Get-LocalConfig
if ($saved -and -not $TenantId)       { $Gui.State.TenantId = $saved.tenantId }
if ($saved -and -not $SubscriptionId) { $Gui.State.SubscriptionId = $saved.subscriptionId }
#endregion

#region 3. Load the window ----------------------------------------------------
#   WHAT   Shell into a Window, the chosen Theme merged into the window's resources,
#          named controls into $Gui.Ui.
#   WHY    Window-level resources are what {DynamicResource} and the implicit control
#          styles resolve against for everything inside the window, XAML or code-built.
#          No System.Windows.Application is created: only one can exist per process
#          and it cannot be reused after it shuts down, which would make the second
#          launch in the same PowerShell session fail.
#   GOTCHA XamlReader will not accept x:Class or event attributes; the XAML files
#          carry neither. Handlers are attached here with Add_Click etc. Any error
#          inside a handler would otherwise tear the window down, so every handler
#          goes through Invoke-Guarded and lands in the log instead.
function Import-Xaml {
    param([string]$Path)
    $xml = [xml](Get-Content -Path $Path -Raw)
    $reader = [System.Xml.XmlNodeReader]::new($xml)
    return [System.Windows.Markup.XamlReader]::Load($reader)
}

# Theme.xaml is Ember; any other theme is Theme.<Name>.xaml with the same keys (the tests check).
$Gui.Theme = Import-Xaml -Path (Join-Path $Gui.GuiDir $(if ($Theme -eq 'Ember') { 'Theme.xaml' } else { "Theme.$Theme.xaml" }))
$Gui.Window = Import-Xaml -Path (Join-Path $Gui.GuiDir 'Shell.xaml')
$Gui.Window.Resources.MergedDictionaries.Add($Gui.Theme)
foreach ($m in [regex]::Matches((Get-Content (Join-Path $Gui.GuiDir 'Shell.xaml') -Raw), 'x:Name="([^"]+)"')) {
    $name = $m.Groups[1].Value
    $Gui.Ui[$name] = $Gui.Window.FindName($name)
}

# Pure address maths for instant checks in dialogs. These three make no Azure calls;
# everything else in NetworkBuild runs in the worker (region 4) like all Azure work.
Import-Module (Join-Path $PSScriptRoot 'modules' 'NetworkBuild' 'NetworkBuild.psd1') -Function Test-NetCidr, Test-NetSubnetPrefix, Get-NetFreeSubnetPrefix -Force

function Get-ThemeResource {
    param([string]$Key)
    return $Gui.Window.TryFindResource($Key)
}

function Invoke-Guarded {
    # Every UI event goes through here: an exception in a handler must end in the
    # log, not in a crashed window.
    param([scriptblock]$Handler, [object]$Context)
    try { & $Handler $Context }
    catch {
        $msg = $_.Exception.Message
        if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) { $msg += " (line $($_.InvocationInfo.ScriptLineNumber))" }
        if ($Gui.Ui.ContainsKey('LogBox')) { Write-GuiLog "Error: $msg" 'error' } else { Write-Error $msg }
    }
}

function Write-GuiLog {
    <#
    .SYNOPSIS
        Append a line to the log pane. A plain TextBox has one colour, so the level
        is a prefix.
    #>
    param([string]$Message, [ValidateSet('info', 'verbose', 'warn', 'error', 'ok')] [string]$Level = 'info')
    $prefix = switch ($Level) { 'verbose' { '   ' } 'warn' { ' ! ' } 'error' { ' X ' } 'ok' { ' + ' } default { ' > ' } }
    $line = '{0} {1}{2}' -f (Get-Date).ToString('HH:mm:ss'), $prefix, $Message
    $Gui.Ui.LogBox.AppendText($line + [Environment]::NewLine)
    $Gui.Ui.LogBox.ScrollToEnd()
}

function Set-Status {
    param([string]$Text, [bool]$Busy = $Gui.State.Busy)
    $Gui.Ui.StatusText.Text = $Text
    $Gui.Ui.BusyBar.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
}

function Show-Message {
    param([string]$Text, [string]$Title = 'Azure Virtual Desktop', [string]$Icon = 'Information')
    $null = [System.Windows.MessageBox]::Show($Gui.Window, $Text, $Title, 'OK', $Icon)
}

function Confirm-Action {
    param([string]$Text, [string]$Title = 'Confirm')
    $r = [System.Windows.MessageBox]::Show($Gui.Window, $Text, $Title, 'OKCancel', 'Question')
    return ($r -eq 'OK')
}
#endregion

#region 4. Worker runspace ----------------------------------------------------
#   WHAT   One long-lived runspace that owns the Az sign-in and runs every job,
#          one at a time. A DispatcherTimer copies its streams into the log.
#   WHY    Az context lives in the runspace that signed in. Using one worker for
#          everything means no cross-runspace context games, and the UI thread
#          never blocks on Azure. One job at a time keeps the story simple: the
#          busy bar is on, buttons are off, and the log is about one thing.
#   GOTCHA Handlers on the worker's streams would fire on the worker thread, which
#          must not touch WPF objects. Polling from the timer (UI thread) avoids it.
#          Modules are imported with an explicit Import-Module after the runspace
#          opens: InitialSessionState.ImportPSModule swallows import errors, which
#          once left the worker without the repo modules and every job failing with
#          "Find-AzSubscriptionAcrossTenant is not recognized".
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$Gui.Worker = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
$Gui.Worker.ApartmentState = 'MTA'
$Gui.Worker.ThreadOptions = 'ReuseThread'
$Gui.Worker.Open()

$init = [System.Management.Automation.PowerShell]::Create()
$init.Runspace = $Gui.Worker
$null = $init.AddScript({
    param([string[]]$Paths)
    $ErrorActionPreference = 'Stop'
    foreach ($path in $Paths) {
        if (-not (Test-Path $path)) { throw "Module manifest not found: $path" }
        $m = Import-Module $path -Force -PassThru -ErrorAction Stop
        "$($m.Name) ($($m.ExportedFunctions.Count) functions)"
    }
    if (-not (Get-Command Find-AzSubscriptionAcrossTenant -ErrorAction SilentlyContinue)) { throw 'AzHelpers imported but Find-AzSubscriptionAcrossTenant is missing.' }
}.ToString()).AddArgument($Gui.Modules)
try {
    $loaded = @($init.Invoke())
    if ($init.HadErrors) { throw (($init.Streams.Error | ForEach-Object { $_.ToString() }) -join '; ') }
} catch {
    $Gui.Worker.Close()
    throw "The worker runspace could not load the repo modules: $($_.Exception.Message)"
} finally {
    $init.Dispose()
}

function Start-Work {
    <#
    .SYNOPSIS
        Run a scriptblock in the worker with one hashtable argument. OnDone runs on
        the UI thread as ($result, $failureMessage, $Context) when it finishes.
    #>
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [scriptblock]$Script,
        [hashtable]$Argument = @{},
        [scriptblock]$OnDone,
        [object]$Context
    )
    if ($Gui.State.Busy) { Show-Message 'Something is already running. Wait for it to finish.' 'Busy' 'Warning'; return }
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $Gui.Worker
    $null = $ps.AddScript($Script.ToString()).AddArgument($Argument)
    $inbound = [System.Management.Automation.PSDataCollection[psobject]]::new()
    $output  = [System.Management.Automation.PSDataCollection[psobject]]::new()
    $Gui.Job = @{
        Name = $Name; Ps = $ps; Output = $output; OnDone = $OnDone; Context = $Context
        Handle = $ps.BeginInvoke($inbound, $output)
        Read = @{ Verbose = 0; Warning = 0; Error = 0; Information = 0; Progress = 0 }
    }
    $Gui.State.Busy = $true
    Set-Status "Running: $Name" $true
    Write-GuiLog "$Name ..." 'info'
    Set-PageEnabled $false
}

function Read-WorkStream {
    # Copy anything new from the worker's streams into the log.
    $j = $Gui.Job
    if (-not $j) { return }
    $s = $j.Ps.Streams
    while ($j.Read.Verbose -lt $s.Verbose.Count)         { Write-GuiLog $s.Verbose[$j.Read.Verbose].Message 'verbose'; $j.Read.Verbose++ }
    while ($j.Read.Information -lt $s.Information.Count) { Write-GuiLog ("$($s.Information[$j.Read.Information].MessageData)") 'info'; $j.Read.Information++ }
    while ($j.Read.Warning -lt $s.Warning.Count)         { Write-GuiLog $s.Warning[$j.Read.Warning].Message 'warn'; $j.Read.Warning++ }
    while ($j.Read.Error -lt $s.Error.Count)             { Write-GuiLog ("$($s.Error[$j.Read.Error])") 'error'; $j.Read.Error++ }
    if ($j.Read.Progress -lt $s.Progress.Count) {
        $p = $s.Progress[$s.Progress.Count - 1]
        Set-Status ("{0}: {1}" -f $p.Activity, $p.StatusDescription) $true
        $j.Read.Progress = $s.Progress.Count
    }
}

function Complete-Work {
    $j = $Gui.Job
    $result = $null; $failure = $null
    try {
        $null = $j.Ps.EndInvoke($j.Handle)
        $result = @($j.Output)
    } catch {
        $e = $_.Exception
        if ($e.InnerException -and $e.GetType().Name -eq 'MethodInvocationException') { $e = $e.InnerException }
        $failure = $e.Message
    }
    $j.Ps.Dispose()
    $Gui.Job = $null
    $Gui.State.Busy = $false
    Set-PageEnabled $true
    if ($failure) {
        Write-GuiLog "$($j.Name) FAILED: $failure" 'error'
        Set-Status "Failed: $($j.Name)" $false
    } else {
        Write-GuiLog "$($j.Name) done." 'ok'
        Set-Status 'Ready' $false
    }
    if ($j.OnDone) {
        try { & $j.OnDone $result $failure $j.Context }
        catch { Write-GuiLog "UI update after $($j.Name) failed: $($_.Exception.Message)" 'error' }
    }
    if ($Gui.PendingShow -and -not $Gui.State.Busy) {
        $key = $Gui.PendingShow; $Gui.PendingShow = $null
        $pg = $Gui.Pages[$key]
        if ($pg -and $Gui.Ui.PageHost.Content -eq $pg.Root -and $pg.ContainsKey('OnShow')) {
            try { & $pg.OnShow $pg } catch { Write-GuiLog "Loading the page failed: $($_.Exception.Message)" 'error' }
        }
    }
}

$Gui.Timer = [System.Windows.Threading.DispatcherTimer]::new()
$Gui.Timer.Interval = [TimeSpan]::FromMilliseconds(400)
$Gui.Timer.Add_Tick({
    Invoke-Guarded {
        if ($Gui.Job) {
            Read-WorkStream
            if ($Gui.Job.Handle.IsCompleted) { Read-WorkStream; Complete-Work }
            return
        }
        # Sizes and SKUs are two jobs and the worker takes one at a time: when the
        # sizes job has finished and a SKU load is pending, run it now.
        if ($Gui.PendingSkuLoad) {
            $pending = $Gui.PendingSkuLoad; $Gui.PendingSkuLoad = $null
            Update-ImageSkuOption -Location $pending.Location -Form $pending.Form
            return
        }
        # Just-in-time RDP grants made in this session are closed when their time is up.
        $due = $Gui.Jit | Where-Object { $_.Expires -le (Get-Date) } | Select-Object -First 1
        if ($due) { Invoke-RdpRevoke -ResourceGroupName $due.Rg -VMName $due.Vm -Silent }
    }
})
$Gui.Timer.Start()

# The job every action page uses: run a repo script with a parameter hashtable.
# Verbose is forced on so the script narrates into the log. A credential check
# runs first when one is present, so a bad password fails here and not on step six.
$Gui.RunScriptJob = {
    param([hashtable]$Job)
    $ErrorActionPreference = 'Stop'
    $p = $Job.Params.Clone()
    if ($p.ContainsKey('LocalAdminCredential')) {
        $problems = @(Test-AvdVmCredentialPolicy -Credential $p.LocalAdminCredential)
        if ($problems.Count -gt 0) { throw "Local admin credential: $($problems -join ' ')" }
    }
    if ($Job.ContainsKey('Before')) { & ([scriptblock]::Create($Job.Before)) $p }
    $p.Verbose = $true
    & $Job.Path @p
}

function Format-ParamPreview {
    # Same masking as the console: credentials show the user name, tokens are hidden.
    param([hashtable]$Params)
    $lines = foreach ($k in ($Params.Keys | Sort-Object)) {
        $v = $Params[$k]
        $shown = if ($v -is [pscredential]) { "<credential: $($v.UserName)>" }
                 elseif ($k -like '*Token*') { '<hidden>' }
                 elseif ($v -is [array]) { $v -join ', ' }
                 else { "$v" }
        '{0,-26} {1}' -f $k, $shown
    }
    return ($lines -join [Environment]::NewLine)
}

function Invoke-RepoScript {
    <#
    .SYNOPSIS
        Preview the parameters, confirm, run the script in the worker, log the result.
    .PARAMETER Before
        Optional scriptblock text run in the worker first with the params hashtable,
        for things like fetching a registration token.
    #>
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [hashtable]$Params,
        [switch]$DryRun,
        [switch]$Destructive,
        [string]$Before,
        [scriptblock]$OnDone,
        [object]$Context
    )
    $p = $Params.Clone()
    if ($DryRun) { $p.WhatIf = $true }
    $verb = if ($DryRun) { 'Dry run (-WhatIf) of' } elseif ($Destructive) { 'THIS DELETES THINGS. Run' } else { 'Run' }
    $text = "$verb $(Split-Path $Path -Leaf) with:`n`n$(Format-ParamPreview $p)"
    if (-not (Confirm-Action $text $Name)) { Write-GuiLog "$Name cancelled." 'info'; return }
    $arg = @{ Path = $Path; Params = $p }
    if ($Before) { $arg.Before = $Before }
    Start-Work -Name $Name -Script $Gui.RunScriptJob -Argument $arg -Context @{ OnDone = $OnDone; Context = $Context } -OnDone {
        param($result, $failure, $c)
        if (-not $failure -and $result) {
            foreach ($r in $result) { if ($null -ne $r) { Write-GuiLog (($r | Format-List | Out-String).Trim()) 'info' } }
        }
        if ($c.OnDone) { & $c.OnDone $result $failure $c.Context }
    }
}
#endregion

#region 5. Form builder -------------------------------------------------------
#   WHAT   Pages are data. A field is a hashtable (Name, Label, Type, Default, Help,
#          Options, Required, Span). New-FormSection turns a list into a card with a
#          two-column grid; Get-FormValue reads one back typed.
#   WHY    Adding a question to a form is one line, same as the console. The look
#          comes entirely from Theme.xaml, so this code never mentions a colour.
#   GOTCHA Empty text means "use the script's default": the caller omits the
#          parameter. Required fields are checked by Test-FormRequired.
function ConvertTo-Thickness {
    # 'l,t,r,b', 'h,v' or a single number, as XAML writes margins. Thickness has no Parse.
    param([string]$Text)
    $n = @($Text -split ',' | ForEach-Object { [double]$_.Trim() })
    switch ($n.Count) {
        1 { return [System.Windows.Thickness]::new($n[0]) }
        2 { return [System.Windows.Thickness]::new($n[0], $n[1], $n[0], $n[1]) }
        4 { return [System.Windows.Thickness]::new($n[0], $n[1], $n[2], $n[3]) }
    }
    throw "Thickness '$Text' needs 1, 2 or 4 numbers."
}

function New-TextBlock {
    param([string]$Text, [string]$Style, [string]$Margin)
    $t = [System.Windows.Controls.TextBlock]::new()
    $t.Text = $Text
    if ($Style) { $t.Style = Get-ThemeResource $Style }
    if ($Margin) { $t.Margin = ConvertTo-Thickness $Margin }
    return $t
}

function New-Button {
    <#
    .SYNOPSIS
        A button whose click handler receives -Context. The handler is stored on the
        button's Tag and invoked through $this, so no closure is needed.
    #>
    param([string]$Text, [scriptblock]$OnClick, [object]$Context, [string]$Style, [string]$ToolTip)
    $b = [System.Windows.Controls.Button]::new()
    $b.Content = $Text
    if ($Style) { $b.Style = Get-ThemeResource $Style }
    if ($ToolTip) { $b.ToolTip = $ToolTip }
    if ($OnClick) {
        $b.Tag = @{ Handler = $OnClick; Context = $Context }
        $b.Add_Click({ Invoke-Guarded $this.Tag.Handler $this.Tag.Context })
    }
    return $b
}

function Add-ControlHandler {
    # Same trick for any control: Tag carries the handler and its context.
    param([System.Windows.FrameworkElement]$Control, [string]$EventName, [scriptblock]$Handler, [object]$Context)
    $Control.Tag = @{ Handler = $Handler; Context = $Context }
    switch ($EventName) {
        'SelectionChanged' { $Control.Add_SelectionChanged({ Invoke-Guarded $this.Tag.Handler $this.Tag.Context }) }
        'LostFocus'        { $Control.Add_LostFocus({ Invoke-Guarded $this.Tag.Handler $this.Tag.Context }) }
        'Checked'          { $Control.Add_Checked({ Invoke-Guarded $this.Tag.Handler $this.Tag.Context }); $Control.Add_Unchecked({ Invoke-Guarded $this.Tag.Handler $this.Tag.Context }) }
        'DoubleClick'      { $Control.Add_MouseDoubleClick({ Invoke-Guarded $this.Tag.Handler $this.Tag.Context }) }
    }
}

function New-ButtonRow {
    param([System.Windows.Controls.Button[]]$Buttons)
    $row = [System.Windows.Controls.StackPanel]::new()
    $row.Orientation = 'Horizontal'
    $row.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    foreach ($b in $Buttons) { $null = $row.Children.Add($b) }
    return $row
}

function New-Card {
    param([string]$Title, [string]$Subtitle)
    $card = [System.Windows.Controls.Border]::new()
    $card.Style = Get-ThemeResource 'Card'
    $stack = [System.Windows.Controls.StackPanel]::new()
    if ($Title)    { $null = $stack.Children.Add((New-TextBlock -Text $Title -Style 'Subhead')) }
    if ($Subtitle) { $null = $stack.Children.Add((New-TextBlock -Text $Subtitle -Style 'Muted' -Margin '0,-6,0,12')) }
    $card.Child = $stack
    return $card
}

function New-Combo {
    param([int]$Width, [string]$Margin = '0,0,8,0')
    $c = [System.Windows.Controls.ComboBox]::new()
    if ($Width) { $c.Width = $Width }
    $c.Margin = ConvertTo-Thickness $Margin
    return $c
}

function Add-ComboOption {
    <#
    .SYNOPSIS
        Replace a ComboBox's items. Options are strings or objects/hashtables with
        Label and Value; the value rides on each item's Tag.
    #>
    param([System.Windows.Controls.ComboBox]$Combo, [object[]]$Options, [string]$Default)
    $Combo.Items.Clear()
    foreach ($o in $Options) {
        $item = [System.Windows.Controls.ComboBoxItem]::new()
        if ($o -is [string]) { $item.Content = $o; $item.Tag = $o }
        else { $item.Content = $o.Label; $item.Tag = $o.Value }
        $null = $Combo.Items.Add($item)
        if ($Default -and "$($item.Tag)" -eq $Default) { $Combo.SelectedItem = $item }
    }
    if ($Combo.SelectedIndex -lt 0 -and $Combo.Items.Count -gt 0 -and -not $Default) { $Combo.SelectedIndex = 0 }
}

function Get-ComboValue {
    param([System.Windows.Controls.ComboBox]$Combo)
    if ($Combo.SelectedItem) { return "$($Combo.SelectedItem.Tag)" }
    if ($Combo.IsEditable) { return $Combo.Text.Trim() }
    return ''
}

function New-Form { return @{ Controls = @{}; Fields = @{}; Cells = @{} } }

function New-FormSection {
    param(
        [Parameter(Mandatory)] [hashtable]$Form,
        [string]$Title,
        [string]$Subtitle,
        [Parameter(Mandatory)] [object[]]$Fields
    )
    $card = New-Card -Title $Title -Subtitle $Subtitle
    $grid = [System.Windows.Controls.Grid]::new()
    foreach ($i in 0..1) {
        $col = [System.Windows.Controls.ColumnDefinition]::new()
        $col.Width = [System.Windows.GridLength]::new(1, 'Star')
        $null = $grid.ColumnDefinitions.Add($col)
    }
    $row = 0; $col = 0
    foreach ($f in $Fields) {
        $span = if ($f.ContainsKey('Span')) { [int]$f.Span } else { 1 }
        if ($span -eq 2 -and $col -eq 1) { $row++; $col = 0 }
        while ($grid.RowDefinitions.Count -le $row) { $null = $grid.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new()) }

        $cell = [System.Windows.Controls.StackPanel]::new()
        $left  = if ($col -eq 0) { 0 } else { 12 }
        $right = if ($col -eq 0 -and $span -eq 1) { 12 } else { 0 }
        $cell.Margin = [System.Windows.Thickness]::new($left, 0, $right, 16)
        $type = if ($f.ContainsKey('Type')) { $f.Type } else { 'text' }
        $default = if ($f.ContainsKey('Default')) { $f.Default } else { '' }
        $required = $f.ContainsKey('Required') -and $f.Required
        $label = $f.Label + $(if ($required) { ' *' } else { '' })

        if ($type -ne 'check') { $null = $cell.Children.Add((New-TextBlock -Text $label -Style 'FieldLabel')) }
        $control = switch ($type) {
            'password' { [System.Windows.Controls.PasswordBox]::new() }
            'multiline' {
                $t = [System.Windows.Controls.TextBox]::new(); $t.Text = "$default"
                $t.AcceptsReturn = $true; $t.TextWrapping = 'Wrap'; $t.Height = 96; $t.VerticalScrollBarVisibility = 'Auto'; $t
            }
            'check' {
                $c = [System.Windows.Controls.CheckBox]::new(); $c.Content = $f.Label; $c.IsChecked = [bool]$default; $c
            }
            'combo' {
                $c = [System.Windows.Controls.ComboBox]::new()
                if ($f.ContainsKey('Editable') -and $f.Editable) { $c.IsEditable = $true }
                Add-ComboOption -Combo $c -Options $(if ($f.ContainsKey('Options')) { $f.Options } else { @() }) -Default "$default"
                $c
            }
            default {
                $t = [System.Windows.Controls.TextBox]::new(); $t.Text = "$default"; $t
            }
        }
        $null = $cell.Children.Add($control)
        if ($f.ContainsKey('Help') -and $f.Help) { $null = $cell.Children.Add((New-TextBlock -Text $f.Help -Style 'Caption' -Margin '0,4,0,0')) }
        [System.Windows.Controls.Grid]::SetRow($cell, $row)
        [System.Windows.Controls.Grid]::SetColumn($cell, $col)
        [System.Windows.Controls.Grid]::SetColumnSpan($cell, $span)
        $null = $grid.Children.Add($cell)
        $Form.Controls[$f.Name] = $control
        $Form.Fields[$f.Name] = $f
        $Form.Cells[$f.Name] = $cell
        if ($span -eq 2 -or $col -eq 1) { $row++; $col = 0 } else { $col = 1 }
    }
    $null = $card.Child.Children.Add($grid)
    return $card
}

function Get-FormValue {
    param([hashtable]$Form, [string]$Name)
    $c = $Form.Controls[$Name]
    $f = $Form.Fields[$Name]
    $type = if ($f.ContainsKey('Type')) { $f.Type } else { 'text' }
    switch ($type) {
        'check'    { return [bool]$c.IsChecked }
        'password' { return $c.SecurePassword }
        'int'      { $t = $c.Text.Trim(); if ($t -eq '') { return $null } else { return [int]$t } }
        'combo'    { return (Get-ComboValue $c) }
        default    { return $c.Text.Trim() }
    }
}

function Set-FormValue {
    # Push a value into a form control, by field type.
    param([hashtable]$Form, [string]$Name, $Value)
    $c = $Form.Controls[$Name]
    $f = $Form.Fields[$Name]
    $type = if ($f.ContainsKey('Type')) { $f.Type } else { 'text' }
    switch ($type) {
        'check' { $c.IsChecked = [bool]$Value }
        'combo' {
            $match = $c.Items | Where-Object { "$($_.Tag)" -eq "$Value" } | Select-Object -First 1
            if ($match) { $c.SelectedItem = $match } elseif ($c.IsEditable) { $c.SelectedItem = $null; $c.Text = "$Value" }
        }
        'password' { }
        default { $c.Text = "$Value" }
    }
}

function Test-FormRequired {
    # $true when every Required field has a value; otherwise shows which are missing.
    param([hashtable]$Form, [string[]]$Only)
    $missing = foreach ($name in $Form.Fields.Keys) {
        if ($Only -and $name -notin $Only) { continue }
        $f = $Form.Fields[$name]
        if ($f.ContainsKey('Required') -and $f.Required) {
            $v = Get-FormValue $Form $name
            if ($null -eq $v -or "$v" -eq '' -or ($v -is [securestring] -and $v.Length -eq 0)) { $f.Label }
        }
    }
    if (@($missing).Count -gt 0) {
        Show-Message "Please fill in:`n`n- $(@($missing) -join "`n- ")" 'Missing values' 'Warning'
        return $false
    }
    return $true
}

function Add-FormParameter {
    <#
    .SYNOPSIS
        Copy non-empty form values into a parameter hashtable. Field names are the
        parameter names. Unchecked boxes are omitted so switches stay off.
    #>
    param([hashtable]$Params, [hashtable]$Form, [string[]]$Names)
    foreach ($n in $Names) {
        $v = Get-FormValue $Form $n
        if ($null -eq $v) { continue }
        if ($v -is [bool]) { if ($v) { $Params[$n] = $true }; continue }
        if ("$v" -ne '') { $Params[$n] = $v }
    }
}

function Get-FormCredential {
    # Two password boxes must match; the Azure policy check itself runs in the worker.
    param([hashtable]$Form, [string]$UserField = 'AdminUser', [string]$SecretField = 'AdminPassword', [string]$ConfirmField = 'AdminPasswordConfirm')
    $u = Get-FormValue $Form $UserField
    $p1 = $Form.Controls[$SecretField]; $p2 = $Form.Controls[$ConfirmField]
    if (-not $u) { Show-Message 'Local administrator user name is required.' 'Credential' 'Warning'; return $null }
    if ($p1.SecurePassword.Length -eq 0) { Show-Message 'Password is required.' 'Credential' 'Warning'; return $null }
    if ($p1.Password -ne $p2.Password) { Show-Message 'The two passwords do not match.' 'Credential' 'Warning'; return $null }
    return [pscredential]::new($u, $p1.SecurePassword)
}

function ConvertTo-DataTable {
    # WPF's DataGrid cannot auto-generate columns from PSObjects; from a DataTable it can.
    param([object[]]$Rows, [string[]]$Columns)
    # GOTCHA PowerShell unrolls a DataTable into its rows on output, so the table is
    #        returned behind the comma operator to keep it whole.
    $dt = [System.Data.DataTable]::new()
    if ($Rows -and @($Rows).Count -gt 0) {
        if (-not $Columns) { $Columns = @($Rows[0].PSObject.Properties.Name) }
        foreach ($c in $Columns) { $null = $dt.Columns.Add($c, [string]) }
        foreach ($r in $Rows) {
            $dr = $dt.NewRow()
            # StrictMode throws on a missing property, and result rows are not all the
            # same shape (a failure row has fewer columns), so look each one up.
            foreach ($c in $Columns) {
                $v = if ($r -is [System.Collections.IDictionary]) { if ($r.Contains($c)) { $r[$c] } else { $null } }
                     else { $pp = $r.PSObject.Properties[$c]; if ($pp) { $pp.Value } else { $null } }
                $dr[$c] = "$v"
            }
            $dt.Rows.Add($dr)
        }
    }
    return , $dt
}

function Get-GridSelection {
    # Selected rows of a DataGrid bound to a DataTable, as hashtables of column -> text.
    param($Grid)   # a DataGrid; untyped so the function can be unit-tested without WPF
    $rows = foreach ($rv in $Grid.SelectedItems) {
        $h = @{}
        foreach ($c in $rv.Row.Table.Columns) { $h[$c.ColumnName] = $rv.Row[$c.ColumnName] }
        $h
    }
    # GOTCHA A single hashtable returned on its own unrolls, and its .Count is then
    #        the number of columns. The comma keeps the result an array of rows.
    return , @($rows)
}

function New-DataGrid {
    param([int]$Height = 320)
    $g = [System.Windows.Controls.DataGrid]::new()
    $g.Height = $Height
    $g.Margin = [System.Windows.Thickness]::new(0, 8, 0, 8)
    return $g
}

function Set-PageEnabled {
    param([bool]$Enabled)
    $Gui.Ui.PageHost.IsEnabled = $Enabled
    $Gui.Ui.AccountButton.IsEnabled = $Enabled
    $Gui.Ui.SubscriptionCombo.IsEnabled = $Enabled -and ($Gui.State.Subscriptions.Count -gt 0)
}

function Test-SignedIn {
    if (-not $Gui.State.Account) { Show-Message 'Sign in first (account menu, top right).' 'Not signed in' 'Warning'; return $false }
    return $true
}
function Test-PoolSelected {
    if (-not (Test-SignedIn)) { return $false }
    if (-not $Gui.State.Pool) { Show-Message 'Pick a host pool first: Cloud desktops > Host pools, select one, then Open.' 'No host pool' 'Warning'; return $false }
    return $true
}

# --- Menus, table cards, dialogs -------------------------------------------
#   WHAT   The console idioms: a card with a coloured header band and a grid in it,
#          a Manage menu in that band, the same menu on right-click of a row.
#   GOTCHA A ContextMenu lives in its own popup and can hang off one control only,
#          so the button and the grid each get their own menu built from one list.
#          WPF does not select a row on right-click; Set-GridRowMenu does.
function Show-ControlMenu {
    param([System.Windows.Controls.Control]$Control)
    $m = $Control.ContextMenu
    $m.PlacementTarget = $Control; $m.Placement = 'Bottom'; $m.IsOpen = $true
}

function New-ActionMenu {
    <#
    .SYNOPSIS
        A ContextMenu from items of @{ Text; Handler; Context; ToolTip } or
        @{ Separator = $true }. Like New-Button, the handler rides on the item's Tag.
    #>
    param([object[]]$Items)
    $menu = [System.Windows.Controls.ContextMenu]::new()
    foreach ($i in $Items) {
        if ($i.ContainsKey('Separator') -and $i.Separator) { $null = $menu.Items.Add([System.Windows.Controls.Separator]::new()); continue }
        $mi = [System.Windows.Controls.MenuItem]::new()
        $mi.Header = $i.Text
        if ($i.ContainsKey('ToolTip') -and $i.ToolTip) { $mi.ToolTip = $i.ToolTip }
        $mi.Tag = @{ Handler = $i.Handler; Context = $(if ($i.ContainsKey('Context')) { $i.Context } else { $null }) }
        $mi.Add_Click({ Invoke-Guarded $this.Tag.Handler $this.Tag.Context })
        $null = $menu.Items.Add($mi)
    }
    return $menu
}

function New-MenuButton {
    # "Manage" with a drop-down: the actions of a table card, applied to the selected rows.
    param([string]$Text = 'Manage', [object[]]$Items, [string]$Style, [string]$ToolTip = 'Actions for the selected rows')
    $b = [System.Windows.Controls.Button]::new()
    $b.Content = "$Text $([char]0x25BE)"
    if ($Style) { $b.Style = Get-ThemeResource $Style }
    $b.ToolTip = $ToolTip
    $b.ContextMenu = New-ActionMenu -Items $Items
    $b.Add_Click({ Invoke-Guarded { param($c) Show-ControlMenu $c } $this })
    return $b
}

function Get-VisualAncestor {
    param($Element, [type]$Type)
    $d = $Element
    while ($d) {
        if ($d -is $Type) { return $d }
        $d = if ($d -is [System.Windows.Media.Visual]) { [System.Windows.Media.VisualTreeHelper]::GetParent($d) }
             elseif ($d -is [System.Windows.FrameworkContentElement]) { $d.Parent }
             else { $null }
    }
    return $null
}

function Set-GridRowMenu {
    # Right-click a row: select it (unless it is already in the selection) and open the actions.
    param([System.Windows.Controls.DataGrid]$Grid, [object[]]$Items)
    $Grid.ContextMenu = New-ActionMenu -Items $Items
    $Grid.Add_PreviewMouseRightButtonDown({
        $row = Get-VisualAncestor -Element $args[1].OriginalSource -Type ([System.Windows.Controls.DataGridRow])
        if ($row -and -not $row.IsSelected) { $this.SelectedItems.Clear(); $row.IsSelected = $true }
    })
}

function New-TableCard {
    <#
    .SYNOPSIS
        A card with a header band (title left, tools right) and a grid below it.
        Tools are buttons in the TopBarButton style so they read on the band.
    #>
    param([string]$Title, [System.Windows.Controls.DataGrid]$Grid, [object[]]$Tools, [string]$Note)
    $card = [System.Windows.Controls.Border]::new(); $card.Style = Get-ThemeResource 'TableCard'
    $stack = [System.Windows.Controls.StackPanel]::new()
    $head = [System.Windows.Controls.Border]::new(); $head.Style = Get-ThemeResource 'CardHeader'
    # GOTCHA Variable names are case-insensitive: a local $tools or $title would assign
    #        into the typed parameter and be converted to its type. Locals get other names.
    $bar = [System.Windows.Controls.DockPanel]::new()
    $toolPanel = [System.Windows.Controls.StackPanel]::new(); $toolPanel.Orientation = 'Horizontal'
    [System.Windows.Controls.DockPanel]::SetDock($toolPanel, 'Right')
    foreach ($t in @($Tools)) {
        if (-not $t) { continue }
        $t.Style = Get-ThemeResource 'TopBarButton'; $t.MinHeight = 26; $t.Padding = ConvertTo-Thickness '10,2'; $t.Margin = ConvertTo-Thickness '8,0,0,0'
        $null = $toolPanel.Children.Add($t)
    }
    $null = $bar.Children.Add($toolPanel)   # docked children first; the last child fills what is left
    $titleText = New-TextBlock -Text $Title -Style 'CardHeaderText'; $titleText.VerticalAlignment = 'Center'
    $null = $bar.Children.Add($titleText)
    $head.Child = $bar
    $null = $stack.Children.Add($head)
    $Grid.Margin = ConvertTo-Thickness '0'; $Grid.BorderThickness = ConvertTo-Thickness '0'
    $null = $stack.Children.Add($Grid)
    if ($Note) { $n = New-TextBlock -Text $Note -Style 'Caption' -Margin '16,8,16,10'; $n.TextWrapping = 'Wrap'; $null = $stack.Children.Add($n) }
    $card.Child = $stack
    return $card
}

function New-ToolButton {
    # A header-band button; New-TableCard restyles it.
    param([string]$Text, [scriptblock]$OnClick, [object]$Context, [string]$ToolTip)
    return (New-Button -Text $Text -OnClick $OnClick -Context $Context -ToolTip $ToolTip)
}

function Show-ChoiceDialog {
    # One combo and a button. Returns the chosen value or $null.
    param([string]$Title, [string]$Text, [object[]]$Options, [string]$Default = '', [string]$OkText = 'OK')
    $dlg = [System.Windows.Window]::new()
    $dlg.Title = $Title; $dlg.Width = 500; $dlg.SizeToContent = 'Height'; $dlg.Owner = $Gui.Window
    $dlg.WindowStartupLocation = 'CenterOwner'; $dlg.ResizeMode = 'NoResize'
    $dlg.Resources.MergedDictionaries.Add($Gui.Theme); $dlg.Background = Get-ThemeResource 'Brush.Background'
    $stack = [System.Windows.Controls.StackPanel]::new(); $stack.Margin = [System.Windows.Thickness]::new(24)
    $t = New-TextBlock -Text $Text -Style 'Muted' -Margin '0,0,0,12'; $t.TextWrapping = 'Wrap'
    $null = $stack.Children.Add($t)
    $combo = New-Combo -Margin '0'
    Add-ComboOption -Combo $combo -Options $Options -Default $Default
    $null = $stack.Children.Add($combo)
    $ok = New-Button -Text $OkText -Style 'PrimaryButton' -Context $dlg -OnClick { param($d) $d.DialogResult = $true }
    $ok.Margin = [System.Windows.Thickness]::new(0, 16, 0, 0); $ok.HorizontalAlignment = 'Right'
    $null = $stack.Children.Add($ok)
    $dlg.Content = $stack
    if ($dlg.ShowDialog()) { return (Get-ComboValue $combo) }
    return $null
}

function Show-InputDialog {
    # A text box (one line or several) and a button. Returns the text, or $null on cancel.
    param([string]$Title, [string]$Text, [string]$Default = '', [switch]$Multiline, [string]$OkText = 'OK')
    $dlg = [System.Windows.Window]::new()
    $dlg.Title = $Title; $dlg.Width = 520; $dlg.SizeToContent = 'Height'; $dlg.Owner = $Gui.Window
    $dlg.WindowStartupLocation = 'CenterOwner'; $dlg.ResizeMode = 'NoResize'
    $dlg.Resources.MergedDictionaries.Add($Gui.Theme); $dlg.Background = Get-ThemeResource 'Brush.Background'
    $stack = [System.Windows.Controls.StackPanel]::new(); $stack.Margin = [System.Windows.Thickness]::new(24)
    $t = New-TextBlock -Text $Text -Style 'Muted' -Margin '0,0,0,12'; $t.TextWrapping = 'Wrap'
    $null = $stack.Children.Add($t)
    $box = [System.Windows.Controls.TextBox]::new(); $box.Text = $Default
    if ($Multiline) { $box.AcceptsReturn = $true; $box.TextWrapping = 'Wrap'; $box.Height = 140; $box.VerticalScrollBarVisibility = 'Auto' }
    $null = $stack.Children.Add($box)
    $ok = New-Button -Text $OkText -Style 'PrimaryButton' -Context $dlg -OnClick { param($d) $d.DialogResult = $true }
    $ok.Margin = [System.Windows.Thickness]::new(0, 16, 0, 0); $ok.HorizontalAlignment = 'Right'
    $null = $stack.Children.Add($ok)
    $dlg.Content = $stack
    $null = $box.Focus()
    if ($dlg.ShowDialog()) { return $box.Text.Trim() }
    return $null
}

function Show-FormDialog {
    <#
    .SYNOPSIS
        A small window with form fields (same field specs as New-FormSection), one
        button per action and Cancel. -Validate gets (form, action, context) and
        returns problem sentences; the window stays open while there are any.
        Returns @{ Action; Form } or $null when cancelled.
    #>
    param([string]$Title, [string]$Lead, [object[]]$Fields, [object[]]$Buttons, [scriptblock]$Validate, [object]$Context, [int]$Width = 640)
    $dlg = [System.Windows.Window]::new()
    $dlg.Title = $Title; $dlg.Width = $Width; $dlg.SizeToContent = 'Height'; $dlg.Owner = $Gui.Window
    $dlg.WindowStartupLocation = 'CenterOwner'; $dlg.ResizeMode = 'NoResize'
    $dlg.Resources.MergedDictionaries.Add($Gui.Theme); $dlg.Background = Get-ThemeResource 'Brush.Background'
    $stack = [System.Windows.Controls.StackPanel]::new(); $stack.Margin = [System.Windows.Thickness]::new(24, 20, 24, 20)
    $null = $stack.Children.Add((New-TextBlock -Text $Title -Style 'Subhead'))
    if ($Lead) { $t = New-TextBlock -Text $Lead -Style 'Muted' -Margin '0,0,0,12'; $t.TextWrapping = 'Wrap'; $null = $stack.Children.Add($t) }
    $form = New-Form
    $section = New-FormSection -Form $form -Fields $Fields
    $section.Margin = ConvertTo-Thickness '0'
    $null = $stack.Children.Add($section)
    $row = [System.Windows.Controls.StackPanel]::new(); $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Right'; $row.Margin = ConvertTo-Thickness '0,16,0,0'
    foreach ($b in $Buttons) {
        $style = if ($b.ContainsKey('Style')) { $b.Style } else { '' }
        $null = $row.Children.Add((New-Button -Text $b.Text -Style $style -Context @{ Dlg = $dlg; Form = $form; Action = $b.Action; Validate = $Validate; Ctx = $Context } -OnClick {
            param($c)
            if (-not (Test-FormRequired -Form $c.Form)) { return }
            if ($c.Validate) {
                $problems = @(& $c.Validate $c.Form $c.Action $c.Ctx | Where-Object { $_ })
                if ($problems.Count -gt 0) { Show-Message ($problems -join [Environment]::NewLine) 'Check the form' 'Warning'; return }
            }
            $c.Dlg.Tag = $c.Action; $c.Dlg.DialogResult = $true
        }))
    }
    $null = $row.Children.Add((New-Button -Text 'Cancel' -Style 'GhostButton' -Context $dlg -OnClick { param($d) $d.DialogResult = $false }))
    $null = $stack.Children.Add($row)
    $dlg.Content = $stack
    $first = @($Fields | ForEach-Object { $form.Controls[$_.Name] } | Where-Object { $_ -is [System.Windows.Controls.TextBox] -and -not $_.IsReadOnly }) | Select-Object -First 1
    if ($first) { $null = $first.Focus(); $first.CaretIndex = $first.Text.Length }
    if ($dlg.ShowDialog()) { return @{ Action = $dlg.Tag; Form = $form } }
    return $null
}

function Show-SecretDialog {
    <#
    .SYNOPSIS
        Show new passwords once, each with a Copy button. They never reach the log
        pane: scripts return them as SecureStrings, which the log prints as a type
        name, and this dialog is the only place they are turned back into text.
    #>
    param([object[]]$Rows, [string]$Title = 'New password')
    $dlg = [System.Windows.Window]::new()
    $dlg.Title = $Title; $dlg.Width = 560; $dlg.SizeToContent = 'Height'; $dlg.Owner = $Gui.Window
    $dlg.WindowStartupLocation = 'CenterOwner'; $dlg.ResizeMode = 'NoResize'
    $dlg.Resources.MergedDictionaries.Add($Gui.Theme); $dlg.Background = Get-ThemeResource 'Brush.Background'
    $stack = [System.Windows.Controls.StackPanel]::new(); $stack.Margin = [System.Windows.Thickness]::new(24)
    $lead = New-TextBlock -Text 'Shown once. Copy it now and give it to the user over a separate channel. It is not saved or logged.' -Style 'Muted' -Margin '0,0,0,12'
    $lead.TextWrapping = 'Wrap'
    $null = $stack.Children.Add($lead)
    foreach ($r in $Rows) {
        $plain = [System.Net.NetworkCredential]::new('', $r.TemporaryPassword).Password
        $null = $stack.Children.Add((New-TextBlock -Text "$($r.User)$(if ($r.MustChange) { '  (must change at next sign-in)' })" -Style 'FieldLabel' -Margin '0,8,0,4'))
        $row = [System.Windows.Controls.DockPanel]::new()
        $copy = New-Button -Text 'Copy' -Context $plain -OnClick { param($v) [System.Windows.Clipboard]::SetText($v) }
        [System.Windows.Controls.DockPanel]::SetDock($copy, 'Right'); $copy.Margin = ConvertTo-Thickness '8,0,0,0'
        $null = $row.Children.Add($copy)
        $box = [System.Windows.Controls.TextBox]::new(); $box.Text = $plain; $box.IsReadOnly = $true; $box.FontFamily = Get-ThemeResource 'Font.Mono'
        $null = $row.Children.Add($box)
        $null = $stack.Children.Add($row)
    }
    $ok = New-Button -Text 'Done' -Style 'PrimaryButton' -Context $dlg -OnClick { param($d) $d.DialogResult = $true }
    $ok.Margin = [System.Windows.Thickness]::new(0, 16, 0, 0); $ok.HorizontalAlignment = 'Right'
    $null = $stack.Children.Add($ok)
    $dlg.Content = $stack
    $null = $dlg.ShowDialog()
}

function Show-ResultSecret {
    # After a script that may return TemporaryPassword: show those rows, if any.
    param([object[]]$Result)
    $rows = @(foreach ($r in @($Result)) {
        if ($null -eq $r) { continue }
        $tp = $r.PSObject.Properties['TemporaryPassword']
        if ($tp -and $tp.Value -is [securestring]) {
            $who = if ($r.PSObject.Properties['UserPrincipalName']) { $r.UserPrincipalName } elseif ($r.PSObject.Properties['User']) { $r.User } else { '' }
            $must = if ($r.PSObject.Properties['MustChange']) { [bool]$r.MustChange } else { $false }
            [pscustomobject]@{ User = $who; TemporaryPassword = $tp.Value; MustChange = $must }
        }
    })
    if ($rows.Count -gt 0) { Show-SecretDialog -Rows $rows -Title $(if ($rows.Count -eq 1) { 'New password' } else { 'New passwords' }) }
}

function Show-ResultGrid {
    # Put a script's result rows into a grid, without the secret column.
    param($Grid, [object[]]$Result, [string[]]$Columns)
    $rows = @($Result | Where-Object { $null -ne $_ -and $_ -isnot [string] })
    $Grid.ItemsSource = (ConvertTo-DataTable -Rows $rows -Columns $Columns).DefaultView
}

function New-SearchBar {
    <#
    .SYNOPSIS
        A text box and a Search button; Enter in the box searches too. Returns the
        panel; the box is stored on the page as $Page.SearchBox.
    #>
    param([hashtable]$Page, [string]$Label = 'Search', [string]$Help, [scriptblock]$OnSearch)
    $row = [System.Windows.Controls.StackPanel]::new(); $row.Orientation = 'Horizontal'; $row.Margin = ConvertTo-Thickness '0,0,0,12'
    $null = $row.Children.Add((New-TextBlock -Text $Label -Style 'Muted' -Margin '0,0,8,0'))
    $box = [System.Windows.Controls.TextBox]::new(); $box.Width = 320; $box.Margin = ConvertTo-Thickness '0,0,8,0'
    if ($Help) { $box.ToolTip = $Help }
    $box.Tag = @{ Handler = $OnSearch; Context = $Page }
    $box.Add_KeyDown({ if ($args[1].Key -eq 'Return') { Invoke-Guarded $this.Tag.Handler $this.Tag.Context } })
    $null = $row.Children.Add($box)
    $null = $row.Children.Add((New-Button -Text 'Search' -Context $Page -OnClick $OnSearch))
    $Page.SearchBox = $box
    return $row
}
#endregion

#region 5b. Pickers -----------------------------------------------------------
#   WHAT   Two reusable composite controls: an Entra group picker (search / create
#          with duplicate check) and the VM size picker (family -> CPU vendor ->
#          generation -> size, from Get-AvdVmSizeCatalog).
#   WHY    Both appear on several pages. Each returns a hashtable that is also the
#          context its handlers receive.
#   GOTCHA The duplicate check matters: Entra allows several groups with one display
#          name, and a re-run of the wizard once created a second AVD-USERS.
function New-GroupPicker {
    param([string]$Purpose = 'AVD users')
    $picker = @{ Purpose = $Purpose }
    $panel = [System.Windows.Controls.StackPanel]::new()
    $null = $panel.Children.Add((New-TextBlock -Text "Entra security group for $Purpose" -Style 'FieldLabel'))
    $row = [System.Windows.Controls.DockPanel]::new()
    $picker.Search = [System.Windows.Controls.TextBox]::new(); $picker.Search.Width = 260; $picker.Search.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $find   = New-Button -Text 'Search' -Context $picker -OnClick { param($pk) Start-GroupSearch -Picker $pk }
    $create = New-Button -Text 'Create group' -Context $picker -OnClick { param($pk) Start-GroupCreate -Picker $pk }
    $null = $row.Children.Add($picker.Search); $null = $row.Children.Add($find); $null = $row.Children.Add($create)
    $null = $panel.Children.Add($row)
    $picker.Combo = New-Combo -Margin '0,8,0,0'
    $null = $panel.Children.Add($picker.Combo)
    $null = $panel.Children.Add((New-TextBlock -Text 'Type the start of a name and Search, or a full name and Create group. Leave empty to skip; users can be assigned later.' -Style 'Caption' -Margin '0,4,0,0'))
    $picker.Panel = $panel
    return $picker
}

function Get-GroupPickerId {
    param([hashtable]$Picker)
    return (Get-ComboValue $Picker.Combo)
}

function Start-GroupSearch {
    param([hashtable]$Picker)
    if (-not (Test-SignedIn)) { return }
    $q = $Picker.Search.Text.Trim()
    if (-not $q) { Show-Message 'Type the start of the group name first.' 'Search' 'Warning'; return }
    Start-Work -Name "Search groups '$q*'" -Argument @{ Query = $q } -Context $Picker -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        Get-AzADGroup -DisplayNameStartsWith $Job.Query | Sort-Object DisplayName | Select-Object -First 25 |
            ForEach-Object { [pscustomobject]@{ Label = "$($_.DisplayName)  ($($_.Id))"; Value = $_.Id } }
    } -OnDone {
        param($result, $failure, $pk)
        if ($failure) { return }
        Add-ComboOption -Combo $pk.Combo -Options @($result) -Default ''
        if (@($result).Count -eq 0) { Write-GuiLog "No group matches '$($pk.Search.Text.Trim())*'." 'warn' }
    }
}

function Start-GroupCreate {
    param([hashtable]$Picker)
    if (-not (Test-SignedIn)) { return }
    $name = $Picker.Search.Text.Trim()
    if (-not $name) { Show-Message 'Type the full display name for the new group first.' 'Create group' 'Warning'; return }
    if (-not (Confirm-Action "Create security group '$name'? If a group with that name already exists it is listed instead." 'Create group')) { return }
    Start-Work -Name "Create group '$name'" -Argument @{ Name = $name } -Context $Picker -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        $dupes = @(Get-AzADGroup -DisplayName $Job.Name -ErrorAction SilentlyContinue)
        if ($dupes.Count -gt 0) {
            Write-Warning "A group named '$($Job.Name)' already exists. Pick it from the list instead of creating a duplicate."
            return $dupes | ForEach-Object { [pscustomobject]@{ Label = "$($_.DisplayName)  ($($_.Id))  created $($_.CreatedDateTime)"; Value = $_.Id } }
        }
        $g = New-AzADGroup -DisplayName $Job.Name -MailNickname ($Job.Name -replace '[^A-Za-z0-9]', '') -SecurityEnabled -Description 'AVD users'
        Write-Verbose "Created $($g.DisplayName) ($($g.Id))"
        [pscustomobject]@{ Label = "$($g.DisplayName)  ($($g.Id))"; Value = $g.Id }
    } -OnDone {
        param($result, $failure, $pk)
        if ($failure) { return }
        Add-ComboOption -Combo $pk.Combo -Options @($result) -Default ''
    }
}

function New-SizePicker {
    param([string]$Default = 'Standard_D4s_v5')
    $picker = @{ Catalog = @(); Default = $Default }
    $picker.FamilyNames = @{ D = 'General purpose'; E = 'Memory optimised'; F = 'Compute optimised'; B = 'Burstable'; NV = 'GPU (NV)'; NC = 'GPU (NC)'; DC = 'Confidential'; L = 'Storage optimised'; M = 'Large memory' }
    $panel = [System.Windows.Controls.StackPanel]::new()
    $null = $panel.Children.Add((New-TextBlock -Text 'VM size' -Style 'FieldLabel'))
    $row = [System.Windows.Controls.StackPanel]::new(); $row.Orientation = 'Horizontal'
    $picker.Family = New-Combo -Width 170
    $picker.Cpu    = New-Combo -Width 100
    $picker.Ver    = New-Combo -Width 80
    $picker.Size   = New-Combo -Width 430 -Margin '0'
    foreach ($c in $picker.Family, $picker.Cpu, $picker.Ver, $picker.Size) { $null = $row.Children.Add($c) }
    $null = $panel.Children.Add($row)
    $picker.Hint = New-TextBlock -Text "Not loaded. $Default is used until you load sizes for the region." -Style 'Caption' -Margin '0,4,0,0'
    $null = $panel.Children.Add($picker.Hint)
    Add-ControlHandler -Control $picker.Family -EventName SelectionChanged -Context $picker -Handler { param($pk) Update-SizePickerCpu -Picker $pk }
    Add-ControlHandler -Control $picker.Cpu    -EventName SelectionChanged -Context $picker -Handler { param($pk) Update-SizePickerVersion -Picker $pk }
    Add-ControlHandler -Control $picker.Ver    -EventName SelectionChanged -Context $picker -Handler { param($pk) Update-SizePickerSize -Picker $pk }
    $picker.Panel = $panel
    return $picker
}

function Get-SizePickerValue {
    param([hashtable]$Picker)
    $v = Get-ComboValue $Picker.Size
    if ($v) { return $v } else { return $Picker.Default }
}

function Update-SizePickerCpu {
    param([hashtable]$Picker)
    $fam = Get-ComboValue $Picker.Family
    if (-not $fam) { return }
    $items = @($Picker.Catalog | Where-Object Family -eq $fam | Select-Object -ExpandProperty Cpu -Unique | Sort-Object | ForEach-Object { @{ Label = $_; Value = $_ } })
    $def = ($Picker.Catalog | Where-Object Name -eq $Picker.Default | Select-Object -First 1)
    Add-ComboOption -Combo $Picker.Cpu -Options $items -Default $(if ($def -and $def.Family -eq $fam) { $def.Cpu } else { '' })
    if ($Picker.Cpu.SelectedIndex -lt 0 -and $Picker.Cpu.Items.Count -gt 0) { $Picker.Cpu.SelectedIndex = 0 }
}

function Update-SizePickerVersion {
    param([hashtable]$Picker)
    $fam = Get-ComboValue $Picker.Family; $cpu = Get-ComboValue $Picker.Cpu
    if (-not $fam -or -not $cpu) { return }
    $items = @($Picker.Catalog | Where-Object { $_.Family -eq $fam -and $_.Cpu -eq $cpu } | Select-Object -ExpandProperty Version -Unique | Sort-Object -Descending | ForEach-Object { @{ Label = "v$_"; Value = "$_" } })
    $def = ($Picker.Catalog | Where-Object Name -eq $Picker.Default | Select-Object -First 1)
    Add-ComboOption -Combo $Picker.Ver -Options $items -Default $(if ($def -and $def.Family -eq $fam -and $def.Cpu -eq $cpu) { "$($def.Version)" } else { '' })
    if ($Picker.Ver.SelectedIndex -lt 0 -and $Picker.Ver.Items.Count -gt 0) { $Picker.Ver.SelectedIndex = 0 }
}

function Update-SizePickerSize {
    param([hashtable]$Picker)
    $fam = Get-ComboValue $Picker.Family; $cpu = Get-ComboValue $Picker.Cpu; $ver = Get-ComboValue $Picker.Ver
    if (-not $fam -or -not $cpu -or -not $ver) { return }
    $items = @($Picker.Catalog | Where-Object { $_.Family -eq $fam -and $_.Cpu -eq $cpu -and "$($_.Version)" -eq $ver } | Sort-Object Cores, Name | ForEach-Object { @{ Label = $_.Label; Value = $_.Name } })
    Add-ComboOption -Combo $Picker.Size -Options $items -Default $Picker.Default
    if ($Picker.Size.SelectedIndex -lt 0 -and $Picker.Size.Items.Count -gt 0) { $Picker.Size.SelectedIndex = 0 }
}

function Start-SizePickerLoad {
    <#
    .SYNOPSIS
        Load the size catalog for a region into the picker. If -Form is given, the
        image SKU combo on that form is refreshed right after (chained by the timer).
    #>
    param([hashtable]$Picker, [string]$Location, [hashtable]$Form)
    if (-not (Test-SignedIn)) { return }
    if (-not $Location) { Show-Message 'Enter the region first.' 'VM sizes' 'Warning'; return }
    Start-Work -Name "Load VM sizes for $Location" -Argument @{ Location = $Location } -Context @{ Picker = $Picker; Location = $Location; Form = $Form } -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        Get-AvdVmSizeCatalog -Location $Job.Location
    } -OnDone {
        param($result, $failure, $c)
        if ($failure) { return }
        $pk = $c.Picker
        $pk.Catalog = @($result)
        $fams = @($pk.Catalog | Select-Object -ExpandProperty Family -Unique | Sort-Object | ForEach-Object {
            $desc = if ($pk.FamilyNames.ContainsKey($_)) { $pk.FamilyNames[$_] } else { '' }
            @{ Label = "$_  $desc".Trim(); Value = $_ } })
        $def = ($pk.Catalog | Where-Object Name -eq $pk.Default | Select-Object -First 1)
        Add-ComboOption -Combo $pk.Family -Options $fams -Default $(if ($def) { $def.Family } else { '' })
        if ($pk.Family.SelectedIndex -lt 0 -and $pk.Family.Items.Count -gt 0) { $pk.Family.SelectedIndex = 0 }
        $pk.Hint.Text = "$($pk.Catalog.Count) sizes in $($c.Location) with vCPU quota (families at 0 quota are hidden). Family, then CPU vendor, then generation, then size."
        if ($c.Form) { $Gui.PendingSkuLoad = @{ Location = $c.Location; Form = $c.Form } }
    }
}

function Update-ImageSkuOption {
    param([string]$Location, [hashtable]$Form, [string]$FieldName = 'ImageSku')
    Start-Work -Name "Load image SKUs for $Location" -Argument @{ Location = $Location } -Context @{ Form = $Form; FieldName = $FieldName } -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        Get-AvdMarketplaceImageSku -Location $Job.Location
    } -OnDone {
        param($result, $failure, $c)
        if ($failure) { return }
        $combo = $c.Form.Controls[$c.FieldName]
        $current = Get-ComboValue $combo
        Add-ComboOption -Combo $combo -Options @($result | ForEach-Object { @{ Value = $_.Value; Label = "$($_.Value)  $($_.Label)" } }) -Default $current
        if ($combo.SelectedIndex -lt 0 -and $combo.Items.Count -gt 0) { $combo.SelectedIndex = 0 }
    }
}
#endregion

#region 6. Sign in and scope --------------------------------------------------
#   WHAT   Sign-in job (same decisions as the console's Initialize-ConsoleSession),
#          subscription switch, host pool list. All inside the worker.
#   WHY    Personal accounts land in a consumer directory with no subscription;
#          the job then looks across tenants and, if a tenant needs its own sign-in,
#          hands the choice back to the window.
$Gui.SignInJob = {
    param([hashtable]$Job)
    $ErrorActionPreference = 'Stop'
    try { $null = Update-AzConfig -EnableLoginByWam $false -Scope Process -WarningAction SilentlyContinue } catch { Write-Verbose "WAM stays on: $($_.Exception.Message)" }

    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    $fits = $ctx -and $ctx.Subscription -and $ctx.Subscription.Id -and
            (-not $Job.TenantId -or $ctx.Tenant.Id -eq $Job.TenantId) -and
            (-not $Job.SubscriptionId -or $ctx.Subscription.Id -eq $Job.SubscriptionId)
    if (-not $fits -or $Job.Force) {
        Write-Verbose 'Opening the browser for sign-in...'
        $connect = @{ ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
        if ($Job.TenantId)       { $connect.TenantId = $Job.TenantId }
        if ($Job.SubscriptionId) { $connect.Subscription = $Job.SubscriptionId }
        try { $null = Connect-AzAccount @connect }
        catch {
            if ($Job.TenantId -or $Job.SubscriptionId) {
                Write-Warning "Sign-in with the remembered tenant failed ($($_.Exception.Message.Split([char]10)[0])). Trying without it."
                $null = Connect-AzAccount -ErrorAction Stop -WarningAction SilentlyContinue
            } else { throw }
        }
        $ctx = Get-AzContext
    } else {
        Write-Verbose "Reusing the existing sign-in for $($ctx.Account.Id)."
    }

    if (-not ($ctx -and $ctx.Subscription -and $ctx.Subscription.Id)) {
        Write-Verbose 'That sign-in has no subscription in its directory. Looking across tenants...'
        $choices = @(Find-AzSubscriptionAcrossTenant)
        if ($choices.Count -eq 0) {
            $tenants = @(Get-AzTenant -ErrorAction SilentlyContinue)
            if ($tenants.Count -eq 0) { throw "Signed in as $($ctx.Account.Id) but this account cannot see any Azure tenant. Is the subscription on a different account?" }
            if ($tenants.Count -gt 1) {
                return [pscustomobject]@{ Kind = 'ChooseTenant'; Account = $ctx.Account.Id
                    Tenants = @($tenants | ForEach-Object { [pscustomobject]@{ Label = "$($_.Name)  ($($_.Id))"; Value = $_.Id } }) }
            }
            Write-Verbose "Signing in to tenant $($tenants[0].Name) directly..."
            $null = Connect-AzAccount -TenantId $tenants[0].Id -ErrorAction Stop -WarningAction SilentlyContinue
            $subs = @(Get-AzSubscription -TenantId $tenants[0].Id -WarningAction SilentlyContinue | Where-Object State -eq 'Enabled')
            if ($subs.Count -eq 0) { throw "Tenant $($tenants[0].Name) has no enabled subscription for $($ctx.Account.Id)." }
            $choices = @($subs | ForEach-Object { [pscustomobject]@{ TenantId = $tenants[0].Id; TenantName = $tenants[0].Name; SubscriptionId = $_.Id; SubscriptionName = $_.Name } })
        }
        $pick = $choices | Where-Object SubscriptionId -eq $Job.SubscriptionId | Select-Object -First 1
        if (-not $pick) { $pick = $choices[0] }
        try { $ctx = Set-AzContext -Tenant $pick.TenantId -Subscription $pick.SubscriptionId -ErrorAction Stop }
        catch {
            $null = Connect-AzAccount -TenantId $pick.TenantId -Subscription $pick.SubscriptionId -ErrorAction Stop -WarningAction SilentlyContinue
            $ctx = Get-AzContext
        }
    }
    $all = @(Find-AzSubscriptionAcrossTenant | Sort-Object TenantName, SubscriptionName)
    if ($all.Count -eq 0) { $all = @([pscustomobject]@{ TenantId = $ctx.Tenant.Id; TenantName = $ctx.Tenant.Id; SubscriptionId = $ctx.Subscription.Id; SubscriptionName = $ctx.Subscription.Name }) }
    [pscustomobject]@{
        Kind = 'SignedIn'; Account = $ctx.Account.Id; TenantId = $ctx.Tenant.Id
        SubscriptionId = $ctx.Subscription.Id; SubscriptionName = $ctx.Subscription.Name; Subscriptions = $all
    }
}

function Show-TenantChooser {
    param([object[]]$Tenants)
    return Show-ChoiceDialog -Title 'Choose a tenant' -Text 'No subscription was reachable without a direct sign-in. Sign in to which tenant?' -Options $Tenants -OkText 'Sign in'
}

function Complete-SignIn {
    param($result)
    $r = @($result)[-1]
    if ($r.Kind -eq 'ChooseTenant') {
        $t = Show-TenantChooser -Tenants $r.Tenants
        if ($t) { Start-SignIn -TenantId $t -Force }
        return
    }
    $Gui.State.Account = $r.Account
    $Gui.State.TenantId = $r.TenantId
    $Gui.State.SubscriptionId = $r.SubscriptionId
    $Gui.State.Subscriptions = @($r.Subscriptions)
    $Gui.Ui.AccountText.Text = $r.Account
    $Gui.Ui.TenantText.Text = "tenant $($r.TenantId)"
    $Gui.Ui.ContextText.Text = $r.SubscriptionName
    $Gui.State.SuppressEvents = $true
    Add-ComboOption -Combo $Gui.Ui.SubscriptionCombo -Options @($Gui.State.Subscriptions | ForEach-Object {
        @{ Label = "$($_.SubscriptionName)  in $($_.TenantName)"; Value = "$($_.TenantId)|$($_.SubscriptionId)" } }) -Default "$($r.TenantId)|$($r.SubscriptionId)"
    $Gui.State.SuppressEvents = $false
    Save-LocalConfig -Account $r.Account -TenantId $r.TenantId -SubscriptionId $r.SubscriptionId -SubscriptionName $r.SubscriptionName
    Write-GuiLog "Signed in as $($r.Account), subscription '$($r.SubscriptionName)' ($($r.SubscriptionId)). Remembered in console.local.json." 'ok'
    Set-PageEnabled $true
    Update-HostPoolList
}

function Start-SignIn {
    param([string]$TenantId, [string]$SubscriptionId, [switch]$Force)
    $arg = @{ Force = [bool]$Force }
    if ($TenantId)       { $arg.TenantId = $TenantId }
    if ($SubscriptionId) { $arg.SubscriptionId = $SubscriptionId }
    Start-Work -Name 'Sign in' -Script $Gui.SignInJob -Argument $arg -OnDone {
        param($result, $failure, $c)
        if (-not $failure) { Complete-SignIn $result }
    }
}

function Update-HostPoolList {
    Start-Work -Name 'List host pools' -Script {
        $ErrorActionPreference = 'Stop'
        Get-AzWvdHostPool | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; ResourceGroupName = ($_.Id -split '/')[4]; Type = "$($_.HostPoolType)"; Location = $_.Location }
        }
    } -OnDone {
        param($result, $failure, $c)
        if ($failure) { return }
        $pools = @($result)
        $current = if ($Gui.State.Pool) { "$($Gui.State.Pool.ResourceGroupName)|$($Gui.State.Pool.Name)|$($Gui.State.Pool.Type)|$($Gui.State.Pool.Location)" } else { '' }
        $Gui.State.SuppressEvents = $true
        Add-ComboOption -Combo $Gui.Ui.PoolCombo -Options @($pools | ForEach-Object {
            @{ Label = "$($_.Name)  ($($_.ResourceGroupName), $($_.Type))"; Value = "$($_.ResourceGroupName)|$($_.Name)|$($_.Type)|$($_.Location)" } }) -Default $current
        $Gui.State.SuppressEvents = $false
        if ($pools.Count -eq 0) { Write-GuiLog 'No host pools in this subscription yet. Build one on the New environment page.' 'warn'; $Gui.State.Pool = $null; Update-PoolLabel }
        else { Set-PoolFromCombo }
        Set-PageEnabled $true
    }
}

function Update-PoolLabel {
    # The current pool, shown in the rail and on the banner of every page that works on it.
    $text = if ($Gui.State.Pool) { "$($Gui.State.Pool.Name)  ($($Gui.State.Pool.ResourceGroupName), $($Gui.State.Pool.Type))" } else { 'none picked' }
    $Gui.Ui.PoolText.Text = $(if ($Gui.State.Pool) { "Pool: $($Gui.State.Pool.Name)" } else { 'No host pool' })
    foreach ($t in $Gui.PoolBanners) { $t.Text = "Host pool: $text" }
}

function Set-PoolFromCombo {
    # PoolCombo is hidden: it only holds the list. The Host pools page picks from it.
    $v = Get-ComboValue $Gui.Ui.PoolCombo
    if (-not $v) { $Gui.State.Pool = $null; Update-PoolLabel; return }
    $parts = $v -split '\|'
    $Gui.State.Pool = @{ ResourceGroupName = $parts[0]; Name = $parts[1]; Type = $parts[2]; Location = $parts[3] }
    $Gui.State.Hosts = @()
    Write-GuiLog "Host pool: $($parts[1]) in $($parts[0])." 'info'
    Update-PoolLabel
    # Pages that show pool data drop what they have; the visible one reloads.
    foreach ($pg in $Gui.Pages.Values) {
        if ($pg.ContainsKey('OnPoolChanged')) { & $pg.OnPoolChanged $pg ($Gui.Ui.PageHost.Content -eq $pg.Root) }
    }
}

function Start-SubscriptionSwitch {
    if ($Gui.State.SuppressEvents) { return }
    $v = Get-ComboValue $Gui.Ui.SubscriptionCombo
    if (-not $v) { return }
    $parts = $v -split '\|'
    if ($parts[1] -eq $Gui.State.SubscriptionId) { return }
    Start-Work -Name 'Switch subscription' -Argument @{ TenantId = $parts[0]; SubscriptionId = $parts[1] } -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        try { $ctx = Set-AzContext -Tenant $Job.TenantId -Subscription $Job.SubscriptionId -ErrorAction Stop }
        catch {
            Write-Verbose "That tenant wants a fresh sign-in ($($_.Exception.Message.Split([char]10)[0]))."
            $null = Connect-AzAccount -TenantId $Job.TenantId -Subscription $Job.SubscriptionId -ErrorAction Stop -WarningAction SilentlyContinue
            $ctx = Get-AzContext
        }
        [pscustomobject]@{ Account = $ctx.Account.Id; TenantId = $ctx.Tenant.Id; SubscriptionId = $ctx.Subscription.Id; SubscriptionName = $ctx.Subscription.Name }
    } -OnDone {
        param($result, $failure, $c)
        if ($failure) { return }
        $r = @($result)[-1]
        $Gui.State.TenantId = $r.TenantId; $Gui.State.SubscriptionId = $r.SubscriptionId; $Gui.State.Pool = $null; $Gui.State.ResourceGroups = @()
        Update-PoolLabel
        $Gui.Ui.TenantText.Text = "tenant $($r.TenantId)"
        $Gui.Ui.ContextText.Text = $r.SubscriptionName
        Save-LocalConfig -Account $r.Account -TenantId $r.TenantId -SubscriptionId $r.SubscriptionId -SubscriptionName $r.SubscriptionName
        Write-GuiLog "Subscription: $($r.SubscriptionName) ($($r.SubscriptionId))." 'ok'
        Update-HostPoolList
    }
}

# Account menu (top right): switching account is a fresh browser sign-in with no remembered tenant.
$Gui.Ui.AccountButton.ContextMenu = New-ActionMenu -Items @(
    @{ Text = 'Switch account'; Handler = { Start-SignIn -Force }; ToolTip = 'Sign in as someone else' }
    @{ Text = 'Sign in again'; Handler = { Start-SignIn -TenantId $Gui.State.TenantId -SubscriptionId $Gui.State.SubscriptionId }; ToolTip = 'Repeat the sign-in with the remembered tenant and subscription' }
    @{ Separator = $true }
    @{ Text = 'Open the Azure portal'; Handler = { Start-Process 'https://portal.azure.com' } }
)
$Gui.Ui.AccountButton.Add_Click({ Invoke-Guarded { Show-ControlMenu $Gui.Ui.AccountButton } })
$Gui.Ui.PoolText.Add_MouseLeftButtonUp({ Invoke-Guarded { Show-Page 'NavHostPools' } })
$Gui.Ui.PoolCombo.Add_SelectionChanged({ Invoke-Guarded { if (-not $Gui.State.SuppressEvents) { Set-PoolFromCombo } } })
$Gui.Ui.SubscriptionCombo.Add_SelectionChanged({ Invoke-Guarded { Start-SubscriptionSwitch } })
$Gui.Ui.ClearLogButton.Add_Click({ $Gui.Ui.LogBox.Clear() })
#endregion

#region 7. Pages --------------------------------------------------------------
#   WHAT   One New-*Page function per nav item builds the panel from field lists
#          and stores its controls in a page hashtable; one Invoke-* function per
#          action turns that page's form into a parameter hashtable for
#          Invoke-RepoScript. Reading a page top to bottom is the same as reading
#          the script's parameter list.
#   WHY    Mirrors the console's menu actions one for one, so a parameter added to
#          a script is one line here and one line there.
function New-PageRoot {
    # -PoolBanner: the page works on the current host pool; a line under the title
    # names it, with a link to the Host pools page to change it.
    param([string]$Title, [string]$Lead, [switch]$PoolBanner)
    $root = [System.Windows.Controls.StackPanel]::new()
    $null = $root.Children.Add((New-TextBlock -Text $Title -Style 'Title'))
    if ($PoolBanner) {
        $bar = [System.Windows.Controls.StackPanel]::new(); $bar.Orientation = 'Horizontal'; $bar.Margin = ConvertTo-Thickness '0,-4,0,8'
        $t = New-TextBlock -Text '' -Margin '0'; $t.FontWeight = [System.Windows.FontWeights]::SemiBold; $t.VerticalAlignment = 'Center'
        $null = $bar.Children.Add($t)
        $link = New-Button -Text 'Change host pool' -Style 'LinkButton' -Context 'NavHostPools' -OnClick { param($k) Show-Page $k }
        $link.Margin = ConvertTo-Thickness '12,0,0,0'
        $null = $bar.Children.Add($link)
        $null = $root.Children.Add($bar)
        $Gui.PoolBanners.Add($t)
        Update-PoolLabel
    }
    if ($Lead) { $null = $root.Children.Add((New-TextBlock -Text $Lead -Style 'Muted' -Margin '0,0,0,20')) }
    return $root
}

function Split-CommaList {
    # Commas, semicolons or new lines: what people paste from a spreadsheet or an email.
    param([string]$Text)
    return @($Text -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# --- Overview ---------------------------------------------------------------
function New-StatTile {
    # A card with one big number and a caption. Value is updated later through the returned TextBlock.
    param([string]$Label)
    $card = [System.Windows.Controls.Border]::new()
    $card.Style = Get-ThemeResource 'Card'
    $card.Width = 150; $card.Margin = [System.Windows.Thickness]::new(0, 0, 12, 12)
    $stack = [System.Windows.Controls.StackPanel]::new()
    $value = New-TextBlock -Text '-'
    $value.FontFamily = Get-ThemeResource 'Font.Display'; $value.FontSize = Get-ThemeResource 'Font.SizeHeading'; $value.FontWeight = [System.Windows.FontWeights]::Bold
    $null = $stack.Children.Add($value)
    $null = $stack.Children.Add((New-TextBlock -Text $Label -Style 'Caption'))
    $card.Child = $stack
    return @{ Card = $card; Value = $value }
}

function New-FactList {
    # Two-column key/value block. Values are TextBlocks kept by key for later updates.
    param([string[]]$Keys)
    $grid = [System.Windows.Controls.Grid]::new()
    foreach ($w in 'Auto', '*') {
        $col = [System.Windows.Controls.ColumnDefinition]::new()
        $col.Width = if ($w -eq 'Auto') { [System.Windows.GridLength]::Auto } else { [System.Windows.GridLength]::new(1, 'Star') }
        $null = $grid.ColumnDefinitions.Add($col)
    }
    $values = @{}
    $r = 0
    foreach ($k in $Keys) {
        $null = $grid.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new())
        $kt = New-TextBlock -Text $k -Style 'Muted' -Margin '0,2,16,2'
        $vt = New-TextBlock -Text '-' -Margin '0,2,0,2'; $vt.TextWrapping = 'Wrap'
        [System.Windows.Controls.Grid]::SetRow($kt, $r); [System.Windows.Controls.Grid]::SetColumn($kt, 0)
        [System.Windows.Controls.Grid]::SetRow($vt, $r); [System.Windows.Controls.Grid]::SetColumn($vt, 1)
        $null = $grid.Children.Add($kt); $null = $grid.Children.Add($vt)
        $values[$k] = $vt
        $r++
    }
    return @{ Panel = $grid; Values = $values }
}

function New-OverviewPage {
    $page = @{ Key = 'NavOverview'; Tiles = @{} }
    $root = New-PageRoot -PoolBanner -Title 'Home' -Lead 'The current host pool at a glance. Numbers refresh when you open this page, change pool, or press Refresh.'
    $null = $root.Children.Add((New-ButtonRow -Buttons @((New-Button -Text 'Refresh' -Context $page -OnClick { param($pg) Invoke-OverviewRefresh -Page $pg }))))
    $tiles = [System.Windows.Controls.WrapPanel]::new(); $tiles.Margin = [System.Windows.Thickness]::new(0, 16, 0, 4)
    foreach ($t in @(@('Available', 'hosts available'), @('Total', 'hosts total'), @('Sessions', 'user sessions'), @('Running', 'VMs running'), @('Deallocated', 'VMs deallocated'), @('Drained', 'hosts drained'), @('Unavailable', 'hosts unavailable'))) {
        $tile = New-StatTile -Label $t[1]
        $page.Tiles[$t[0]] = $tile.Value
        $null = $tiles.Children.Add($tile.Card)
    }
    $null = $root.Children.Add($tiles)

    $poolCard = New-Card -Title 'Host pool'
    $page.Facts = New-FactList -Keys @('Name', 'Resource group', 'Region', 'Type', 'Load balancing', 'Max sessions per host', 'Start VM On Connect', 'Validation environment', 'Agent updates', 'Agent versions on hosts', 'Scaling plan')
    $null = $poolCard.Child.Children.Add($page.Facts.Panel)
    $null = $poolCard.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Autoscale settings' -Style 'GhostButton' -OnClick { Show-Page 'NavAutoscale' }),
        (New-Button -Text 'Session hosts' -Style 'GhostButton' -OnClick { Show-Page 'NavHosts' }))))
    $null = $root.Children.Add($poolCard)

    $costCard = New-Card -Title 'Estimated compute cost' -Subtitle 'Pay-as-you-go retail prices for the VM sizes in this pool. Windows_Client licensing is covered by Microsoft 365, so the compute-only rate applies. Disks, storage and egress are extra.'
    $page.Cost = New-FactList -Keys @('Every host running 24x7', '10 hours on weekdays (what autoscale targets)', 'What is running right now, kept on all month', 'Hosts priced')
    $null = $costCard.Child.Children.Add($page.Cost.Panel)
    $null = $root.Children.Add($costCard)

    $page.Grid = New-DataGrid -Height 260
    $null = $root.Children.Add((New-TableCard -Title 'Session hosts' -Grid $page.Grid -Tools @(
        (New-ToolButton -Text 'Manage hosts' -OnClick { Show-Page 'NavHosts' }))))
    $page.OnShow = { param($pg) if ($Gui.State.Pool -and -not $Gui.State.Busy) { Invoke-OverviewRefresh -Page $pg } }
    $page.OnPoolChanged = { param($pg, $visible) $pg.Grid.ItemsSource = $null; if ($visible -and -not $Gui.State.Busy) { Invoke-OverviewRefresh -Page $pg } }
    $page.Root = $root
    return $page
}

function Invoke-OverviewRefresh {
    param([hashtable]$Page)
    if (-not (Test-PoolSelected)) { return }
    $pool = $Gui.State.Pool
    Start-Work -Name "Overview of $($pool.Name)" -Context $Page -Argument @{ Rg = $pool.ResourceGroupName; Pool = $pool.Name } -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        Get-AvdHostPoolOverview -ResourceGroupName $Job.Rg -HostPoolName $Job.Pool -IncludePrice
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $o = @($result)[-1]
        foreach ($k in $pg.Tiles.Keys) { $pg.Tiles[$k].Text = "$($o.Counts.$k)" }
        $f = $pg.Facts.Values
        $f['Name'].Text = $o.Pool.Name; $f['Resource group'].Text = $o.Pool.ResourceGroupName; $f['Region'].Text = $o.Pool.Location
        $f['Type'].Text = $o.Pool.Type; $f['Load balancing'].Text = $o.Pool.LoadBalancer; $f['Max sessions per host'].Text = "$($o.Pool.MaxSessionLimit)"
        $f['Start VM On Connect'].Text = $(if ($o.Pool.StartVMOnConnect) { 'On' } else { 'Off' })
        $f['Validation environment'].Text = $(if ($o.Pool.ValidationEnvironment) { 'Yes (gets service updates first)' } else { 'No' })
        $f['Agent updates'].Text = $o.Pool.AgentUpdate
        $f['Agent versions on hosts'].Text = $(if ($o.Counts.AgentVersions) { $o.Counts.AgentVersions } else { '-' })
        $f['Scaling plan'].Text = $(if (@($o.ScalingPlans).Count -eq 0) { 'None. Hosts run until someone stops them. Set one up under Autoscale.' } else { @($o.ScalingPlans | ForEach-Object { "$($_.Name): $(if ($_.Enabled) { 'enabled' } else { 'attached, disabled' }), $($_.TimeZone). $($_.Schedules)" }) -join [Environment]::NewLine })
        $c = $pg.Cost.Values
        if ($o.Cost) {
            $c['Every host running 24x7'].Text = ('${0:n0} / month' -f $o.Cost.Monthly24x7Usd)
            $c['10 hours on weekdays (what autoscale targets)'].Text = ('${0:n0} / month' -f $o.Cost.MonthlyBusinessHoursUsd)
            $c['What is running right now, kept on all month'].Text = ('${0:n0} / month  (${1:n3} / hour)' -f $o.Cost.MonthlyCurrentUsd, $o.Cost.HourlyRunningUsd)
            $c['Hosts priced'].Text = "$($o.Cost.PricedHosts) of $($o.Counts.Total)$(if (@($o.Cost.UnpricedHosts).Count -gt 0) { " (no price for: $(@($o.Cost.UnpricedHosts) -join ', '))" })"
        } else {
            foreach ($k in $c.Keys) { $c[$k].Text = 'price list unavailable' }
        }
        $Gui.State.Hosts = @($o.Hosts)
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows @($o.Hosts) -Columns @('Name', 'Status', 'PowerState', 'Drain', 'Sessions', 'VMSize', 'AgentVersion', 'LastHeartBeat')).DefaultView
    }
}

# --- Autoscale --------------------------------------------------------------
function New-AutoscalePage {
    $page = @{ Key = 'NavAutoscale'; Form = New-Form; Selected = $null; Plans = @() }
    $root = New-PageRoot -PoolBanner -Title 'Autoscale' -Lead 'A native AVD scaling plan starts hosts before people arrive and deallocates them after. The service needs one role to touch VMs; the plan is one resource; attaching it to the pool is a switch. Pooled host pools only.'
    $page.RoleText = New-TextBlock -Text 'Role: not checked yet.' -Style 'Muted' -Margin '0,0,0,8'
    $null = $root.Children.Add($page.RoleText)
    $page.Grid = New-DataGrid -Height 180
    $page.Grid.SelectionMode = 'Single'
    Add-ControlHandler -Control $page.Grid -EventName SelectionChanged -Context $page -Handler { param($pg) Update-AutoscaleFormFromSelection -Page $pg }
    $actions = @(
        @{ Text = 'Enable on this pool';  Context = @{ Page = $page; Enabled = $true };  Handler = { param($c) Invoke-AutoscaleToggle -Page $c.Page -Enabled $c.Enabled } }
        @{ Text = 'Disable on this pool'; Context = @{ Page = $page; Enabled = $false }; Handler = { param($c) Invoke-AutoscaleToggle -Page $c.Page -Enabled $c.Enabled } }
    )
    Set-GridRowMenu -Grid $page.Grid -Items $actions
    $null = $root.Children.Add((New-TableCard -Title 'Scaling plans' -Grid $page.Grid -Tools @(
        (New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Invoke-AutoscaleRefresh -Page $pg }),
        (New-MenuButton -Items $actions)) -Note 'Select a plan to load its schedule into the form below.'))
    $page.Editing = New-TextBlock -Text 'No plan selected: the form below creates a new one.' -Style 'Muted' -Margin '0,0,0,8'
    $null = $root.Children.Add($page.Editing)

    $card = New-FormSection -Form $page.Form -Title 'Schedule' -Subtitle 'Select a plan above to load its weekday schedule here and Save changes; or fill the form and Create a new plan. Times are local to the time zone below; percentages are of the pool''s host count.' -Fields @(
        @{ Name = 'Name'; Label = 'Plan name'; Help = 'Default sp-<host pool>. Cannot be changed on an existing plan.' }
        @{ Name = 'TimeZone'; Label = 'Time zone (Windows ID)'; Default = (Get-TimeZone).Id; Required = $true }
        @{ Name = 'RampUpStart'; Label = 'Ramp-up starts (hosts power on ahead of users)'; Default = '07:00' }
        @{ Name = 'PeakStart'; Label = 'Peak starts (full capacity)'; Default = '09:00' }
        @{ Name = 'RampDownStart'; Label = 'Ramp-down starts (consolidate, warn stragglers)'; Default = '18:00' }
        @{ Name = 'OffPeakStart'; Label = 'Off-peak starts (minimum hosts)'; Default = '20:00' }
        @{ Name = 'RampUpMinimumHostsPct'; Label = 'Minimum hosts on during ramp-up (%)'; Type = 'int'; Default = 20 }
        @{ Name = 'RampUpCapacityThresholdPct'; Label = 'Start another host at this % of capacity'; Type = 'int'; Default = 60 }
        @{ Name = 'RampDownMinimumHostsPct'; Label = 'Minimum hosts on during ramp-down and off-peak (%)'; Type = 'int'; Default = 10 }
        @{ Name = 'RampDownWaitTimeMinutes'; Label = 'Warning minutes before a host is stopped'; Type = 'int'; Default = 30 }
        @{ Name = 'RampDownMessage'; Label = 'Warning shown to users'; Default = 'This desktop will shut down for the night in 30 minutes. Please save your work and sign out.'; Span = 2 }
        @{ Name = 'RampDownCapacityThresholdPct'; Label = 'Ramp-down: start another host at this % of capacity'; Type = 'int'; Default = 90 }
        @{ Name = 'RampDownStopHostsWhen'; Label = 'Stop a host when it has'; Type = 'combo'; Default = 'ZeroSessions'; Options = @(
            @{ Value = 'ZeroSessions';       Label = 'ZeroSessions  no sessions at all (disconnected ones keep it on)' }
            @{ Value = 'ZeroActiveSessions'; Label = 'ZeroActiveSessions  no active sessions (disconnected ones are signed out)' }) }
        @{ Name = 'RampDownForceLogoff'; Label = 'Sign out users who ignore the warning'; Type = 'check'; Default = $false }
        @{ Name = 'WeekendOffPeak'; Label = 'Weekends off-peak all day (minimum hosts 0)'; Type = 'check'; Default = $true }
        @{ Name = 'ExclusionTag'; Label = 'Exclusion tag (VMs with this tag name are left alone)'; Span = 2 }
        @{ Name = 'RoleScope'; Label = 'Grant the service role at (new plans)'; Type = 'combo'; Default = 'Subscription'; Options = @(
            @{ Value = 'Subscription'; Label = 'Subscription (Microsoft recommendation)' }
            @{ Value = 'ResourceGroup'; Label = 'This resource group only' }) }
        @{ Name = 'Enable'; Label = 'Attach enabled (new plans)'; Type = 'check'; Default = $true }
    )
    $save = New-Button -Text 'Save changes to selected plan' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-AutoscaleSave -Page $c.Page -DryRun:$c.DryRun }
    $go   = New-Button -Text 'Create as new plan' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-AutoscaleCreate -Page $c.Page -DryRun:$c.DryRun }
    $dry  = New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) if ($c.Page.Selected) { Invoke-AutoscaleSave -Page $c.Page -DryRun } else { Invoke-AutoscaleCreate -Page $c.Page -DryRun } }
    $page.SaveButton = $save
    $save.IsEnabled = $false
    $null = $card.Child.Children.Add((New-ButtonRow -Buttons @($save, $go, $dry)))
    $null = $root.Children.Add($card)
    $page.OnShow = { param($pg) if ($Gui.State.Pool -and -not $Gui.State.Busy) { Invoke-AutoscaleRefresh -Page $pg } }
    $page.OnPoolChanged = { param($pg, $visible) $pg.Grid.ItemsSource = $null; if ($visible -and -not $Gui.State.Busy) { Invoke-AutoscaleRefresh -Page $pg } }
    $page.Root = $root
    return $page
}

function Invoke-AutoscaleRefresh {
    param([hashtable]$Page)
    if (-not (Test-PoolSelected)) { return }
    $pool = $Gui.State.Pool
    if (-not (Get-FormValue $Page.Form 'Name')) { $Page.Form.Controls['Name'].Text = "sp-$($pool.Name)" }
    Start-Work -Name "Scaling plans for $($pool.Name)" -Context $Page -Argument @{ Rg = $pool.ResourceGroupName; Pool = $pool.Name; Sub = $Gui.State.SubscriptionId } -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        $role = try { Test-AvdAutoscaleRole -SubscriptionId $Job.Sub -ResourceGroupName $Job.Rg } catch { Write-Warning "Role check failed: $($_.Exception.Message)"; $null }
        [pscustomobject]@{ Role = $role; Plans = @(Get-AvdScalingPlan -ResourceGroupName $Job.Rg -HostPoolName $Job.Pool) }
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $r = @($result)[-1]
        $pg.RoleText.Text = switch ($r.Role) {
            $true  { 'Role: the Azure Virtual Desktop service can power VMs on and off here.' }
            $false { 'Role: NOT granted. Creating a plan grants it (needs Owner or User Access Administrator).' }
            default { 'Role: could not be checked.' }
        }
        $pg.Plans = @($r.Plans)
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows @($r.Plans) -Columns @('Name', 'EnabledForPool', 'AttachedToPool', 'TimeZone', 'Schedules', 'PoolCount')).DefaultView
        if (@($r.Plans).Count -eq 0) { Write-GuiLog 'No scaling plans in this resource group.' 'info' }
        Update-AutoscaleFormFromSelection -Page $pg
    }
}

function Update-AutoscaleFormFromSelection {
    # Selected plan -> form (its weekday schedule); nothing selected -> form stays as is and Save is disabled.
    param([hashtable]$Page)
    $sel = Get-GridSelection $Page.Grid
    $plan = if ($sel.Count -eq 1) { $Page.Plans | Where-Object { $_.Name -eq $sel[0].Name } | Select-Object -First 1 } else { $null }
    $Page.Selected = $plan
    $Page.SaveButton.IsEnabled = ($null -ne $plan)
    $Page.Form.Controls['Name'].IsReadOnly = ($null -ne $plan)
    if (-not $plan) { $Page.Editing.Text = 'No plan selected: the form below creates a new one.'; return }
    $Page.Editing.Text = "Editing '$($plan.Name)'. Save writes the form to its weekday schedule; Create as new plan copies it under a new name."
    $f = $Page.Form
    Set-FormValue $f 'Name' $plan.Name
    Set-FormValue $f 'TimeZone' $plan.TimeZone
    Set-FormValue $f 'ExclusionTag' "$($plan.ExclusionTag)"
    Set-FormValue $f 'WeekendOffPeak' $plan.HasWeekend
    Set-FormValue $f 'Enable' $plan.EnabledForPool
    $w = $plan.Weekday
    if ($w) {
        foreach ($k in 'RampUpStart', 'PeakStart', 'RampDownStart', 'OffPeakStart', 'RampUpMinimumHostsPct', 'RampUpCapacityThresholdPct', 'RampDownMinimumHostsPct', 'RampDownCapacityThresholdPct', 'RampDownWaitTimeMinutes', 'RampDownMessage', 'RampDownForceLogoff', 'RampDownStopHostsWhen') {
            Set-FormValue $f $k $w.$k
        }
    }
}

function Invoke-AutoscaleSave {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-PoolSelected)) { return }
    $plan = $Page.Selected
    if (-not $plan) { Show-Message 'Select a plan in the list first.' 'Autoscale' 'Warning'; return }
    $pool = $Gui.State.Pool
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = $pool.ResourceGroupName; Name = $plan.Name }
    Add-FormParameter -Params $p -Form $Page.Form -Names @('TimeZone', 'RampUpStart', 'PeakStart', 'RampDownStart', 'OffPeakStart', 'RampUpMinimumHostsPct', 'RampUpCapacityThresholdPct',
        'RampDownMinimumHostsPct', 'RampDownCapacityThresholdPct', 'RampDownWaitTimeMinutes', 'RampDownMessage', 'RampDownStopHostsWhen')
    # Booleans must be sent even when false, and the tag even when cleared: these are edits, not switches.
    $p.RampDownForceLogoff = Get-FormValue $Page.Form 'RampDownForceLogoff'
    $p.WeekendOffPeak = Get-FormValue $Page.Form 'WeekendOffPeak'
    $p.ExclusionTag = Get-FormValue $Page.Form 'ExclusionTag'
    Invoke-RepoScript -Name "Save scaling plan $($plan.Name)" -Path $Gui.Scripts.ScalingPlanEdit -Params $p -DryRun:$DryRun -Context $Page -OnDone { param($result, $failure, $pg) Invoke-AutoscaleRefresh -Page $pg }
}

function Invoke-AutoscaleCreate {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-PoolSelected)) { return }
    if (-not (Test-FormRequired $Page.Form)) { return }
    $pool = $Gui.State.Pool
    if ($pool.Type -ne 'Pooled') { Show-Message "Host pool $($pool.Name) is $($pool.Type). This page builds Pooled schedules." 'Autoscale' 'Warning'; return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = $pool.ResourceGroupName; HostPoolName = $pool.Name }
    Add-FormParameter -Params $p -Form $Page.Form -Names @('Name', 'TimeZone', 'RampUpStart', 'PeakStart', 'RampDownStart', 'OffPeakStart', 'RampUpMinimumHostsPct', 'RampUpCapacityThresholdPct',
        'RampDownMinimumHostsPct', 'RampDownCapacityThresholdPct', 'RampDownWaitTimeMinutes', 'RampDownMessage', 'RampDownForceLogoff', 'WeekendOffPeak', 'ExclusionTag', 'RoleScope')
    $p.Enable = Get-FormValue $Page.Form 'Enable'
    if ($Page.Selected -and $p.Name -eq $Page.Selected.Name) { Show-Message "A plan named '$($p.Name)' is selected. Change the name to create a copy, or use Save to change it." 'Autoscale' 'Warning'; return }
    Invoke-RepoScript -Name "Scaling plan for $($pool.Name)" -Path $Gui.Scripts.ScalingPlan -Params $p -DryRun:$DryRun -Context $Page -OnDone { param($result, $failure, $pg) Invoke-AutoscaleRefresh -Page $pg }
}

function Invoke-AutoscaleToggle {
    param([hashtable]$Page, [bool]$Enabled)
    if (-not (Test-PoolSelected)) { return }
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -ne 1) { Show-Message 'Select exactly one plan.' 'Autoscale' 'Warning'; return }
    $pool = $Gui.State.Pool
    $verb = if ($Enabled) { 'Enable' } else { 'Disable' }
    if (-not (Confirm-Action "$verb scaling plan '$($sel[0].Name)' for host pool $($pool.Name)?" $verb)) { return }
    Start-Work -Name "$verb $($sel[0].Name)" -Context $Page -Argument @{ Rg = $pool.ResourceGroupName; Pool = $pool.Name; Plan = $sel[0].Name; Enabled = $Enabled } -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        $poolId = (Get-AzWvdHostPool -ResourceGroupName $Job.Rg -Name $Job.Pool).Id
        $null = Set-AvdScalingPlanEnabled -ResourceGroupName $Job.Rg -Name $Job.Plan -HostPoolId $poolId -Enabled $Job.Enabled -Verbose
    } -OnDone { param($result, $failure, $pg) Invoke-AutoscaleRefresh -Page $pg }
}

# --- Build ----------------------------------------------------------------
function New-BuildPage {
    $page = @{ Key = 'NavBuild'; Form = New-Form }
    $form = $page.Form
    $root = New-PageRoot -Title 'New environment' -Lead 'Every field has a recommended default. Nothing is created until you confirm the plan. If a step fails, everything built so far stays; fix the cause and build again, it continues from the first missing piece. Entra ID joined only; Active Directory comes later.'
    $env = 'lab'
    $null = $root.Children.Add((New-FormSection -Form $form -Title 'Scope' -Fields @(
        @{ Name = 'Environment';       Label = 'Environment label'; Default = $env; Required = $true; Help = '2-10 lowercase letters/digits, used in every name.' }
        @{ Name = 'Location';          Label = 'Azure region';      Default = 'westus3'; Required = $true; Help = 'Must be an AVD metadata region.' }
        @{ Name = 'ResourceGroupName'; Label = 'Resource group';    Default = "rg-avd-$env"; Required = $true; Help = 'One group for the whole environment. Created if missing.' }
        @{ Name = 'SkipPermissionCheck'; Label = 'Skip the permission preflight'; Type = 'check'; Default = $false }
    )))
    $null = $root.Children.Add((New-FormSection -Form $form -Title 'Network' -Fields @(
        @{ Name = 'AddressPrefix'; Label = 'VNet address space'; Default = '10.10.0.0/16' }
        @{ Name = 'SubnetPrefix';  Label = 'Session host subnet'; Default = '10.10.1.0/24' }
    )))
    $null = $root.Children.Add((New-FormSection -Form $form -Title 'Profile storage' -Subtitle 'Azure Files with Entra Kerberos. Admin consent is granted through Graph when your account may; otherwise the log says where to click.' -Fields @(
        @{ Name = 'DeployProfileStorage'; Label = 'Deploy FSLogix profile storage'; Type = 'check'; Default = $true; Span = 2 }
        @{ Name = 'StorageAccountName'; Label = 'Storage account name'; Default = "stavd${env}prof01"; Help = 'Globally unique, 3-24 lowercase letters/digits.' }
        @{ Name = 'StorageSkuName'; Label = 'Storage SKU'; Type = 'combo'; Default = 'Standard_LRS'; Options = @(
            @{ Value = 'Standard_LRS'; Label = 'Standard_LRS  cheap, fine for a lab' }
            @{ Value = 'Premium_LRS';  Label = 'Premium_LRS  fast, use for real profiles' }
            @{ Value = 'Premium_ZRS';  Label = 'Premium_ZRS  premium, zone redundant' }) }
        @{ Name = 'ProfileShareName'; Label = 'Share name'; Default = 'profiles' }
        @{ Name = 'NtfsVia'; Label = 'FSLogix NTFS permissions'; Type = 'combo'; Default = 'SessionHost'; Options = @(
            @{ Value = 'SessionHost'; Label = 'From the first session host (works behind any ISP)' }
            @{ Value = 'Local';       Label = 'From this machine (needs outbound TCP 445)' }
            @{ Value = 'Skip';        Label = 'Not now (Profile storage page later)' }) }
    )))
    $null = $root.Children.Add((New-FormSection -Form $form -Title 'Image gallery' -Fields @(
        @{ Name = 'DeployGallery'; Label = 'Also create a Compute Gallery for custom images later'; Type = 'check'; Default = $false; Span = 2 }
        @{ Name = 'GalleryName'; Label = 'Gallery name'; Default = "gal_avd_$env"; Help = 'No hyphens.' }
        @{ Name = 'ImageDefinitionName'; Label = 'Image definition name'; Default = 'win11-avd-m365' }
    )))
    $groupCard = New-Card -Title 'Users' -Subtitle 'The group gets the desktop and Virtual Machine User Login on every host.'
    $page.Group = New-GroupPicker -Purpose 'AVD users'
    $null = $groupCard.Child.Children.Add($page.Group.Panel)
    $null = $root.Children.Add($groupCard)
    $null = $root.Children.Add((New-FormSection -Form $form -Title 'Host pool' -Fields @(
        @{ Name = 'HostPoolName';  Label = 'Host pool name'; Default = "hp-$env" }
        @{ Name = 'WorkspaceName'; Label = 'Workspace name'; Default = "ws-$env" }
        @{ Name = 'HostPoolType'; Label = 'Pool type'; Type = 'combo'; Default = 'Pooled'; Options = @(
            @{ Value = 'Pooled';   Label = 'Pooled  shared hosts, FSLogix profiles' }
            @{ Value = 'Personal'; Label = 'Personal  one VM per user' }) }
        @{ Name = 'LoadBalancerType'; Label = 'Load balancing (pooled)'; Type = 'combo'; Default = 'BreadthFirst'; Options = @(
            @{ Value = 'BreadthFirst'; Label = 'BreadthFirst  spread users, best performance' }
            @{ Value = 'DepthFirst';   Label = 'DepthFirst  fill one host first, best for autoscale cost' }) }
        @{ Name = 'MaxSessionLimit'; Label = 'Max sessions per host'; Type = 'int'; Default = 10 }
        @{ Name = 'StartVMOnConnect'; Label = 'Enable Start VM On Connect'; Type = 'check'; Default = $false }
    )))
    $hostCard = New-FormSection -Form $form -Title 'Session hosts' -Fields @(
        @{ Name = 'SessionHostCount';  Label = 'How many to build now'; Type = 'int'; Default = 1; Help = '0 builds the pool with no hosts.' }
        @{ Name = 'SessionHostPrefix'; Label = 'Host name prefix'; Default = "avd-$env-"; Help = 'Hosts become <prefix>01, 02... Prefix + 2 digits must be 15 characters or fewer.' }
        @{ Name = 'ImageSku'; Label = 'Marketplace image'; Type = 'combo'; Editable = $true; Default = 'win11-25h2-avd-m365'; Options = @('win11-25h2-avd-m365'); Help = 'Load region options lists every Windows multi-session + Microsoft 365 Apps SKU.' }
        @{ Name = 'SecurityType'; Label = 'Security type'; Type = 'combo'; Default = 'TrustedLaunch'; Options = @(
            @{ Value = 'TrustedLaunch'; Label = 'TrustedLaunch  Secure Boot + vTPM (default)' }
            @{ Value = 'Standard';      Label = 'Standard  only if the image cannot do Trusted Launch' }) }
        @{ Name = 'AdminUser';            Label = 'Local administrator user name'; Default = 'avdadmin'; Help = 'Not administrator/admin/root etc. Azure reserves those.' }
        @{ Name = 'AdminPassword';        Label = 'Password'; Type = 'password'; Help = '12-123 characters, 3 of: lower, upper, digit, symbol.' }
        @{ Name = 'AdminPasswordConfirm'; Label = 'Password again'; Type = 'password' }
    )
    $page.Sizes = New-SizePicker
    $page.Sizes.Panel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $loadBtn = New-Button -Text 'Load region options' -ToolTip 'VM sizes and image SKUs offered in the region above' -Context $page -OnClick {
        param($pg) Start-SizePickerLoad -Picker $pg.Sizes -Location (Get-FormValue $pg.Form 'Location') -Form $pg.Form
    }
    $null = $hostCard.Child.Children.Insert(1, $page.Sizes.Panel)
    $null = $hostCard.Child.Children.Insert(1, (New-ButtonRow -Buttons @($loadBtn)))
    $null = $root.Children.Add($hostCard)
    $null = $root.Children.Add((New-FormSection -Form $form -Title 'Backup' -Fields @(
        @{ Name = 'EnableBackup'; Label = 'Create a Recovery Services vault and protect the profile share'; Type = 'check'; Default = $false; Span = 2 }
        @{ Name = 'VaultName'; Label = 'Vault name'; Default = "rsv-avd-$env" }
    )))
    # The environment label drives the default names. When it changes, update the
    # names that still carry the old default and leave the ones the person edited.
    Add-ControlHandler -Control $form.Controls['Environment'] -EventName LostFocus -Context $page -Handler { param($pg) Update-BuildDefault -Page $pg }

    $go  = New-Button -Text 'Build environment' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-BuildRun -Page $c.Page -DryRun:$c.DryRun }
    $dry = New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-BuildRun -Page $c.Page -DryRun:$c.DryRun }
    $null = $root.Children.Add((New-ButtonRow -Buttons @($go, $dry)))
    $page.Root = $root
    return $page
}

function Update-BuildDefault {
    param([hashtable]$Page)
    $form = $Page.Form
    $e = Get-FormValue $form 'Environment'
    if (-not $e -or $e -eq $Gui.State.LastEnv) { return }
    $old = $Gui.State.LastEnv
    $map = @{ ResourceGroupName = "rg-avd-{0}"; StorageAccountName = "stavd{0}prof01"; GalleryName = "gal_avd_{0}"; HostPoolName = "hp-{0}"; WorkspaceName = "ws-{0}"; SessionHostPrefix = "avd-{0}-"; VaultName = "rsv-avd-{0}" }
    foreach ($k in $map.Keys) {
        if ($form.Controls[$k].Text -eq ($map[$k] -f $old)) { $form.Controls[$k].Text = ($map[$k] -f $e) }
    }
    $Gui.State.LastEnv = $e
}

function Invoke-BuildRun {
    param([hashtable]$Page, [switch]$DryRun)
    $form = $Page.Form
    if (-not (Test-SignedIn)) { return }
    if (-not (Test-FormRequired $form)) { return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; IdentityType = 'EntraId' }
    Add-FormParameter -Params $p -Form $form -Names @('Environment', 'Location', 'ResourceGroupName', 'SkipPermissionCheck', 'AddressPrefix', 'SubnetPrefix',
        'HostPoolName', 'WorkspaceName', 'HostPoolType', 'LoadBalancerType', 'MaxSessionLimit', 'StartVMOnConnect', 'SessionHostCount', 'SessionHostPrefix', 'ImageSku', 'SecurityType', 'EnableBackup')
    $p.DeployProfileStorage = Get-FormValue $form 'DeployProfileStorage'
    if ($p.DeployProfileStorage) {
        Add-FormParameter -Params $p -Form $form -Names @('StorageAccountName', 'StorageSkuName', 'ProfileShareName')
        $ntfs = Get-FormValue $form 'NtfsVia'
        if ($ntfs -ne 'Skip') { $p.SetNtfsPermissions = $true; $p.NtfsVia = $ntfs }
    }
    $p.DeployGallery = Get-FormValue $form 'DeployGallery'
    if ($p.DeployGallery) { Add-FormParameter -Params $p -Form $form -Names @('GalleryName', 'ImageDefinitionName') }
    if ($p.ContainsKey('EnableBackup')) { Add-FormParameter -Params $p -Form $form -Names @('VaultName') }
    $gid = Get-GroupPickerId $Page.Group
    if ($gid) { $p.UserGroupObjectId = $gid }
    $count = Get-FormValue $form 'SessionHostCount'
    if ($null -ne $count -and $count -gt 0) {
        $cred = Get-FormCredential $form
        if (-not $cred) { return }
        $p.LocalAdminCredential = $cred
        $p.VMSize = Get-SizePickerValue $Page.Sizes
    }
    if (-not $gid -and -not (Confirm-Action 'No user group chosen. The desktop will have no users until you assign some. Continue?' 'No user group')) { return }
    Invoke-RepoScript -Name 'Build environment' -Path $Gui.Scripts.Environment -Params $p -DryRun:$DryRun -OnDone {
        param($result, $failure, $c)
        $Gui.State.ResourceGroups = @()   # the build may have created one; the Servers pages re-list on their next visit
        if (-not $failure) { Update-HostPoolList }
    }
}

# --- Add a host -----------------------------------------------------------
function New-AddHostPage {
    $page = @{ Key = 'NavAddHost'; Form = New-Form }
    $form = $page.Form
    $root = New-PageRoot -PoolBanner -Title 'Add a session host' -Lead 'Builds one Entra ID joined VM into the current host pool, registers it, and waits for it to turn Available.'
    $card = New-FormSection -Form $form -Title 'Virtual machine' -Fields @(
        @{ Name = 'ResourceGroupName'; Label = 'VM resource group'; Required = $true; Help = 'Defaults to the host pool resource group when you load options.' }
        @{ Name = 'VMName'; Label = 'VM name'; Required = $true; Help = '15 characters or fewer. A stale Entra device record with this name is removed before the join.' }
        @{ Name = 'SubnetId'; Label = 'Subnet'; Type = 'combo'; Required = $true; Help = 'Load options lists every subnet in the subscription, same region first.' }
        @{ Name = 'FsLogixProfileShare'; Label = 'FSLogix profile share (UNC)'; Type = 'combo'; Editable = $true; Help = 'Leave empty for no FSLogix. Load options lists shares in the resource group.' }
        @{ Name = 'ImageChoice'; Label = 'Image'; Type = 'combo'; Default = 'marketplace'; Options = @(@{ Value = 'marketplace'; Label = 'Marketplace image (next field)' }); Help = 'Gallery images with a finished version are listed when options load (Cloud desktops, Desktop images).' }
        @{ Name = 'ImageSku'; Label = 'Marketplace image'; Type = 'combo'; Editable = $true; Default = 'win11-25h2-avd-m365'; Options = @('win11-25h2-avd-m365') }
        @{ Name = 'SecurityType'; Label = 'Security type'; Type = 'combo'; Default = 'TrustedLaunch'; Options = @('TrustedLaunch', 'Standard') }
        @{ Name = 'AdminUser';            Label = 'Local administrator user name'; Default = 'avdadmin' }
        @{ Name = 'AdminPassword';        Label = 'Password'; Type = 'password' }
        @{ Name = 'AdminPasswordConfirm'; Label = 'Password again'; Type = 'password' }
    )
    $page.Sizes = New-SizePicker
    $page.Sizes.Panel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $load = New-Button -Text 'Load options from the host pool' -Context $page -OnClick { param($pg) Start-AddHostOptionLoad -Page $pg }
    $null = $card.Child.Children.Insert(1, $page.Sizes.Panel)
    $null = $card.Child.Children.Insert(1, (New-ButtonRow -Buttons @($load)))
    $null = $root.Children.Add($card)
    $groupCard = New-Card -Title 'Users' -Subtitle 'Optional. Grants Virtual Machine User Login on this VM to the group.'
    $page.Group = New-GroupPicker -Purpose 'VM sign-in'
    $null = $groupCard.Child.Children.Add($page.Group.Panel)
    $null = $root.Children.Add($groupCard)
    $go  = New-Button -Text 'Add session host' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-AddHostRun -Page $c.Page -DryRun:$c.DryRun }
    $dry = New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-AddHostRun -Page $c.Page -DryRun:$c.DryRun }
    $null = $root.Children.Add((New-ButtonRow -Buttons @($go, $dry)))
    # Every visit with a pool selected reloads subnets, shares and sizes.
    $page.OnShow = { param($pg) if ($Gui.State.Pool -and -not $Gui.State.Busy) { Start-AddHostOptionLoad -Page $pg } }
    $page.Root = $root
    return $page
}

function Start-AddHostOptionLoad {
    param([hashtable]$Page)
    if (-not (Test-PoolSelected)) { return }
    $form = $Page.Form; $pool = $Gui.State.Pool
    if (-not (Get-FormValue $form 'ResourceGroupName')) { $form.Controls['ResourceGroupName'].Text = $pool.ResourceGroupName }
    $rg = Get-FormValue $form 'ResourceGroupName'
    Start-Work -Name "Load options for $rg" -Argument @{ ResourceGroupName = $rg; HostPoolName = $pool.Name; PoolResourceGroupName = $pool.ResourceGroupName } -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        $rgObj = Get-AzResourceGroup -Name $Job.ResourceGroupName
        $subnets = @(Get-AzVirtualNetwork | Sort-Object { $_.Location -ne $rgObj.Location }, ResourceGroupName, Name | ForEach-Object {
            $vnet = $_; foreach ($s in $vnet.Subnets) { [pscustomobject]@{ Label = "$($vnet.ResourceGroupName)/$($vnet.Name)/$($s.Name)  $($s.AddressPrefix -join ',')  ($($vnet.Location))"; Value = $s.Id } } })
        $shares = @(Get-AzStorageAccount -ResourceGroupName $Job.ResourceGroupName | ForEach-Object {
            $sa = $_; foreach ($sh in @(Get-AzRmStorageShare -StorageAccount $sa -ErrorAction SilentlyContinue)) { "\\$($sa.StorageAccountName).file.core.windows.net\$($sh.Name)" } })
        $count = @(Get-AvdSessionHostInfo -ResourceGroupName $Job.PoolResourceGroupName -HostPoolName $Job.HostPoolName).Count
        $images = @(try { Get-GalleryImageInfo | Where-Object { $_.Latest -and $_.OsState -eq 'Generalized' } } catch { Write-Warning "Gallery images: $($_.Exception.Message)" })
        [pscustomobject]@{ Location = $rgObj.Location; Subnets = $subnets; Shares = $shares; Images = $images; Suggested = ('{0}{1:d2}' -f "avd-$($Job.HostPoolName -replace '^hp-', '')-", ($count + 1)) }
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $r = @($result)[-1]
        Add-ComboOption -Combo $pg.Form.Controls['SubnetId'] -Options @($r.Subnets) -Default ''
        Add-ComboOption -Combo $pg.Form.Controls['FsLogixProfileShare'] -Options @($r.Shares) -Default ''
        $imgCombo = $pg.Form.Controls['ImageChoice']
        $keepImage = if ($Gui.State.PreferredImage) { $Gui.State.PreferredImage } else { Get-ComboValue $imgCombo }
        $Gui.State.PreferredImage = ''
        Add-ComboOption -Combo $imgCombo -Options (@(@{ Value = 'marketplace'; Label = 'Marketplace image (next field)' }) + @($r.Images | Where-Object { $_ } | ForEach-Object {
            @{ Value = "gallery|$($_.ResourceGroupName)|$($_.Gallery)|$($_.Name)"; Label = "Gallery: $($_.Gallery)/$($_.Name)  latest $($_.Latest)  ($($_.SecurityType))" } })) -Default $keepImage
        if ($imgCombo.SelectedIndex -lt 0) { $imgCombo.SelectedIndex = 0 }
        if (-not (Get-FormValue $pg.Form 'VMName')) { $pg.Form.Controls['VMName'].Text = $r.Suggested }
        Write-GuiLog "Region $($r.Location): $(@($r.Subnets).Count) subnet(s), $(@($r.Shares).Count) share(s). Loading VM sizes next." 'info'
        Start-SizePickerLoad -Picker $pg.Sizes -Location $r.Location -Form $pg.Form
    }
}

function Invoke-AddHostRun {
    param([hashtable]$Page, [switch]$DryRun)
    $form = $Page.Form
    if (-not (Test-PoolSelected)) { return }
    if (-not (Test-FormRequired $form -Only @('ResourceGroupName', 'VMName', 'SubnetId'))) { return }
    $cred = Get-FormCredential $form
    if (-not $cred) { return }
    $pool = $Gui.State.Pool
    $p = @{
        SubscriptionId = $Gui.State.SubscriptionId; HostPoolName = $pool.Name; HostPoolResourceGroupName = $pool.ResourceGroupName
        RegistrationToken = '<fetched in the worker>'; JoinType = 'EntraId'; ImageSource = 'Marketplace'; LocalAdminCredential = $cred
        VMSize = (Get-SizePickerValue $Page.Sizes)
    }
    Add-FormParameter -Params $p -Form $form -Names @('ResourceGroupName', 'VMName', 'SubnetId', 'FsLogixProfileShare', 'SecurityType')
    $img = Get-FormValue $form 'ImageChoice'
    if ($img -like 'gallery|*') {
        $g = $img -split '\|'
        $p.ImageSource = 'Gallery'; $p.GalleryResourceGroupName = $g[1]; $p.GalleryName = $g[2]; $p.GalleryImageDefinitionName = $g[3]
    } else {
        Add-FormParameter -Params $p -Form $form -Names @('ImageSku')
    }
    $gid = Get-GroupPickerId $Page.Group
    if ($gid) { $p.UserGroupObjectId = $gid }
    $before = 'param($p); $p.RegistrationToken = (Get-AvdRegistrationToken -ResourceGroupName $p.HostPoolResourceGroupName -HostPoolName $p.HostPoolName).Token'
    Invoke-RepoScript -Name "Add host $($p.VMName)" -Path $Gui.Scripts.NewHost -Params $p -DryRun:$DryRun -Before $before
}

# --- Session hosts ----------------------------------------------------------
function Update-HostList {
    <#
    .SYNOPSIS
        Refresh $Gui.State.Hosts for the selected pool and every host combo, then
        run OnDone (with Context) if given.
    #>
    param([scriptblock]$OnDone, [object]$Context)
    if (-not (Test-PoolSelected)) { return }
    $pool = $Gui.State.Pool
    Start-Work -Name "List hosts in $($pool.Name)" -Argument @{ ResourceGroupName = $pool.ResourceGroupName; HostPoolName = $pool.Name } -Context @{ OnDone = $OnDone; Context = $Context } -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        Get-AvdSessionHostInfo -ResourceGroupName $Job.ResourceGroupName -HostPoolName $Job.HostPoolName -IncludeVm | Sort-Object Name
    } -OnDone {
        param($result, $failure, $c)
        if ($failure) { return }
        $Gui.State.Hosts = @($result)
        $Gui.State.SuppressEvents = $true
        try {
            foreach ($combo in $Gui.HostCombos) {
                $keep = Get-ComboValue $combo
                Add-ComboOption -Combo $combo -Options @($Gui.State.Hosts | ForEach-Object { @{ Value = $_.Name; Label = "$($_.Name)  $($_.Status)  $($_.PowerState)  sessions=$($_.Sessions)" } }) -Default $keep
            }
        } finally { $Gui.State.SuppressEvents = $false }
        if ($c.OnDone) { & $c.OnDone $c.Context }
    }
}

function New-HostsPage {
    $page = @{ Key = 'NavHosts'; Form = New-Form }
    $root = New-PageRoot -PoolBanner -Title 'Session hosts' -Lead 'Hosts in the current pool. Right-click a row, or select rows and open Manage. Drain stops new sessions; Repair re-runs join, agent and FSLogix on a host that is Unavailable.'
    $page.Grid = New-DataGrid -Height 340
    $actions = @(
        @{ Text = 'Drain on';   Context = @{ Page = $page; Action = 'DrainOn' };  Handler = { param($c) Invoke-HostsDrain -Page $c.Page -Action $c.Action }; ToolTip = 'No new sessions on the selected hosts' }
        @{ Text = 'Drain off';  Context = @{ Page = $page; Action = 'DrainOff' }; Handler = { param($c) Invoke-HostsDrain -Page $c.Page -Action $c.Action } }
        @{ Separator = $true }
        @{ Text = 'Start';      Context = @{ Page = $page; Action = 'Start' };      Handler = { param($c) Invoke-HostsPower -Page $c.Page -Action $c.Action }; ToolTip = 'Start the selected VMs' }
        @{ Text = 'Deallocate'; Context = @{ Page = $page; Action = 'Deallocate' }; Handler = { param($c) Invoke-HostsPower -Page $c.Page -Action $c.Action }; ToolTip = 'Stop and deallocate (stops billing). Refuses hosts with users signed in.' }
        @{ Text = 'Restart';    Context = @{ Page = $page; Action = 'Restart' };    Handler = { param($c) Invoke-HostsPower -Page $c.Page -Action $c.Action }; ToolTip = 'Refuses hosts with users signed in.' }
        @{ Separator = $true }
        @{ Text = 'Generate RDP...'; Context = @{ Page = $page; Kind = 'host' }; Handler = { param($c) Invoke-RdpGrant -Page $c.Page -Kind $c.Kind }; ToolTip = 'Open 3389 from your public IP for a chosen time, attach a public IP if needed, write and launch the .rdp file' }
        @{ Text = 'Close RDP';       Context = @{ Page = $page; Kind = 'host' }; Handler = { param($c) Invoke-RdpRevokeSelected -Page $c.Page -Kind $c.Kind }; ToolTip = 'Set the rule to Deny now' }
        @{ Separator = $true }
        @{ Text = 'Repair host';     Context = $page; Handler = { param($pg) Invoke-HostsRepair -Page $pg }; ToolTip = 'Uses the repair options at the bottom of the page' }
    )
    Set-GridRowMenu -Grid $page.Grid -Items $actions
    $null = $root.Children.Add((New-TableCard -Title 'Session hosts' -Grid $page.Grid -Tools @(
        (New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Invoke-HostsRefresh -Page $pg }),
        (New-MenuButton -Items $actions)) -Note 'Power actions refuse a host with users signed in. Drain and log off first, or use the rolling restart below, which does that for you one host at a time.'))

    $rolling = New-FormSection -Form $page.Form -Title 'Rolling restart' -Subtitle 'Per host, one at a time: drain, message users, wait, restart, wait for Available, undrain. Selected rows, or every host when none is selected.' -Fields @(
        @{ Name = 'WaitMinutes'; Label = 'Minutes to wait for users to leave'; Type = 'int'; Default = 30 }
        @{ Name = 'RollingMessage'; Label = 'Message to active users'; Default = 'This desktop will restart for maintenance in 30 minutes. Please save your work and sign out.' }
        @{ Name = 'ForceLogoff'; Label = 'Log off users still signed in when the wait runs out (otherwise skip that host)'; Type = 'check'; Default = $false; Span = 2 }
        @{ Name = 'IncludeUnavailable'; Label = 'Also restart hosts that are not Available'; Type = 'check'; Default = $false; Span = 2 }
    )
    $rollGo  = New-Button -Text 'Rolling restart' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-HostsRolling -Page $c.Page -DryRun:$c.DryRun }
    $rollDry = New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-HostsRolling -Page $c.Page -DryRun:$c.DryRun }
    $null = $rolling.Child.Children.Add((New-ButtonRow -Buttons @($rollGo, $rollDry)))
    $null = $root.Children.Add($rolling)

    $agent = New-FormSection -Form $page.Form -Title 'Agent update window' -Subtitle 'AVD agent updates restart the agent. Pin them to a weekly two-hour window outside business hours.' -Fields @(
        @{ Name = 'AgentDay'; Label = 'Day'; Type = 'combo'; Default = 'Saturday'; Options = @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday') }
        @{ Name = 'AgentHour'; Label = 'Start hour (0-23)'; Type = 'int'; Default = 2 }
        @{ Name = 'AgentTimeZone'; Label = 'Time zone (Windows ID)'; Default = (Get-TimeZone).Id }
        @{ Name = 'AgentLocalTime'; Label = 'Use each host''s local time instead'; Type = 'check'; Default = $false }
    )
    $agentSet = New-Button -Text 'Set window' -Context @{ Page = $page; Default = $false } -OnClick { param($c) Invoke-HostsAgentWindow -Page $c.Page -Default:$c.Default }
    $agentDef = New-Button -Text 'Back to Microsoft default' -Context @{ Page = $page; Default = $true } -OnClick { param($c) Invoke-HostsAgentWindow -Page $c.Page -Default:$c.Default }
    $null = $agent.Child.Children.Add((New-ButtonRow -Buttons @($agentSet, $agentDef)))
    $null = $root.Children.Add($agent)

    $null = $root.Children.Add((New-FormSection -Form $page.Form -Title 'Repair options' -Fields @(
        @{ Name = 'RejoinEntra'; Label = 'Re-run the Entra ID join'; Type = 'check'; Default = $false; Span = 2; Help = 'If a stale device record with the host name exists, the repair stops and names it for you to delete in the Entra admin center.' }
        @{ Name = 'UserGroupObjectId'; Label = 'User group object ID (optional)'; Help = 'Re-grants Virtual Machine User Login.' }
        @{ Name = 'FsLogixProfileShare'; Label = 'FSLogix share UNC (optional)'; Help = 'Re-applies the FSLogix registry settings.' }
    )))
    $page.OnShow = { param($pg) if ($Gui.State.Pool -and -not $Gui.State.Busy) { Invoke-HostsRefresh -Page $pg } }
    $page.OnPoolChanged = { param($pg, $visible) $pg.Grid.ItemsSource = $null; if ($visible -and -not $Gui.State.Busy) { Invoke-HostsRefresh -Page $pg } }
    $page.Root = $root
    return $page
}

function Invoke-HostsPower {
    param([hashtable]$Page, [string]$Action)
    if (-not (Test-PoolSelected)) { return }
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -eq 0) { Show-Message 'Select one or more hosts first.' 'Nothing selected' 'Warning'; return }
    $pool = $Gui.State.Pool
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = $pool.ResourceGroupName; HostPoolName = $pool.Name; SessionHostName = @($sel | ForEach-Object { $_.Name }); Action = $Action }
    Invoke-RepoScript -Name "$Action $($p.SessionHostName.Count) host(s)" -Path $Gui.Scripts.Power -Params $p -Context $Page -OnDone { param($result, $failure, $pg) Invoke-HostsRefresh -Page $pg }
}

function Invoke-HostsRolling {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-PoolSelected)) { return }
    $pool = $Gui.State.Pool
    $sel = Get-GridSelection $Page.Grid
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = $pool.ResourceGroupName; HostPoolName = $pool.Name }
    if ($sel.Count -gt 0) { $p.SessionHostName = @($sel | ForEach-Object { $_.Name }) }
    $wait = Get-FormValue $Page.Form 'WaitMinutes'
    if ($null -ne $wait) { $p.WaitMinutes = $wait }
    $msg = Get-FormValue $Page.Form 'RollingMessage'
    if ($msg) { $p.MessageBody = $msg }
    Add-FormParameter -Params $p -Form $Page.Form -Names @('ForceLogoff', 'IncludeUnavailable')
    $scope = if ($sel.Count -gt 0) { "$($sel.Count) selected host(s)" } else { 'EVERY host in the pool' }
    Invoke-RepoScript -Name "Rolling restart of $scope" -Path $Gui.Scripts.Rolling -Params $p -DryRun:$DryRun -Context $Page -OnDone { param($result, $failure, $pg) Invoke-HostsRefresh -Page $pg }
}

function Invoke-HostsAgentWindow {
    param([hashtable]$Page, [switch]$Default)
    if (-not (Test-PoolSelected)) { return }
    $pool = $Gui.State.Pool
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = $pool.ResourceGroupName; HostPoolName = $pool.Name }
    if ($Default) {
        $p.Default = $true
    } else {
        $p.DayOfWeek = Get-FormValue $Page.Form 'AgentDay'
        $hour = Get-FormValue $Page.Form 'AgentHour'
        if ($null -eq $hour) { Show-Message 'Enter the start hour.' 'Agent updates' 'Warning'; return }
        $p.Hour = $hour
        if (Get-FormValue $Page.Form 'AgentLocalTime') { $p.UseSessionHostLocalTime = $true }
        else { $p.TimeZone = Get-FormValue $Page.Form 'AgentTimeZone' }
    }
    Invoke-RepoScript -Name 'Agent update window' -Path $Gui.Scripts.AgentWindow -Params $p
}

function Invoke-HostsRefresh {
    param([hashtable]$Page)
    Update-HostList -Context $Page -OnDone {
        param($pg)
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows $Gui.State.Hosts -Columns @('Name', 'Status', 'PowerState', 'Drain', 'Sessions', 'VMSize', 'AgentVersion', 'LastHeartBeat', 'UpdateState')).DefaultView
    }
}

function Invoke-HostsDrain {
    param([hashtable]$Page, [string]$Action)
    if (-not (Test-PoolSelected)) { return }
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -eq 0) { Show-Message 'Select one or more hosts first.' 'Nothing selected' 'Warning'; return }
    $pool = $Gui.State.Pool
    $names = @($sel | ForEach-Object { $_.Name })
    if (-not (Confirm-Action "$Action on:`n`n$($names -join "`n")" $Action)) { return }
    Start-Work -Name "$Action $($names.Count) host(s)" -Context $Page -Argument @{ Path = $Gui.Scripts.Drain; Names = $names; Action = $Action; Sub = $Gui.State.SubscriptionId; Rg = $pool.ResourceGroupName; Pool = $pool.Name } -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        foreach ($n in $Job.Names) {
            & $Job.Path -SubscriptionId $Job.Sub -ResourceGroupName $Job.Rg -HostPoolName $Job.Pool -SessionHostName $n -Action $Job.Action -Verbose
        }
    } -OnDone { param($result, $failure, $pg) Invoke-HostsRefresh -Page $pg }
}

function Invoke-HostsRepair {
    param([hashtable]$Page)
    if (-not (Test-PoolSelected)) { return }
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -ne 1) { Show-Message 'Select exactly one host to repair.' 'Repair' 'Warning'; return }
    $pool = $Gui.State.Pool
    $vm = ($sel[0].Name -split '\.')[0]
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = $pool.ResourceGroupName; HostPoolName = $pool.Name; VMName = $vm; JoinType = 'EntraId' }
    Add-FormParameter -Params $p -Form $Page.Form -Names @('RejoinEntra', 'UserGroupObjectId', 'FsLogixProfileShare')
    Invoke-RepoScript -Name "Repair $vm" -Path $Gui.Scripts.Repair -Params $p -Context $Page -OnDone { param($result, $failure, $pg) Invoke-HostsRefresh -Page $pg }
}

# --- User sessions ----------------------------------------------------------
function New-SessionsPage {
    $page = @{ Key = 'NavSessions'; Form = New-Form }
    $root = New-PageRoot -PoolBanner -Title 'User sessions' -Lead 'Pick a host, list its sessions, then message or log off the selected ones. Log off is immediate; send a message first.'
    $pick = [System.Windows.Controls.StackPanel]::new(); $pick.Orientation = 'Horizontal'
    $page.HostCombo = New-Combo -Width 420
    $Gui.HostCombos.Add($page.HostCombo)
    $null = $pick.Children.Add($page.HostCombo)
    Add-ControlHandler -Control $page.HostCombo -EventName SelectionChanged -Context $page -Handler { param($pg) if (-not $Gui.State.SuppressEvents -and -not $Gui.State.Busy -and (Get-ComboValue $pg.HostCombo)) { Invoke-SessionList -Page $pg } }
    $pick.Margin = ConvertTo-Thickness '0,0,0,12'
    $null = $root.Children.Add($pick)
    $page.Grid = New-DataGrid -Height 260
    $actions = @(
        @{ Text = 'Send message'; Context = @{ Page = $page; Action = 'Message' }; Handler = { param($c) Invoke-SessionAction -Page $c.Page -Action $c.Action }; ToolTip = 'The title and body from the Message card below' }
        @{ Text = 'Log off';      Context = @{ Page = $page; Action = 'LogOff' };  Handler = { param($c) Invoke-SessionAction -Page $c.Page -Action $c.Action }; ToolTip = 'Immediate. Send a message first.' }
    )
    Set-GridRowMenu -Grid $page.Grid -Items $actions
    $null = $root.Children.Add((New-TableCard -Title 'User sessions' -Grid $page.Grid -Tools @(
        (New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Invoke-SessionsRefresh -Page $pg }),
        (New-MenuButton -Items $actions)) -Note 'With no rows selected an action applies to every session on the host.'))
    # Opening the page loads the hosts, selects the first and lists its sessions. Choosing another host lists it.
    $page.OnShow = { param($pg) if ($Gui.State.Pool -and -not $Gui.State.Busy) { Invoke-SessionsRefresh -Page $pg } }
    $page.OnPoolChanged = { param($pg, $visible) $pg.Grid.ItemsSource = $null; if ($visible -and -not $Gui.State.Busy) { Invoke-SessionsRefresh -Page $pg } }
    $null = $root.Children.Add((New-FormSection -Form $page.Form -Title 'Message' -Fields @(
        @{ Name = 'MessageTitle'; Label = 'Title'; Default = 'Maintenance' }
        @{ Name = 'MessageBody';  Label = 'Body'; Default = 'This host will be restarted in 15 minutes. Please save your work.' }
    )))
    $msg = New-Button -Text 'Send message' -Style 'PrimaryButton' -Context @{ Page = $page; Action = 'Message' } -OnClick { param($c) Invoke-SessionAction -Page $c.Page -Action $c.Action }
    $off = New-Button -Text 'Log off' -Style 'DangerButton' -Context @{ Page = $page; Action = 'LogOff' } -OnClick { param($c) Invoke-SessionAction -Page $c.Page -Action $c.Action }
    $null = $root.Children.Add((New-ButtonRow -Buttons @($msg, $off)))
    $page.Root = $root
    return $page
}

function Invoke-SessionsRefresh {
    param([hashtable]$Page)
    Update-HostList -Context $Page -OnDone {
        param($pg)
        # Update-HostList filled the combo with events suppressed; pick the first host and list it.
        if (-not (Get-ComboValue $pg.HostCombo) -and $pg.HostCombo.Items.Count -gt 0) {
            $Gui.State.SuppressEvents = $true; try { $pg.HostCombo.SelectedIndex = 0 } finally { $Gui.State.SuppressEvents = $false }
        }
        if (Get-ComboValue $pg.HostCombo) { Invoke-SessionList -Page $pg } else { $pg.Grid.ItemsSource = $null }
    }
}

function Invoke-SessionList {
    param([hashtable]$Page)
    if (-not (Test-PoolSelected)) { return }
    $sessionHost = Get-ComboValue $Page.HostCombo
    if (-not $sessionHost) { Show-Message 'Pick a host first (Load hosts).' 'Sessions' 'Warning'; return }
    $pool = $Gui.State.Pool
    Start-Work -Name "Sessions on $sessionHost" -Context $Page -Argument @{ Rg = $pool.ResourceGroupName; Pool = $pool.Name; SessionHost = $sessionHost } -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        Get-AvdUserSession -ResourceGroupName $Job.Rg -HostPoolName $Job.Pool -SessionHostName $Job.SessionHost
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows @($result) -Columns @('SessionId', 'UserPrincipalName', 'SessionState', 'ApplicationType', 'CreateTime')).DefaultView
        if (@($result).Count -eq 0) { Write-GuiLog 'No sessions on that host.' 'info' }
    }
}

function Invoke-SessionAction {
    param([hashtable]$Page, [string]$Action)
    if (-not (Test-PoolSelected)) { return }
    $sessionHost = Get-ComboValue $Page.HostCombo
    if (-not $sessionHost) { Show-Message 'Pick a host first (Load hosts).' 'Sessions' 'Warning'; return }
    $ids = @((Get-GridSelection $Page.Grid) | ForEach-Object { $_.SessionId })
    $pool = $Gui.State.Pool
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = $pool.ResourceGroupName; HostPoolName = $pool.Name; SessionHostName = $sessionHost; Action = $Action }
    if ($ids.Count -gt 0) { $p.SessionId = $ids }
    if ($Action -eq 'Message') { Add-FormParameter -Params $p -Form $Page.Form -Names @('MessageTitle', 'MessageBody') }
    if ($Action -eq 'LogOff') { $p.Force = $true }
    $scope = if ($ids.Count -gt 0) { "$($ids.Count) selected session(s)" } else { 'EVERY session on the host' }
    Invoke-RepoScript -Name "$Action $scope" -Path $Gui.Scripts.Drain -Params $p -Destructive:($Action -eq 'LogOff') -Context $Page -OnDone { param($result, $failure, $pg) if (-not $failure) { Invoke-SessionList -Page $pg } }
}

# --- Profile storage --------------------------------------------------------
function New-StoragePage {
    $page = @{ Key = 'NavStorage'; Form = New-Form }
    $root = New-PageRoot -PoolBanner -Title 'Profile storage' -Lead 'Enable Entra Kerberos on an existing storage account, set the default share permission, grant the group, and apply FSLogix NTFS permissions. Safe to re-run.'
    $null = $root.Children.Add((New-FormSection -Form $page.Form -Title 'Share' -Fields @(
        @{ Name = 'ResourceGroupName';  Label = 'Resource group'; Required = $true; Help = 'Prefilled from the host pool.' }
        @{ Name = 'StorageAccountName'; Label = 'Storage account'; Type = 'combo'; Editable = $true; Required = $true; Help = 'Accounts in the group are listed when the page opens.' }
        @{ Name = 'ShareName'; Label = 'Share name'; Default = 'profiles' }
        @{ Name = 'DefaultSharePermission'; Label = 'Default share permission'; Type = 'combo'; Default = 'StorageFileDataSmbShareContributor'; Options = @(
            'StorageFileDataSmbShareContributor', 'StorageFileDataSmbShareReader', 'StorageFileDataSmbShareElevatedContributor', 'None') }
        @{ Name = 'SetNtfsPermissions'; Label = 'Apply FSLogix NTFS permissions'; Type = 'check'; Default = $true; Span = 2 }
        @{ Name = 'NtfsVia'; Label = 'Apply NTFS from'; Type = 'combo'; Default = 'SessionHost'; Options = @(
            @{ Value = 'SessionHost'; Label = 'SessionHost  via Run Command on a VM (works behind any ISP)' }
            @{ Value = 'Local';       Label = 'Local  from this machine (needs outbound TCP 445)' }) }
        @{ Name = 'ViaVMName'; Label = 'VM to run it from'; Help = 'Needed for SessionHost. Same resource group unless set below.' }
        @{ Name = 'ViaVMResourceGroupName'; Label = 'VM resource group (if different)' }
    )))
    $page.OnShow = { param($pg) if ($Gui.State.Pool -and -not $Gui.State.Busy) { Invoke-StorageOptionLoad -Page $pg } }
    $groupCard = New-Card -Title 'Users' -Subtitle 'Granted Storage File Data SMB Share Contributor on the account.'
    $page.Group = New-GroupPicker -Purpose 'profile share users'
    $null = $groupCard.Child.Children.Add($page.Group.Panel)
    $null = $root.Children.Add($groupCard)
    $go  = New-Button -Text 'Apply share access' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-StorageRun -Page $c.Page -DryRun:$c.DryRun }
    $dry = New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-StorageRun -Page $c.Page -DryRun:$c.DryRun }
    $null = $root.Children.Add((New-ButtonRow -Buttons @($go, $dry)))
    $page.Root = $root
    return $page
}

function Invoke-StorageOptionLoad {
    # Group from the pool unless typed; storage accounts and session host VMs of that group into the combos.
    param([hashtable]$Page)
    $form = $Page.Form
    if (-not (Get-FormValue $form 'ResourceGroupName')) { $form.Controls['ResourceGroupName'].Text = $Gui.State.Pool.ResourceGroupName }
    $rg = Get-FormValue $form 'ResourceGroupName'
    Start-Work -Name "Storage accounts in $rg" -Context $Page -Argument @{ Rg = $rg } -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        [pscustomobject]@{
            Accounts = @(Get-AzStorageAccount -ResourceGroupName $Job.Rg | ForEach-Object { $_.StorageAccountName })
            Vms      = @(Get-AzVM -ResourceGroupName $Job.Rg | ForEach-Object { $_.Name })
        }
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $r = @($result)[-1]
        $keep = Get-FormValue $pg.Form 'StorageAccountName'
        Add-ComboOption -Combo $pg.Form.Controls['StorageAccountName'] -Options @($r.Accounts) -Default $keep
        if (-not (Get-FormValue $pg.Form 'ViaVMName') -and @($r.Vms).Count -gt 0) { $pg.Form.Controls['ViaVMName'].Text = $r.Vms[0] }
    }
}

function Invoke-StorageRun {
    param([hashtable]$Page, [switch]$DryRun)
    $form = $Page.Form
    if (-not (Test-SignedIn)) { return }
    if (-not (Test-FormRequired $form)) { return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId }
    Add-FormParameter -Params $p -Form $form -Names @('ResourceGroupName', 'StorageAccountName', 'ShareName', 'DefaultSharePermission', 'SetNtfsPermissions')
    if ($p.ContainsKey('SetNtfsPermissions')) { Add-FormParameter -Params $p -Form $form -Names @('NtfsVia', 'ViaVMName', 'ViaVMResourceGroupName') }
    $gid = Get-GroupPickerId $Page.Group
    if ($gid) { $p.UserGroupObjectId = $gid }
    Invoke-RepoScript -Name "Share access $($p.StorageAccountName)" -Path $Gui.Scripts.ShareAccess -Params $p -DryRun:$DryRun
}

# --- Backup -----------------------------------------------------------------
function New-BackupPage {
    $page = @{ Key = 'NavBackup'; Form = New-Form }
    $root = New-PageRoot -PoolBanner -Title 'Backup' -Lead 'Creates or reuses a Recovery Services vault, an Enhanced VM policy and an Azure Files policy, then protects the profile share and any Personal hosts in the pool.'
    $null = $root.Children.Add((New-FormSection -Form $page.Form -Title 'Vault' -Fields @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Required = $true }
        @{ Name = 'VaultName'; Label = 'Vault name'; Default = 'rsv-avd-lab'; Required = $true }
        @{ Name = 'Location'; Label = 'Region'; Default = 'westus3'; Required = $true }
        @{ Name = 'StorageRedundancy'; Label = 'Vault redundancy'; Type = 'combo'; Default = 'LocallyRedundant'; Options = @('LocallyRedundant', 'ZoneRedundant', 'GeoRedundant') }
        @{ Name = 'ProfileStorageAccountName'; Label = 'Profile storage account (optional)' }
        @{ Name = 'ProfileShareName'; Label = 'Profile share (optional)'; Default = 'profiles' }
        @{ Name = 'RetentionDays'; Label = 'Daily retention (days)'; Type = 'int'; Default = 30 }
        @{ Name = 'BackupTimeUtc'; Label = 'Backup time (UTC, HH:mm)'; Default = '02:00' }
        @{ Name = 'IncludePool'; Label = 'Also protect Personal hosts in the current host pool'; Type = 'check'; Default = $true; Span = 2 }
    )))
    $page.OnShow = {
        param($pg)
        if (-not $Gui.State.Pool) { return }
        $f = $pg.Form
        if (-not (Get-FormValue $f 'ResourceGroupName')) { $f.Controls['ResourceGroupName'].Text = $Gui.State.Pool.ResourceGroupName }
        if ($Gui.State.Pool.Location -and (Get-FormValue $f 'Location') -in '', 'westus3') { $f.Controls['Location'].Text = $Gui.State.Pool.Location }
        if ((Get-FormValue $f 'VaultName') -in '', 'rsv-avd-lab') { $f.Controls['VaultName'].Text = "rsv-$($Gui.State.Pool.ResourceGroupName -replace '^rg-', '')" }
    }
    $go  = New-Button -Text 'Enable backup' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-BackupRun -Page $c.Page -DryRun:$c.DryRun }
    $dry = New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-BackupRun -Page $c.Page -DryRun:$c.DryRun }
    $null = $root.Children.Add((New-ButtonRow -Buttons @($go, $dry)))
    $page.Root = $root
    return $page
}

function Invoke-BackupRun {
    param([hashtable]$Page, [switch]$DryRun)
    $form = $Page.Form
    if (-not (Test-SignedIn)) { return }
    if (-not (Test-FormRequired $form)) { return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId }
    Add-FormParameter -Params $p -Form $form -Names @('ResourceGroupName', 'VaultName', 'Location', 'StorageRedundancy', 'ProfileStorageAccountName', 'RetentionDays', 'BackupTimeUtc')
    if ($p.ContainsKey('ProfileStorageAccountName')) { Add-FormParameter -Params $p -Form $form -Names @('ProfileShareName') }
    if ((Get-FormValue $form 'IncludePool') -and $Gui.State.Pool) { $p.HostPoolName = $Gui.State.Pool.Name; $p.HostPoolResourceGroupName = $Gui.State.Pool.ResourceGroupName }
    Invoke-RepoScript -Name "Backup $($p.VaultName)" -Path $Gui.Scripts.Backup -Params $p -DryRun:$DryRun
}

# --- Servers ----------------------------------------------------------------
#   WHAT   Plain VMs, not session hosts: inventory and power by resource group,
#          role install on an existing VM, and a new-server form with IIS, AD DS
#          forest and SQL Server roles. Scripts under servers/.
function Get-FormPasswordCredential {
    # Two matching password boxes -> a credential with a fixed user name, or $null when both are empty.
    param([hashtable]$Form, [string]$SecretField, [string]$ConfirmField, [string]$UserName, [string]$Label)
    $p1 = $Form.Controls[$SecretField]; $p2 = $Form.Controls[$ConfirmField]
    if ($p1.SecurePassword.Length -eq 0 -and $p2.SecurePassword.Length -eq 0) { return $null }
    if ($p1.Password -ne $p2.Password) { throw "The two $Label passwords do not match." }
    return [pscredential]::new($UserName, $p1.SecurePassword)
}

function Get-ServerRoleOption {
    @(
        @{ Value = 'None';     Label = 'General purpose  plain Windows Server, no role' }
        @{ Value = 'IIS';      Label = 'Web server  IIS with management console and ASP.NET 4.8' }
        @{ Value = 'ADForest'; Label = 'Domain controller  first DC of a new forest (AD DS + DNS)' }
        @{ Value = 'SQL';      Label = 'SQL Server  configure a SQL Server marketplace image' }
    )
}

function Get-ServerRoleAdFieldSpec {
    @(
        @{ Name = 'DomainName'; Label = 'Domain DNS name'; Help = 'Two or more labels, e.g. corp.example.com.' }
        @{ Name = 'NetbiosName'; Label = 'NetBIOS name'; Help = 'Default: first label, upper case.' }
        @{ Name = 'SafeModePassword'; Label = 'DSRM password'; Type = 'password'; Help = 'Directory Services Restore Mode. Keep it somewhere safe.' }
        @{ Name = 'SafeModePasswordConfirm'; Label = 'DSRM password again'; Type = 'password' }
        @{ Name = 'SetVNetDns'; Label = 'Point the VNet DNS at this DC (live change; other VMs pick it up on restart)'; Type = 'check'; Default = $false; Span = 2 }
    )
}

function Get-ServerRoleSqlFieldSpec {
    @(
        @{ Name = 'SaPassword'; Label = 'sa password (enables mixed mode; empty = Windows authentication only)'; Type = 'password' }
        @{ Name = 'SaPasswordConfirm'; Label = 'sa password again'; Type = 'password' }
        @{ Name = 'SqlLicenseType'; Label = 'Licence for the SQL IaaS registration'; Type = 'combo'; Default = 'PAYG'; Options = @(
            @{ Value = 'PAYG'; Label = 'PAYG  pay-as-you-go (included in the image price)' }
            @{ Value = 'AHUB'; Label = 'AHUB  Azure Hybrid Benefit (own licence with Software Assurance)' }
            @{ Value = 'DR';   Label = 'DR  free disaster-recovery replica' }) }
    )
}

function Add-ServerRoleCard {
    <#
    .SYNOPSIS
        Adds the role picker and the per-role cards to a page root; wires the picker
        so only the chosen role's card is visible. Page gets AdCard, SqlCard, DataCard.
    #>
    param([hashtable]$Page, [System.Windows.Controls.Panel]$Root, [string]$Title = 'Role', [string]$Subtitle, [switch]$NewVm)
    $null = $Root.Children.Add((New-FormSection -Form $Page.Form -Title $Title -Subtitle $Subtitle -Fields @(
        @{ Name = 'Role'; Label = 'What should this server be?'; Type = 'combo'; Default = 'None'; Options = (Get-ServerRoleOption); Span = 2 }
    )))
    if ($NewVm) {
        # New VM: the disk is optional. Off by default; SQL turns it on because the data
        # and log folders are the point. A DC without one keeps AD on the OS disk, which
        # is fine for a lab; Microsoft recommends a caching-off disk for production.
        $Page.DataCard = New-FormSection -Form $Page.Form -Title 'Data disks' -Subtitle 'Premium SSD disks beside the OS disk. The role disk (F:, caching off) is what Microsoft recommends for a DC or SQL; untick it and the role uses C:. The general disk (G:) is for whatever else.' -Fields @(
            @{ Name = 'AddDataDisk'; Label = 'Add a data disk for the role (recommended)'; Type = 'check'; Default = $true }
            @{ Name = 'DataDiskGB'; Label = 'Role disk size (GB)'; Type = 'int'; Help = 'Empty = 256 for SQL, 32 for a domain controller.' }
            @{ Name = 'AddGeneralDisk'; Label = 'Add a general-purpose data disk'; Type = 'check'; Default = $false }
            @{ Name = 'GeneralDataDiskGB'; Label = 'General disk size (GB)'; Type = 'int'; Help = 'Empty = 64.' }
        )
        Add-ControlHandler -Control $Page.Form.Controls['AddDataDisk'] -EventName Checked -Context $Page -Handler { param($pg) Update-ServerDataDiskField -Page $pg }
        Add-ControlHandler -Control $Page.Form.Controls['AddGeneralDisk'] -EventName Checked -Context $Page -Handler { param($pg) Update-ServerDataDiskField -Page $pg }
    } else {
        $Page.DataCard = New-FormSection -Form $Page.Form -Title 'Data disk' -Subtitle 'If the VM has an unformatted data disk, it is formatted with this letter and the role uses it. Without one the role uses the OS disk.' -Fields @(
            @{ Name = 'DataDrive'; Label = 'Drive letter'; Default = 'F' }
        )
    }
    $Page.AdCard  = New-FormSection -Form $Page.Form -Title 'Domain controller' -Subtitle 'Promotes to the first DC of a new forest, restarts, sets the DNS forwarder to Azure DNS and verifies the domain answers.' -Fields (Get-ServerRoleAdFieldSpec)
    $Page.SqlCard = New-FormSection -Form $Page.Form -Title 'SQL Server' -Subtitle 'For a SQL Server marketplace image: default folders on the data drive, optional mixed mode, firewall rule for 1433, SQL IaaS registration.' -Fields (Get-ServerRoleSqlFieldSpec)
    foreach ($c in $Page.DataCard, $Page.AdCard, $Page.SqlCard) { $null = $Root.Children.Add($c) }
    Add-ControlHandler -Control $Page.Form.Controls['Role'] -EventName SelectionChanged -Context $Page -Handler { param($pg) Update-ServerRoleCard -Page $pg }
    Update-ServerRoleCard -Page $Page
}

function Update-ServerRoleCard {
    param([hashtable]$Page)
    $role = Get-ComboValue $Page.Form.Controls['Role']
    $Page.AdCard.Visibility   = if ($role -eq 'ADForest') { 'Visible' } else { 'Collapsed' }
    $Page.SqlCard.Visibility  = if ($role -eq 'SQL') { 'Visible' } else { 'Collapsed' }
    $newVm = $Page.Form.Controls.ContainsKey('AddDataDisk')
    $Page.DataCard.Visibility = if ($newVm -or $role -in 'ADForest', 'SQL') { 'Visible' } else { 'Collapsed' }
    if ($newVm) {
        # The role disk only exists for roles that have database files; its label says which.
        $roleDisk = $Page.Form.Controls['AddDataDisk']
        $roleDisk.Content = switch ($role) {
            'ADForest' { 'Add a data disk for the AD database and SYSVOL (recommended)' }
            'SQL'      { 'Add a data disk for SQL data, logs and backups (recommended)' }
            default    { 'Add a data disk for the role (no role chosen)' }
        }
        $hasRoleDisk = $role -in 'ADForest', 'SQL'
        foreach ($f in 'AddDataDisk', 'DataDiskGB') { $Page.Form.Cells[$f].Visibility = if ($hasRoleDisk) { 'Visible' } else { 'Collapsed' } }
        Update-ServerDataDiskField -Page $Page
    }
    if ($Page.ContainsKey('OnRoleChanged')) { & $Page.OnRoleChanged $Page $role }
}

function Update-ServerDataDiskField {
    # A size only makes sense when that disk is being added.
    param([hashtable]$Page)
    $Page.Form.Cells['DataDiskGB'].IsEnabled = [bool]$Page.Form.Controls['AddDataDisk'].IsChecked
    $Page.Form.Cells['GeneralDataDiskGB'].IsEnabled = [bool]$Page.Form.Controls['AddGeneralDisk'].IsChecked
}

function Add-ServerRoleParameter {
    # Role fields -> script parameters. Throws on mismatched passwords or a missing AD value.
    param([hashtable]$Params, [hashtable]$Form)
    $role = Get-FormValue $Form 'Role'
    $Params.Role = $role
    if ($role -eq 'None') { return }
    $drive = Get-FormValue $Form 'DataDrive'
    if ($drive) { $Params.DataDrive = $drive }
    switch ($role) {
        'ADForest' {
            Add-FormParameter -Params $Params -Form $Form -Names @('DomainName', 'NetbiosName', 'SetVNetDns')
            if (-not $Params.ContainsKey('DomainName')) { throw 'ADForest needs the domain DNS name.' }
            $cred = Get-FormPasswordCredential -Form $Form -SecretField 'SafeModePassword' -ConfirmField 'SafeModePasswordConfirm' -UserName 'dsrm' -Label 'DSRM'
            if (-not $cred) { throw 'ADForest needs the DSRM password.' }
            $Params.SafeModeCredential = $cred
        }
        'SQL' {
            Add-FormParameter -Params $Params -Form $Form -Names @('SqlLicenseType')
            $cred = Get-FormPasswordCredential -Form $Form -SecretField 'SaPassword' -ConfirmField 'SaPasswordConfirm' -UserName 'sa' -Label 'sa'
            if ($cred) { $Params.SaCredential = $cred }
        }
    }
}

function Update-ResourceGroupList {
    # Fill every registered resource-group combo from the subscription. OnDone (with Context) runs after.
    param([scriptblock]$OnDone, [object]$Context)
    if (-not (Test-SignedIn)) { return }
    Start-Work -Name 'List resource groups' -Context @{ OnDone = $OnDone; Context = $Context } -Script {
        $ErrorActionPreference = 'Stop'
        Get-AzResourceGroup | Sort-Object ResourceGroupName | ForEach-Object { [pscustomobject]@{ Name = $_.ResourceGroupName; Location = $_.Location } }
    } -OnDone {
        param($result, $failure, $c)
        if ($failure) { return }
        $Gui.State.ResourceGroups = @($result)
        # Filling a combo raises SelectionChanged; suppressed so two pages do not both start a job.
        $Gui.State.SuppressEvents = $true
        try {
            foreach ($combo in $Gui.RgCombos) {
                $keep = Get-ComboValue $combo
                Add-ComboOption -Combo $combo -Options @($Gui.State.ResourceGroups | ForEach-Object { @{ Value = $_.Name; Label = "$($_.Name)  ($($_.Location))" } }) -Default $keep
            }
        } finally { $Gui.State.SuppressEvents = $false }
        if ($c.OnDone) { & $c.OnDone $c.Context }
    }
}

function New-ServersPage {
    $page = @{ Key = 'NavServers'; Form = New-Form }
    $root = New-PageRoot -Title 'Servers' -Lead 'Virtual machines in a resource group. Right-click a row, or select rows and open Manage: power, RDP, install a role. Nothing here deletes a VM.'
    $pick = [System.Windows.Controls.StackPanel]::new(); $pick.Orientation = 'Horizontal'
    $page.RgCombo = New-Combo -Width 360
    $Gui.RgCombos.Add($page.RgCombo)
    Add-ControlHandler -Control $page.RgCombo -EventName SelectionChanged -Context $page -Handler { param($pg) if (-not $Gui.State.SuppressEvents -and -not $Gui.State.Busy -and (Get-ComboValue $pg.RgCombo)) { Invoke-ServersRefresh -Page $pg } }
    $null = $pick.Children.Add((New-TextBlock -Text 'Resource group' -Style 'Muted' -Margin '0,0,8,0'))
    $null = $pick.Children.Add($page.RgCombo)
    $pick.Margin = ConvertTo-Thickness '0,0,0,12'
    $null = $root.Children.Add($pick)
    $page.Grid = New-DataGrid -Height 260
    $actions = @(
        @{ Text = 'Start';      Context = @{ Page = $page; Action = 'Start' };      Handler = { param($c) Invoke-ServersPower -Page $c.Page -Action $c.Action } }
        @{ Text = 'Deallocate'; Context = @{ Page = $page; Action = 'Deallocate' }; Handler = { param($c) Invoke-ServersPower -Page $c.Page -Action $c.Action }; ToolTip = 'Stop and deallocate: stops billing' }
        @{ Text = 'Restart';    Context = @{ Page = $page; Action = 'Restart' };    Handler = { param($c) Invoke-ServersPower -Page $c.Page -Action $c.Action } }
        @{ Separator = $true }
        @{ Text = 'Generate RDP...'; Context = @{ Page = $page; Kind = 'server' }; Handler = { param($c) Invoke-RdpGrant -Page $c.Page -Kind $c.Kind }; ToolTip = 'Open 3389 from your public IP for a chosen time, attach a public IP if needed, write and launch the .rdp file' }
        @{ Text = 'Close RDP';       Context = @{ Page = $page; Kind = 'server' }; Handler = { param($c) Invoke-RdpRevokeSelected -Page $c.Page -Kind $c.Kind }; ToolTip = 'Set the rule to Deny now' }
        @{ Separator = $true }
        @{ Text = 'Install role';    Context = @{ Page = $page; DryRun = $false }; Handler = { param($c) Invoke-ServersInstallRole -Page $c.Page -DryRun:$c.DryRun }; ToolTip = 'Uses the role card below' }
    )
    Set-GridRowMenu -Grid $page.Grid -Items $actions
    $null = $root.Children.Add((New-TableCard -Title 'Servers' -Grid $page.Grid -Tools @(
        (New-ToolButton -Text 'Refresh' -ToolTip 'Re-read resource groups and the VMs of the selected one' -Context $page -OnClick {
            param($pg) Update-ResourceGroupList -Context $pg -OnDone { param($p) if (Get-ComboValue $p.RgCombo) { Invoke-ServersRefresh -Page $p } } }),
        (New-MenuButton -Items $actions))))

    Add-ServerRoleCard -Page $page -Root $root -Title 'Install a role on the selected VM' -Subtitle 'Runs the role script inside the guest through a managed Run Command. Passwords travel as protected parameters and are not logged.'
    $go  = New-Button -Text 'Install role' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-ServersInstallRole -Page $c.Page -DryRun:$c.DryRun }
    $dry = New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-ServersInstallRole -Page $c.Page -DryRun:$c.DryRun }
    $null = $root.Children.Add((New-ButtonRow -Buttons @($go, $dry)))
    # Every visit re-reads the resource groups, then the VMs of the selected one, so a
    # group or VM created since the last visit is there without pressing anything.
    $page.OnShow = {
        param($pg)
        if (-not $Gui.State.Account -or $Gui.State.Busy) { return }
        Update-ResourceGroupList -Context $pg -OnDone { param($p) if (Get-ComboValue $p.RgCombo) { Invoke-ServersRefresh -Page $p } }
    }
    $page.Root = $root
    return $page
}

function Invoke-ServersRefresh {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    $rg = Get-ComboValue $Page.RgCombo
    if (-not $rg) { Show-Message 'Pick a resource group first.' 'Servers' 'Warning'; return }
    Start-Work -Name "VMs in $rg" -Context $Page -Argument @{ Rg = $rg } -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        foreach ($vm in Get-ServerVmInfo -ResourceGroupName $Job.Rg | Sort-Object Name) {
            # Just-in-time RDP state per VM; a grant whose time has passed is closed here.
            $rdp = 'Closed'
            try {
                $a = Get-ServerRdpAccess -ResourceGroupName $Job.Rg -Name $vm.Name
                if ($a.State -eq 'Expired') { $null = Revoke-ServerRdpAccess -ResourceGroupName $Job.Rg -Name $vm.Name -OnlyIfExpired; Write-Verbose "Closed expired RDP access on $($vm.Name)." }
                elseif ($a.State -eq 'Open') { $rdp = "Open until $($a.ExpiresUtc.ToLocalTime().ToString('HH:mm')) from $($a.SourceIp)" }
            } catch { Write-Verbose "RDP state for $($vm.Name) not read: $($_.Exception.Message)" }
            $vm | Add-Member -NotePropertyName Rdp -NotePropertyValue $rdp -PassThru
        }
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows @($result) -Columns @('Name', 'PowerState', 'VMSize', 'Image', 'PrivateIp', 'Role', 'Rdp', 'OS', 'Location')).DefaultView
        if (@($result).Count -eq 0) { Write-GuiLog 'No VMs in that resource group.' 'info' }
    }
}

function Invoke-ServersPower {
    param([hashtable]$Page, [string]$Action)
    if (-not (Test-SignedIn)) { return }
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -eq 0) { Show-Message 'Select one or more VMs first.' 'Nothing selected' 'Warning'; return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = (Get-ComboValue $Page.RgCombo); Name = @($sel | ForEach-Object { $_.Name }); Action = $Action }
    Invoke-RepoScript -Name "$Action $($p.Name.Count) VM(s)" -Path $Gui.Scripts.ServerPower -Params $p -Context $Page -OnDone { param($result, $failure, $pg) Invoke-ServersRefresh -Page $pg }
}

function Invoke-ServersInstallRole {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -ne 1) { Show-Message 'Select exactly one VM.' 'Install role' 'Warning'; return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = (Get-ComboValue $Page.RgCombo); Name = $sel[0].Name }
    try { Add-ServerRoleParameter -Params $p -Form $Page.Form } catch { Show-Message $_.Exception.Message 'Install role' 'Warning'; return }
    if ($p.Role -eq 'None') { Show-Message 'Pick a role to install. General purpose means nothing to do.' 'Install role' 'Warning'; return }
    Invoke-RepoScript -Name "Install $($p.Role) on $($p.Name)" -Path $Gui.Scripts.ServerRole -Params $p -DryRun:$DryRun -Context $Page -OnDone { param($result, $failure, $pg) Invoke-ServersRefresh -Page $pg }
}

function New-NewServerPage {
    $page = @{ Key = 'NavNewServer'; Form = New-Form }
    $form = $page.Form
    $root = New-PageRoot -Title 'New server' -Lead 'Pick what the server is for, then the machine. Quota and credential rules are checked before anything is created. No NSG rule is opened, even with a public IP.'
    Add-ServerRoleCard -Page $page -Root $root -NewVm -Subtitle 'A role is applied after the VM is up, through Install-ServerRole.ps1. General purpose leaves a clean Windows Server.'
    # The role cards were added to the root by Add-ServerRoleCard; the VM card goes between the picker and them.
    $card = New-FormSection -Form $form -Title 'Virtual machine' -Fields @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Type = 'combo'; Required = $true; Help = 'Choosing one loads subnets, images and sizes for its region.' }
        @{ Name = 'Name'; Label = 'VM name'; Required = $true; Help = '15 characters or fewer; becomes the computer name.' }
        @{ Name = 'SubnetId'; Label = 'Subnet'; Type = 'combo'; Required = $true; Help = 'Every VNet in the subscription, same region first. Must be in the VM''s region.' }
        @{ Name = 'ImageKey'; Label = 'Image'; Type = 'combo'; Editable = $true; Default = 'windowsserver:2025-datacenter-azure-edition'; Options = @('windowsserver:2025-datacenter-azure-edition'); Help = 'SQL Server role needs a SQL Server image; it is picked for you when one is loaded.' }
        @{ Name = 'AdminUser';            Label = 'Local administrator user name'; Default = 'srvadmin' }
        @{ Name = 'AdminPassword';        Label = 'Password'; Type = 'password' }
        @{ Name = 'AdminPasswordConfirm'; Label = 'Password again'; Type = 'password' }
        @{ Name = 'StaticPrivateIp'; Label = 'Pin the private IP (always on for a domain controller)'; Type = 'check'; Default = $false }
        @{ Name = 'PublicIp'; Label = 'Add a public IP (no NSG rule is opened)'; Type = 'check'; Default = $false }
        @{ Name = 'HybridBenefit'; Label = 'Azure Hybrid Benefit (only with Software Assurance)'; Type = 'check'; Default = $false }
        @{ Name = 'SecurityType'; Label = 'Security type'; Type = 'combo'; Default = 'TrustedLaunch'; Options = @('TrustedLaunch', 'Standard') }
    )
    $page.RgCombo = $form.Controls['ResourceGroupName']
    $Gui.RgCombos.Add($page.RgCombo)
    Add-ControlHandler -Control $page.RgCombo -EventName SelectionChanged -Context $page -Handler { param($pg) if (-not $Gui.State.SuppressEvents -and -not $Gui.State.Busy -and (Get-ComboValue $pg.RgCombo)) { Start-NewServerOptionLoad -Page $pg } }
    $page.Sizes = New-SizePicker -Default 'Standard_D2s_v5'
    $page.Sizes.Panel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $null = $card.Child.Children.Insert(1, $page.Sizes.Panel)
    $null = $card.Child.Children.Insert(1, (New-ButtonRow -Buttons @(
        (New-Button -Text 'Refresh lists' -Style 'GhostButton' -ToolTip 'Lists load when the page opens; this re-reads groups, subnets, images and sizes now' -Context $page -OnClick {
            param($pg) Update-ResourceGroupList -Context $pg -OnDone { param($p) if (Get-ComboValue $p.RgCombo) { Start-NewServerOptionLoad -Page $p } } }))))
    # Order: title, lead, role picker, VM card, then the role cards Add-ServerRoleCard already placed.
    $root.Children.Insert($root.Children.IndexOf($page.DataCard), $card)

    # A role choice adjusts the machine: a DC pins its IP; SQL wants a SQL image.
    $page.OnRoleChanged = {
        param($pg, $role)
        if ($role -eq 'ADForest') { $pg.Form.Controls['StaticPrivateIp'].IsChecked = $true }
        $img = $pg.Form.Controls['ImageKey']
        $current = Get-ComboValue $img
        if ($role -eq 'SQL' -and $current -notlike 'sql:*') {
            $sql = $img.Items | Where-Object { "$($_.Tag)" -like 'sql:*' } | Select-Object -First 1
            if ($sql) { $img.SelectedItem = $sql } else { Write-GuiLog 'Pick a resource group to load SQL Server images, then choose one.' 'warn' }
        } elseif ($role -ne 'SQL' -and $current -like 'sql:*') {
            $ws = $img.Items | Where-Object { "$($_.Tag)" -like 'windowsserver:*' } | Select-Object -First 1
            if ($ws) { $img.SelectedItem = $ws }
        }
    }
    $go  = New-Button -Text 'Create server' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-NewServerRun -Page $c.Page -DryRun:$c.DryRun }
    $dry = New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-NewServerRun -Page $c.Page -DryRun:$c.DryRun }
    $null = $root.Children.Add((New-ButtonRow -Buttons @($go, $dry)))
    # Every visit re-reads the resource groups, then subnets, images and sizes for the
    # selected one. The form's typed values are kept; only the lists refresh.
    $page.OnShow = {
        param($pg)
        if (-not $Gui.State.Account -or $Gui.State.Busy) { return }
        Update-ResourceGroupList -Context $pg -OnDone { param($p) if (Get-ComboValue $p.RgCombo) { Start-NewServerOptionLoad -Page $p } }
    }
    $page.Root = $root
    return $page
}

function Start-NewServerOptionLoad {
    # Resource group chosen: its subnets and the image catalog in one job, then the sizes.
    param([hashtable]$Page)
    $rg = Get-ComboValue $Page.RgCombo
    $rgRow = $Gui.State.ResourceGroups | Where-Object Name -eq $rg | Select-Object -First 1
    Start-Work -Name "Options for $rg" -Context $Page -Argument @{ Rg = $rg; Location = $(if ($rgRow) { $rgRow.Location } else { '' }) } -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        $loc = if ($Job.Location) { $Job.Location } else { (Get-AzResourceGroup -Name $Job.Rg).Location }
        # Every VNet the account can see, same-region ones first: the network often lives in another group.
        $subnets = @(Get-AzVirtualNetwork | Sort-Object { $_.Location -ne $loc }, ResourceGroupName, Name | ForEach-Object {
            $vnet = $_; foreach ($s in $vnet.Subnets) { [pscustomobject]@{ Label = "$($vnet.ResourceGroupName)/$($vnet.Name)/$($s.Name)  $($s.AddressPrefix -join ',')  ($($vnet.Location))"; Value = $s.Id } } })
        [pscustomobject]@{ Location = $loc; Subnets = $subnets; Images = @(Get-ServerImageCatalog -Location $loc) }
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $r = @($result)[-1]
        $keepSubnet = Get-ComboValue $pg.Form.Controls['SubnetId']
        Add-ComboOption -Combo $pg.Form.Controls['SubnetId'] -Options @($r.Subnets) -Default $keepSubnet
        if ($pg.Form.Controls['SubnetId'].SelectedIndex -lt 0 -and $pg.Form.Controls['SubnetId'].Items.Count -gt 0) { $pg.Form.Controls['SubnetId'].SelectedIndex = 0 }
        $current = Get-FormValue $pg.Form 'ImageKey'
        Add-ComboOption -Combo $pg.Form.Controls['ImageKey'] -Options @($r.Images | ForEach-Object { @{ Value = $_.Value; Label = $_.Label } }) -Default $current
        if ($pg.Form.Controls['ImageKey'].SelectedIndex -lt 0 -and $pg.Form.Controls['ImageKey'].Items.Count -gt 0) { $pg.Form.Controls['ImageKey'].SelectedIndex = 0 }
        Write-GuiLog "Region $($r.Location): $(@($r.Subnets).Count) subnet(s), $(@($r.Images).Count) image(s). Loading VM sizes next." 'info'
        Start-SizePickerLoad -Picker $pg.Sizes -Location $r.Location
    }
}

function Invoke-NewServerRun {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    $form = $Page.Form
    if (-not (Test-FormRequired $form -Only @('ResourceGroupName', 'Name', 'SubnetId'))) { return }
    $cred = Get-FormCredential $form
    if (-not $cred) { return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; LocalAdminCredential = $cred; VMSize = (Get-SizePickerValue $Page.Sizes) }
    Add-FormParameter -Params $p -Form $form -Names @('ResourceGroupName', 'Name', 'SubnetId', 'ImageKey', 'StaticPrivateIp', 'PublicIp', 'HybridBenefit', 'SecurityType')
    try { Add-ServerRoleParameter -Params $p -Form $form } catch { Show-Message $_.Exception.Message 'New server' 'Warning'; return }
    $p.Remove('DataDrive')   # New-Server.ps1 uses F: for the role disk
    if ($p.Role -in 'ADForest', 'SQL' -and (Get-FormValue $form 'AddDataDisk')) {
        $gb = Get-FormValue $form 'DataDiskGB'
        $p.DataDiskGB = if ($null -ne $gb -and $gb -gt 0) { $gb } else { switch ($p.Role) { 'SQL' { 256 } default { 32 } } }
    } else {
        $p.DataDiskGB = 0   # explicit: the script's default would add the recommended disk
    }
    if (Get-FormValue $form 'AddGeneralDisk') {
        $gb = Get-FormValue $form 'GeneralDataDiskGB'
        $p.GeneralDataDiskGB = if ($null -ne $gb -and $gb -gt 0) { $gb } else { 64 }
    }
    Invoke-RepoScript -Name "Create server $($p.Name)" -Path $Gui.Scripts.ServerNew -Params $p -DryRun:$DryRun
}

# --- Just-in-time RDP (servers and session hosts) ---------------------------
#   WHAT   A duration picker, Generate RDP and Close RDP, for the selected VM.
#   WHY    Opens 3389 from your public IP for that long, attaches a public IP if
#          needed, writes <vm>.rdp to Downloads and launches it. Closing sets the
#          NSG rule to Deny; nothing is deleted. The timer closes grants from this
#          session when they expire, and the Servers page closes any expired grant
#          it sees on refresh.
function Show-RdpDurationDialog {
    # "Generate RDP" asks how long, like the console does: 30 minutes to 8 hours.
    param([string]$VMName)
    $v = Show-ChoiceDialog -Title "RDP to $VMName" -Text 'Port 3389 opens from your public IP for this long, then the rule flips to Deny on its own (while this window is open).' -OkText 'Generate' -Default '60' -Options @(
        @{ Value = '30'; Label = '30 minutes' }, @{ Value = '60'; Label = '1 hour' }, @{ Value = '120'; Label = '2 hours' },
        @{ Value = '240'; Label = '4 hours' }, @{ Value = '480'; Label = '8 hours' })
    if ($v) { return [int]$v }
    return 0
}

function Get-RdpTarget {
    # Selected row -> VM resource group and name; session host rows carry their VM in $Gui.State.Hosts.
    param([hashtable]$Page, [string]$Kind)
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -ne 1) { Show-Message 'Select exactly one row.' 'RDP' 'Warning'; return $null }
    if ($Kind -eq 'server') { return @{ Rg = (Get-ComboValue $Page.RgCombo); Vm = $sel[0].Name; Entra = $false } }
    $h = $Gui.State.Hosts | Where-Object Name -eq $sel[0].Name | Select-Object -First 1
    if (-not $h -or -not $h.VMName) { Show-Message 'Refresh the hosts first.' 'RDP' 'Warning'; return $null }
    return @{ Rg = $h.VMResourceGroup; Vm = $h.VMName; Entra = $true }
}

function Invoke-RdpGrant {
    param([hashtable]$Page, [string]$Kind)
    if (-not (Test-SignedIn)) { return }
    $t = Get-RdpTarget -Page $Page -Kind $Kind
    if (-not $t) { return }
    $minutes = Show-RdpDurationDialog -VMName $t.Vm
    if ($minutes -le 0) { return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = $t.Rg; Name = $t.Vm; Minutes = $minutes }
    if ($t.Entra) { $p.EntraAuth = $true }
    Invoke-RepoScript -Name "RDP to $($t.Vm) for $minutes min" -Path $Gui.Scripts.RdpGrant -Params $p -Context @{ Page = $Page; Kind = $Kind; Target = $t; Minutes = $minutes } -OnDone {
        param($result, $failure, $c)
        if ($failure) { return }
        $r = @($result | Where-Object { $_ -and $_.PSObject.Properties['RdpFile'] })[-1]
        if (-not $r) { return }
        $Gui.Jit.Add(@{ Rg = $c.Target.Rg; Vm = $c.Target.Vm; Expires = (Get-Date).AddMinutes($c.Minutes) })
        Write-GuiLog "RDP open to $($r.Address) from $($r.From) until $($r.OpenUntil). File: $($r.RdpFile). Closes itself when time is up while this window is open." 'ok'
        try { Start-Process -FilePath 'mstsc.exe' -ArgumentList "`"$($r.RdpFile)`"" } catch { Write-GuiLog "Could not launch mstsc: $($_.Exception.Message). Open the file yourself." 'warn' }
        if ($c.Kind -eq 'server') { Invoke-ServersRefresh -Page $c.Page }
    }
}

function Invoke-RdpRevokeSelected {
    param([hashtable]$Page, [string]$Kind)
    if (-not (Test-SignedIn)) { return }
    $t = Get-RdpTarget -Page $Page -Kind $Kind
    if (-not $t) { return }
    Invoke-RdpRevoke -ResourceGroupName $t.Rg -VMName $t.Vm -Page $(if ($Kind -eq 'server') { $Page } else { $null })
}

function Invoke-RdpRevoke {
    param([string]$ResourceGroupName, [string]$VMName, [switch]$Silent, [hashtable]$Page)
    if ($Gui.State.Busy) { return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = $ResourceGroupName; Name = $VMName }
    $arg = @{ Path = $Gui.Scripts.RdpRevoke; Params = $p }
    Start-Work -Name "Close RDP on $VMName" -Script $Gui.RunScriptJob -Argument $arg -Context @{ Rg = $ResourceGroupName; Vm = $VMName; Page = $Page } -OnDone {
        param($result, $failure, $c)
        $gone = @($Gui.Jit | Where-Object { $_.Rg -eq $c.Rg -and $_.Vm -eq $c.Vm })
        foreach ($g in $gone) { $null = $Gui.Jit.Remove($g) }
        if ($c.Page) { Invoke-ServersRefresh -Page $c.Page }
    }
    if (-not $Silent) { Write-GuiLog "Closing RDP on $VMName." 'info' }
}

# --- Networks ---------------------------------------------------------------
#   WHAT   Virtual networks and subnets: list, create, edit DNS, add address space,
#          add a subnet, change a subnet's prefix, attach or detach an NSG, create
#          an NSG. Scripts under network/. Nothing deletes; address space only grows.
function New-NetworkPage {
    $page = @{ Key = 'NavNetwork'; Form = New-Form; VNets = @(); Subnets = @(); Nsgs = @(); SelectedVNet = $null }
    $form = $page.Form
    $root = New-PageRoot -Title 'Networks' -Lead 'Every virtual network the account can see. Select one to see and edit its subnets. Nothing here deletes; address space can be added but not removed.'
    $page.Grid = New-DataGrid -Height 200
    $page.Grid.SelectionMode = 'Single'
    Add-ControlHandler -Control $page.Grid -EventName SelectionChanged -Context $page -Handler { param($pg) Update-NetworkSelection -Page $pg }
    $null = $root.Children.Add((New-TableCard -Title 'Virtual networks' -Grid $page.Grid -Tools @(
        (New-ToolButton -Text 'Refresh' -ToolTip 'Re-read resource groups, networks and NSGs' -Context $page -OnClick {
            param($pg) Update-ResourceGroupList -Context $pg -OnDone { param($p) Invoke-NetworkRefresh -Page $p } }))))

    # Subnets of the selected VNet: right under it; add and edit open a dialog.
    $page.SubnetGrid = New-DataGrid -Height 180
    $page.SubnetGrid.SelectionMode = 'Single'
    $subnetActions = @(@{ Text = 'Edit subnet...'; Context = $page; Handler = { param($pg) Invoke-NetworkSubnetEdit -Page $pg }; ToolTip = 'Prefix and NSG' })
    Set-GridRowMenu -Grid $page.SubnetGrid -Items $subnetActions
    Add-ControlHandler -Control $page.SubnetGrid -EventName DoubleClick -Context $page -Handler { param($pg) Invoke-NetworkSubnetEdit -Page $pg }
    $null = $root.Children.Add((New-TableCard -Title 'Subnets of the selected network' -Grid $page.SubnetGrid -Tools @(
        (New-ToolButton -Text 'Add subnet' -Context $page -OnClick { param($pg) Invoke-NetworkSubnetAdd -Page $pg } -ToolTip 'Opens a form prefilled with the next free range of the selected network'),
        (New-MenuButton -Items $subnetActions)) -Note 'Double-click a subnet to change its prefix or NSG.'))

    # Edit the selected VNet
    $page.EditCard = New-FormSection -Form $form -Title 'Selected virtual network' -Subtitle 'DNS servers and address space. VMs pick up a DNS change on their next restart.' -Fields @(
        @{ Name = 'EditDns'; Label = 'DNS servers (comma separated; empty = Azure default)'; Help = 'For a domain, the DC first and 168.63.129.16 second.' }
        @{ Name = 'EditAddPrefix'; Label = 'Add address space (CIDR, optional)'; Help = 'Existing prefixes stay.' }
    )
    $null = $page.EditCard.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Save network changes' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-NetworkVNetSave -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-NetworkVNetSave -Page $c.Page -DryRun:$c.DryRun }))))
    $null = $root.Children.Add($page.EditCard)

    # Create a VNet
    $createCard = New-FormSection -Form $form -Title 'Create a virtual network' -Fields @(
        @{ Name = 'NewRg'; Label = 'Resource group'; Type = 'combo'; Required = $true }
        @{ Name = 'NewName'; Label = 'Name'; Required = $true }
        @{ Name = 'NewPrefix'; Label = 'Address space (CIDR, comma separated for several)'; Default = '10.20.0.0/16'; Required = $true }
        @{ Name = 'NewDns'; Label = 'DNS servers (comma separated; empty = Azure default)' }
        @{ Name = 'NewSubnetName'; Label = 'First subnet name'; Default = 'default'; Required = $true }
        @{ Name = 'NewSubnetPrefix'; Label = 'First subnet prefix'; Default = '10.20.1.0/24'; Required = $true }
    )
    $Gui.RgCombos.Add($form.Controls['NewRg'])
    $null = $createCard.Child.Children.Add((New-ButtonRow -Buttons @(
        (New-Button -Text 'Create network' -Style 'PrimaryButton' -Context @{ Page = $page; DryRun = $false } -OnClick { param($c) Invoke-NetworkVNetCreate -Page $c.Page -DryRun:$c.DryRun }),
        (New-Button -Text 'Dry run (-WhatIf)' -Context @{ Page = $page; DryRun = $true } -OnClick { param($c) Invoke-NetworkVNetCreate -Page $c.Page -DryRun:$c.DryRun }))))
    $null = $root.Children.Add($createCard)

    # Create an NSG
    $nsgCard = New-FormSection -Form $form -Title 'Create a network security group' -Subtitle 'Default rules only: VNet traffic allowed, internet inbound denied. Attach it to a subnet above.' -Fields @(
        @{ Name = 'NsgRg'; Label = 'Resource group'; Type = 'combo'; Required = $true }
        @{ Name = 'NsgName'; Label = 'Name'; Required = $true }
    )
    $Gui.RgCombos.Add($form.Controls['NsgRg'])
    $null = $nsgCard.Child.Children.Add((New-ButtonRow -Buttons @((New-Button -Text 'Create NSG' -Context $page -OnClick { param($pg) Invoke-NetworkNsgCreate -Page $pg }))))
    $null = $root.Children.Add($nsgCard)

    $page.OnShow = {
        param($pg)
        if (-not $Gui.State.Account -or $Gui.State.Busy) { return }
        Update-ResourceGroupList -Context $pg -OnDone { param($p) Invoke-NetworkRefresh -Page $p }
    }
    $page.Root = $root
    return $page
}

function Invoke-NetworkRefresh {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    Start-Work -Name 'Virtual networks' -Context $Page -Script {
        $ErrorActionPreference = 'Stop'
        [pscustomobject]@{ VNets = @(Get-NetVirtualNetworkInfo); Nsgs = @(Get-NetSecurityGroupInfo) }
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $r = @($result)[-1]
        $pg.VNets = @($r.VNets)
        $pg.Nsgs = @($r.Nsgs)
        # GOTCHA Replacing ItemsSource clears the selection, which runs
        #        Update-NetworkSelection and sets SelectedVNet to $null, so the name
        #        to select again is read before, into plain variables.
        $keepName = if ($pg.SelectedVNet) { $pg.SelectedVNet.Name } else { $null }
        $keepRg   = if ($pg.SelectedVNet) { $pg.SelectedVNet.ResourceGroupName } else { $null }
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows $pg.VNets -Columns @('Name', 'ResourceGroupName', 'Location', 'AddressSpace', 'DnsServers', 'Subnets', 'Peerings')).DefaultView
        if ($keepName) {
            $row = $pg.Grid.Items | Where-Object { $_.Row['Name'] -eq $keepName -and $_.Row['ResourceGroupName'] -eq $keepRg } | Select-Object -First 1
            if ($row) { $pg.Grid.SelectedItem = $row }
        }
        if (@($r.VNets).Count -eq 0) { Write-GuiLog 'No virtual networks in this subscription.' 'info' }
    }
}

function Update-NetworkSelection {
    param([hashtable]$Page)
    $sel = Get-GridSelection $Page.Grid
    $v = if ($sel.Count -eq 1) { $Page.VNets | Where-Object { $_.Name -eq $sel[0].Name -and $_.ResourceGroupName -eq $sel[0].ResourceGroupName } | Select-Object -First 1 } else { $null }
    $Page.SelectedVNet = $v
    $Page.EditCard.IsEnabled = ($null -ne $v)
    if (-not $v) { $Page.SubnetGrid.ItemsSource = $null; $Page.Subnets = @(); return }
    Set-FormValue $Page.Form 'EditDns' $(if ($v.DnsServers -eq 'Azure default') { '' } else { $v.DnsServers })
    Set-FormValue $Page.Form 'EditAddPrefix' ''
    if ($Gui.State.Busy) { return }
    Start-Work -Name "Subnets of $($v.Name)" -Context $Page -Argument @{ Id = $v.Id } -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        Get-NetSubnetInfo -VirtualNetworkId $Job.Id
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.Subnets = @($result)
        $pg.SubnetGrid.ItemsSource = (ConvertTo-DataTable -Rows $pg.Subnets -Columns @('Name', 'AddressPrefix', 'Nsg', 'RouteTable', 'Delegation', 'Nics')).DefaultView
    }
}

function Invoke-NetworkVNetSave {
    param([hashtable]$Page, [switch]$DryRun)
    $v = $Page.SelectedVNet
    if (-not $v) { Show-Message 'Select a virtual network first.' 'Networks' 'Warning'; return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = $v.ResourceGroupName; Name = $v.Name }
    $dns = Get-FormValue $Page.Form 'EditDns'
    if ($dns) { $p.DnsServer = @($dns -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { $p.AzureDefaultDns = $true }
    $add = Get-FormValue $Page.Form 'EditAddPrefix'
    if ($add) { $p.AddAddressPrefix = @($add -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    Invoke-RepoScript -Name "Update network $($v.Name)" -Path $Gui.Scripts.NetVNetSet -Params $p -DryRun:$DryRun -Context $Page -OnDone { param($result, $failure, $pg) Invoke-NetworkRefresh -Page $pg }
}

function Get-NetworkSubnetContext {
    # The selected VNet's address space and its subnets as name -> prefix, for the dialogs.
    param([hashtable]$Page, [string]$Except)
    $taken = @{}
    foreach ($sn in @($Page.Subnets | Where-Object Name -ne $Except)) { $taken[$sn.Name] = $sn.AddressPrefix }
    $space = @("$($Page.SelectedVNet.AddressSpace)" -split '[,\s]+' | Where-Object { $_ })
    return @{ Space = $space; Taken = $taken }
}

function Get-NetworkNsgOption {
    # NSGs in the VNet's region first, then the rest.
    param([hashtable]$Page)
    $loc = $Page.SelectedVNet.Location
    return @(@{ Value = ''; Label = 'None' }) + @($Page.Nsgs | Sort-Object { $_.Location -ne $loc }, ResourceGroupName, Name | ForEach-Object {
        @{ Value = $_.Id; Label = "$($_.ResourceGroupName)/$($_.Name)  ($($_.Location), $($_.Rules) rules)" } })
}

function Get-SubnetFixedPart {
    # The octets the address space pins: "10.10." for 10.10.0.0/16, "10." for a /8,
    # "10.10.20." for a /24. Shown in the dialog, never typed.
    param([string]$Space)
    $ip, $len = $Space -split '/'
    $n = [math]::Min(3, [math]::Floor([int]$len / 8))
    if ($n -eq 0) { return '' }
    return ((($ip -split '\.')[0..($n - 1)]) -join '.') + '.'
}

function Show-SubnetDialog {
    <#
    .SYNOPSIS
        Add or edit a subnet. By default it is a /24 from a dropdown: the octets the
        network pins (10.10. for a /16) are shown, not typed, and the list holds the
        free /24s, the next one after the subnets in use already picked. "Manual
        entry" swaps the dropdown for a box to type the whole range, any size.
        Checks run as you go; the buttons stay off while the range is outside the
        network, overlaps a subnet or already exists, or the name is taken.
        Returns @{ Action; Name; Prefix; NsgId } or $null.
    #>
    param([hashtable]$Page, [ValidateSet('Add', 'Edit')] [string]$Mode = 'Add', $Subnet)
    $v = $Page.SelectedVNet
    $ctx = Get-NetworkSubnetContext -Page $Page -Except $(if ($Subnet) { $Subnet.Name } else { '' })
    $current = if ($Subnet) { ("$($Subnet.AddressPrefix)" -split '[,\s]+')[0] } else { '' }
    $st = @{ Page = $Page; Ctx = $ctx; Mode = $Mode; Subnet = $Subnet; Current = $current; Buttons = @(); Result = $null; Full = ''; Ok = $false; NoFree = ''; NameBox = $null; Hint = $null }

    $dlg = [System.Windows.Window]::new()
    $dlg.Title = $(if ($Mode -eq 'Add') { "Add a subnet to $($v.Name)" } else { "Subnet $($Subnet.Name)" })
    $dlg.Width = 560; $dlg.SizeToContent = 'Height'; $dlg.Owner = $Gui.Window; $dlg.WindowStartupLocation = 'CenterOwner'; $dlg.ResizeMode = 'NoResize'
    $dlg.Resources.MergedDictionaries.Add($Gui.Theme); $dlg.Background = Get-ThemeResource 'Brush.Background'
    $st.Dlg = $dlg
    $stack = [System.Windows.Controls.StackPanel]::new(); $stack.Margin = [System.Windows.Thickness]::new(24, 20, 24, 20)
    $null = $stack.Children.Add((New-TextBlock -Text $dlg.Title -Style 'Subhead'))
    $taken = if ($ctx.Taken.Count) { ($ctx.Taken.Keys | Sort-Object | ForEach-Object { "$_ $($ctx.Taken[$_])" }) -join ', ' } else { 'none yet' }
    $lead = New-TextBlock -Text "Network $($v.Name): $($ctx.Space -join ', '). Subnets in it: $taken." -Style 'Muted' -Margin '0,0,0,12'; $lead.TextWrapping = 'Wrap'
    $null = $stack.Children.Add($lead)

    $null = $stack.Children.Add((New-TextBlock -Text 'Name' -Style 'FieldLabel'))
    if ($Mode -eq 'Add') {
        $st.NameBox = [System.Windows.Controls.TextBox]::new(); $st.NameBox.Text = 'snet-'; $st.NameBox.Tag = $st
        $st.NameBox.Add_TextChanged({ Invoke-Guarded { param($x) Update-SubnetDialogHint $x } $this.Tag })
        $null = $stack.Children.Add($st.NameBox)
    } else {
        $null = $stack.Children.Add((New-TextBlock -Text $Subnet.Name -Margin '0,0,0,4'))
    }

    if ($ctx.Space.Count -gt 1) {
        $null = $stack.Children.Add((New-TextBlock -Text 'Address space' -Style 'FieldLabel' -Margin '0,12,0,4'))
        $st.SpaceCombo = New-Combo -Margin '0'
        $inSpace = if ($current) { @($ctx.Space | Where-Object { -not (@(Test-NetSubnetPrefix -Prefix $current -AddressSpace $_) -match 'outside') }) | Select-Object -First 1 } else { $null }
        Add-ComboOption -Combo $st.SpaceCombo -Options $ctx.Space -Default $(if ($inSpace) { $inSpace } else { $ctx.Space[0] })
        Add-ControlHandler -Control $st.SpaceCombo -EventName SelectionChanged -Context $st -Handler { param($x) Update-SubnetDialogRange $x }
        $null = $stack.Children.Add($st.SpaceCombo)
    }

    # Default: fixed octets + a dropdown of free /24s.
    $null = $stack.Children.Add((New-TextBlock -Text 'Address range' -Style 'FieldLabel' -Margin '0,12,0,4'))
    $st.PickRow = [System.Windows.Controls.DockPanel]::new()
    $st.Fixed = New-TextBlock -Text '' -Margin '0,0,4,0'
    $st.Fixed.FontFamily = Get-ThemeResource 'Font.Mono'; $st.Fixed.FontSize = 16; $st.Fixed.VerticalAlignment = 'Center'
    $st.Fixed.ToolTip = 'Set by the network''s address space'
    [System.Windows.Controls.DockPanel]::SetDock($st.Fixed, 'Left')
    $null = $st.PickRow.Children.Add($st.Fixed)
    $st.Pick = New-Combo -Margin '0'
    $st.Pick.FontFamily = Get-ThemeResource 'Font.Mono'
    Add-ControlHandler -Control $st.Pick -EventName SelectionChanged -Context $st -Handler { param($x) Update-SubnetDialogHint $x }
    $null = $st.PickRow.Children.Add($st.Pick)
    $null = $stack.Children.Add($st.PickRow)

    # Manual: the whole range typed, any size.
    $st.ManualBox = [System.Windows.Controls.TextBox]::new(); $st.ManualBox.FontFamily = Get-ThemeResource 'Font.Mono'; $st.ManualBox.Visibility = 'Collapsed'; $st.ManualBox.Tag = $st
    $st.ManualBox.ToolTip = 'The whole range, for example 10.10.4.0/26'
    $st.ManualBox.Add_TextChanged({ Invoke-Guarded { param($x) Update-SubnetDialogHint $x } $this.Tag })
    $null = $stack.Children.Add($st.ManualBox)
    $st.Manual = [System.Windows.Controls.CheckBox]::new(); $st.Manual.Content = 'Manual entry (type the whole range, any size)'; $st.Manual.Margin = ConvertTo-Thickness '0,8,0,0'
    Add-ControlHandler -Control $st.Manual -EventName Checked -Context $st -Handler { param($x) Set-SubnetDialogManual $x }
    $null = $stack.Children.Add($st.Manual)

    $st.Hint = New-TextBlock -Text '' -Margin '0,8,0,0'; $st.Hint.TextWrapping = 'Wrap'
    $null = $stack.Children.Add($st.Hint)

    $null = $stack.Children.Add((New-TextBlock -Text $(if ($Mode -eq 'Add') { 'Network security group' } else { 'Network security group (None detaches it)' }) -Style 'FieldLabel' -Margin '0,12,0,4'))
    $st.Nsg = New-Combo -Margin '0'
    Add-ComboOption -Combo $st.Nsg -Options (Get-NetworkNsgOption -Page $Page) -Default $(if ($Subnet) { "$($Subnet.NsgId)" } else { '' })
    if ($st.Nsg.SelectedIndex -lt 0) { $st.Nsg.SelectedIndex = 0 }
    $null = $stack.Children.Add($st.Nsg)
    if ($Subnet -and [int]$Subnet.Nics -gt 0) {
        $w = New-TextBlock -Text "$($Subnet.Nics) NIC(s) sit in this subnet, so Azure refuses a range change; the NSG can still change." -Style 'Caption' -Margin '0,8,0,0'; $w.TextWrapping = 'Wrap'
        $null = $stack.Children.Add($w)
    }

    $buttons = [System.Windows.Controls.StackPanel]::new(); $buttons.Orientation = 'Horizontal'; $buttons.HorizontalAlignment = 'Right'; $buttons.Margin = ConvertTo-Thickness '0,18,0,0'
    foreach ($b in @(@{ Text = $(if ($Mode -eq 'Add') { 'Add subnet' } else { 'Save' }); Action = 'Run'; Style = 'PrimaryButton' }, @{ Text = 'Dry run (-WhatIf)'; Action = 'DryRun'; Style = '' })) {
        $btn = New-Button -Text $b.Text -Style $b.Style -Context @{ St = $st; Action = $b.Action } -OnClick {
            param($c)
            $x = $c.St
            Update-SubnetDialogHint $x
            if (-not $x.Ok) { return }
            $x.Result = @{ Action = $c.Action; Prefix = $x.Full; NsgId = (Get-ComboValue $x.Nsg); Name = $(if ($x.NameBox) { $x.NameBox.Text.Trim() } else { $x.Subnet.Name }) }
            $x.Dlg.DialogResult = $true
        }
        $st.Buttons += $btn
        $null = $buttons.Children.Add($btn)
    }
    $null = $buttons.Children.Add((New-Button -Text 'Cancel' -Style 'GhostButton' -Context $dlg -OnClick { param($d) $d.DialogResult = $false }))
    $null = $stack.Children.Add($buttons)
    $dlg.Content = $stack

    Update-SubnetDialogRange $st
    # A subnet that is not a /24 inside the pinned octets opens in manual entry.
    if ($current -and ($current -notlike '*/24' -or -not $current.StartsWith($st.Fixed.Text))) { $st.ManualBox.Text = $current; $st.Manual.IsChecked = $true }
    if ($st.NameBox) { $null = $st.NameBox.Focus(); $st.NameBox.CaretIndex = $st.NameBox.Text.Length }
    if ($dlg.ShowDialog()) { return $st.Result }
    return $null
}

function Get-SubnetDialogSpace {
    param([hashtable]$St)
    if ($St.ContainsKey('SpaceCombo')) { return (Get-ComboValue $St.SpaceCombo) }
    return $St.Ctx.Space[0]
}

function Update-SubnetDialogRange {
    # The dropdown: free /24s of the address space, the next one first (and, when
    # editing, the subnet's own range on top).
    param([hashtable]$St)
    $space = Get-SubnetDialogSpace $St
    $fixed = Get-SubnetFixedPart $space
    $St.Fixed.Text = $fixed
    $free = @(Get-NetFreeSubnetPrefix -AddressSpace @($space) -Used @($St.Ctx.Taken.Values) -PrefixLength 24 -All -Max 128)
    $opts = @($free | ForEach-Object { @{ Value = $_; Label = $_.Substring($fixed.Length) } })
    if ($St.Current -like '*/24' -and $St.Current.StartsWith($fixed)) {
        $opts = @(@{ Value = $St.Current; Label = "$($St.Current.Substring($fixed.Length))   (current)" }) + @($opts | Where-Object { $_.Value -ne $St.Current })
    }
    $St.NoFree = if ($opts.Count -eq 0) { "No free /24 left in $space. Use manual entry for a smaller range, or add address space to the network first." } else { '' }
    Add-ComboOption -Combo $St.Pick -Options $opts -Default ''
    if ($St.Pick.SelectedIndex -lt 0 -and $St.Pick.Items.Count -gt 0) { $St.Pick.SelectedIndex = 0 }
    if (-not $St.ManualBox.Text) { $St.ManualBox.Text = Get-ComboValue $St.Pick }
    Update-SubnetDialogHint $St
}

function Set-SubnetDialogManual {
    # Flip between the /24 dropdown and the typed range.
    param([hashtable]$St)
    $manual = [bool]$St.Manual.IsChecked
    $St.PickRow.Visibility = $(if ($manual) { 'Collapsed' } else { 'Visible' })
    $St.ManualBox.Visibility = $(if ($manual) { 'Visible' } else { 'Collapsed' })
    if ($manual) {
        if (-not $St.ManualBox.Text) { $St.ManualBox.Text = Get-ComboValue $St.Pick }
        $null = $St.ManualBox.Focus(); $St.ManualBox.CaretIndex = $St.ManualBox.Text.Length
    }
    Update-SubnetDialogHint $St
}

function Update-SubnetDialogHint {
    # Live check under the range; turns the buttons off while something is wrong.
    param([hashtable]$St)
    if (-not $St.Hint) { return }
    $manual = [bool]$St.Manual.IsChecked
    $full = if ($manual) { $St.ManualBox.Text.Trim() } else { Get-ComboValue $St.Pick }
    $problems = @()
    $nameMissing = $false
    if ($St.NameBox) {
        $n = $St.NameBox.Text.Trim()
        if ($n -in '', 'snet-') { $nameMissing = $true }
        elseif ($n -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,78}[A-Za-z0-9_]$') { $problems += 'Name: 2 to 80 letters, digits, dots, dashes or underscores, not ending in a dot or dash.' }
        elseif (@($St.Page.Subnets | ForEach-Object Name) -contains $n) { $problems += "A subnet named $n already exists." }
    }
    if (-not $full) { $problems += $(if (-not $manual -and $St.NoFree) { $St.NoFree } else { 'Type the whole range, for example 10.10.4.0/26.' }) }
    else { $problems += @(Test-NetSubnetPrefix -Prefix $full -AddressSpace $St.Ctx.Space -Existing $St.Ctx.Taken) }
    $St.Full = $full
    $St.Ok = ($problems.Count -eq 0 -and -not $nameMissing)
    foreach ($b in $St.Buttons) { $b.IsEnabled = $St.Ok }
    if ($problems.Count -eq 0) {
        # Range is fine; a name not typed yet is a next step, not an error.
        $len = [int](($full -split '/')[1]); $count = [math]::Pow(2, 32 - $len)
        $St.Hint.Text = "$full  ($count addresses, $($count - 5) usable; Azure keeps 5)" + $(if ($nameMissing) { '. Name the subnet to add it.' } else { '' })
        $St.Hint.Foreground = Get-ThemeResource $(if ($nameMissing) { 'Brush.TextSecondary' } else { 'Brush.Success' })
    } else {
        $St.Hint.Text = ($problems -join [Environment]::NewLine)
        $St.Hint.Foreground = Get-ThemeResource 'Brush.Error'
    }
}

function Invoke-NetworkSubnetAdd {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    $v = $Page.SelectedVNet
    if (-not $v) { Show-Message 'Select the virtual network to add the subnet to.' 'Add subnet' 'Warning'; return }
    $r = Show-SubnetDialog -Page $Page -Mode Add
    if (-not $r) { return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = $v.ResourceGroupName; VirtualNetworkName = $v.Name; Name = $r.Name; AddressPrefix = $r.Prefix }
    if ($r.NsgId) { $p.NetworkSecurityGroupId = $r.NsgId }
    Invoke-RepoScript -Name "Add subnet $($p.Name) to $($v.Name)" -Path $Gui.Scripts.NetSubnetNew -Params $p -DryRun:($r.Action -eq 'DryRun') -Context $Page -OnDone { param($result, $failure, $pg) Invoke-NetworkRefresh -Page $pg }
}

function Invoke-NetworkSubnetEdit {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    $v = $Page.SelectedVNet
    $sel = Get-GridSelection $Page.SubnetGrid
    if (-not $v -or $sel.Count -ne 1) { Show-Message 'Select a subnet first.' 'Edit subnet' 'Warning'; return }
    $s = $Page.Subnets | Where-Object Name -eq $sel[0].Name | Select-Object -First 1
    $r = Show-SubnetDialog -Page $Page -Mode Edit -Subnet $s
    if (-not $r) { return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = $v.ResourceGroupName; VirtualNetworkName = $v.Name; Name = $s.Name }
    if ($r.Prefix -and $r.Prefix -ne $s.AddressPrefix) { $p.AddressPrefix = $r.Prefix }
    if ($r.NsgId -and $r.NsgId -ne "$($s.NsgId)") { $p.NetworkSecurityGroupId = $r.NsgId }
    elseif (-not $r.NsgId -and $s.NsgId) { $p.DetachNetworkSecurityGroup = $true }
    if ($p.Count -eq 4) { Show-Message 'Nothing changed.' 'Edit subnet'; return }
    Invoke-RepoScript -Name "Update subnet $($s.Name)" -Path $Gui.Scripts.NetSubnetSet -Params $p -DryRun:($r.Action -eq 'DryRun') -Context $Page -OnDone { param($result, $failure, $pg) Invoke-NetworkRefresh -Page $pg }
}

function Invoke-NetworkVNetCreate {
    param([hashtable]$Page, [switch]$DryRun)
    if (-not (Test-SignedIn)) { return }
    if (-not (Test-FormRequired $Page.Form -Only @('NewRg', 'NewName', 'NewPrefix', 'NewSubnetName', 'NewSubnetPrefix'))) { return }
    $f = $Page.Form
    $p = @{
        SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = (Get-FormValue $f 'NewRg'); Name = (Get-FormValue $f 'NewName')
        AddressPrefix = @((Get-FormValue $f 'NewPrefix') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        SubnetName = (Get-FormValue $f 'NewSubnetName'); SubnetPrefix = (Get-FormValue $f 'NewSubnetPrefix')
    }
    $dns = Get-FormValue $f 'NewDns'
    if ($dns) { $p.DnsServer = @($dns -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    Invoke-RepoScript -Name "Create network $($p.Name)" -Path $Gui.Scripts.NetVNetNew -Params $p -DryRun:$DryRun -Context $Page -OnDone { param($result, $failure, $pg) Invoke-NetworkRefresh -Page $pg }
}

function Invoke-NetworkNsgCreate {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    if (-not (Test-FormRequired $Page.Form -Only @('NsgRg', 'NsgName'))) { return }
    $p = @{ SubscriptionId = $Gui.State.SubscriptionId; ResourceGroupName = (Get-FormValue $Page.Form 'NsgRg'); Name = (Get-FormValue $Page.Form 'NsgName') }
    Invoke-RepoScript -Name "Create NSG $($p.Name)" -Path $Gui.Scripts.NetNsgNew -Params $p -Context $Page -OnDone { param($result, $failure, $pg) Invoke-NetworkRefresh -Page $pg }
}

# --- Permissions ------------------------------------------------------------
function New-PermissionsPage {
    $page = @{ Key = 'NavPermissions'; Form = New-Form }
    $root = New-PageRoot -Title 'Permissions' -Lead 'What this account can and cannot do for an AVD build, before anything is created. Rows with Required True and Granted False will fail the build.'
    $null = $root.Children.Add((New-FormSection -Form $page.Form -Title 'Check against' -Fields @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group (optional)'; Help = 'If it exists, roles on the group count too.' }
        @{ Name = 'IncludeBackup'; Label = 'Include Recovery Services'; Type = 'check'; Default = $false }
    )))
    $page.Grid = New-DataGrid -Height 360
    $null = $root.Children.Add((New-TableCard -Title 'Permissions' -Grid $page.Grid -Tools @(
        (New-ToolButton -Text 'Check again' -Context $page -OnClick { param($pg) Invoke-PermissionCheck -Page $pg }))))
    $page.OnShow = {
        param($pg)
        if (-not $Gui.State.Account -or $Gui.State.Busy) { return }
        if ($Gui.State.Pool -and -not (Get-FormValue $pg.Form 'ResourceGroupName')) { $pg.Form.Controls['ResourceGroupName'].Text = $Gui.State.Pool.ResourceGroupName }
        Invoke-PermissionCheck -Page $pg
    }
    $page.Root = $root
    return $page
}

function Invoke-PermissionCheck {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    $arg = @{ SubscriptionId = $Gui.State.SubscriptionId; IncludeBackup = (Get-FormValue $Page.Form 'IncludeBackup') }
    $rg = Get-FormValue $Page.Form 'ResourceGroupName'
    if ($rg) { $arg.ResourceGroupName = $rg }
    Start-Work -Name 'Check permissions' -Argument $arg -Context $Page -Script {
        param($Job)
        $ErrorActionPreference = 'Stop'
        $p = @{ SubscriptionId = $Job.SubscriptionId; IncludeBackup = $Job.IncludeBackup }
        if ($Job.ContainsKey('ResourceGroupName')) { $p.ResourceGroupName = $Job.ResourceGroupName }
        Test-AvdBuildPermission @p
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $rows = @($result)
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows $rows -Columns @('Area', 'Capability', 'Granted', 'Required', 'Scope', 'FixWith')).DefaultView
        $missing = @($rows | Where-Object { $_.Required -and $_.Granted -eq $false })
        if ($missing.Count -gt 0) { Write-GuiLog "$($missing.Count) required permission(s) missing. See the FixWith column." 'warn' }
        else { Write-GuiLog 'All required permissions present.' 'ok' }
    }
}

# --- Host pools -------------------------------------------------------------
#   WHAT   Every host pool in the subscription with host and session counts; the
#          row menu makes one the current pool and jumps to its pages.
function New-HostPoolsPage {
    $page = @{ Key = 'NavHostPools'; Pools = @() }
    $root = New-PageRoot -Title 'Host pools' -Lead 'Every host pool in the subscription. Double-click one, or use its menu, to make it the current pool; the other Cloud desktops pages work on that pool.'
    $page.Grid = New-DataGrid -Height 380
    $page.Grid.SelectionMode = 'Single'
    Add-ControlHandler -Control $page.Grid -EventName DoubleClick -Context $page -Handler { param($pg) Select-HostPoolFromRow -Page $pg -Then 'NavOverview' }
    $actions = @(
        @{ Text = 'Use this pool';  Context = @{ Page = $page; Then = '' };              Handler = { param($c) Select-HostPoolFromRow -Page $c.Page -Then $c.Then } }
        @{ Separator = $true }
        @{ Text = 'Home';           Context = @{ Page = $page; Then = 'NavOverview' };   Handler = { param($c) Select-HostPoolFromRow -Page $c.Page -Then $c.Then } }
        @{ Text = 'Session hosts';  Context = @{ Page = $page; Then = 'NavHosts' };      Handler = { param($c) Select-HostPoolFromRow -Page $c.Page -Then $c.Then } }
        @{ Text = 'User sessions';  Context = @{ Page = $page; Then = 'NavSessions' };   Handler = { param($c) Select-HostPoolFromRow -Page $c.Page -Then $c.Then } }
        @{ Text = 'Autoscale';      Context = @{ Page = $page; Then = 'NavAutoscale' };  Handler = { param($c) Select-HostPoolFromRow -Page $c.Page -Then $c.Then } }
        @{ Separator = $true }
        @{ Text = 'Add a host';     Context = @{ Page = $page; Then = 'NavAddHost' };    Handler = { param($c) Select-HostPoolFromRow -Page $c.Page -Then $c.Then } }
        @{ Text = 'Profile storage'; Context = @{ Page = $page; Then = 'NavStorage' };   Handler = { param($c) Select-HostPoolFromRow -Page $c.Page -Then $c.Then } }
    )
    Set-GridRowMenu -Grid $page.Grid -Items $actions
    $null = $root.Children.Add((New-TableCard -Title 'Host pools' -Grid $page.Grid -Tools @(
        (New-ToolButton -Text 'Refresh' -Context $page -OnClick { param($pg) Invoke-HostPoolsRefresh -Page $pg }),
        (New-ToolButton -Text 'New environment' -OnClick { Show-Page 'NavBuild' } -ToolTip 'Build a new host pool with the wizard'),
        (New-MenuButton -Items $actions))))
    $page.OnShow = { param($pg) if ($Gui.State.Account -and -not $Gui.State.Busy) { Invoke-HostPoolsRefresh -Page $pg } }
    $page.Root = $root
    return $page
}

function Invoke-HostPoolsRefresh {
    param([hashtable]$Page)
    if (-not (Test-SignedIn)) { return }
    Start-Work -Name 'List host pools' -Context $Page -Script {
        $ErrorActionPreference = 'Stop'
        Get-AzWvdHostPool | Sort-Object Name | ForEach-Object {
            $rg = ($_.Id -split '/')[4]
            $hosts = @(Get-AzWvdSessionHost -ResourceGroupName $rg -HostPoolName $_.Name -ErrorAction SilentlyContinue)
            [pscustomobject]@{
                Name = $_.Name; ResourceGroup = $rg; Type = "$($_.HostPoolType)"; Location = $_.Location
                Hosts = $hosts.Count
                Available = @($hosts | Where-Object Status -eq 'Available').Count
                Sessions = [int](($hosts | Measure-Object -Property Session -Sum).Sum ?? 0)
                LoadBalancing = "$($_.LoadBalancerType)"; MaxSessions = $_.MaxSessionLimit
                StartVmOnConnect = "$($_.StartVMOnConnect)"
            }
        }
    } -OnDone {
        param($result, $failure, $pg)
        if ($failure) { return }
        $pg.Pools = @($result)
        $pg.Grid.ItemsSource = (ConvertTo-DataTable -Rows $pg.Pools -Columns @('Name', 'ResourceGroup', 'Type', 'Location', 'Hosts', 'Available', 'Sessions', 'LoadBalancing', 'MaxSessions', 'StartVmOnConnect')).DefaultView
        if ($pg.Pools.Count -eq 0) { Write-GuiLog 'No host pools in this subscription yet. Build one on the New environment page.' 'warn' }
    }
}

function Select-HostPoolFromRow {
    # The hidden PoolCombo is the one source of "current pool": pick its matching item and let its event do the rest.
    param([hashtable]$Page, [string]$Then)
    $sel = Get-GridSelection $Page.Grid
    if ($sel.Count -ne 1) { Show-Message 'Select one host pool.' 'Host pools' 'Warning'; return }
    $prefix = "$($sel[0].ResourceGroup)|$($sel[0].Name)|"
    $item = $Gui.Ui.PoolCombo.Items | Where-Object { "$($_.Tag)".StartsWith($prefix) } | Select-Object -First 1
    if (-not $item) { Write-GuiLog "The pool list does not have $($sel[0].Name) yet; refreshing it." 'warn'; Update-HostPoolList; return }
    if ($Gui.Ui.PoolCombo.SelectedItem -ne $item) { $Gui.Ui.PoolCombo.SelectedItem = $item }   # fires Set-PoolFromCombo
    if ($Then) { Show-Page $Then }
}

# --- Placeholders -------------------------------------------------------------
#   WHAT   A page for every console area this toolbox does not cover, saying so,
#          with the portal page that does the job and the nearest page here.
#   WHY    The rail mirrors a full management console so the layout is familiar;
#          an honest "not built" beats a missing entry or a page that pretends.
function New-PlaceholderPage {
    param([string]$Key, [string]$Title, [string]$Text, [string]$Portal, [string]$See, [string]$SeeText)
    $page = @{ Key = $Key }
    $root = New-PageRoot -Title $Title -Lead 'Not built yet.'
    $card = New-Card -Title 'A management console has this page. This toolbox does not, yet.'
    $t = New-TextBlock -Text $Text -Style 'Muted' -Margin '0,0,0,12'; $t.TextWrapping = 'Wrap'
    $null = $card.Child.Children.Add($t)
    $buttons = @()
    if ($Portal) { $buttons += New-Button -Text 'Open in the portal' -Style 'PrimaryButton' -Context $Portal -OnClick { param($u) Start-Process $u } -ToolTip $Portal }
    if ($See)    { $buttons += New-Button -Text $(if ($SeeText) { $SeeText } else { 'Nearest page here' }) -Style 'GhostButton' -Context $See -OnClick { param($k) Show-Page $k } }
    if ($buttons.Count -gt 0) { $null = $card.Child.Children.Add((New-ButtonRow -Buttons $buttons)) }
    $null = $root.Children.Add($card)
    $page.Root = $root
    return $page
}

# --- All features -------------------------------------------------------------
#   WHAT   Every page as a link, grouped like the rail. The top-bar search filters it.
function New-AllFeaturesPage {
    $page = @{ Key = 'NavAll'; Local = $true }   # Local: needs no Azure call, so it loads even while a job runs
    $root = New-PageRoot -Title 'All features' -Lead 'Every page, grouped as the rail groups them. Type in the search box at the top to filter.'
    $page.Body = [System.Windows.Controls.WrapPanel]::new()
    $null = $root.Children.Add($page.Body)
    $page.OnShow = { param($pg) Update-AllFeatureList -Page $pg }
    $page.Root = $root
    return $page
}

function Update-AllFeatureList {
    param([hashtable]$Page)
    $filter = $Gui.Ui.SearchBox.Text.Trim()
    $Page.Body.Children.Clear()
    foreach ($section in $Gui.NavTree) {
        $card = New-Card -Title $section.Label
        $card.Width = 280; $card.Margin = ConvertTo-Thickness '0,0,16,16'; $card.VerticalAlignment = 'Top'
        $any = $false
        foreach ($group in $section.Groups) {
            $hits = @($group.Items | Where-Object { -not $filter -or "$($section.Label) $($group.Label) $($_.Label)" -match [regex]::Escape($filter) })
            if ($hits.Count -eq 0) { continue }
            $any = $true
            if ($group.Label) { $null = $card.Child.Children.Add((New-TextBlock -Text $group.Label -Style 'SectionGroupLabel' -Margin '0,8,0,2')) }
            foreach ($item in $hits) {
                $b = New-Button -Text $item.Label -Style 'LinkButton' -Context $item.Key -OnClick { param($k) Show-Page $k }
                if ($item.ContainsKey('Placeholder')) { $b.Foreground = Get-ThemeResource 'Brush.Neutral'; $b.ToolTip = 'Not built yet' }
                $null = $card.Child.Children.Add($b)
            }
        }
        if ($any) { $null = $Page.Body.Children.Add($card) }
    }
    if ($Page.Body.Children.Count -eq 0) { $null = $Page.Body.Children.Add((New-TextBlock -Text "Nothing matches '$filter'." -Style 'Muted')) }
}

# --- Page files -------------------------------------------------------------
#   WHAT   The newer wings (Entra, images, files and backup, network services,
#          applications, scripting, insights, FinOps, settings) live in
#          gui/pages/<Area>.ps1. Dot-sourcing puts their functions in this
#          script's scope, exactly as if they were written above.
#   WHY    One 3000-line file was getting hard to read. Same rules apply inside
#          them: no closures, no $script: variables, handlers take their context
#          from the sender's Tag. The tests read them together with this file.
foreach ($pageFile in Get-ChildItem -Path (Join-Path $Gui.GuiDir 'pages') -Filter '*.ps1' | Sort-Object Name) { . $pageFile.FullName }

#endregion

#region 8. Navigation and run -------------------------------------------------
#   WHAT   The rail (one button per section), the section panel (that section's
#          groups and links), the All features page and search, the menu toggle;
#          then window show and clean shutdown.
#   WHY    The sections mirror a full management console so the layout is familiar;
#          an entry the toolbox has no page for opens an honest placeholder that
#          links to the portal and to the nearest page here. Pages are built on
#          first visit so start-up is instant, and kept so a half-filled form
#          survives a trip to another page.
#   GOTCHA Rail and section buttons keep Tag for the active-state style, so their
#          key rides on Name, like the old sidebar did.
$Gui.NavTree = @(
    @{ Key = 'Insights'; Label = 'Insights'; Groups = @(
        @{ Label = ''; Items = @(
            @{ Label = 'Home'; Key = 'NavOverview'; Builder = 'New-OverviewPage' }
        ) }
        @{ Label = 'Dashboards'; Items = @(
            @{ Label = 'AVD'; Key = 'NavDashboardAvd'; Builder = 'New-AvdDashboardPage' }
        ) }
        @{ Label = 'Reporting'; Items = @(
            @{ Label = 'Report summary'; Key = 'NavReports'; Builder = 'New-ReportsPage' }
        ) }
    ) }
    @{ Key = 'Entra'; Label = 'Entra'; Groups = @(
        @{ Label = ''; Items = @(
            @{ Label = 'Users';        Key = 'NavEntraUsers';    Builder = 'New-EntraUsersPage' }
            @{ Label = 'Groups';       Key = 'NavEntraGroups';   Builder = 'New-EntraGroupsPage' }
            @{ Label = 'Add user';     Key = 'NavEntraAddUser';  Builder = 'New-EntraAddUserPage' }
            @{ Label = 'Add group';    Key = 'NavEntraAddGroup'; Builder = 'New-EntraAddGroupPage' }
            @{ Label = 'User actions'; Key = 'NavEntraActions';  Builder = 'New-EntraUserActionsPage' }
        ) }
    ) }
    @{ Key = 'Desktops'; Label = 'Cloud desktops'; Groups = @(
        @{ Label = 'AVD'; Items = @(
            @{ Label = 'Host pools';      Key = 'NavHostPools'; Builder = 'New-HostPoolsPage' }
            @{ Label = 'Session hosts';   Key = 'NavHosts';     Builder = 'New-HostsPage' }
            @{ Label = 'User sessions';   Key = 'NavSessions';  Builder = 'New-SessionsPage' }
            @{ Label = 'Autoscale';       Key = 'NavAutoscale'; Builder = 'New-AutoscalePage' }
            @{ Label = 'Desktop images';  Key = 'NavImages';    Builder = 'New-DesktopImagesPage' }
        ) }
        @{ Label = 'Build'; Items = @(
            @{ Label = 'New environment'; Key = 'NavBuild';   Builder = 'New-BuildPage' }
            @{ Label = 'Add a host';      Key = 'NavAddHost'; Builder = 'New-AddHostPage' }
            @{ Label = 'Profile storage'; Key = 'NavStorage'; Builder = 'New-StoragePage' }
            @{ Label = 'Pool backup';     Key = 'NavBackup';  Builder = 'New-BackupPage' }
        ) }
        @{ Label = 'Windows 365'; Items = @(
            @{ Label = 'Desktop images'; Key = 'NavW365Images'; Builder = 'New-W365ImagesPage' }
        ) }
    ) }
    @{ Key = 'Azure'; Label = 'Azure'; Groups = @(
        @{ Label = 'Servers'; Items = @(
            @{ Label = 'List';   Key = 'NavServers';   Builder = 'New-ServersPage' }
            @{ Label = 'Add';    Key = 'NavNewServer'; Builder = 'New-NewServerPage' }
            @{ Label = 'Backup and restore'; Key = 'NavServerBackup'; Builder = 'New-ServerBackupPage' }
        ) }
        @{ Label = 'Azure Files'; Items = @(
            @{ Label = 'List'; Key = 'NavFilesList'; Builder = 'New-FilesListPage' }
            @{ Label = 'Add';  Key = 'NavFilesAdd';  Builder = 'New-FilesAddPage' }
            @{ Label = 'Backup and restore'; Key = 'NavFilesBackup'; Builder = 'New-FilesBackupPage' }
        ) }
        @{ Label = 'Network'; Items = @(
            @{ Label = 'Virtual networks'; Key = 'NavNetwork'; Builder = 'New-NetworkPage' }
            @{ Label = 'NSGs';           Key = 'NavNsg';     Builder = 'New-NsgPage' }
            @{ Label = 'VPN';            Key = 'NavVpn';     Builder = 'New-VpnPage' }
            @{ Label = 'Public IPs';     Key = 'NavPip';     Builder = 'New-PublicIpPage' }
            @{ Label = 'NAT gateways';   Key = 'NavNat';     Builder = 'New-NatPage' }
        ) }
    ) }
    @{ Key = 'Policies'; Label = 'Policies'; Groups = @(
        @{ Label = ''; Items = @(
            @{ Label = 'Backup'; Key = 'NavBackupPolicy'; Builder = 'New-BackupPolicyPage' }
        ) }
    ) }
    @{ Key = 'Apps'; Label = 'Applications'; Groups = @(
        @{ Label = 'Winget'; Items = @(
            @{ Label = 'Unified catalog'; Key = 'NavWinget';    Builder = 'New-WingetPage' }
            @{ Label = 'App groups';      Key = 'NavAppGroups'; Builder = 'New-AppGroupsPage' }
        ) }
        @{ Label = ''; Items = @(
            @{ Label = 'Shell apps';      Key = 'NavShellApps'; Builder = 'New-ShellAppsPage' }
            @{ Label = 'Certificates';    Key = 'NavCerts';     Builder = 'New-CertificatesPage' }
            @{ Label = 'MSIX app attach'; Key = 'NavMsix';      Builder = 'New-MsixPage' }
        ) }
        @{ Label = 'Deployments'; Items = @(
            @{ Label = 'Policies'; Key = 'NavDeployPolicies'; Builder = 'New-DeploymentsPage' }
            @{ Label = 'Status';   Key = 'NavDeployStatus';   Builder = 'New-DeploymentStatusPage' }
        ) }
    ) }
    @{ Key = 'Scripting'; Label = 'Scripting'; Groups = @(
        @{ Label = 'Windows scripts'; Items = @(
            @{ Label = 'Scripts'; Key = 'NavScripts';      Builder = 'New-WindowsScriptsPage' }
            @{ Label = 'Groups';  Key = 'NavScriptGroups'; Builder = 'New-ScriptGroupsPage' }
        ) }
        @{ Label = 'Azure runbooks'; Items = @(
            @{ Label = 'Runbooks'; Key = 'NavRunbooks';      Builder = 'New-RunbooksPage' }
            @{ Label = 'Groups';   Key = 'NavRunbookGroups'; Builder = 'New-RunbookGroupsPage' }
        ) }
    ) }
    @{ Key = 'FinOps'; Label = 'FinOps'; Groups = @(
        @{ Label = ''; Items = @(
            @{ Label = 'Cost management';       Key = 'NavCosts';    Builder = 'New-CostPage' }
            @{ Label = 'Estimated vs deployed'; Key = 'NavCostDiff'; Builder = 'New-CostComparisonPage' }
        ) }
    ) }
    @{ Key = 'Settings'; Label = 'Settings'; Groups = @(
        @{ Label = ''; Items = @(
            @{ Label = 'Permissions';  Key = 'NavPermissions'; Builder = 'New-PermissionsPage' }
            @{ Label = 'Integrations'; Key = 'NavIntegrations'; Builder = 'New-IntegrationsPage' }
            @{ Label = 'Azure portal'; Key = 'NavPortal'; Builder = 'New-PortalPage' }
            @{ Label = 'Logs';         Key = 'NavLogs'; Builder = 'New-LogsPage' }
        ) }
    ) }
)

# Page builders and the page -> section index come from the tree.
$Gui.PageBuilders = @{ NavAll = @{ Builder = 'New-AllFeaturesPage'; Args = @{} } }
$Gui.NavIndex = @{ NavAll = 'All' }
foreach ($section in $Gui.NavTree) {
    foreach ($group in $section.Groups) {
        foreach ($item in $group.Items) {
            $Gui.NavIndex[$item.Key] = $section.Key
            if ($item.ContainsKey('Placeholder')) {
                $a = @{ Key = $item.Key } + $item.Placeholder
                $Gui.PageBuilders[$item.Key] = @{ Builder = 'New-PlaceholderPage'; Args = $a }
            } else {
                $Gui.PageBuilders[$item.Key] = @{ Builder = $item.Builder; Args = @{} }
            }
        }
    }
}

function Get-NavSection {
    param([string]$Key)
    return ($Gui.NavTree | Where-Object Key -eq $Key | Select-Object -First 1)
}

function Update-SectionPanel {
    # Rebuild the second-level panel for a section and mark the current page in it.
    param([string]$SectionKey, [string]$PageKey)
    $items = $Gui.Ui.SectionItems
    $items.Children.Clear()
    if ($SectionKey -eq 'All') {
        $Gui.Ui.SectionTitle.Text = 'All features'
        foreach ($section in $Gui.NavTree) {
            $b = New-Button -Text $section.Label -Style 'SectionItemButton' -Context $section.Key -OnClick { param($k) Show-Section $k }
            $null = $items.Children.Add($b)
        }
        return
    }
    $section = Get-NavSection $SectionKey
    $Gui.Ui.SectionTitle.Text = $section.Label
    foreach ($group in $section.Groups) {
        if ($group.Label) { $null = $items.Children.Add((New-TextBlock -Text $group.Label -Style 'SectionGroupLabel')) }
        foreach ($item in $group.Items) {
            $b = [System.Windows.Controls.Button]::new()
            $b.Content = $item.Label; $b.Name = $item.Key; $b.Style = Get-ThemeResource 'SectionItemButton'
            if ($item.ContainsKey('Placeholder')) { $b.ToolTip = 'Not built yet'; $b.Opacity = 0.7 }
            if ($item.Key -eq $PageKey) { $b.Tag = 'active' }
            $b.Add_Click({ Invoke-Guarded { param($k) Show-Page $k } $this.Name })
            $null = $items.Children.Add($b)
        }
    }
}

function Show-Section {
    # Rail click: the section's first page.
    param([string]$Key)
    $section = Get-NavSection $Key
    Show-Page $section.Groups[0].Items[0].Key
}

function Show-Page {
    param([string]$Key)
    if (-not $Gui.PageBuilders.ContainsKey($Key)) { throw "No page named '$Key'." }
    if (-not $Gui.Pages.ContainsKey($Key)) {
        $b = $Gui.PageBuilders[$Key]; $a = $b.Args
        $Gui.Pages[$Key] = & $b.Builder @a
    }
    $page = $Gui.Pages[$Key]
    $Gui.Ui.PageHost.Content = $page.Root
    $Gui.State.PageKey = $Key
    $sectionKey = $Gui.NavIndex[$Key]
    $Gui.State.SectionKey = $sectionKey
    foreach ($rb in @($Gui.Ui.Rail.Children | Where-Object { $_ -is [System.Windows.Controls.Button] })) {
        $rb.Tag = $(if ($rb.Name -eq "Rail$sectionKey") { 'active' } else { '' })
    }
    Update-SectionPanel -SectionKey $sectionKey -PageKey $Key
    if ($page.ContainsKey('OnShow')) {
        # A page opened while a job runs loads as soon as that job finishes (see Complete-Work),
        # unless it is local to the window and needs no worker.
        $local = $page.ContainsKey('Local') -and $page.Local
        if ($Gui.State.Busy -and -not $local) { $Gui.PendingShow = $Key } else { if (-not $local) { $Gui.PendingShow = $null }; & $page.OnShow $page }
    }
}

# Rail: All features (from the XAML) then one button per section.
$Gui.Ui.RailAll.Add_Click({ Invoke-Guarded { Show-Page 'NavAll' } })
foreach ($section in $Gui.NavTree) {
    $b = [System.Windows.Controls.Button]::new()
    $b.Content = $section.Label; $b.Name = "Rail$($section.Key)"; $b.Style = Get-ThemeResource 'RailButton'
    $b.Add_Click({ Invoke-Guarded { param($k) Show-Section $k } $this.Name.Substring(4) })
    $null = $Gui.Ui.Rail.Children.Add($b)
}

# Mouse wheel over a grid or a text box scrolls the page.
#   GOTCHA Every DataGrid and TextBox carries its own ScrollViewer, and a
#          ScrollViewer marks the wheel event handled even when it has nothing to
#          scroll, so the page never moved while the pointer was over a table or a
#          field. The page's ScrollViewer sees the wheel first (Preview, tunnelling):
#          if a viewer under the pointer can still scroll that way it gets the wheel,
#          otherwise the page scrolls. A long grid scrolls itself, then hands over at
#          its end, the way a browser does.
function Send-PageWheel {
    param($Outer, $WheelEvent)
    $up = $WheelEvent.Delta -gt 0
    $d = $WheelEvent.OriginalSource
    while ($d -and $d -ne $Outer) {
        if ($d -is [System.Windows.Controls.ScrollViewer] -and $d.ScrollableHeight -gt 0) {
            if (($up -and $d.VerticalOffset -gt 0) -or (-not $up -and $d.VerticalOffset -lt $d.ScrollableHeight)) { return }
        }
        $d = if ($d -is [System.Windows.Media.Visual]) { [System.Windows.Media.VisualTreeHelper]::GetParent($d) }
             elseif ($d -is [System.Windows.FrameworkContentElement]) { $d.Parent }
             else { $null }
    }
    $Outer.ScrollToVerticalOffset($Outer.VerticalOffset - ($WheelEvent.Delta * 0.4))
    $WheelEvent.Handled = $true
}
$Gui.Ui.PageScroll.Add_PreviewMouseWheel({ $wheel = $args[1]; Invoke-Guarded { param($c) Send-PageWheel -Outer $c.Outer -WheelEvent $c.Wheel } @{ Outer = $this; Wheel = $wheel } })

# Menu toggle hides the section panel so a wide grid gets the room.
$Gui.Ui.MenuToggle.Add_Click({ Invoke-Guarded {
    $open = $Gui.Ui.SectionPanel.Visibility -eq 'Visible'
    $Gui.Ui.SectionPanel.Visibility = $(if ($open) { 'Collapsed' } else { 'Visible' })
    $Gui.Ui.SectionColumn.Width = $(if ($open) { [System.Windows.GridLength]::new(0) } else { [System.Windows.GridLength]::new(250) })
} })

# Search filters the All features page, opening it if needed.
$Gui.Ui.SearchBox.Add_TextChanged({ Invoke-Guarded {
    if ($Gui.State.PageKey -ne 'NavAll') { Show-Page 'NavAll' } else { Update-AllFeatureList -Page $Gui.Pages['NavAll'] }
} })
$Gui.Ui.SearchBox.Add_KeyDown({ if ($args[1].Key -eq 'Escape') { $this.Clear() } })

Show-Page 'NavOverview'
Set-PageEnabled $true
Write-GuiLog "Worker ready: $($loaded -join ', ')." 'verbose'
if ($saved) { Write-GuiLog "Last time: $($saved.account), subscription '$($saved.subscriptionName)'. Signing in with that; use the account menu (top right) for a different one." 'info' }
else { Write-GuiLog 'Signing in. A browser window opens if there is no current session.' 'info' }
# Sign in straight away; the window shows while the worker does it, and the timer completes it.
Start-SignIn -TenantId $Gui.State.TenantId -SubscriptionId $Gui.State.SubscriptionId

$Gui.Window.Add_Closed({
    $Gui.Timer.Stop()
    if ($Gui.Job) { try { $Gui.Job.Ps.Stop() } catch { Write-Verbose 'Job stop: ignored.' } }
    $Gui.Worker.Close(); $Gui.Worker.Dispose()
})
$null = $Gui.Window.ShowDialog()
#endregion
