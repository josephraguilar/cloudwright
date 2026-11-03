BeforeAll {
    Import-Module (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'src') 'MsScripter') 'MsScripter.psd1') -Force
    $script:CatalogRoot = Join-Path (Join-Path $PSScriptRoot '..') 'catalog'
    $script:Sample = Import-PowerShellDataFile (Join-Path $script:CatalogRoot '_contoso.psd1')
}
AfterAll { $null = Set-MsContosoMode -Off }

Describe 'Contoso sample data' {
    It 'has a Context with tenant and subscription' {
        foreach ($k in 'TenantId', 'TenantDomain', 'SubscriptionName', 'SubscriptionId', 'Account') { $script:Sample.Context.ContainsKey($k) | Should -BeTrue -Because $k }
        $script:Sample.Context.TenantDomain | Should -Match 'contoso'
    }
    It 'covers every lookup cmdlet used by any field, with the Display and Value properties' {
        $catalog = Get-MsTaskCatalog -CatalogRoot $script:CatalogRoot -Strict | Where-Object Kind -eq 'Task'
        foreach ($t in $catalog) {
            foreach ($f in @($t.Definition.Fields)) {
                if (-not $f.ContainsKey('Source')) { continue }
                $src = $f.Source
                $script:Sample.ContainsKey($src.Cmdlet) | Should -BeTrue -Because "$($t.Id)/$($f.Name) looks up $($src.Cmdlet)"
                $rows = @($script:Sample[$src.Cmdlet])
                $rows.Count | Should -BeGreaterThan 0 -Because $src.Cmdlet
                foreach ($row in $rows) {
                    $row.ContainsKey($src.Display) | Should -BeTrue -Because "$($src.Cmdlet) rows need $($src.Display) (Display for $($t.Id)/$($f.Name))"
                    $row.ContainsKey($src.Value)   | Should -BeTrue -Because "$($src.Cmdlet) rows need $($src.Value) (Value for $($t.Id)/$($f.Name))"
                }
            }
        }
    }
    It 'contains nothing that looks like a real tenant: only contoso domains' {
        $text = Get-Content (Join-Path $script:CatalogRoot '_contoso.psd1') -Raw
        foreach ($m in [regex]::Matches($text, '[\w.-]+@[\w.-]+')) { $m.Value | Should -Match '@contoso\.(com|onmicrosoft\.com)$' }
    }
}

Describe 'Contoso mode lookups' {
    It 'is off by default and toggles' {
        Get-MsContosoMode | Should -BeFalse
        $ctx = Set-MsContosoMode
        Get-MsContosoMode | Should -BeTrue
        $ctx.SubscriptionName | Should -Be 'Contoso Production'
        $null = Set-MsContosoMode -Off
        Get-MsContosoMode | Should -BeFalse
    }
    It 'serves sample rows without any connection and filters by scoped parameters' {
        $null = Set-MsContosoMode
        InModuleScope MsScripter {
            $fields = @(@{ Name = 'ResourceGroupName'; Label = 'RG'; Type = 'Choice'; Help = 'x' }, @{ Name = 'VNetName'; Label = 'V'; Type = 'Choice'; Help = 'x' })
            $src = @{ Cmdlet = 'Get-AzVirtualNetwork'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' }
            $all   = Resolve-MsSource -Source $src -Answers @{} -Fields $fields
            $inLab = Resolve-MsSource -Source $src -Answers @{ ResourceGroupName = 'rg-contoso-avd-lab' } -Fields $fields
            @($all).Count | Should -BeGreaterThan @($inLab).Count
            @($inLab).Count | Should -Be 1
            $inLab[0].Value | Should -Be 'vnet-contoso-avd-lab'
        }
        $null = Set-MsContosoMode -Off
    }
    It 'ignores switch-style parameters such as -All when filtering' {
        $null = Set-MsContosoMode
        InModuleScope MsScripter {
            $src = @{ Cmdlet = 'Get-MgUser'; Parameters = @{ All = '$true' }; Display = 'UserPrincipalName'; Value = 'UserPrincipalName'; Auth = 'Graph' }
            $users = Resolve-MsSource -Source $src -Answers @{} -Fields @()
            @($users).Count | Should -BeGreaterThan 5
            $users.Value | Should -Contain 'adele.vance@contoso.com'
        }
        $null = Set-MsContosoMode -Off
    }
    It 'every task generates from Contoso defaults alone: first sample row per lookup, example per text field' {
        $null = Set-MsContosoMode
        $catalog = Get-MsTaskCatalog -CatalogRoot $script:CatalogRoot -Strict | Where-Object Kind -eq 'Task'
        InModuleScope MsScripter -Parameters @{ catalog = $catalog } {
            foreach ($t in $catalog) {
                $answers = @{}
                foreach ($f in @($t.Definition.Fields)) {
                    if ($f.Type -in 'Secret', 'Reference') { continue }
                    $v = $null
                    if ($f.ContainsKey('Source')) {
                        $items = Resolve-MsSource -Source $f.Source -Answers $answers -Fields @($t.Definition.Fields)
                        if ($items) { $v = @($items)[0].Value; if ($f.Type -eq 'MultiChoice') { $v = @($v) } }
                    } elseif ($f.ContainsKey('Options')) {
                        $o = @($f.Options)[0]; $v = if ($o -is [hashtable]) { $o.Value } else { "$o" }
                        if ($f.Type -eq 'MultiChoice') { $v = @($v) }
                    } elseif ($f.Type -in 'Bool', 'TrueFalse') { $v = $true }
                    elseif ($f.ContainsKey('Default') -and "$($f.Default)" -ne '') { $v = $f.Default }
                    elseif ($f.ContainsKey('Example')) { $v = $f.Example }
                    if ($f.Type -eq 'Hashtable' -and $v -is [string]) { $v = ConvertFrom-MsFieldText -Text $v -Type Hashtable }
                    if ($null -ne $v -and "$v" -ne '') { $answers[$f.Name] = $v }
                }
                { New-MsScript -Task $t -Answers $answers -Context (Get-MsSampleData).Context } | Should -Not -Throw -Because "$($t.Id) should generate from Contoso defaults alone"
            }
        }
        $null = Set-MsContosoMode -Off
    }
}
