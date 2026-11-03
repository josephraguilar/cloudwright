BeforeAll {
    Import-Module (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'src') 'MsScripter') 'MsScripter.psd1') -Force
    $script:CatalogRoot = Join-Path (Join-Path $PSScriptRoot '..') 'catalog'
    $script:Files = Get-ChildItem -Path $script:CatalogRoot -Filter '*.psd1' -Recurse -File | Where-Object Name -notlike '_*'
}
Describe 'Catalog' {
    It 'has at least one task' {
        $script:Files.Count | Should -BeGreaterThan 0
    }
    It 'loads strictly with no invalid entries' {
        { Get-MsTaskCatalog -CatalogRoot $script:CatalogRoot -Strict } | Should -Not -Throw
    }
    It 'has unique Ids' {
        $ids = (Get-MsTaskCatalog -CatalogRoot $script:CatalogRoot -Strict).Id
        ($ids | Group-Object | Where-Object Count -gt 1).Count | Should -Be 0
    }
    It 'only references existing tasks in Prerequisites and paths' {
        $catalog = Get-MsTaskCatalog -CatalogRoot $script:CatalogRoot -Strict
        $ids = $catalog.Id
        foreach ($entry in $catalog) {
            $d = $entry.Definition
            if ($d.ContainsKey('Prerequisites')) { foreach ($p in @($d.Prerequisites)) { $ids | Should -Contain $p -Because "$($entry.Id) lists it as a prerequisite" } }
            if ($entry.Kind -eq 'Path') { foreach ($p in @($d.Tasks)) { $ids | Should -Contain $p -Because "path $($entry.Id) lists it" } }
        }
    }
    It 'has no prerequisite cycles' {
        $catalog = Get-MsTaskCatalog -CatalogRoot $script:CatalogRoot -Strict | Where-Object Kind -eq 'Task'
        $graph = @{}
        foreach ($t in $catalog) { $graph[$t.Id] = @($(if ($t.Definition.ContainsKey('Prerequisites')) { $t.Definition.Prerequisites } else { @() })) }
        $visiting = @{}; $done = @{}
        function Test-Cycle($node) {
            if ($done.ContainsKey($node)) { return $false }
            if ($visiting.ContainsKey($node)) { return $true }
            $visiting[$node] = $true
            foreach ($n in $graph[$node]) { if ($graph.ContainsKey($n) -and (Test-Cycle $n)) { return $true } }
            $visiting.Remove($node); $done[$node] = $true
            return $false
        }
        foreach ($id in $graph.Keys) { (Test-Cycle $id) | Should -BeFalse -Because "$id is in a prerequisite cycle" }
    }
}
Describe 'Test-MsTaskDefinition' {
    It 'rejects a write cmdlet as a lookup source' {
        $bad = Import-PowerShellDataFile (Join-Path (Join-Path (Join-Path $script:CatalogRoot 'azure') 'create') 'resource-group.psd1')
        $bad.Fields[1].Source.Cmdlet = 'Remove-AzLocation'
        (Test-MsTaskDefinition -Task $bad) -join ' ' | Should -Match 'not read-only'
    }
    It 'rejects a template token that is not a field' {
        $bad = Import-PowerShellDataFile (Join-Path (Join-Path (Join-Path $script:CatalogRoot 'azure') 'create') 'resource-group.psd1')
        $bad.Verify = @('Get-Thing {{Nope}}')
        (Test-MsTaskDefinition -Task $bad) -join ' ' | Should -Match 'Nope'
    }
    It 'rejects an Id that does not match the path' {
        $t = Import-PowerShellDataFile (Join-Path (Join-Path (Join-Path $script:CatalogRoot 'azure') 'create') 'resource-group.psd1')
        (Test-MsTaskDefinition -Task $t -Path '/repo/catalog/azure/network/resource-group.psd1') -join ' ' | Should -Match 'does not match its path'
    }
}
