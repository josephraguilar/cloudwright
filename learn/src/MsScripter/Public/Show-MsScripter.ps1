function Show-MsScripter {
    <#
    .SYNOPSIS
        The console UI: browse sections, pick a task, answer its fields, generate the script.
    .DESCRIPTION
        Sections come from the catalog folder structure. Nothing here runs a generated
        command; the only live calls are the optional sign-ins and read-only pick-list
        lookups. Generated text goes to the screen, the clipboard (C), or out/ (S).
    .PARAMETER CatalogRoot
        Defaults to the repo's catalog/ folder.
    .PARAMETER OutputDirectory
        Where S saves scripts. Defaults to out/ in the repo root (gitignored).
    .PARAMETER NoSignIn
        Skip the sign-in questions. Everything becomes typed values.
    .PARAMETER Contoso
        Contoso mode: no sign-in, pick lists from sample data, fields default to their examples.
    .EXAMPLE
        Show-MsScripter
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console. Output is for the operator, not the pipeline.')]
    [CmdletBinding()]
    param(
        [Parameter()] [string]$CatalogRoot = $script:CatalogRoot,
        [Parameter()] [string]$OutputDirectory = (Join-Path (Join-Path (Join-Path $script:ModuleRoot '..') '..') 'out'),
        [Parameter()] [switch]$NoSignIn,
        [Parameter()] [switch]$Contoso
    )

    #region 1. Load catalog and sign in (optional) ------------------------------
    $catalog = @(Get-MsTaskCatalog -CatalogRoot $CatalogRoot)
    if ($catalog.Count -eq 0) { throw "No tasks found under $CatalogRoot." }
    $tasks = @($catalog | Where-Object Kind -eq 'Task')
    $paths = @($catalog | Where-Object Kind -eq 'Path')

    Write-Host ''
    Write-Host '== ms-scripter ==' -ForegroundColor Cyan
    Write-Host '  Builds Microsoft admin scripts for you to review and run elsewhere. It never runs them itself.'
    Write-Host "  $($tasks.Count) tasks, $($paths.Count) build paths loaded."

    $context = @{}
    if ($Contoso) {
        $context = Set-MsContosoMode
        Write-Host "  Contoso mode: sample tenant '$($context.TenantDomain)'. Nothing is live; pick lists are fictional." -ForegroundColor Yellow
    }
    if (-not $NoSignIn -and -not $Contoso) {
        if ((Read-Host '  Sign in to Azure so pick lists show your real resource groups, regions, VNets? [y/N]') -match '^[Yy]') {
            $az = Assert-MsAzContext
            if ($az) {
                $subs = @(Get-AzSubscription -ErrorAction SilentlyContinue | Where-Object State -eq 'Enabled' | Sort-Object Name)
                if ($subs.Count -gt 1) {
                    $pick = Select-MsItem -Title 'Subscription for pick lists' -Items $subs -Label { "$($_.Name)  ($($_.Id))" } -AllowNone
                    if ($pick) { $az = Set-AzContext -Subscription $pick.Id }
                }
                $context.SubscriptionName = $az.Subscription.Name
                $context.SubscriptionId   = $az.Subscription.Id
                $context.TenantId         = $az.Tenant.Id
                Write-Host "  Azure: $($az.Account.Id) on '$($az.Subscription.Name)'" -ForegroundColor Green
            }
        }
        if ((Read-Host '  Sign in to Microsoft Graph (read-only scopes) so pick lists show users and groups? [y/N]') -match '^[Yy]') {
            $mg = Assert-MsGraphContext
            if ($mg) {
                if (-not $context.ContainsKey('TenantId')) { $context.TenantId = $mg.TenantId }
                Write-Host "  Graph: $($mg.Account) with scopes $($mg.Scopes -join ', ')" -ForegroundColor Green
            }
        }
    }
    #endregion

    #region 2. Menu loop: section tree -> task -> fields -> generate ------------
    $queue = [System.Collections.Generic.List[object]]::new()   # tasks appended with N (one script, many regions)
    while ($true) {
        $picked = Select-MsSection -Tasks $tasks -Paths $paths
        if (-not $picked) { break }

        $defs  = @()
        $share = @{}
        if ($picked.Kind -eq 'Path') {
            foreach ($id in $picked.Definition.Tasks) {
                $t = $tasks | Where-Object Id -eq $id
                if (-not $t) { Write-Host "  Path references unknown task $id" -ForegroundColor Yellow; continue }
                $defs += $t
            }
            if ($picked.Definition.ContainsKey('Share')) { $share = $picked.Definition.Share }
        } else {
            $defs = @($picked)
        }

        foreach ($t in $defs) { Show-MsTaskIntro -Task $t -Tasks $tasks }
        $answers = @{}
        foreach ($t in $defs) {
            foreach ($f in @($t.Definition.Fields)) {
                if ($share.ContainsKey($f.Name) -and $answers.ContainsKey($share[$f.Name])) { continue }   # shared, already answered
                if ($answers.ContainsKey($f.Name)) { continue }
                $v = Read-MsField -Field $f -Answers $answers -Fields @($t.Definition.Fields)
                if ($null -ne $v) { $answers[$f.Name] = $v }
            }
        }

        $script = $null
        while ($true) {
            try {
                $allDefs = @($queue + $defs)
                $script = New-MsScript -Task $allDefs -Answers $answers -Context $context -Share $share
            } catch {
                Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
                break
            }
            Write-Host ''
            Write-Host ('-' * 78) -ForegroundColor DarkGray
            Write-Host $script
            Write-Host ('-' * 78) -ForegroundColor DarkGray
            Write-Host '  [C]opy to clipboard   [S]ave to out/   [E]dit an answer   [N]ext task, same script   [B]ack to menu'
            $action = "$(Read-Host '  Choose')".Trim().ToUpperInvariant()
            switch ($action) {
                'C' {
                    if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) { $script | Set-Clipboard; Write-Host '  Copied.' -ForegroundColor Green }
                    else { Write-Host '  Set-Clipboard is not available here. Use S to save instead.' -ForegroundColor Yellow }
                }
                'S' {
                    if (-not (Test-Path $OutputDirectory)) { $null = New-Item -ItemType Directory -Path $OutputDirectory }
                    $name = (($allDefs | ForEach-Object { ($_.Id -split '\.')[-1] }) -join '_') + '_' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.ps1'
                    $file = Join-Path $OutputDirectory $name
                    Set-Content -Path $file -Value $script -Encoding utf8
                    Write-Host "  Saved $file" -ForegroundColor Green
                }
                'E' {
                    $fields = @($defs | ForEach-Object { $_.Definition.Fields } | Where-Object { $_.Type -notin 'Secret', 'Reference' })
                    $f = Select-MsItem -Title 'Which answer?' -Items $fields -Label { "$($_.Label) = $($answers[$_.Name])" } -AllowNone
                    if ($f) {
                        $script:Remembered.Remove($f.Name)
                        $v = Read-MsField -Field $f -Answers $answers -Fields $fields
                        if ($null -ne $v) { $answers[$f.Name] = $v } else { $answers.Remove($f.Name) }
                    }
                    continue
                }
                'N' { foreach ($d in $defs) { $queue.Add($d) }; Write-Host "  Queued. Pick the next task; the script will have $($queue.Count + 1)+ parts." -ForegroundColor Green; break }
                default { $queue.Clear(); break }
            }
            if ($action -in 'N', 'B', '') { break }
        }
    }
    Write-Host '  Bye. Nothing was executed.' -ForegroundColor DarkGray
    #endregion
}

function Select-MsSection {
    <#
    .SYNOPSIS
        Walk the section tree (built from catalog folders) down to one task or path.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive menu.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]$Tasks,
        [Parameter()] [AllowEmptyCollection()] [object[]]$Paths = @()
    )
    $all = @($Tasks + $Paths)
    $prefix = ''
    while ($true) {
        $here = @($all | Where-Object { $prefix -eq '' -or $_.Section -eq $prefix -or $_.Section -like "$prefix/*" })
        $children = @($here | ForEach-Object {
            $rest = if ($prefix) { $_.Section.Substring($prefix.Length).TrimStart('/') } else { $_.Section }
            if ($rest) { [pscustomobject]@{ Display = ($rest -split '/')[0] + '/'; Kind = 'Section'; Item = ($rest -split '/')[0] } }
            else       { [pscustomobject]@{ Display = $_.Title; Kind = $_.Kind; Item = $_ } }
        } | Sort-Object Kind, Display -Unique)
        Write-Host ''
        Write-Host "  Where: $(if ($prefix) { $prefix } else { 'top' })" -ForegroundColor DarkGray
        $pick = Select-MsItem -Title $(if ($prefix) { 'Pick a section or task (Enter to go up)' } else { 'Pick an area (Enter to quit)' }) -Items $children -AllowNone
        if (-not $pick) {
            if (-not $prefix) { return $null }
            $prefix = if ($prefix -match '/') { $prefix.Substring(0, $prefix.LastIndexOf('/')) } else { '' }
            continue
        }
        if ($pick.Kind -eq 'Section') { $prefix = if ($prefix) { "$prefix/$($pick.Item)" } else { $pick.Item }; continue }
        return $pick.Item
    }
}

function Show-MsTaskIntro {
    <#
    .SYNOPSIS
        Print what a task does, what to learn, what it needs, and what to do first.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Task,
        [Parameter(Mandatory)] [object[]]$Tasks
    )
    $d = $Task.Definition
    Write-Host ''
    Write-Host "== $($d.Title) ==" -ForegroundColor Cyan
    Write-Host "  $($d.Summary)"
    if ($d.ContainsKey('Learn')) { foreach ($l in @($d.Learn)) { Write-Host "  - $l" -ForegroundColor DarkGray } }
    if ($d.Requires.ContainsKey('Modules')) { Write-Host "  Needs modules: $($d.Requires.Modules -join ', ')" -ForegroundColor DarkGray }
    if ($d.Requires.ContainsKey('Roles'))   { Write-Host "  Needs role:    $($d.Requires.Roles -join '; ')" -ForegroundColor DarkGray }
    if ($d.ContainsKey('Prerequisites') -and @($d.Prerequisites).Count -gt 0) {
        $names = foreach ($id in @($d.Prerequisites)) { $t = $Tasks | Where-Object Id -eq $id; if ($t) { $t.Title } else { $id } }
        Write-Host "  Do first:      $($names -join '; ')" -ForegroundColor Yellow
    }
    Write-Host "  Status:        $($d.Status)" -ForegroundColor DarkGray
}
