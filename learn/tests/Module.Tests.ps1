BeforeAll {
    $script:ManifestPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'src') 'MsScripter') 'MsScripter.psd1'
}
Describe 'MsScripter module' {
    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }
    It 'exports exactly the public surface' {
        Import-Module $script:ManifestPath -Force
        $expected = 'Get-MsTaskCatalog', 'Get-MsTask', 'Test-MsTaskDefinition', 'New-MsScript', 'Show-MsScripter', 'Show-MsScripterWindow', 'Set-MsContosoMode', 'Get-MsContosoMode'
        $actual = (Get-Command -Module MsScripter).Name
        foreach ($f in $expected) { $actual | Should -Contain $f }
        $actual | Should -Not -Contain 'Read-MsField'
        $actual | Should -Not -Contain 'Resolve-MsSource'
    }
}
