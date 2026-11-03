<#
.SYNOPSIS
    Runs the Microsoft 365 half of new-client onboarding from one client config file.
.DESCRIPTION
    The orchestrator. It holds no tenant logic of its own: Get-OnboardingPlan decides the
    steps, and each step is one of the single-purpose task scripts in entra/, exchange/,
    mailauth/ and partner/. This script signs in to the right tenant for each phase, runs
    the scripts in checklist order, prints a checklist-shaped log, and writes a run record.

      Internal  our tenant:    1.6 alias, 1.7 folder + inbox rules, 1.11 POC contact + DL
      Tenant    client tenant: 5.1 user review, 5.3 break-glass, 5.4 admin accounts,
                               5.5 SPF, 5.6 DKIM, 5.7 GDAP check, 5.9 technical contact,
                               5.10 hidden contact, 5.11 IT@, 5.12 alerts@, 5.13 911@

    Manual steps (Partner Dashboard, Autotask, Pax8, release form, Augment, help desk card,
    welcome letter for now)
    are printed with their SOP link so the run doubles as the tech's reminder list.
    Every step is idempotent; re-running after a failure or after DNS changes is the
    intended way to finish. -WhatIf shows the whole plan and every change without touching
    anything, and is the recommended first run for every client.

    Before any sign-in the run checks that tenantId, onmicrosoftDomain and every domain in the
    client config belong to the same tenant, and stops if one of them names another client.
    Every Exchange step names its tenant explicitly (ours for the Internal phase), and every
    change goes through Invoke-M365Change, so a -WhatIf run lists each change with its tenant
    and exact command.
.PARAMETER Client
    Client short name. Loads config/clients/<Client>.local.json.
.PARAMETER ConfigPath
    Explicit client config path. Overrides -Client.
.PARAMETER Phase
    Which phases to run. Default both, in order.
.PARAMETER Only
    Run only these step ids (e.g. 5.3, 5.10). Manual steps are still listed.
.PARAMETER Skip
    Skip these step ids.
.PARAMETER Interactive
    Ask Retry / Skip / Abort when a step fails instead of stopping.
.PARAMETER AdoptExistingAccounts
    Let steps 5.3 (break-glass) and 5.4 (admin accounts) accept an account that already exists
    (for example one this toolkit created on an earlier run): its role and Conditional Access
    exclusions are checked and completed, and its password is NOT changed. Without it, an
    existing account fails the step and nothing about it changes.
.EXAMPLE
    ./New-ClientOnboarding.ps1 -Client contoso -WhatIf
    Shows every step and every change for Contoso without changing anything. It signs in with
    the same scopes as the real run (so the real run needs no second sign-in).
.EXAMPLE
    ./New-ClientOnboarding.ps1 -Client contoso -Phase Tenant -Only 5.6
    Re-runs only the DKIM step after the client's DNS was updated.
.NOTES
    Requires: Microsoft.Graph, ExchangeOnlineManagement, plus whatever each task script lists
    Interactive: yes (steps 5.3 and 5.4 ask for passwords; -Interactive adds Retry/Skip/Abort)
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
#   WHAT   One client, optional phase/step filters, optional interactive error handling.
#   WHY    The config file carries every client-specific value so the same command
#          onboards any client. Filters exist because real onboardings are finished
#          in pieces over days (DNS propagation, forms, GDAP acceptance).
[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Checklist output is for the operator. Step results are also returned as objects and written to the run record.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Interactive', Justification = 'Read inside the Invoke-Step helper function, which the analyzer does not follow.')]
param(
    [Parameter()]
    [string]$Client,

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [ValidateSet('Internal', 'Tenant')]
    [string[]]$Phase = @('Internal', 'Tenant'),

    [Parameter()]
    [string[]]$Only,

    [Parameter()]
    [string[]]$Skip = @(),

    [Parameter()]
    [switch]$Interactive,

    [Parameter()]
    [switch]$AdoptExistingAccounts
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Load modules, settings, client config, and the plan.
#   WHY    Everything below is driven by the plan. If the plan is wrong, stop here,
#          before any sign-in.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
$modules = Join-Path $PSScriptRoot '..' 'modules'
Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
Import-Module (Join-Path $modules 'OnboardingHelpers' 'OnboardingHelpers.psd1') -Force

$settings = Get-M365Settings
$clientParams = @{ Settings = $settings }
if ($ConfigPath) { $clientParams.Path = $ConfigPath } elseif ($Client) { $clientParams.Name = $Client } else { throw 'Pass -Client <shortName> or -ConfigPath <file>.' }
$clientConfig = Get-M365ClientConfig @clientParams
$plan = @(Get-OnboardingPlan -Client $clientConfig -Settings $settings -Phase $Phase)

#   WHAT   Stop before any sign-in when the config names more than one tenant.
#   WHY    Graph steps sign in to tenantId and Exchange steps to onmicrosoftDomain; one typo
#          would send half the run to another client. Custom domains that are not verified
#          anywhere yet only warn; a domain verified in a DIFFERENT tenant stops the run.
$identifiers = [ordered]@{ tenantId = $clientConfig.tenantId; onmicrosoftDomain = $clientConfig.onmicrosoftDomain }
$domainLabels = @()
foreach ($d in @($clientConfig.domains)) { $label = "domain $d"; $identifiers[$label] = $d; $domainLabels += $label }
$null = Assert-M365SameTenant -Identifier $identifiers -AllowUnresolved $domainLabels

$results = [System.Collections.Generic.List[object]]::new()
$adminUpn = if ($settings.msp.adminUpn -notmatch '^<') { $settings.msp.adminUpn } else { $null }

Write-Host ''
Write-Host "Onboarding: $($clientConfig.name)  tenant $($clientConfig.tenantId) ($($clientConfig.onmicrosoftDomain))  domain $($clientConfig.primaryDomain)" -ForegroundColor White
Write-Host "Phases: $($Phase -join ', ')$(if ($WhatIfPreference) { '   (WhatIf: nothing will change)' })" -ForegroundColor White
Write-Host ''
#endregion

#region 3. Helpers --------------------------------------------------------------
#   WHAT   Invoke-Step (Retry/Skip/Abort), Invoke-TaskScript (call one task script
#          with -WhatIf only if it supports it), Get-ResultDetail (one-line summary).
#   WHY    The same runner for every step keeps the loop below readable, and the
#          -WhatIf guard matters because read-only scripts do not declare it.
function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)
    while ($true) {
        try {
            return [pscustomobject]@{ Ok = $true; Output = @(& $Action); Error = $null }
        } catch {
            $message = $_.Exception.Message
            Write-Warning "Step '$Name' failed: $message"
            if (-not $Interactive) { return [pscustomobject]@{ Ok = $false; Output = @(); Error = $message } }
            $choice = (Read-Host '  [R]etry, [S]kip, or [A]bort').Trim().ToUpperInvariant()
            switch ($choice) {
                'R' { continue }
                'S' { return [pscustomobject]@{ Ok = $false; Output = @(); Error = "Skipped by operator: $message" } }
                default { throw "Aborted at step '$Name'." }
            }
        }
    }
}

function Invoke-TaskScript {
    #   GOTCHA Nothing is injected except -WhatIf. -UserPrincipalName means the TARGET user in
    #          several scripts, so it is never filled in for the operator; scripts default their
    #          -SignInAs account from settings themselves.
    param([string]$RelativePath, [System.Collections.IDictionary]$Parameters)
    $path = Join-Path $repoRoot $RelativePath
    $command = Get-Command $path -ErrorAction Stop
    $params = @{}
    foreach ($k in $Parameters.Keys) { $params[$k] = $Parameters[$k] }
    if ($command.Parameters.ContainsKey('WhatIf')) { $params.WhatIf = $WhatIfPreference }
    Write-Verbose ("  " + (Format-M365Command -Command "& ./$RelativePath" -Parameters $Parameters))
    & $path @params
}

function Get-ResultDetail {
    param([object[]]$Output)
    if (-not $Output) { return '' }
    $interesting = 'UserPrincipalName', 'PrimarySmtpAddress', 'Alias', 'Mailbox', 'Domain', 'Email', 'Policy', 'Member',
    'Created', 'Added', 'Updated', 'Assigned', 'Enabled', 'Status', 'GlobalAdminAssigned', 'PasswordStoredInHudu', 'RolesAssigned', 'Sent', 'LookupCount'
    $parts = foreach ($item in $Output) {
        $props = $item.PSObject.Properties | Where-Object { $_.Name -in $interesting -and $null -ne $_.Value -and "$($_.Value)" -ne '' }
        ($props | ForEach-Object { "$($_.Name)=$($_.Value -join ',')" }) -join ' '
    }
    return ($parts | Where-Object { $_ }) -join ' | '
}

function Connect-Phase {
    param([string]$Name)
    #   GOTCHA Always drop the previous phase's sessions. Assert-M365Graph compares
    #          tenant GUIDs so it would reconnect anyway, but Exchange Online
    #          delegated sessions are matched by organization string and a stale
    #          home-tenant session is exactly the kind of thing that creates a
    #          distribution list in the wrong place.
    Disconnect-M365Tenant -WhatIf:$false -Confirm:$false
    switch ($Name) {
        'Internal' {
            $null = Assert-M365Graph -TenantId $settings.msp.homeTenantId -Scopes (Get-OnboardingGraphScopes -Phase Internal)
            $null = Assert-M365Exchange -Organization $settings.msp.homeTenantId -UserPrincipalName $adminUpn -ExpectedTenantId $settings.msp.homeTenantId
        }
        'Tenant' {
            $null = Assert-M365Graph -TenantId $clientConfig.tenantId -Scopes (Get-OnboardingGraphScopes -Phase Tenant)
            $null = Assert-M365Exchange -Organization $clientConfig.onmicrosoftDomain -UserPrincipalName $adminUpn -ExpectedTenantId $clientConfig.tenantId
        }
    }
}
#endregion

#region 4. Run the plan, phase by phase ------------------------------------------
#   WHAT   Connect once per phase, then run each step's invocations.
#   WHY    Internal is our tenant, Tenant is the client's. Two sign-ins per full
#          run, each with all the scopes that phase needs.
foreach ($phaseName in 'Internal', 'Tenant') {
    if ($Phase -notcontains $phaseName) { continue }
    $steps = @($plan | Where-Object { $_.Phase -eq $phaseName })
    if ($steps.Count -eq 0) { continue }
    Write-Host "== $phaseName phase ==" -ForegroundColor White

    $needsConnection = @($steps | Where-Object { $_.Applies -and $_.Kind -ne 'Manual' -and (-not $Only -or $Only -contains $_.Id) -and $Skip -notcontains $_.Id }).Count -gt 0
    if ($needsConnection) { Connect-Phase -Name $phaseName }

    foreach ($step in $steps) {
        $started = (Get-Date).ToString('o')
        $record = [pscustomobject]@{ Id = $step.Id; Name = $step.Name; Phase = $step.Phase; Kind = $step.Kind; Status = ''; Detail = ''; StartedAt = $started }

        if (-not $step.Applies) {
            $record.Status = 'Skipped'; $record.Detail = if ($step.Note) { $step.Note } else { 'Not applicable to this client.' }
            Write-M365Step -Id $step.Id -Name $step.Name -Status Skipped -Detail $record.Detail
        } elseif ($step.Kind -eq 'Manual') {
            $record.Status = 'Manual'; $record.Detail = "SOP: $($step.SopUrl)$(if ($step.Note) { "  $($step.Note)" })"
            Write-M365Step -Id $step.Id -Name $step.Name -Status Manual -Detail $record.Detail
        } elseif (($Only -and $Only -notcontains $step.Id) -or $Skip -contains $step.Id) {
            $record.Status = 'Skipped'; $record.Detail = 'Excluded by -Only / -Skip.'
            Write-M365Step -Id $step.Id -Name $step.Name -Status Skipped -Detail $record.Detail
        } else {
            $outputs = @(); $errors = @()
            foreach ($invocation in $step.Invocations) {
                $params = $invocation
                if ($AdoptExistingAccounts -and $step.Id -in '5.3', '5.4') {
                    $params = [ordered]@{}; foreach ($k in $invocation.Keys) { $params[$k] = $invocation[$k] }; $params['AdoptExisting'] = $true
                }
                $run = Invoke-Step -Name "$($step.Id) $($step.Name)" -Action { Invoke-TaskScript -RelativePath $step.Script -Parameters $params }
                if ($run.Ok) { $outputs += $run.Output } else { $errors += $run.Error }
            }
            #   WHAT   A step can say what its output must show (5.7: an active relationship), and a
            #          script that reports Completed = $false (account created, but a role or CA
            #          exclusion failed) fails the step even though it did not throw.
            if ($errors.Count -eq 0 -and $step.Expect) {
                $problem = & $step.Expect $outputs
                if ($problem) { $errors += $problem }
            }
            foreach ($o in $outputs | Where-Object { $_ -and $_.PSObject.Properties.Name -contains 'Completed' -and $_.Completed -eq $false }) {
                $why = if ($o.PSObject.Properties.Name -contains 'Errors' -and $o.Errors) { @($o.Errors) -join '; ' } else { 'not completed' }
                $errors += "Not completed: $why"
            }

            if ($errors.Count -gt 0) {
                $record.Status = 'Failed'; $record.Detail = $errors -join ' | '
                Write-M365Step -Id $step.Id -Name $step.Name -Status Failed -Detail $record.Detail
            } else {
                $record.Status = if ($WhatIfPreference) { 'WhatIf' } else { 'Done' }
                $detail = Get-ResultDetail -Output $outputs
                if ($step.Kind -eq 'Assisted' -and $step.Note) { $detail = "$detail  $($step.Note)".Trim() }
                $record.Detail = $detail
                Write-M365Step -Id $step.Id -Name $step.Name -Status $record.Status -Detail $detail
            }
        }
        $results.Add($record)
    }
    Write-Host ''
}
#endregion

#region 5. Record and summarize -------------------------------------------------
#   WHAT   Write runs/<client>-<stamp>.json, print counts, list what is still manual.
#   WHY    The run record is what you close the Autotask checklist from, and what
#          Test-ClientOnboarding.ps1 compares against. runs/ is gitignored.
Disconnect-M365Tenant -WhatIf:$false -Confirm:$false
$recordPath = Save-OnboardingRunRecord -Client $clientConfig -Results $results.ToArray() -WhatIf:$false
$counts = $results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host "Summary: $($counts -join '  ')" -ForegroundColor White
Write-Host "Run record: $recordPath" -ForegroundColor DarkGray
$manual = @($results | Where-Object { $_.Status -eq 'Manual' })
if ($manual.Count -gt 0) {
    Write-Host ''
    Write-Host 'Still yours to do by hand:' -ForegroundColor Yellow
    foreach ($m in $manual) { Write-Host "  $($m.Id)  $($m.Name)" -ForegroundColor Yellow }
}
$failed = @($results | Where-Object { $_.Status -eq 'Failed' })
if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host "Failed steps: $($failed.Id -join ', '). Fix the cause and re-run with -Only." -ForegroundColor Red
    if (@($failed | Where-Object { $_.Id -in '5.3', '5.4' -and $_.Detail -match 'already exists' }).Count -gt 0) {
        Write-Host 'An account already exists. If it is ours (for example from an earlier run), re-run those steps with -AdoptExistingAccounts; its password is not changed.' -ForegroundColor Red
    }
}
$results.ToArray()
#endregion
