function New-MsScript {
    <#
    .SYNOPSIS
        Render one or more tasks plus answers into a reviewable PowerShell script.
    .DESCRIPTION
        Pure function: no prompts, no network, no execution. The UI calls it; tests call it
        with fixed answers and compare against golden files. Pass several tasks (a build
        path) and the regions number continuously, with verification and rollback collected
        at the end, rollback in reverse order.
    .PARAMETER Task
        One or more task objects from Get-MsTask / Get-MsTaskCatalog, or raw definition hashtables.
    .PARAMETER Answers
        Field Name -> value. Shared across tasks, so 'ResourceGroupName' answered once applies everywhere.
    .PARAMETER Context
        Optional. Hashtable with SubscriptionName, SubscriptionId, TenantId, Account for the header.
    .PARAMETER Share
        Optional. From a build path: target field Name -> source field Name to copy an answer from.
    .PARAMETER Style
        OneLiner (default): one command per line, nothing else. Explained: the long form
        with a header, WHAT/WHY comments, splatted parameters, verify and rollback regions.
    .PARAMETER WithContext
        OneLiner only: prepend the sign-in / context lines (commented).
    .PARAMETER WithVerify
        OneLiner only: append the Verify lines.
    .PARAMETER WithRollback
        OneLiner only: append the Rollback lines, commented out.
    .PARAMETER Date
        Defaults to today. Tests pass a fixed date.
    .EXAMPLE
        New-MsScript -Task (Get-MsTask azure.create.resource-group) -Answers @{ Name = 'rg-lab'; Location = 'eastus2' }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure function. Returns text, changes nothing.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [object[]]$Task,
        [Parameter(Mandatory)] [hashtable]$Answers,
        [Parameter()] [hashtable]$Context = @{},
        [Parameter()] [hashtable]$Share = @{},
        [Parameter()] [ValidateSet('OneLiner', 'Explained')] [string]$Style = 'OneLiner',
        [Parameter()] [switch]$WithContext,
        [Parameter()] [switch]$WithVerify,
        [Parameter()] [switch]$WithRollback,
        [Parameter()] [datetime]$Date = (Get-Date)
    )

    #region 0. Shared answers (build paths) -------------------------------------
    #   WHAT   Share = @{ ResourceGroupName = 'Name' } copies the answer for Name into
    #          ResourceGroupName when the latter was not answered on its own.
    #   WHY    In a path the group is named once and the network task reuses it.
    $Answers = @{} + $Answers
    foreach ($target in $Share.Keys) {
        $from = $Share[$target]
        if (-not ($Answers.ContainsKey($target) -and "$($Answers[$target])" -ne '') -and $Answers.ContainsKey($from)) {
            $Answers[$target] = $Answers[$from]
        }
    }
    #endregion

    $defs = @(foreach ($t in $Task) { if ($t -is [hashtable]) { $t } else { $t.Definition } })

    #region 1. Validate answers -------------------------------------------------
    #   WHAT   Required fields present, patterns match, ints parse. All problems at once.
    #   WHY    A script with a blank -Name is worse than no script.
    $problems = foreach ($def in $defs) {
        foreach ($f in @($def.Fields)) {
            if ($f.Type -in 'Secret', 'Reference') { continue }
            $has = $Answers.ContainsKey($f.Name) -and "$($Answers[$f.Name])" -ne ''
            if ($f.ContainsKey('Required') -and $f.Required -and -not $has) { "$($def.Id): '$($f.Label)' is required."; continue }
            if (-not $has) { continue }
            $v = "$($Answers[$f.Name])"
            if ($f.ContainsKey('Pattern') -and $f.Type -in 'String', 'Choice' -and $v -notmatch $f.Pattern) { "$($def.Id): '$($f.Label)' value '$v' does not match $($f.Pattern)." }
            if ($f.Type -eq 'Int' -and $v -notmatch '^-?\d+$') { "$($def.Id): '$($f.Label)' must be a whole number, got '$v'." }
        }
    }
    if ($problems) { throw ("Cannot generate:`n  " + ($problems -join "`n  ")) }
    #endregion

    #region 2. Resolve Reference fields -----------------------------------------
    $resolved = @{} + $Answers
    foreach ($def in $defs) {
        foreach ($f in @($def.Fields)) {
            if ($f.Type -eq 'Reference' -and -not $resolved.ContainsKey($f.Name) -and $resolved.ContainsKey($f.From)) {
                $resolved[$f.Name] = $resolved[$f.From]
            }
        }
    }
    #endregion

    if ($Style -eq 'OneLiner') {
        return Format-MsOneLiner -Definitions $defs -Answers $resolved -Context $Context -WithContext:$WithContext -WithVerify:$WithVerify -WithRollback:$WithRollback
    }

    #region 3. Header -----------------------------------------------------------
    $modules = @($defs | ForEach-Object { if ($_.Requires.ContainsKey('Modules')) { $_.Requires.Modules } } | Select-Object -Unique)
    $roles   = @($defs | ForEach-Object { if ($_.Requires.ContainsKey('Roles'))   { $_.Requires.Roles } }   | Select-Object -Unique)
    $docs    = @($defs | ForEach-Object { if ($_.ContainsKey('Docs')) { $_.Docs } } | Select-Object -Unique)
    $auth    = @($defs | ForEach-Object { $_.Requires.Auth } | Where-Object { $_ -ne 'None' } | Select-Object -Unique)
    $title   = if ($defs.Count -eq 1) { $defs[0].Title } else { ($defs | ForEach-Object { $_.Title }) -join ', then ' }

    $out = [System.Text.StringBuilder]::new()
    $null = $out.AppendLine('<#')
    $null = $out.AppendLine('.SYNOPSIS')
    $null = $out.AppendLine("    $title")
    $null = $out.AppendLine('.DESCRIPTION')
    foreach ($def in $defs) {
        $null = $out.AppendLine("    $($def.Summary)")
        foreach ($l in @($(if ($def.ContainsKey('Learn')) { $def.Learn } else { @() }))) { $null = $out.AppendLine("      - $l") }
    }
    $null = $out.AppendLine('.NOTES')
    $scope = if ($Context.ContainsKey('SubscriptionName')) { " for subscription '$($Context.SubscriptionName)' ($($Context.SubscriptionId))" }
             elseif ($Context.ContainsKey('TenantId')) { " for tenant $($Context.TenantId)" } else { '' }
    $null = $out.AppendLine("    Generated by ms-scripter on $($Date.ToString('yyyy-MM-dd'))$scope.")
    $null = $out.AppendLine('    Review every line before running. Run one region at a time, in order.')
    $null = $out.AppendLine('    ms-scripter did not run any of this. Nothing here has been executed.')
    if ($modules) { $null = $out.AppendLine("    Requires: $($modules -join ', ')") }
    if ($roles)   { $null = $out.AppendLine("    Roles:    $($roles -join '; ')") }
    foreach ($d in $docs) { $null = $out.AppendLine("    Docs:     $d") }
    $null = $out.AppendLine('#>')
    if ($modules) { $null = $out.AppendLine("#Requires -Modules $($modules -join ', ')") }
    $null = $out.AppendLine()
    #endregion

    #region 4. Context region ---------------------------------------------------
    $n = 0
    $null = $out.AppendLine((Format-MsRegionHeader -Number $n -Title 'Context'))
    $null = $out.AppendLine((Format-MsComment -Tag 'WHAT' -Text 'Confirm you are signed in to the tenant and subscription you think you are.'))
    $null = $out.AppendLine((Format-MsComment -Tag 'WHY' -Text 'Running the right script against the wrong tenant is the classic mistake. Check before every region, not just this one.'))
    if ('Azure' -in $auth) {
        $null = $out.AppendLine('# Connect-AzAccount' + $(if ($Context.ContainsKey('TenantId')) { " -Tenant '$($Context.TenantId)'" }))
        if ($Context.ContainsKey('SubscriptionId')) { $null = $out.AppendLine("# Set-AzContext -Subscription '$($Context.SubscriptionId)'") }
        $null = $out.AppendLine('Get-AzContext | Format-List Account, Tenant, Subscription')
    }
    if ('Graph' -in $auth) {
        $scopes = @($defs | ForEach-Object { if ($_.Requires.ContainsKey('Scopes')) { $_.Requires.Scopes } } | Select-Object -Unique)
        $null = $out.AppendLine("# Connect-MgGraph -Scopes $(($scopes | ForEach-Object { "'$_'" }) -join ', ')")
        $null = $out.AppendLine('Get-MgContext | Format-List Account, TenantId, Scopes')
    }
    if ('ExchangeOnline' -in $auth) {
        $null = $out.AppendLine('# Connect-ExchangeOnline')
        $null = $out.AppendLine('Get-ConnectionInformation | Format-List UserPrincipalName, TenantId')
    }
    $null = $out.AppendLine('#endregion')
    $null = $out.AppendLine()
    #endregion

    #region 5. Steps, then verify, then rollback --------------------------------
    $verify   = [System.Collections.Generic.List[string]]::new()
    $rollback = [System.Collections.Generic.List[string]]::new()
    foreach ($def in $defs) {
        if ($defs.Count -gt 1) {
            $null = $out.AppendLine("# ===== $($def.Title) " + ('=' * [Math]::Max(3, 70 - $def.Title.Length)))
            $null = $out.AppendLine()
        }
        foreach ($step in @($def.Steps)) {
            if ($step.ContainsKey('When')) {
                $gate = $resolved[$step.When]
                $on = if ($null -eq $gate) { $false } elseif ($gate -is [bool]) { $gate } else { "$gate" -ne '' -and "$gate" -notmatch '^(n|no|false|0)$' }
                if (-not $on) { continue }
            }
            $n++
            $null = $out.AppendLine((Format-MsStep -Step $step -Number $n -Answers $resolved -Fields @($def.Fields)))
            $null = $out.AppendLine()
        }
        if ($def.ContainsKey('Verify'))   { foreach ($l in @($def.Verify))   { $verify.Add((Expand-MsTemplate -Text "$l" -Answers $resolved -Fields @($def.Fields))) } }
        if ($def.ContainsKey('Rollback')) { foreach ($l in @($def.Rollback)) { $rollback.Insert(0, (Expand-MsTemplate -Text "$l" -Answers $resolved -Fields @($def.Fields))) } }
    }
    if ($verify.Count -gt 0) {
        $n++
        $null = $out.AppendLine((Format-MsRegionHeader -Number $n -Title 'Verify'))
        $null = $out.AppendLine((Format-MsComment -Tag 'WHAT' -Text 'Read back what was created. Compare with what you asked for.'))
        foreach ($l in $verify) { $null = $out.AppendLine($l) }
        $null = $out.AppendLine('#endregion')
        $null = $out.AppendLine()
    }
    if ($rollback.Count -gt 0) {
        $n++
        $null = $out.AppendLine((Format-MsRegionHeader -Number $n -Title 'Rollback (only if you need to undo)'))
        $null = $out.AppendLine((Format-MsComment -Tag 'WHAT' -Text 'Commented out on purpose. Reverse order of creation. Uncomment one line at a time.'))
        foreach ($l in $rollback) { $null = $out.AppendLine("# $l") }
        $null = $out.AppendLine('#endregion')
    }
    #endregion

    return $out.ToString().TrimEnd() + "`n"
}
