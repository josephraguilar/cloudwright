#region Module setup ----------------------------------------------------------
#   WHAT   Strict mode. No Graph here; this module only reads the repo.
#   WHY    The catalog is what lets a new script appear in the GUI and console
#          without touching either: drop a Verb-M365Noun.ps1 in an area folder,
#          give it comment-based help and a Status line, and it is a task.
Set-StrictMode -Version Latest
$script:CommonParameters = [System.Management.Automation.PSCmdlet]::CommonParameters + [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
$script:ReadOnlyTasks = @(
    'partner/Get-M365GdapCustomer.ps1', 'partner/Get-M365GdapRelationship.ps1',
    'partner/Test-M365GdapCompliance.ps1', 'partner/Wait-M365GdapApproval.ps1',
    'onboarding/Test-ClientOnboarding.ps1', 'entra/Get-M365Group.ps1', 'entra/Get-M365UserReview.ps1',
    'mailauth/Get-M365DkimStatus.ps1', 'mailauth/Test-M365DmarcRecord.ps1',
    'mailauth/Test-M365MailAuth.ps1', 'mailauth/Test-M365SpfRecord.ps1',
    'security/Test-M365SecurityBaseline.ps1', 'reports/Get-M365AdminReport.ps1',
    'reports/Get-M365ForwardingReport.ps1', 'reports/Get-M365LicenseReport.ps1',
    'reports/Get-M365MailboxPermissionReport.ps1'
)
$script:AreaLabels = [ordered]@{
    partner    = 'GDAP & Partner'
    onboarding = 'Client Onboarding'
    entra      = 'Entra ID'
    exchange   = 'Exchange Online'
    mailauth   = 'Mail Authentication'
    security   = 'Security Baselines'
    reports    = 'Reporting'
    lifecycle  = 'User Lifecycle'
}
#endregion

function Get-M365TaskArea {
    <#
    .SYNOPSIS
        Lists the task areas (script folders) and their display labels, in menu order.
    .EXAMPLE
        Get-M365TaskArea | Format-Table
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ScriptsRoot
    )
    if (-not $ScriptsRoot) { $ScriptsRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..')) }
    $folders = Get-ChildItem -Path $ScriptsRoot -Directory | Where-Object { $_.Name -notin 'modules', 'gui' }
    $ordered = @($script:AreaLabels.Keys | Where-Object { $folders.Name -contains $_ }) + @($folders.Name | Where-Object { $script:AreaLabels.Keys -notcontains $_ } | Sort-Object)
    foreach ($name in $ordered) {
        [pscustomobject]@{
            Name  = $name
            Label = if ($script:AreaLabels.Contains($name)) { $script:AreaLabels[$name] } else { (Get-Culture).TextInfo.ToTitleCase($name) }
            Path  = Join-Path $ScriptsRoot $name
        }
    }
}

function Get-M365Task {
    <#
    .SYNOPSIS
        Discovers task scripts and describes each one: parameters, help, read-only or write, status.
    .DESCRIPTION
        Scans scripts/powershell/<area>/*.ps1 (not modules/, gui/, _template, Start-*). For each
        script it reads the parameter block through Get-Command and the comment-based help
        through Get-Help, and returns:

          Name, Area, AreaLabel, Path, RelativePath
          Synopsis, Description, Status (from the .NOTES Status: line), Requires, GraphScopes
          IsWrite        true when the script declares SupportsShouldProcess (has -WhatIf)
          IsInteractive  true when the .NOTES block has 'Interactive: yes ...' (prompts at the keyboard; run in a terminal)
          Parameters[]   Name, Type, IsSwitch, IsArray, Mandatory, Default, ValidateSet, Help, Order
                         (in the order the script declares them, so forms and command lines read
                         the way the script's author laid them out)

        The GUI builds its forms from this; the console builds its catalog menu from this; the
        tests assert every script has a synopsis, a status line and at least one example.
    .PARAMETER Area
        Limit to these area folder names.
    .PARAMETER Name
        Limit to scripts whose base name matches this wildcard.
    .PARAMETER ScriptsRoot
        Override the scripts folder (tests).
    .PARAMETER ReadOnly
        Return only explicitly reviewed read tasks. New scripts are not automatically admitted.
    .EXAMPLE
        Get-M365Task -Area exchange | Format-Table Name, IsWrite, Synopsis
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string[]]$Area,

        [Parameter()]
        [string]$Name,

        [Parameter()]
        [string]$ScriptsRoot,

        [Parameter()]
        [switch]$ReadOnly
    )
    if (-not $ScriptsRoot) { $ScriptsRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..')) }
    $repoRoot = [IO.Path]::GetFullPath((Join-Path $ScriptsRoot '..' '..'))
    $areas = Get-M365TaskArea -ScriptsRoot $ScriptsRoot
    if ($Area) { $areas = $areas | Where-Object { $Area -contains $_.Name } }

    foreach ($a in $areas) {
        $files = Get-ChildItem -Path $a.Path -Filter '*.ps1' | Where-Object { $_.Name -notlike '_*' -and $_.Name -notlike 'Start-*' } | Sort-Object Name
        if ($Name) { $files = $files | Where-Object { $_.BaseName -like $Name } }
        foreach ($file in $files) {
            if ($ReadOnly -and "$($a.Name)/$($file.Name)" -notin $script:ReadOnlyTasks) { continue }
            $cmd = Get-Command -Name $file.FullName -ErrorAction Stop
            $help = Get-Help -Name $file.FullName -ErrorAction SilentlyContinue
            $raw = Get-Content -Path $file.FullName -Raw
            $status = if ($raw -match '(?m)^\s*Status:\s*(.+?)\s*$') { $Matches[1] } else { 'Unknown' }
            $requires = if ($raw -match '(?m)^\s*Requires:\s*(.+?)\s*$') { $Matches[1] } else { $null }
            $scopes = @(if ($raw -match '(?m)^\s*Graph scopes:\s*(.+?)\s*$') { @($Matches[1] -split ',\s*') } else { @() })
            $interactive = if ($raw -match '(?m)^\s*Interactive:\s*(.+?)\s*$') { $Matches[1] } else { $null }
            $paramHelp = @{}
            if ($help -and $help.PSObject.Properties.Name -contains 'parameters' -and $help.parameters -and $help.parameters.PSObject.Properties.Name -contains 'parameter') {
                foreach ($ph in @($help.parameters.parameter)) {
                    $desc = $ph.PSObject.Properties['description']
                    $paramHelp[$ph.name] = if ($desc -and $desc.Value) { (($desc.Value | ForEach-Object { $_.Text }) -join ' ').Trim() } else { '' }
                }
            }
            $parameters = foreach ($p in $cmd.Parameters.Values | Where-Object { $script:CommonParameters -notcontains $_.Name }) {
                $pa = $p.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | Select-Object -First 1
                $vs = $p.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | Select-Object -First 1
                $default = $null
                $declared = @($cmd.ScriptBlock.Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
                $ast = $cmd.ScriptBlock.Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $p.Name } | Select-Object -First 1
                if ($ast -and $ast.DefaultValue) { $default = $ast.DefaultValue.Extent.Text }
                [pscustomobject]@{
                    Name        = $p.Name
                    Type        = $p.ParameterType.Name
                    IsSwitch    = ($p.ParameterType -eq [switch])
                    IsArray     = $p.ParameterType.IsArray
                    Mandatory   = [bool]($pa -and $pa.Mandatory)
                    Default     = $default
                    ValidateSet = @(if ($vs) { @($vs.ValidValues) } else { @() })
                    Help        = if ($paramHelp.ContainsKey($p.Name)) { $paramHelp[$p.Name] } else { '' }
                    Position    = if ($pa) { $pa.Position } else { -1 }
                    Order       = [array]::IndexOf($declared, $p.Name)
                }
            }
            [pscustomobject]@{
                Name         = $file.BaseName
                Area         = $a.Name
                AreaLabel    = $a.Label
                Path         = $file.FullName
                RelativePath = $file.FullName.Substring($repoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
                Synopsis     = if ($help -and $help.Synopsis -and $help.Synopsis -notlike "*$($file.Name)*") { $help.Synopsis.Trim() } else { '' }
                Description  = if ($help -and $help.PSObject.Properties.Name -contains 'description' -and $help.description) { (($help.description | ForEach-Object { $_.Text }) -join "`n").Trim() } else { '' }
                Examples     = @(if ($help -and $help.PSObject.Properties.Name -contains 'examples' -and $help.examples -and $help.examples.PSObject.Properties.Name -contains 'example') { @($help.examples.example | ForEach-Object { ($_.code -replace '^\s*PS\s*>\s*', '').Trim() }) } else { @() })
                Status       = $status
                Requires     = $requires
                GraphScopes  = $scopes
                IsWrite      = $cmd.Parameters.ContainsKey('WhatIf')
                IsInteractive = [bool]($interactive -and $interactive -match '^(?i)(yes|true)')
                InteractiveNote = $interactive
                Parameters   = @($parameters | Sort-Object Order)
            }
        }
    }
}

function Assert-M365ReadOnlyCommand {
    <# .SYNOPSIS
        Accepts one allowlisted task with literal arguments; rejects executable expressions.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Line)
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Line, [ref]$null, [ref]$parseErrors)
    if ($parseErrors -or $ast.BeginBlock -or $ast.ProcessBlock -or $ast.ParamBlock -or
        -not $ast.EndBlock -or $ast.EndBlock.Statements.Count -ne 1) {
        throw 'Safe mode requires exactly one read-only task command.'
    }
    $pipeline = $ast.EndBlock.Statements[0]
    if ($pipeline -isnot [System.Management.Automation.Language.PipelineAst] -or $pipeline.PipelineElements.Count -ne 1 -or $pipeline.Background) {
        throw 'Safe mode refuses pipelines and additional statements.'
    }
    $command = $pipeline.PipelineElements[0]
    if ($command -isnot [System.Management.Automation.Language.CommandAst] -or
        $command.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Ampersand -or
        $command.CommandElements[0] -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
        throw 'Safe mode requires a literal task path.'
    }
    $allowedAst = @('ScriptBlockAst', 'NamedBlockAst', 'PipelineAst', 'CommandAst', 'CommandParameterAst',
        'StringConstantExpressionAst', 'ConstantExpressionAst', 'ArrayLiteralAst', 'VariableExpressionAst')
    $invalid = @($ast.FindAll({ param($node) $node.GetType().Name -notin $allowedAst -or
        ($node -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.VariablePath.UserPath -notin 'true', 'false', 'null') }, $true))
    if ($invalid.Count) { throw 'Safe mode accepts literal arguments only; expressions, redirection, and nested commands are refused.' }
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..' '..'))
    $path = $command.CommandElements[0].Value
    $full = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $root $path }))
    $task = Get-M365Task -ReadOnly | Where-Object { $_.Path -ceq $full } | Select-Object -First 1
    if (-not $task) { throw 'Safe mode refused a task outside the reviewed read-only allowlist.' }
    foreach ($parameter in $command.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] }) {
        if ($parameter.ParameterName -notin $task.Parameters.Name) { throw "Safe mode refused task parameter '$($parameter.ParameterName)'." }
    }
}

function Format-M365Argument {
    <#
    .SYNOPSIS
        Renders one value as a PowerShell literal for a command line: quoted string, number, $true/$false, or a comma list.
    .EXAMPLE
        Format-M365Argument @('a', "it's")   # 'a', 'it''s'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Value
    )
    #   GOTCHA PowerShell treats the typographic quotes Outlook and Word insert (U+2018,
    #          U+2019, U+201A, U+201B) as single quotes too. Escaping only ' lets a pasted name with a curly apostrophe end the string early,
    #          and a crafted value run a second command. CodeGeneration escapes all of them.
    $quote = { param($s) "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent("$s") + "'" }
    if ($null -eq $Value) { return "''" }
    if ($Value -is [switch]) { return $(if ($Value.IsPresent) { '$true' } else { '$false' }) }
    if ($Value -is [bool]) { return $(if ($Value) { '$true' } else { '$false' }) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return [string]::Format([cultureinfo]::InvariantCulture, '{0}', $Value) }
    if ($Value -is [array]) { return (($Value | ForEach-Object { Format-M365Argument $_ }) -join ', ') }
    if ($Value -is [System.Collections.IDictionary]) {
        $keys = if ($Value -is [System.Collections.Specialized.OrderedDictionary]) { @($Value.Keys) } else { @($Value.Keys | Sort-Object) }
        return '@{ ' + (($keys | ForEach-Object { "$(if ("$_" -match '^[A-Za-z_][A-Za-z0-9_]*$') { $_ } else { & $quote $_ }) = $(Format-M365Argument $Value[$_])" }) -join '; ') + ' }'
    }
    return (& $quote $Value)
}

function Format-M365CommandLine {
    <#
    .SYNOPSIS
        Builds the exact command line that runs a task script with the given values.
    .DESCRIPTION
        Output looks like:
            & './scripts/powershell/exchange/New-M365MailContact.ps1' -Organization 'contoso.onmicrosoft.com' -Name 'X' -HiddenFromAddressLists

        Built to be read by a person before it runs:
          - The script path is relative to the repo root when the script lives in the repo
            (the GUI and console run commands from the repo root).
          - The tenant comes first (TenantId, CustomerTenantId, Organization, Client,
            ConfigPath), then the parameters in the order given (pass an [ordered] dictionary
            in the script's own parameter order; a plain hashtable is sorted by name).
          - [switch] values: present -> -Name, not present -> omitted.
          - [bool] values (a [bool] parameter): always -Name:$true or -Name:$false, the only
            form PowerShell binds for a non-switch boolean.
          - Empty strings, $null and empty arrays are omitted; arrays become comma lists.
        -AppendWhatIf adds -WhatIf.
    .PARAMETER ScriptPath
        Absolute path of the script.
    .PARAMETER Values
        Parameter name -> value. Ordered dictionaries keep their order.
    .PARAMETER AppendWhatIf
        Append -WhatIf to the line (a dry run of the task).
    .PARAMETER RepoRoot
        Repo root used to shorten the path. Defaults to this repo.
    .EXAMPLE
        Format-M365CommandLine -ScriptPath $task.Path -Values ([ordered]@{ TenantId = 'x.onmicrosoft.com'; IncludeMfa = [switch]::new($true) })
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter()]
        [System.Collections.IDictionary]$Values = @{},

        [Parameter()]
        [switch]$AppendWhatIf,

        [Parameter()]
        [string]$RepoRoot
    )
    if (-not $RepoRoot) { $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..' '..')) }
    $shown = $ScriptPath
    if ([IO.Path]::IsPathRooted($ScriptPath)) {
        $full = [IO.Path]::GetFullPath($ScriptPath)
        $root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $shown = './' + ($full.Substring($root.Length) -replace '\\', '/') }
    }
    $parts = @("& $(Format-M365Argument $shown)")

    $order = if ($Values -is [System.Collections.Specialized.OrderedDictionary]) { @($Values.Keys) } else { @($Values.Keys | Sort-Object) }
    $lead = @('TenantId', 'CustomerTenantId', 'Organization', 'Client', 'ConfigPath')
    $order = @($lead | Where-Object { $order -contains $_ }) + @($order | Where-Object { $lead -notcontains $_ })
    foreach ($key in $order) {
        $v = $Values[$key]
        if ($null -eq $v) { continue }
        if ($v -is [string] -and [string]::IsNullOrWhiteSpace($v)) { continue }
        if ($v -is [array] -and $v.Count -eq 0) { continue }
        if ($v -is [switch]) { if ($v.IsPresent) { $parts += "-$key" }; continue }
        if ($v -is [bool]) { $parts += "-${key}:$(if ($v) { '$true' } else { '$false' })"; continue }
        $parts += "-$key $(Format-M365Argument $v)"
    }
    if ($AppendWhatIf) { $parts += '-WhatIf' }
    return ($parts -join ' ')
}

function ConvertTo-M365TaskValue {
    <#
    .SYNOPSIS
        Coerces text typed into a form field to the parameter's type (int, string[], bool, string).
    .DESCRIPTION
        Arrays split on commas or newlines and trim. Switches and booleans accept y/yes/true/1/on.
        A switch comes back as a [switch] (omitted from the command line when off); a [bool]
        parameter comes back as a [bool] (always written as -Name:$true / -Name:$false).
        Empty text returns $null so the command line omits the parameter.
    .PARAMETER Text
        What the operator typed.
    .PARAMETER Parameter
        One entry from Get-M365Task.Parameters.
    .EXAMPLE
        ConvertTo-M365TaskValue -Text 'a, b' -Parameter ($task.Parameters | Where-Object Name -eq Members)
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()][AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory)]
        [object]$Parameter
    )
    if ($Parameter.IsSwitch) { return [switch]::new($Text -match '^(y|yes|true|1|on)$') }
    if ($Parameter.Type -eq 'Boolean') { return ($Text -match '^(y|yes|true|1|on)$') }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    if ($Parameter.IsArray) { return @($Text -split '[,\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    if ($Parameter.Type -in 'Int32', 'Int64') { return [int]$Text }
    if ($Parameter.Type -eq 'Hashtable') {
        $h = @{}
        foreach ($pair in ($Text -split '[;\r\n]+' | Where-Object { $_ -match '=' })) { $k, $v = $pair -split '=', 2; $h[$k.Trim()] = $v.Trim() }
        return $h
    }
    return $Text.Trim()
}

Export-ModuleMember -Function Get-M365Task, Get-M365TaskArea, Format-M365Argument, Format-M365CommandLine, ConvertTo-M365TaskValue, Assert-M365ReadOnlyCommand
