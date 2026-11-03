function Format-MsOneLiner {
    <#
    .SYNOPSIS
        Render tasks as plain one-line commands. No comments, no splatting.
    .DESCRIPTION
        Each Cmdlet step becomes 'Verb-Noun -Param value -Param value'. Switch-style values
        ($true) become bare '-Param'; $false becomes '-Param:$false'; empty values are
        dropped. A step's Output variable is assigned only when a later line actually uses
        it, so simple tasks come out as a bare command. Raw steps are emitted as written.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [object[]]$Definitions,
        [Parameter(Mandatory)] [hashtable]$Answers,
        [Parameter()] [hashtable]$Context = @{},
        [Parameter()] [switch]$WithContext,
        [Parameter()] [switch]$WithVerify,
        [Parameter()] [switch]$WithRollback
    )
    $lines    = [System.Collections.Generic.List[string]]::new()
    $verify   = [System.Collections.Generic.List[string]]::new()
    $rollback = [System.Collections.Generic.List[string]]::new()
    $auth     = @($Definitions | ForEach-Object { $_.Requires.Auth } | Where-Object { $_ -ne 'None' } | Select-Object -Unique)

    if ($WithContext) {
        if ('Azure' -in $auth) {
            $lines.Add('# Connect-AzAccount' + $(if ($Context.ContainsKey('TenantId')) { " -Tenant $(Format-MsValue $Context.TenantId)" }))
            if ($Context.ContainsKey('SubscriptionId')) { $lines.Add("# Set-AzContext -Subscription $(Format-MsValue $Context.SubscriptionId)") }
        }
        if ('Graph' -in $auth) {
            $scopes = @($Definitions | ForEach-Object { if ($_.Requires.ContainsKey('Scopes')) { $_.Requires.Scopes } } | Select-Object -Unique)
            $lines.Add("# Connect-MgGraph -Scopes $(($scopes | ForEach-Object { "'$_'" }) -join ', ')")
        }
        if ('ExchangeOnline' -in $auth) { $lines.Add('# Connect-ExchangeOnline') }
        if ($lines.Count -gt 0) { $lines.Add('') }
    }

    $first = $true
    foreach ($def in $Definitions) {
        if (-not $first -and $Definitions.Count -gt 1) { $lines.Add('') }
        $first = $false
        $fields = @($def.Fields)
        $steps  = @($def.Steps)
        $inline = @{}      # Output name -> '(rendered command)' for steps folded into a later call
        for ($i = 0; $i -lt $steps.Count; $i++) {
            $step = $steps[$i]
            if ($step.ContainsKey('OnlyExplained') -and $step.OnlyExplained) { continue }   # teaching glue, not a command
            if ($step.ContainsKey('When')) {
                $gate = $Answers[$step.When]
                $on = if ($null -eq $gate) { $false } elseif ($gate -is [bool]) { $gate } else { "$gate" -ne '' -and "$gate" -notmatch '^(n|no|false|0)$' }
                if (-not $on) { continue }
            }
            if ($step.ContainsKey('Raw')) {
                foreach ($raw in @($step.Raw)) { $lines.Add((Expand-MsTemplate -Text "$raw" -Answers $Answers -Fields $fields)) }
                continue
            }
            $parts  = [System.Collections.Generic.List[string]]::new()
            $parts.Add($step.Cmdlet)
            $params = if ($step.ContainsKey('Parameters')) { $step.Parameters } else { @{} }
            $bools  = if ($step.ContainsKey('BoolParameters')) { @($step.BoolParameters) } else { @() }
            foreach ($name in (Get-MsParameterOrder -Step $step)) {
                $value = Expand-MsTemplate -Text "$($params[$name])" -Answers $Answers -Fields $fields
                if ($value -match '^\$([A-Za-z][A-Za-z0-9]*)$' -and $inline.ContainsKey($Matches[1])) { $value = $inline[$Matches[1]] }
                if ($value -eq '') { continue }
                if ($name -in $bools) { $parts.Add("-$name $value"); continue }      # [bool] parameter: needs an explicit value
                switch ($value) {
                    '$true'  { $parts.Add("-$name") }                               # [switch] parameter: bare
                    '$false' { $parts.Add("-${name}:`$false") }
                    default  { $parts.Add("-$name $value") }
                }
            }
            $line = $parts -join ' '
            if ($step.ContainsKey('Output')) {
                $use = Get-MsOutputUse -Name $step.Output -Definition $def -FromStep ($i + 1) -IncludeVerify:$WithVerify -IncludeRollback:$WithRollback
                if ($use -eq 'Elsewhere')      { $line = "`$$($step.Output) = $line" }
                elseif ($use -eq 'ExactParam') { $inline[$step.Output] = "($line)"; continue }   # folded into the later call, no line of its own
            }
            $lines.Add($line)
        }
        if ($def.ContainsKey('Verify'))   { foreach ($l in @($def.Verify))   { $verify.Add((Expand-MsTemplate -Text "$l" -Answers $Answers -Fields $fields)) } }
        if ($def.ContainsKey('Rollback')) { foreach ($l in @($def.Rollback)) { $rollback.Insert(0, (Expand-MsTemplate -Text "$l" -Answers $Answers -Fields $fields)) } }
    }

    if ($WithVerify -and $verify.Count -gt 0) {
        $lines.Add('')
        $lines.Add('# Verify')
        foreach ($l in $verify) { $lines.Add($l) }
    }
    if ($WithRollback -and $rollback.Count -gt 0) {
        $lines.Add('')
        $lines.Add('# Rollback')
        foreach ($l in $rollback) { $lines.Add("# $l") }
    }
    return (($lines -join "`n").TrimEnd() + "`n")
}

function Get-MsOutputUse {
    <#
    .SYNOPSIS
        How a step's Output variable is used later: 'None', 'ExactParam', or 'Elsewhere'.
    .DESCRIPTION
        ExactParam: only ever appears as the whole value of a later Cmdlet step's parameter
        (so the call can be nested inline). Elsewhere: appears in a Raw line, inside a longer
        expression, or in Verify/Rollback when those are included (so it must be assigned).
        Steps marked OnlyExplained are ignored; they are not emitted in this style.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [hashtable]$Definition,
        [Parameter(Mandatory)] [int]$FromStep,
        [Parameter()] [switch]$IncludeVerify,
        [Parameter()] [switch]$IncludeRollback
    )
    $exact   = '^\$' + [regex]::Escape($Name) + '$'
    $pattern = '\$' + [regex]::Escape($Name) + '\b'
    $use = 'None'
    $steps = @($Definition.Steps)
    for ($j = $FromStep; $j -lt $steps.Count; $j++) {
        $s = $steps[$j]
        if ($s.ContainsKey('OnlyExplained') -and $s.OnlyExplained) { continue }
        if ($s.ContainsKey('Parameters')) {
            foreach ($v in $s.Parameters.Values) {
                if ("$v" -match $exact) { if ($use -eq 'None') { $use = 'ExactParam' } }
                elseif ("$v" -match $pattern) { return 'Elsewhere' }
            }
        }
        if ($s.ContainsKey('Raw')) { foreach ($v in @($s.Raw)) { if ("$v" -match $pattern) { return 'Elsewhere' } } }
    }
    if ($IncludeVerify   -and $Definition.ContainsKey('Verify'))   { foreach ($v in @($Definition.Verify))   { if ("$v" -match $pattern) { return 'Elsewhere' } } }
    if ($IncludeRollback -and $Definition.ContainsKey('Rollback')) { foreach ($v in @($Definition.Rollback)) { if ("$v" -match $pattern) { return 'Elsewhere' } } }
    return $use
}
