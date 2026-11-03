<#
.SYNOPSIS
    Interactive menu for the Microsoft 365 scripts in this repo. Pick a tenant, pick a task, review its changes, run it.
.DESCRIPTION
    Run it with no arguments. Pick a client config from config/clients (or our own tenant, or
    write a new client config by answering questions), then a task. Every task goes the same way:
      1. It asks for the task's parameters (client values pre-filled) and shows the exact
         command line.
      2. A task that changes something always gets a dry run first. The dry run lists every
         change it would make: the tenant, what changes in plain words, and the exact
         Exchange/Graph command. Nothing changes.
      3. You type yes to make exactly those changes. The run is limited to that list: a change
         that is not on it is refused before it runs.
    Read-only tasks run after a y/n and cannot change anything. No logic lives here: anything you
    can do from the menu you can do from the command line with the same script.
.PARAMETER Client
    Skip the client picker.
.EXAMPLE
    ./Start-M365Console.ps1
.NOTES
    Requires: whatever the script you pick requires (Microsoft.Graph, ExchangeOnlineManagement)
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
#   WHAT   Optional shortcut straight to a client.
#   WHY    Write-Host is normally flagged by PSScriptAnalyzer because it bypasses
#          the pipeline. A console that talks to a human is the one place it is
#          correct, so the rule is suppressed for this file only.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console. Output is for the operator, not the pipeline.')]
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Client
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
$scripts = $PSScriptRoot
Import-Module (Join-Path $scripts 'modules' 'M365Helpers' 'M365Helpers.psd1') -Force
Import-Module (Join-Path $scripts 'modules' 'ToolkitHelpers' 'ToolkitHelpers.psd1') -Force
try { $settings = Get-M365Settings } catch {
    if ($MyInvocation.InvocationName -ne '.') { throw "Setup has not been run on this machine. From the repo folder run: .\Start-Toolkit.ps1  ($($_.Exception.Message))" }
    $settings = $null
}
$script:Client = $null
$catalog = @(Get-M365Task)
#endregion

#region 3. Console helpers -------------------------------------------------------
#   WHAT   Select-Item (numbered picker), Read-Default (prompt with default),
#          Invoke-ReviewedCommand (show command, dry run with plan, run that plan only).
function Select-Item {
    param([string]$Title, [object[]]$Items, [scriptblock]$Label, [switch]$AllowNone)
    Write-Host ''
    Write-Host $Title -ForegroundColor White
    for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ("  {0,2}. {1}" -f ($i + 1), ($Items[$i] | ForEach-Object $Label)) }
    if ($AllowNone) { Write-Host '   0. None / back' }
    while ($true) {
        $answer = Read-Host 'Choice'
        if ($AllowNone -and $answer -eq '0') { return $null }
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $Items.Count) { return $Items[[int]$answer - 1] }
    }
}
function Read-Default {
    param([string]$Prompt, [string]$Default)
    $answer = Read-Host "$Prompt$(if ($Default) { " [$Default]" })"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}
function Show-ChangeList {
    param([object[]]$Records, [string]$Title)
    Write-Host ''
    Write-Host $Title -ForegroundColor White
    $n = 0
    foreach ($r in $Records) {
        $n++
        $tag = if ($r.Status -in 'Planned', 'Done') { '' } else { "$($r.Status.ToUpperInvariant()) " }
        Write-Host ("  {0,2}. {1}[{2}] {3}" -f $n, $tag, $r.Tenant, $r.Action) -ForegroundColor $(switch ($r.Status) { 'Failed' { 'Red' } 'Refused' { 'Red' } 'Done' { 'Green' } default { 'Yellow' } })
        Write-Host "        $($r.Command)" -ForegroundColor DarkGray
        if ($r.Error) { Write-Host "        $($r.Error)" -ForegroundColor Red }
    }
}
function Invoke-ReviewedCommand {
    #   WHAT   The one way the console runs a task: show, dry run, list the changes, run that list.
    #   GOTCHA $ConfirmPreference = 'None' here (inherited by the script): the confirmation is the
    #          typed "yes" after the change list, not a second prompt per change.
    param([string]$Line, [bool]$IsWrite, [bool]$Interactive)
    $ConfirmPreference = 'None'
    Write-Host ''
    Write-Host '  Command:' -ForegroundColor White
    Write-Host "  $Line" -ForegroundColor Cyan
    Push-Location $repoRoot
    try {
        if (-not $IsWrite) {
            if ((Read-Default '  This task only reads. Run it? (y/n)' 'y') -ne 'y') { return }
            Start-M365ChangeRecording -ApprovedPlan @()
            try { & ([scriptblock]::Create($Line)) | Format-Table -AutoSize -Wrap | Out-Host }
            catch { Write-Host "  Stopped: $($_.Exception.Message)" -ForegroundColor Red }
            finally { $null = Stop-M365ChangeRecording }
            return
        }

        Write-Host '  Dry run first: nothing changes; every change it would make is listed.' -ForegroundColor DarkGray
        $failure = $null
        Start-M365ChangeRecording
        try { & ([scriptblock]::Create("$Line -WhatIf")) | Format-List | Out-Host }
        catch { $failure = $_.Exception.Message }
        finally { $records = Stop-M365ChangeRecording }
        $plan = @($records | Where-Object Status -eq 'Planned')
        if ($failure) {
            Write-Host "  The dry run stopped: $failure" -ForegroundColor Red
            Write-Host '  Nothing was changed. Fix the problem and try again.' -ForegroundColor Red
            return
        }
        if ($plan.Count -eq 0) {
            Write-Host ''
            Write-Host '  The dry run found nothing to change.' -ForegroundColor Green
            if ((Read-Default '  Run it anyway to see its output? It will not be allowed to change anything. (y/n)' 'n') -ne 'y') { return }
        } else {
            Show-ChangeList -Records $plan -Title "  Changes it will make ($($plan.Count)):"
            Write-Host ''
            Write-Host '  Only these changes are allowed; anything else is refused before it runs.' -ForegroundColor DarkGray
            if ($Interactive) { Write-Host '  This task will ask for a password at the keyboard.' -ForegroundColor DarkGray }
            if ((Read-Default "  Type yes to make these $($plan.Count) change(s)" 'no') -ne 'yes') { Write-Host '  Nothing was changed.'; return }
        }

        $failure = $null
        Start-M365ChangeRecording -ApprovedPlan $plan
        try { & ([scriptblock]::Create($Line)) | Format-Table -AutoSize -Wrap | Out-Host }
        catch { $failure = $_.Exception.Message }
        finally { $done = Stop-M365ChangeRecording }
        if (@($done).Count -gt 0) { Show-ChangeList -Records $done -Title '  Result:' }
        if ($failure) { Write-Host "  Stopped: $failure" -ForegroundColor Red }
    } finally { Pop-Location }
}
function Get-ClientPrefill {
    param([string]$ParameterName, [bool]$IsArray)
    $c = $script:Client
    if (-not $c) { return $null }
    $isHome = $c.PSObject.Properties.Name -contains 'IsHome'
    switch ($ParameterName) {
        'TenantId' { $c.tenantId }
        'CustomerTenantId' { if ($isHome) { $null } else { $c.tenantId } }
        'Organization' { $c.onmicrosoftDomain }
        'Domain' { if ($IsArray -and -not $isHome) { @($c.domains) -join ', ' } else { $c.primaryDomain } }
        'CustomerName' { if ($isHome) { $null } else { $c.name } }
        'Client' { $c.shortName }
        'ConfigPath' { $c.configPath }
        'HuduCompanyId' { if (-not $isHome -and $c.huduCompanyId) { "$($c.huduCompanyId)" } else { $null } }
        default { $null }
    }
}
function Invoke-CatalogTask {
    #   WHAT   Pick (or be given) a task, answer its parameters (client values prefilled),
    #          then Invoke-ReviewedCommand.
    #   WHY    Same catalog the GUI uses, so every script is reachable and the prompts always
    #          match the script's real parameters.
    param([string]$TaskName, [hashtable]$Defaults = @{})
    if ($TaskName) {
        $task = $catalog | Where-Object Name -eq $TaskName | Select-Object -First 1
        if (-not $task) { throw "Task $TaskName not found in the catalog." }
    } else {
        $areas = @(Get-M365TaskArea)
        $area = Select-Item -Title 'Areas' -Items $areas -Label { "$($_.Label)  ($($_.Name)/)" } -AllowNone
        if (-not $area) { return }
        $tasks = @($catalog | Where-Object Area -eq $area.Name)
        $task = Select-Item -Title "Tasks in $($area.Label)" -Items $tasks -Label { "{0,-36} {1} {2}" -f $_.Name, $(if ($_.IsWrite) { '[changes]' } else { '[reads]  ' }), $_.Synopsis } -AllowNone
        if (-not $task) { return }
    }
    Write-Host ''
    Write-Host "  $($task.Name): $($task.Synopsis)" -ForegroundColor White
    if ($task.Description) { Write-Host "  $($task.Description -replace "`n", "`n  ")" -ForegroundColor DarkGray }
    $values = [ordered]@{}
    foreach ($p in $task.Parameters) {
        if ($p.Name -eq 'SignInAs') { continue }   # partner sign-in account: the script defaults it from settings
        $prefill = Get-ClientPrefill -ParameterName $p.Name -IsArray $p.IsArray
        $short = if ($script:Client -and $script:Client.shortName) { $script:Client.shortName } else { 'ourtenant' }
        $default = if ($Defaults.ContainsKey($p.Name)) { "$($Defaults[$p.Name])".Replace('{short}', $short) } elseif ($prefill) { "$prefill" } elseif ($p.Default -and $p.Default -notmatch '^\$|^@\(\)$') { ($p.Default -replace "^'|'$", '') } else { '' }
        if ($p.IsSwitch -or $p.Type -eq 'Boolean') {
            if (-not $Defaults.ContainsKey($p.Name)) { $default = if ($p.Default -eq '$true') { 'y' } else { 'n' } }
        }
        Write-Host ''
        if ($p.Help) { Write-Host "  $($p.Help)" -ForegroundColor DarkGray }
        $prompt = "  -$($p.Name)$(if ($p.Mandatory) { ' *' })$(if ($p.IsArray) { ' (comma list)' })$(if ($p.ValidateSet.Count -gt 0) { " [$($p.ValidateSet -join '|')]" })$(if ($p.IsSwitch -or $p.Type -eq 'Boolean') { ' (y/n)' })"
        $v = ConvertTo-M365TaskValue -Text (Read-Default $prompt $default) -Parameter $p
        if ($p.Mandatory -and -not $p.IsSwitch -and $p.Type -ne 'Boolean' -and ($null -eq $v -or ($v -is [string] -and -not $v) -or ($v -is [array] -and $v.Count -eq 0))) {
            Write-Host "  $($p.Name) is required. Nothing was run." -ForegroundColor Red; return
        }
        if ($v -is [switch]) { if ($v.IsPresent) { $values[$p.Name] = $v }; continue }
        if ($null -ne $v) { $values[$p.Name] = $v }
    }
    $line = Format-M365CommandLine -ScriptPath $task.Path -Values $values
    $avoid = @([regex]::Matches("$($task.InteractiveNote)", '(?i)unless\s+-(\w+)') | ForEach-Object { $_.Groups[1].Value })
    $interactive = $task.IsInteractive -and -not ($avoid | Where-Object { $values.Contains($_) -and $values[$_] })
    Invoke-ReviewedCommand -Line $line -IsWrite $task.IsWrite -Interactive ([bool]$interactive)
}
function Select-Client {
    $files = @(Get-ChildItem (Join-Path $repoRoot 'config' 'clients') -Filter '*.local.json' -ErrorAction SilentlyContinue)
    $choices = @($files | ForEach-Object { [pscustomobject]@{ Label = $_.BaseName -replace '\.local$', ''; Path = $_.FullName; Home = $false } })
    $choices += [pscustomobject]@{ Label = "Our own tenant ($($settings.msp.homeTenantId))"; Path = $null; Home = $true }
    $choices += [pscustomobject]@{ Label = 'New client (answer questions, writes a config file)'; Path = $null; Home = $false }
    $pick = Select-Item -Title 'Which tenant?' -Items $choices -Label { $_.Label } -AllowNone
    if (-not $pick) { return }
    if ($pick.Home) {
        $script:Client = [pscustomobject]@{ name = "Our tenant ($($settings.msp.name))"; tenantId = $settings.msp.homeTenantId; onmicrosoftDomain = $settings.msp.homeTenantId; primaryDomain = $null; domains = @(); shortName = $null; configPath = $null; huduCompanyId = $null; IsHome = $true }
        return
    }
    if ($pick.Path) { $script:Client = Get-M365ClientConfig -Path $pick.Path -Settings $settings; return }
    Read-NewClientConfig
}
function Read-NewClientConfig {
    $name = Read-Default 'Client name (as in Autotask/Hudu)'
    $short = Read-Default 'Short name (lowercase, becomes the mail alias)' (($name -replace '[^A-Za-z0-9]', '').ToLowerInvariant())
    $onms = Read-Default 'Tenant root domain (<name>.onmicrosoft.com, set when the tenant was created)'
    $tenant = Read-Default 'Tenant ID for Graph sign-in (GUID; blank to use the root domain)' $onms
    $domain = Read-Default 'Primary mail domain'
    #   WHY    A typo here would send half of every run to another client. Check now, while
    #          the tech is still at the keyboard.
    try {
        $null = Assert-M365SameTenant -Identifier ([ordered]@{ tenantId = $tenant; onmicrosoftDomain = $onms; primaryDomain = $domain }) -AllowUnresolved primaryDomain
        Write-Host '  Checked: tenant ID, root domain and mail domain are the same tenant.' -ForegroundColor Green
    } catch {
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '  No config written. Start again with the right values.' -ForegroundColor Red
        return
    }
    $pattern = if ($settings.msp.PSObject.Properties.Name -contains 'clientAliasPattern') { $settings.msp.clientAliasPattern } else { "{shortName}.clients@$(($settings.msp.sharedClientsMailbox -split '@')[1])" }
    $alias = Read-Default "Alias to add on $($settings.msp.sharedClientsMailbox)" ($pattern.Replace('{shortName}', $short))
    $is24x7 = (Read-Default 'Is this client on the 24x7 support plan? (y/n)' 'n') -eq 'y'
    $hudu = Read-Default 'Hudu company_id (0 if unknown)' '0'
    $iron = (Read-Default 'Uses ironScales? (y/n)' 'n') -eq 'y'
    $ahd = (Read-Default 'American HelpDesk client? (y/n)' 'n') -eq 'y'
    $pocName = Read-Default 'Primary POC name (blank to skip)'
    $pocEmail = if ($pocName) { Read-Default 'Primary POC email' } else { $null }
    $config = [ordered]@{
        name = $name; shortName = $short; tenantId = $tenant; onmicrosoftDomain = $onms; primaryDomain = $domain; domains = @($domain)
        internalAlias = $alias; support24x7 = $is24x7
        huduCompanyId = [int]$hudu; ironScales = $iron; americanHelpDesk = $ahd
        poc = @(if ($pocName) { [ordered]@{ name = $pocName; email = $pocEmail } })
    }
    $path = Join-Path $repoRoot 'config' 'clients' "$short.local.json"
    if (Test-Path $path) { Write-Host "  $path already exists; not overwritten. Edit it by hand or pick it from the list." -ForegroundColor Red; return }
    $config | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding utf8
    Write-Host "Wrote $path (gitignored). Edit it to add more domains or POCs." -ForegroundColor Green
    $script:Client = Get-M365ClientConfig -Path $path -Settings $settings
}
#endregion

#region 4. Menu -----------------------------------------------------------------------
#   WHAT   Shortcuts to the tasks used most, then the full catalog. Each shortcut is just a
#          catalog task with a few answers pre-filled, so it always prompts for the script's
#          real parameters and goes through the same review.
$menu = @(
    [pscustomobject]@{ Label = 'Onboard client: run the 365 checklist'; Task = 'New-ClientOnboarding'; Defaults = @{} }
    [pscustomobject]@{ Label = 'Verify onboarding: read-only check of every item'; Task = 'Test-ClientOnboarding'; Defaults = @{} }
    [pscustomobject]@{ Label = 'User review: licenses, admins, last sign-in (CSV)'; Task = 'Get-M365UserReview'; Defaults = @{ CsvPath = 'runs/{short}-users.csv' } }
    [pscustomobject]@{ Label = 'Mail authentication: SPF + DKIM + DMARC report'; Task = 'Test-M365MailAuth'; Defaults = @{} }
    [pscustomobject]@{ Label = 'DKIM: create config / enable once CNAMEs are live'; Task = 'Enable-M365Dkim'; Defaults = @{} }
    [pscustomobject]@{ Label = 'Break-glass account'; Task = 'New-M365BreakGlassAccount'; Defaults = @{} }
    [pscustomobject]@{ Label = 'Mail contact'; Task = 'New-M365MailContact'; Defaults = @{} }
    [pscustomobject]@{ Label = 'Distribution list (+ members)'; Task = 'New-M365DistributionList'; Defaults = @{} }
    [pscustomobject]@{ Label = 'Shared mailbox'; Task = 'New-M365SharedMailbox'; Defaults = @{} }
    [pscustomobject]@{ Label = 'Add alias to a mailbox'; Task = 'Add-M365MailboxAlias'; Defaults = @{} }
    [pscustomobject]@{ Label = 'GDAP: relationships + assignments for this client'; Task = 'Get-M365GdapRelationship'; Defaults = @{ IncludeAssignments = 'y' } }
    [pscustomobject]@{ Label = 'GDAP: compliance against our template (read-only)'; Task = 'Test-M365GdapCompliance'; Defaults = @{} }
    [pscustomobject]@{ Label = 'GDAP: guided onboarding (inspect, request, wait, assign, verify)'; Task = 'Start-M365GdapOnboarding'; Defaults = @{} }
    [pscustomobject]@{ Label = 'Any task from the catalog (every script, by area)'; Task = $null; Defaults = @{} }
    [pscustomobject]@{ Label = 'Switch tenant'; Task = '<switch>'; Defaults = @{} }
) | Where-Object { -not $_.Task -or $_.Task -eq '<switch>' -or ($catalog.Name -contains $_.Task) }

#   GOTCHA Dot-sourcing (. ./Start-M365Console.ps1) loads the functions without starting the
#          menu, so tests can drive Invoke-ReviewedCommand directly.
if ($MyInvocation.InvocationName -eq '.') { return }
if ($Client) { $script:Client = Get-M365ClientConfig -Name $Client -Settings $settings } else { Select-Client }
while ($true) {
    if (-not $script:Client) { Write-Host 'No tenant selected.' -ForegroundColor Yellow; Select-Client; if (-not $script:Client) { break } }
    Write-Host ''
    Write-Host "Tenant: $($script:Client.name)   $($script:Client.onmicrosoftDomain)$(if ($script:Client.primaryDomain) { "   domain: $($script:Client.primaryDomain)" })" -ForegroundColor White
    $pick = Select-Item -Title 'What do you want to do?' -Items $menu -Label { $_.Label } -AllowNone
    if (-not $pick) { break }
    try {
        if ($pick.Task -eq '<switch>') { Select-Client }
        elseif ($pick.Task) { Invoke-CatalogTask -TaskName $pick.Task -Defaults $pick.Defaults }
        else { Invoke-CatalogTask }
    } catch { Write-Host "  $($_.Exception.Message)" -ForegroundColor Red }
}
#endregion
