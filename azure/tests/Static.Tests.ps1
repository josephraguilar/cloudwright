<#
    Cheap static checks across every script and module. CI has no Az module, so a
    wrong parameter name on an Az cmdlet only shows up twenty minutes into a real
    build. These catch the ones that have bitten.
#>
BeforeAll {
    $script:Files = Get-ChildItem -Path (Join-Path $PSScriptRoot '..') -Recurse -Include *.ps1, *.psm1 |
        Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' }
}

Describe 'Az cmdlet parameter names' {
    It 'VM lifecycle cmdlets use -Name, not -VMName' {
        # Get/New/Remove/Start/Stop/Restart-AzVM take -Name. Extension and Run Command cmdlets take -VMName.
        $bad = foreach ($f in $script:Files) {
            $n = 0
            foreach ($line in Get-Content $f.FullName) {
                $n++
                $code = ($line -replace '#.*$', '')   # drop trailing comments
                if ($code -match '\b(Get|New|Remove|Start|Stop|Restart)-AzVM\b[^|;]*-VMName\b') { "$($f.Name):$n  $($line.Trim())" }
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }
}

Describe 'Scripts hand -WhatIf on to module functions' {
    # A script's -WhatIf, -Verbose and -Confirm:$false do not reach the functions of
    # a module it imports (preference variables stop at the module boundary), so a
    # "dry run" would make the change for real. Set-AzScriptDefault fixes that; every
    # script that imports a repo module must call it after its imports.
    It 'every script that imports a repo module calls Set-AzScriptDefault after the imports' {
        $root = Join-Path $PSScriptRoot '..' 'scripts' 'powershell'
        $scripts = Get-ChildItem -Path $root -Recurse -Filter '*.ps1' |
            Where-Object { $_.FullName -notmatch '[\\/](modules|gui|library)[\\/]' -and $_.Name -notmatch '^(Start-Avd|_template)' }
        $bad = foreach ($f in $scripts) {
            $lines = @(Get-Content $f.FullName)
            $imports = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "^Import-Module .*'modules'") { $i } })
            if ($imports.Count -eq 0) { continue }
            $call = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^Set-AzScriptDefault\b') { $i } })
            if ($call.Count -eq 0 -or $call[0] -lt $imports[-1]) { $f.Name }
        }
        @($bad) | Should -BeNullOrEmpty
    }
}

Describe 'Every command resolves' {
    # A misspelt or renamed function only fails when someone clicks the button on
    # Windows. Every Verb-Noun call must be a function in the same file (or, for the
    # GUI, in the script or its page files), an export of a repo module, an Az or
    # Microsoft Graph cmdlet, or a built-in. In-guest scripts (library/, hostconfig/)
    # are skipped: they call Windows-only cmdlets the CI runner does not have.
    BeforeAll {
        $script:Ps = Join-Path $PSScriptRoot '..' 'scripts' 'powershell'
        $script:Exports = @{}
        foreach ($m in Get-ChildItem (Join-Path $script:Ps 'modules') -Filter '*.psd1' -Recurse) {
            foreach ($e in (Import-PowerShellDataFile $m.FullName).FunctionsToExport) { $script:Exports[$e] = $m.BaseName }
        }
        function Get-UnresolvedCommand {
            param([System.IO.FileInfo[]]$File, [hashtable]$AlsoDefined = @{})
            foreach ($f in $File) {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
                $defined = $AlsoDefined.Clone()
                foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $defined[$fn.Name] = 1 }
                foreach ($c in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                    $n = $c.GetCommandName()
                    if (-not $n -or $n -notmatch '^\w+-\w+$') { continue }
                    if ($defined.ContainsKey($n) -or $script:Exports.ContainsKey($n) -or $n -match '^\w+-(Az|Mg)') { continue }
                    if (Get-Command $n -ErrorAction SilentlyContinue) { continue }
                    "$($f.Name):$($c.Extent.StartLineNumber) $n"
                }
            }
        }
    }
    It 'in the GUI and its page files' {
        $files = @(Get-Item (Join-Path $script:Ps 'Start-AvdGui.ps1')) + @(Get-ChildItem (Join-Path $script:Ps 'gui' 'pages') -Filter '*.ps1')
        $all = @{}
        foreach ($f in $files) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $all[$fn.Name] = 1 }
        }
        @(Get-UnresolvedCommand -File $files -AlsoDefined $all) | Should -BeNullOrEmpty
    }
    It 'in the scripts and modules' {
        $files = @(Get-ChildItem $script:Ps -Recurse -Include '*.ps1', '*.psm1' |
            Where-Object { $_.FullName -notmatch '[\\/](gui|library|hostconfig)[\\/]' -and $_.Name -ne 'Start-AvdGui.ps1' })
        @(Get-UnresolvedCommand -File $files) | Should -BeNullOrEmpty
    }
}
