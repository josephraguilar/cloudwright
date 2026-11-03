<#
    Static checks for the WPF front end. WPF cannot run on the Linux CI runner, so
    these guard the things that would only fail at launch on Windows: XAML that is not
    well-formed XML, a control the script wires up but the shell does not define, a
    theme key the script asks for that the theme does not have, and the closure
    pattern that silently breaks when the script is run from a prompt.
#>
BeforeAll {
    $script:Root   = Join-Path $PSScriptRoot '..' 'scripts' 'powershell'
    # The main script plus the page files it dot-sources (gui/pages/*.ps1), read as one.
    $script:Script = (@(Get-Content (Join-Path $script:Root 'Start-AvdGui.ps1') -Raw) +
        @(Get-ChildItem (Join-Path $script:Root 'gui' 'pages') -Filter '*.ps1' | Sort-Object Name | ForEach-Object { Get-Content $_.FullName -Raw })) -join "`n"
    $script:Files = @(Get-Item (Join-Path $script:Root 'Start-AvdGui.ps1')) + @(Get-ChildItem (Join-Path $script:Root 'gui' 'pages') -Filter '*.ps1')
    $script:Shell  = Get-Content (Join-Path $script:Root 'gui' 'Shell.xaml') -Raw
    $script:Theme  = Get-Content (Join-Path $script:Root 'gui' 'Theme.xaml') -Raw
}

Describe 'GUI XAML' {
    It 'Shell.xaml is well-formed XML' { { [xml]$script:Shell } | Should -Not -Throw }
    It 'Theme.xaml is well-formed XML' { { [xml]$script:Theme } | Should -Not -Throw }
    It 'every other theme is well-formed and defines the same keys as Theme.xaml' {
        # -Theme <Name> loads gui/Theme.<Name>.xaml; a missing key would surface as a blank style at launch.
        $keys = @([regex]::Matches($script:Theme, 'x:Key="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
        $others = @(Get-ChildItem (Join-Path $script:Root 'gui') -Filter 'Theme.*.xaml')
        $others.Count | Should -BeGreaterThan 0
        foreach ($f in $others) {
            $t = Get-Content $f.FullName -Raw
            { [xml]$t } | Should -Not -Throw
            $k = @([regex]::Matches($t, 'x:Key="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
            ($k -join ',') | Should -Be ($keys -join ',')
        }
    }
    It 'no theme uses a StaticResource before defining it (XamlReader.Load throws on that)' {
        # StaticResource resolves against what the dictionary holds so far; a key defined
        # lower in the file is a load-time error with no useful message.
        foreach ($f in Get-ChildItem (Join-Path $script:Root 'gui') -Filter 'Theme*.xaml') {
            $t = Get-Content $f.FullName -Raw
            foreach ($m in [regex]::Matches($t, '\{StaticResource ([\w.]+)\}')) {
                $def = $t.IndexOf("x:Key=`"$($m.Groups[1].Value)`"")
                ($def -ge 0 -and $def -lt $m.Index) | Should -BeTrue -Because "$($f.Name): $($m.Groups[1].Value) is used at offset $($m.Index) but defined at $def"
            }
        }
    }
    It 'the -Theme parameter lists every theme file' {
        $names = @(Get-ChildItem (Join-Path $script:Root 'gui') -Filter 'Theme.*.xaml' | ForEach-Object { $_.Name -replace '^Theme\.|\.xaml$', '' })
        $set = [regex]::Match($script:Script, "\[ValidateSet\(([^)]+)\)\]\s*\[string\]\`$Theme").Groups[1].Value
        foreach ($n in $names) { $set | Should -Match "'$n'" }
        $set | Should -Match "'Ember'"
    }
    It 'XAML carries no x:Class or event attributes (XamlReader rejects them)' {
        $script:Shell | Should -Not -Match 'x:Class='
        $script:Shell | Should -Not -Match '\sClick='
    }
}

Describe 'Start-AvdGui.ps1 wiring' {
    It 'parses, with every page file' {
        foreach ($f in $script:Files) {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because $f.Name
        }
    }
    It 'defines each function once across the script and its page files' {
        $names = @([regex]::Matches($script:Script, '(?m)^function ([\w-]+)') | ForEach-Object { $_.Groups[1].Value })
        $names | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name | Should -BeNullOrEmpty
    }
    It 'every $Gui.Scripts entry points at a script that exists' {
        $block = [regex]::Match($script:Script, '(?s)Scripts\s*=\s*@\{(.*?)\n    \}').Groups[1].Value
        $refs = [regex]::Matches($block, "(\w+)\s*=\s*Join-Path \`$PSScriptRoot ((?:'[^']+'\s*)+)")
        $refs.Count | Should -BeGreaterThan 10
        foreach ($r in $refs) {
            $parts = @([regex]::Matches($r.Groups[2].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
            Test-Path (Join-Path $script:Root @parts) | Should -BeTrue -Because "$($r.Groups[1].Value) -> $($parts -join '/')"
        }
    }
    It 'every script the pages call through $Gui.Scripts is defined' {
        $block = [regex]::Match($script:Script, '(?s)Scripts\s*=\s*@\{(.*?)\n    \}').Groups[1].Value
        $keys = @([regex]::Matches($block, '(?m)^\s+(\w+)\s*=') | ForEach-Object { $_.Groups[1].Value })
        $used = @([regex]::Matches($script:Script, '\$Gui\.Scripts\.(\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        foreach ($u in $used) { $keys | Should -Contain $u }
    }
    It 'every module the worker loads exists' {
        foreach ($m in [regex]::Matches($script:Script, "Join-Path \`$PSScriptRoot 'modules' '(\w+)'\s+'(\w+\.psd1)'")) {
            Test-Path (Join-Path $script:Root 'modules' $m.Groups[1].Value $m.Groups[2].Value) | Should -BeTrue
        }
    }
    It 'uses no GetNewClosure and no $script: variables in code' {
        # Both break when the script is run from a prompt; see the Setup region notes.
        # Comments may mention them, so only code tokens count.
        $tokens = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($script:Script, [ref]$tokens, [ref]$null)
        $code = ($tokens | Where-Object Kind -ne 'Comment' | ForEach-Object Text) -join ' '
        ([regex]::Matches($code, 'GetNewClosure')).Count | Should -Be 0
        ([regex]::Matches($code, '\$script:')).Count | Should -Be 0
    }
    It 'every Gui.Ui.<Name> the script uses is an x:Name in Shell.xaml' {
        $defined = @([regex]::Matches($script:Shell, 'x:Name="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        $used = @([regex]::Matches($script:Script, '\$Gui\.Ui\.(\w+)(?!\w*\()') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $used | Should -Not -BeNullOrEmpty
        foreach ($u in $used) { $defined | Should -Contain $u }
    }
    It 'every page builder function is in the nav tree, and every nav builder exists' {
        # The rail and section panel are built from $Gui.NavTree; a page function that is
        # not in the tree is unreachable, and a tree entry naming a missing function throws at click.
        $tree = [regex]::Match($script:Script, '\$Gui\.NavTree = @\((?s:.*?)\n\)\n').Value
        $tree | Should -Not -BeNullOrEmpty
        $inTree = @([regex]::Matches($tree, "Builder = '(New-\w+Page)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $defined = @([regex]::Matches($script:Script, '(?m)^function (New-\w+Page)\b') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $inTree.Count | Should -BeGreaterThan 5
        foreach ($b in $inTree) { $defined | Should -Contain $b }
        foreach ($d in $defined | Where-Object { $_ -notin 'New-PageRoot', 'New-PlaceholderPage', 'New-AllFeaturesPage' }) { $inTree | Should -Contain $d }
    }
    It 'every Show-Page key is a page in the nav tree' {
        $tree = [regex]::Match($script:Script, '\$Gui\.NavTree = @\((?s:.*?)\n\)\n').Value
        $keys = @([regex]::Matches($tree, "Key = '(Nav\w+)'") | ForEach-Object { $_.Groups[1].Value }) + 'NavAll'
        $asked = @([regex]::Matches($script:Script, "Show-Page '(Nav\w+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $asked.Count | Should -BeGreaterThan 3
        foreach ($a in $asked) { $keys | Should -Contain $a }
        $keys | Sort-Object | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name | Should -BeNullOrEmpty
    }
    It 'every Then target in the host pools menu is a nav key' {
        $tree = [regex]::Match($script:Script, '\$Gui\.NavTree = @\((?s:.*?)\n\)\n').Value
        $keys = @([regex]::Matches($tree, "Key = '(Nav\w+)'") | ForEach-Object { $_.Groups[1].Value })
        foreach ($m in [regex]::Matches($script:Script, "(?:Then|See) = '(Nav\w+)'")) { $keys | Should -Contain $m.Groups[1].Value }
    }
    It 'every theme key the script asks for exists in Theme.xaml' {
        $keys = @([regex]::Matches($script:Theme, 'x:Key="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        $asked = @([regex]::Matches($script:Script, "(?:Get-ThemeResource|-Style) '([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $asked | Should -Not -BeNullOrEmpty
        foreach ($a in $asked) { $keys | Should -Contain $a }
    }
    It 'every Shell.xaml DynamicResource exists in Theme.xaml' {
        $keys = @([regex]::Matches($script:Theme, 'x:Key="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        $asked = @([regex]::Matches($script:Shell, '\{DynamicResource ([^}]+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        foreach ($a in $asked) { $keys | Should -Contain $a }
    }
}

Describe 'Start-AvdGui.ps1 parameter shadowing' {
    It 'no function assigns a local spelled like one of its typed parameters' {
        # Variable names are case-insensitive: "$tools = StackPanel" inside a function with
        # [object[]]$Tools converts the panel to an array, and the next property set fails
        # at launch. A different spelling is the tell that a different variable was meant.
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($script:Script, [ref]$null, [ref]$null)
        $bad = foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            if (-not $fn.Body.ParamBlock) { continue }
            $params = @($fn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            foreach ($as in $fn.Body.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
                $target = $as.Left
                if ($target -is [System.Management.Automation.Language.ConvertExpressionAst]) { $target = $target.Child }
                if ($target -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
                $name = $target.VariablePath.UserPath
                if (($params | Where-Object { $_ -ieq $name -and $_ -cne $name })) { "$($fn.Name) line $($as.Extent.StartLineNumber): `$$name" }
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }
}

Describe 'Start-AvdGui.ps1 never deletes' {
    # Design rule from the owner: deleting happens in the Azure portal, by a person.
    It 'references no Remove-* script, no reimage, no rollback and no stale-device deletion' {
        $tokens = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($script:Script, [ref]$tokens, [ref]$null)
        $code = ($tokens | Where-Object Kind -ne 'Comment' | ForEach-Object Text) -join ' '
        $code | Should -Not -Match 'Remove-Avd'
        $code | Should -Not -Match 'Remove-Az'
        $code | Should -Not -Match 'Invoke-AvdHostReimage'
        $code | Should -Not -Match 'RollbackOnFailure'
        $code | Should -Not -Match 'RemoveStaleEntraDevice'
    }
}

Describe 'Get-GridSelection' {
    It 'returns an array even for one selected row' {
        $src = Get-Content (Join-Path $PSScriptRoot '..' 'scripts' 'powershell' 'Start-AvdGui.ps1') -Raw
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-GridSelection' }, $true) | Select-Object -First 1
        . ([scriptblock]::Create($fn.Extent.Text))
        $dt = [System.Data.DataTable]::new(); $null = $dt.Columns.Add('Name'); $null = $dt.Columns.Add('Status')
        $r = $dt.NewRow(); $r['Name'] = 'vm1'; $r['Status'] = 'running'; $dt.Rows.Add($r)
        $fake = [pscustomobject]@{ SelectedItems = @($dt.DefaultView[0]) }
        $sel = Get-GridSelection $fake
        $sel.Count | Should -Be 1
        $sel[0].Name | Should -Be 'vm1'
        (Get-GridSelection ([pscustomobject]@{ SelectedItems = @() })).Count | Should -Be 0
    }
}
