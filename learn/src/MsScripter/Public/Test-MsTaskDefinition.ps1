function Test-MsTaskDefinition {
    <#
    .SYNOPSIS
        Check a task hashtable against the schema in docs/architecture.md.
    .DESCRIPTION
        Returns a list of problem strings. Empty list means valid. Never throws, so the
        catalog test can report every broken task at once instead of stopping at the first.
    .PARAMETER Task
        The hashtable from Import-PowerShellDataFile.
    .PARAMETER Path
        Optional. The file it came from, used to check that Id matches the folder path.
    .EXAMPLE
        $problems = Test-MsTaskDefinition -Task (Import-PowerShellDataFile ./catalog/azure/create/resource-group.psd1)
        if ($problems) { $problems }
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [hashtable]$Task,
        [Parameter()] [string]$Path
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    $fieldTypes  = 'String', 'Int', 'Bool', 'TrueFalse', 'Choice', 'MultiChoice', 'Hashtable', 'Secret', 'Reference'
    $authKinds   = 'Azure', 'Graph', 'ExchangeOnline', 'None'
    $sourceVerbs = 'Get', 'Find', 'Search', 'Resolve'

    #region 1. Top-level keys ---------------------------------------------------
    foreach ($key in 'Id', 'Title', 'Summary', 'Requires', 'Fields', 'Steps', 'Status') {
        if (-not $Task.ContainsKey($key)) { $problems.Add("Missing required key '$key'.") }
    }
    if ($Task.ContainsKey('Id')) {
        if ($Task.Id -notmatch '^[a-z0-9]+(\.[a-z0-9-]+){2,}$') {
            $problems.Add("Id '$($Task.Id)' must look like 'area.section.slug' in lowercase.")
        }
        if ($Path) {
            # catalog/azure/create/resource-group.psd1 -> azure.create.resource-group
            $rel = ($Path -replace '\\', '/') -replace '^.*?/catalog/', ''
            $expected = ($rel -replace '\.psd1$', '') -replace '/', '.'
            if ($Task.Id -ne $expected) { $problems.Add("Id '$($Task.Id)' does not match its path (expected '$expected').") }
        }
    }
    if ($Task.ContainsKey('Status') -and $Task.Status -notmatch '^(Untested|Tested \d{4}-\d{2}-\d{2})$') {
        $problems.Add("Status must be 'Untested' or 'Tested yyyy-mm-dd', got '$($Task.Status)'.")
    }
    if ($Task.ContainsKey('Requires')) {
        $r = $Task.Requires
        if ($r -isnot [hashtable]) { $problems.Add('Requires must be a hashtable.') }
        elseif (-not $r.ContainsKey('Auth') -or $r.Auth -notin $authKinds) { $problems.Add("Requires.Auth must be one of: $($authKinds -join ', ').") }
    }
    foreach ($listKey in 'Learn', 'Prerequisites', 'Verify', 'Rollback', 'Docs') {
        if ($Task.ContainsKey($listKey) -and $Task[$listKey] -isnot [array] -and $Task[$listKey] -isnot [string]) {
            $problems.Add("$listKey must be an array of strings.")
        }
    }
    #endregion

    #region 2. Fields -----------------------------------------------------------
    $fieldNames = @()
    if ($Task.ContainsKey('Fields')) {
        foreach ($f in @($Task.Fields)) {
            if ($f -isnot [hashtable]) { $problems.Add('Every Field must be a hashtable.'); continue }
            $label = if ($f.ContainsKey('Name')) { $f.Name } else { '<unnamed>' }
            foreach ($key in 'Name', 'Label', 'Type', 'Help') {
                if (-not $f.ContainsKey($key) -or "$($f[$key])".Trim() -eq '') { $problems.Add("Field $label is missing '$key'.") }
            }
            if ($f.ContainsKey('Name')) {
                if ($f.Name -notmatch '^[A-Za-z][A-Za-z0-9_]*$') { $problems.Add("Field name '$($f.Name)' must be a plain identifier.") }
                if ($f.Name -in $fieldNames) { $problems.Add("Field name '$($f.Name)' is used twice.") }
                $fieldNames += $f.Name
            }
            if ($f.ContainsKey('Type') -and $f.Type -notin $fieldTypes) { $problems.Add("Field $label has unknown Type '$($f.Type)'.") }
            if ($f.ContainsKey('Type') -and $f.Type -in 'Choice', 'MultiChoice' -and -not ($f.ContainsKey('Options') -or $f.ContainsKey('Source'))) {
                $problems.Add("Field $label is a $($f.Type) but has neither Options nor Source.")
            }
            if ($f.ContainsKey('Type') -and $f.Type -eq 'Reference' -and -not $f.ContainsKey('From')) {
                $problems.Add("Field $label is a Reference but has no From.")
            }
            if ($f.ContainsKey('Source')) {
                $s = $f.Source
                if ($s -isnot [hashtable] -or -not $s.ContainsKey('Cmdlet')) { $problems.Add("Field $label Source needs a Cmdlet.") }
                else {
                    $verb = ($s.Cmdlet -split '-')[0]
                    if ($verb -notin $sourceVerbs) { $problems.Add("Field $label Source cmdlet '$($s.Cmdlet)' is not read-only (verb must be $($sourceVerbs -join '/')).") }
                    foreach ($key in 'Display', 'Value', 'Auth') {
                        if (-not $s.ContainsKey($key)) { $problems.Add("Field $label Source is missing '$key'.") }
                    }
                }
            }
            if ($f.ContainsKey('SecretKind') -and $f.SecretKind -notin 'Credential', 'SecureString', 'PlainText') {
                $problems.Add("Field $label SecretKind must be Credential, SecureString, or PlainText.")
            }
            if ($f.ContainsKey('Pattern')) {
                try { $null = [regex]::new($f.Pattern) } catch { $problems.Add("Field $label Pattern is not a valid regex.") }
            }
        }
    }
    #endregion

    #region 3. Steps and templates ---------------------------------------------
    $templates = [System.Collections.Generic.List[string]]::new()
    if ($Task.ContainsKey('Steps')) {
        $i = 0
        foreach ($s in @($Task.Steps)) {
            $i++
            if ($s -isnot [hashtable]) { $problems.Add("Step $i must be a hashtable."); continue }
            foreach ($key in 'Title', 'What', 'Why') {
                if (-not $s.ContainsKey($key)) { $problems.Add("Step $i is missing '$key'.") }
            }
            $hasCmdlet = $s.ContainsKey('Cmdlet'); $hasRaw = $s.ContainsKey('Raw')
            if (-not ($hasCmdlet -xor $hasRaw)) { $problems.Add("Step $i must have exactly one of Cmdlet or Raw.") }
            if ($hasCmdlet) {
                if ($s.Cmdlet -notmatch '^[A-Z][a-z]+-[A-Za-z0-9]+$') { $problems.Add("Step $i Cmdlet '$($s.Cmdlet)' is not Verb-Noun.") }
                if ($s.ContainsKey('Parameters')) {
                    if ($s.Parameters -isnot [hashtable]) { $problems.Add("Step $i Parameters must be a hashtable.") }
                    else { foreach ($v in $s.Parameters.Values) { $templates.Add("$v") } }
                }
                $fixed = if ($s.ContainsKey('Fixed')) { @($s.Fixed) } else { @() }
                foreach ($fx in $fixed) {
                    if (-not $s.ContainsKey('Parameters') -or -not $s.Parameters.ContainsKey($fx)) { $problems.Add("Step $i Fixed names '$fx' which is not in Parameters.") }
                }
                if ($s.ContainsKey('Parameters') -and $s.Parameters -is [hashtable]) {
                    foreach ($pk in $s.Parameters.Keys) {
                        $pv = "$($s.Parameters[$pk])"
                        if ($pv -notmatch '\{\{' -and $pv -notmatch '^\$(?!true$|false$)[A-Za-z]' -and $pk -notin $fixed) {
                            $problems.Add("Step $i parameter -$pk is hardcoded ('$pv') with no field. Give it a Field, or list it under Fixed if it defines the task.")
                        }
                    }
                }
                if ($s.ContainsKey('BoolParameters')) {
                    foreach ($p in @($s.BoolParameters)) {
                        if (-not $s.ContainsKey('Parameters') -or -not $s.Parameters.ContainsKey($p)) { $problems.Add("Step $i BoolParameters names '$p' which is not in Parameters.") }
                    }
                }
                if ($s.ContainsKey('ParameterOrder')) {
                    foreach ($p in @($s.ParameterOrder)) {
                        if (-not $s.Parameters.ContainsKey($p)) { $problems.Add("Step $i ParameterOrder names '$p' which is not in Parameters.") }
                    }
                }
            }
            if ($hasRaw) {
                $fixed = if ($s.ContainsKey('Fixed')) { @($s.Fixed) } else { @() }
                $ignore = 'AutoSize', 'Descending', 'First', 'Last', 'ExpandProperty', 'Property', 'Wrap', 'Unique', 'ErrorAction', 'Filter', 'Command', 'SearchString', 'Prompt', 'Message'
                foreach ($line in @($s.Raw)) {
                    $templates.Add("$line")
                    $flagPattern = '(?<![\w\-])-(?<name>[A-Z][A-Za-z]+)(?<colon>:\$(?:true|false))?(?:\s+(?<val>''[^'']*''|\d+|[A-Za-z][\w\.]*))?(?=[\s\)\|;]|$)'
                    foreach ($m in [regex]::Matches("$line", $flagPattern)) {
                        $name = $m.Groups['name'].Value
                        if ($name -in $ignore -or $name -in $fixed) { continue }
                        $val = $m.Groups['val'].Value
                        $tail = "$line".Substring($m.Index + $m.Length)
                        if ($tail -match '^\s*(\{\{|\(|\$|@|"|\[)') { continue }       # value is a field, an expression, a variable, a hashtable, or a double-quoted string
                        if ($val -match '\{\{') { continue }
                        $problems.Add("Step $i Raw has a hardcoded flag -$name $val with no field. Give it a Field token, or list '$name' under Fixed.")
                    }
                }
            }
            if ($s.ContainsKey('When') -and $s.When -notin $fieldNames) { $problems.Add("Step $i When='$($s.When)' is not a field.") }
            if ($s.ContainsKey('Output') -and $s.Output -notmatch '^[a-z][A-Za-z0-9]*$') { $problems.Add("Step $i Output '$($s.Output)' must be a camelCase variable name.") }
        }
    }
    foreach ($listKey in 'Verify', 'Rollback') {
        if ($Task.ContainsKey($listKey)) { foreach ($line in @($Task[$listKey])) { $templates.Add("$line") } }
    }
    foreach ($t in $templates) {
        foreach ($m in [regex]::Matches($t, '\{\{([A-Za-z][A-Za-z0-9_]*)(?::raw|:filter:(?:displayName|mailNickname))?\}\}')) {
            if ($m.Groups[1].Value -notin $fieldNames) { $problems.Add("Template token '$($m.Value)' does not name a field.") }
        }
    }
    #endregion

    return $problems.ToArray()
}
