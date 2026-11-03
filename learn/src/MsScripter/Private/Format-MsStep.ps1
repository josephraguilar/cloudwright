function Format-MsStep {
    <#
    .SYNOPSIS
        Render one step of a task as a #region block.
    .DESCRIPTION
        Cmdlet steps become a splat hashtable plus the call. Parameters whose rendered
        value is empty are dropped, which is how optional fields disappear. Raw steps are
        {{Token}}-expanded line by line.
    .PARAMETER Step
        The step hashtable from the task definition.
    .PARAMETER Number
        Region number in the generated script.
    .PARAMETER Answers
        Field Name -> value.
    .PARAMETER Fields
        The task's Fields.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [hashtable]$Step,
        [Parameter(Mandatory)] [int]$Number,
        [Parameter(Mandatory)] [hashtable]$Answers,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Fields
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((Format-MsRegionHeader -Number $Number -Title $Step.Title))
    $lines.Add((Format-MsComment -Tag 'WHAT' -Text $Step.What))
    $lines.Add((Format-MsComment -Tag 'WHY' -Text $Step.Why))
    if ($Step.ContainsKey('Gotcha')) { $lines.Add((Format-MsComment -Tag 'GOTCHA' -Text $Step.Gotcha)) }

    if ($Step.ContainsKey('Cmdlet')) {
        $output   = if ($Step.ContainsKey('Output')) { $Step.Output } else { $null }
        $splat    = if ($output) { "${output}Params" } else { "step${Number}Params" }
        $rendered = [ordered]@{}
        $params   = if ($Step.ContainsKey('Parameters')) { $Step.Parameters } else { @{} }
        foreach ($name in (Get-MsParameterOrder -Step $Step)) {
            $value = Expand-MsTemplate -Text "$($params[$name])" -Answers $Answers -Fields $Fields
            if ($value -ne '') { $rendered[$name] = $value }
        }
        if ($rendered.Count -gt 0) {
            $width = ($rendered.Keys | Measure-Object -Property Length -Maximum).Maximum
            $lines.Add("`$$splat = @{")
            foreach ($k in $rendered.Keys) {
                $row = ('    {0,-' + $width + '} = {1}') -f @($k, $rendered[$k])
                $lines.Add($row)
            }
            $lines.Add('}')
            $call = "$($Step.Cmdlet) @$splat"
        } else {
            $call = $Step.Cmdlet
        }
        $whatIf = -not ($Step.ContainsKey('WhatIf') -and $Step.WhatIf -eq $false)
        if ($whatIf) { $lines.Add("# $call -WhatIf    # uncomment for a dry run first") }
        $lines.Add($(if ($output) { "`$$output = $call" } else { $call }))
        if ($output) { $lines.Add("`$$output") }
    } else {
        foreach ($raw in @($Step.Raw)) {
            $lines.Add((Expand-MsTemplate -Text "$raw" -Answers $Answers -Fields $Fields))
        }
    }
    $lines.Add('#endregion')
    return ($lines -join "`n")
}

function Get-MsParameterOrder {
    <#
    .SYNOPSIS
        Deterministic parameter order: ParameterOrder if given, else the usual suspects first, then alphabetical.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [hashtable]$Step)
    if (-not $Step.ContainsKey('Parameters')) { return @() }
    $keys = @($Step.Parameters.Keys)
    if ($Step.ContainsKey('ParameterOrder')) {
        $ordered = @($Step.ParameterOrder)
        $rest    = @($keys | Where-Object { $_ -notin $ordered } | Sort-Object)
        return @($ordered + $rest)
    }
    $first = @('Name', 'DisplayName', 'ResourceGroupName', 'Location' | Where-Object { $_ -in $keys })
    $rest  = @($keys | Where-Object { $_ -notin $first } | Sort-Object)
    return @($first + $rest)
}

function Format-MsRegionHeader {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [int]$Number, [Parameter(Mandatory)] [string]$Title)
    $head = "#region $Number. $Title "
    return $head + ('-' * [Math]::Max(3, 78 - $head.Length))
}

function Format-MsComment {
    <#
    .SYNOPSIS
        '#   WHAT   text' with wrapping at 78 columns and continuation lines indented.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string]$Tag, [Parameter(Mandatory)] [AllowEmptyString()] [string]$Text)
    $prefix = '#   {0,-6} ' -f $Tag
    $indent = '#          '
    $words  = $Text -split '\s+'
    $out = [System.Collections.Generic.List[string]]::new()
    $line = $prefix
    foreach ($w in $words) {
        if (($line.Length + $w.Length + 1) -gt 78 -and $line.Trim() -ne $prefix.Trim()) {
            $out.Add($line.TrimEnd()); $line = $indent
        }
        $line += "$w "
    }
    $out.Add($line.TrimEnd())
    return ($out -join "`n")
}
