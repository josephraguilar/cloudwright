# Fresh-process regression probe. Deliberately NO try/catch around the tested call:
# a catch changes PowerShell's error-preference semantics and masks the old bypass.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$Kind,
    [Parameter(Mandatory)][string]$Target,
    [Parameter(Mandatory)][string]$Vector,
    [Parameter(Mandatory)][string]$Scratch
)
$ErrorActionPreference = 'Stop'
$ConfirmPreference = 'None'
$env:PSModulePath = (Join-Path $Scratch 'modules') + [IO.Path]::PathSeparator + (Join-Path $PSHOME 'Modules')
$env:M365_TOOLKIT_LOG_PATH = Join-Path $Scratch 'logs'

# No production SDK is discoverable. Calls to these network, sign-in, browser, or
# write fakes terminate the child process with a distinct canary. Environment.Exit
# is required: PowerShell can swallow ordinary exit inside a breakpoint or nested script.
foreach ($name in 'Invoke-RestMethod', 'Invoke-WebRequest', 'Start-Process', 'Connect-ExchangeOnline', 'Remove-CloudwrightCanary', 'Invoke-CloudwrightCanary') {
    Set-Item "function:global:$name" { [Console]::WriteLine('SIDE-EFFECT-CANARY'); [Environment]::Exit(91) }
}
function global:Connect-MgGraph {
    if ($Kind -ne 'LearnGraph') { [Console]::WriteLine('SIGN-IN-CANARY'); [Environment]::Exit(92) }
}
function global:Disconnect-MgGraph { }
function global:Get-MgContext {
    [pscustomobject]@{ TenantId = 'aaaaaaaa-0000-0000-0000-000000000001'; AuthType = 'Delegated'; ContextScope = 'Process'; Scopes = @('Directory.ReadWrite.All') }
}

function Get-ProbeArguments {
    param($Path)
    $command = Get-Command $Path
    $set = @($command.ParameterSets | Where-Object IsDefault | Select-Object -First 1)
    if (-not $set.Count) { $set = @($command.ParameterSets | Select-Object -First 1) }
    $values = @{}
    foreach ($p in $set[0].Parameters | Where-Object IsMandatory) {
        $attributes = $command.Parameters[$p.Name].Attributes
        $valid = @($attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object ValidValues)
        $range = @($attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] })
        $values[$p.Name] = if ($p.ParameterType -eq [pscredential]) {
            [pscredential]::new('fixture', (ConvertTo-SecureString 'Fixture-only-password1!' -AsPlainText -Force))
        } elseif ($p.ParameterType -eq [securestring]) { ConvertTo-SecureString 'Fixture-only-password1!' -AsPlainText -Force
        } elseif ($valid.Count) { $valid[0]
        } elseif ($p.ParameterType -eq [switch]) { $true
        } elseif ($p.ParameterType -eq [int]) { if ($range.Count) { $range[0].MinRange } else { 1 }
        } else { 'fixture' }
    }
    if ($command.Parameters.ContainsKey('Path')) { $values.Path = $Scratch }
    if ($command.Parameters.ContainsKey('Confirm')) { $values.Confirm = $false }
    return $values
}

$arguments = @{}
$path = Join-Path $Repository $Target
if ($Kind -in 'AzureScript', 'AzureModule', 'M365Script') {
    $codePath = $path
    if ($Kind -eq 'AzureModule' -and [IO.Path]::GetExtension($path) -eq '.psd1') {
        $definition = Import-PowerShellDataFile $path
        $codePath = Join-Path (Split-Path $path) $definition.RootModule
    }
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($codePath, [ref]$null, [ref]$null)
    $statements = @($ast.EndBlock.Statements)
    $after = 1
    if ($Kind -eq 'M365Script') {
        $guard = @($statements | Where-Object { $_.Extent.Text -eq 'Assert-M365WriteAllowed' })
        if ($guard.Count -ne 1) { throw 'Probe requires exactly one entry guard.' }
        $after = [array]::IndexOf($statements, $guard[0]) + 1
    }
    # If the refusal regresses, terminate the process at the next statement, with
    # a failing marker. Function-definition-only GUI pages use the caller marker.
    # Run adversarial probes without network access; this is not a PowerShell sandbox.
    $null = Set-PSBreakpoint -Script $codePath -Line $statements[$after].Extent.StartLineNumber -Action {
        [Console]::WriteLine('BODY-CANARY'); [Environment]::Exit(93)
    }
    if ($Kind -ne 'AzureModule') { $arguments = Get-ProbeArguments $path }
} elseif ($Kind -like 'M365*') {
    $modules = Join-Path $Repository 'm365/scripts/powershell/modules'
    Import-Module (Join-Path $modules 'M365Helpers/M365Helpers.psd1') -Force
    Import-Module (Join-Path $modules 'ToolkitHelpers/ToolkitHelpers.psd1') -Force
    Import-Module (Join-Path $modules 'GdapHelpers/GdapHelpers.psd1') -Force
    Set-M365ChangeTarget -Service Exchange -Label 'fixture.example'
} elseif ($Kind -like 'Learn*') {
    Import-Module (Join-Path $Repository 'learn/src/MsScripter/MsScripter.psd1') -Force
    if ($Kind -eq 'LearnGenerate') { $task = Get-MsTask entra.apps.new-app-registration }
} elseif ($Kind -eq 'Launcher') {
    Import-Module (Join-Path $Repository 'Cloudwright.psd1') -Force
}

$common = @{}
# Setup uses Stop; the tested invocation starts with PowerShell's normal Continue.
# Set both scopes so a script-local setup preference cannot mask a global vector.
$ErrorActionPreference = $global:ErrorActionPreference = 'Continue'
switch ($Vector) {
    'CommonSC' { $common.ErrorAction = 'SilentlyContinue' }
    'CommonIgnore' { $common.ErrorAction = 'Ignore' }
    'CommonInquire' { $common.ErrorAction = 'Inquire' }
    'GlobalSC' { $ErrorActionPreference = $global:ErrorActionPreference = 'SilentlyContinue' }
    'GlobalIgnore' { $ErrorActionPreference = $global:ErrorActionPreference = 'Ignore' }
    'DefaultSC' { $global:PSDefaultParameterValues['*:ErrorAction'] = 'SilentlyContinue' }
    'DefaultIgnore' { $global:PSDefaultParameterValues['*:ErrorAction'] = 'Ignore' }
    'DotSC' { $ErrorActionPreference = $global:ErrorActionPreference = 'SilentlyContinue' }
    'DotIgnore' { $ErrorActionPreference = $global:ErrorActionPreference = 'Ignore' }
}
$Error.Clear()

switch ($Kind) {
    { $_ -in 'AzureScript', 'M365Script' } {
        if ($Vector -like 'Dot*') { . $path @arguments } else { & $path @arguments @common }
    }
    'AzureModule' {
        Import-Module $path -Force @common
        # Import-Module can suppress its caller-facing error while the module itself
        # terminates. In that case require the guard error AND absence of any exports.
        $name = [IO.Path]::GetFileNameWithoutExtension($path)
        $refused = @($Error | Where-Object { $_.Exception.Message -like '*Cloudwright safe release: Azure/AVD execution is disabled*' }).Count
        if ((Get-Module $name) -or (Get-Command -Module $name) -or -not $refused) {
            [Console]::WriteLine('IMPORT-CANARY'); exit 94
        }
        [Console]::WriteLine('IMPORT-REFUSED'); exit 0
    }
    'M365Change' { Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action 'fixture' -Command Invoke-CloudwrightCanary @common }
    'M365Guard' { Assert-M365WriteAllowed @common }
    'M365Graph' { Assert-M365Graph -TenantId 'aaaaaaaa-0000-0000-0000-000000000001' -Scopes User.ReadWrite.All @common }
    'M365Exchange' { Assert-M365Exchange -Organization 'aaaaaaaa-0000-0000-0000-000000000001' @common }
    'M365Scope' { & (Get-Module M365Helpers) { param($options) Assert-M365ReadOnlyScope -Scopes User.ReadWrite.All @options } $common }
    'M365Hudu' { & (Get-Module M365Helpers) { param($options) Invoke-M365HuduRequest -Method Post -Path '/fixture' @options } $common }
    'M365Password' { Add-HuduPassword -CompanyId 1 -Name 'fixture' -Username 'reader@fixture.example' -Password 'Fixture-only-password1!' @common }
    'M365Browser' { Open-GdapApprovalPage -Url 'https://admin.microsoft.com/' @common }
    'M365Command' { Assert-M365ReadOnlyCommand -Line "Write-Output 'not an allowed task'" @common }
    'LearnSource' { & (Get-Module MsScripter) { param($options) Resolve-MsSource -Source @{ Cmdlet = 'Remove-CloudwrightCanary' } -Answers @{} -Fields @() @options } $common }
    'LearnGraph' { & (Get-Module MsScripter) { param($options) Assert-MsGraphContext @options } $common }
    'LearnGenerate' { New-MsScript -Task $task -Answers @{ DisplayName = "app`nInvoke-CloudwrightCanary" } -WithRollback @common }
    'Launcher' { Start-Cloudwright -Area azure -Console @common }
    default { [Console]::WriteLine('UNKNOWN-PROBE'); exit 95 }
}
[Console]::WriteLine('CALLER-CONTINUED'); exit 96
