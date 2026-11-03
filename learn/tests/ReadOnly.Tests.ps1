BeforeAll {
    $script:Src = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'src') 'MsScripter'
    $script:Files = Get-ChildItem -Path $script:Src -Filter '*.ps1' -Recurse -File
    $script:Entry = Join-Path (Join-Path $PSScriptRoot '..') 'Start-MsScripter.ps1'
}
Describe 'The one rule: ms-scripter never executes generated text' {
    It 'has no Invoke-Expression, iex, Invoke-Command, Start-Process, or .Invoke( anywhere in the engine' {
        foreach ($f in $script:Files + (Get-Item $script:Entry)) {
            $text = Get-Content $f.FullName -Raw
            $text | Should -Not -Match '(?im)^\s*[^#\r\n]*\bInvoke-Expression\b' -Because "$($f.Name) must not evaluate strings"
            $text | Should -Not -Match '(?im)^\s*[^#\r\n]*\biex\b'               -Because "$($f.Name) must not evaluate strings"
            $text | Should -Not -Match '(?im)^\s*[^#\r\n]*\bInvoke-Command\b'    -Because "$($f.Name) must not run scriptblocks remotely or locally"
            $text | Should -Not -Match '(?im)^\s*[^#\r\n]*\bStart-Process\b'     -Because "$($f.Name) must not launch anything"
            $text | Should -Not -Match '(?im)^\s*[^#\r\n]*\.Invoke\('            -Because "$($f.Name) must not invoke scriptblocks"
        }
    }
    It 'only calls a looked-up command in Resolve-MsSource, which enforces the read-only verb list' {
        foreach ($f in $script:Files) {
            if ($f.Name -eq 'Resolve-MsSource.ps1') { continue }
            (Get-Content $f.FullName -Raw) | Should -Not -Match '(?m)^\s*[^#\r\n]*&\s+\$command' -Because "$($f.Name) must not call dynamic commands"
        }
        (Get-Content (Join-Path (Join-Path $script:Src 'Private') 'Resolve-MsSource.ps1') -Raw) | Should -Match "'Get', 'Find', 'Search', 'Resolve'"
    }
    It 'asks Graph for read-only scopes only' {
        $text = Get-Content (Join-Path (Join-Path $script:Src 'Private') 'Assert-MsGraphContext.ps1') -Raw
        $text | Should -Not -Match 'ReadWrite'
        $text | Should -Not -Match '\.Write'
    }
}
