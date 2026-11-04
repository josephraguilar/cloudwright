BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers/LegacyAzure.ps1')
    $script:AzureTestRoot = New-LegacyAzureTestCopy -Destination (Join-Path $TestDrive 'legacy-azure')
    $script:Manifest = Join-Path $script:AzureTestRoot 'scripts' 'powershell' 'modules' 'OpsAdmin' 'OpsAdmin.psd1'
    $script:Source = Get-Content (Join-Path (Split-Path $script:Manifest) 'OpsAdmin.psm1') -Raw
    # CI has no Az module. One stub with every parameter the modules pass, shared by the test files.
    if (-not (Get-Module -ListAvailable Az.Accounts)) { function global:Invoke-AzRestMethod { param($Method, $Path, $Uri, $Payload) } }
    Import-Module $script:Manifest -Force
}

Describe 'OpsAdmin module' {
    It 'has a valid manifest' { { Test-ModuleManifest -Path $script:Manifest -ErrorAction Stop } | Should -Not -Throw }
    It 'exports what the manifest lists' {
        $actual = (Get-Command -Module OpsAdmin).Name
        foreach ($f in (Import-PowerShellDataFile $script:Manifest).FunctionsToExport) { $actual | Should -Contain $f }
    }
    It 'every state-changing function supports -WhatIf' {
        foreach ($n in (Get-Command -Module OpsAdmin | Where-Object { $_.Verb -in 'New', 'Set' }).Name) {
            (Get-Command $n).Parameters.ContainsKey('WhatIf') | Should -BeTrue -Because "$n changes state"
        }
    }
    It 'never deletes' {
        $script:Source | Should -Not -Match 'Remove-Az'
        $script:Source | Should -Not -Match "Method\s+'?DELETE"
    }
}

Describe 'ConvertTo-OpsHtmlReport' {
    It 'encodes values and writes one table per section' {
        $html = ConvertTo-OpsHtmlReport -Title 'T <x>' -Section ([ordered]@{ 'A' = @([pscustomobject]@{ Name = '<script>'; N = 1 }); 'Empty' = @() })
        $html | Should -Match '&lt;script&gt;'
        $html | Should -Not -Match '<script>'
        ([regex]::Matches($html, '<table>')).Count | Should -Be 1
        $html | Should -Match 'None\.'
    }
}

Describe 'Cost queries' {
    It 'pages through nextLink and names columns' {
        Mock -ModuleName OpsAdmin Invoke-AzRestMethod {
            if ($Path -match 'skiptoken') { [pscustomobject]@{ StatusCode = 200; Content = '{"properties":{"columns":[{"name":"Cost"},{"name":"ResourceGroupName"},{"name":"Currency"}],"rows":[[2.5,"rg-b","USD"]],"nextLink":null}}' } }
            else { [pscustomobject]@{ StatusCode = 200; Content = '{"properties":{"columns":[{"name":"Cost"},{"name":"ResourceGroupName"},{"name":"Currency"}],"rows":[[10.123,"rg-a","USD"]],"nextLink":"https://management.azure.com/subscriptions/s/providers/Microsoft.CostManagement/query?api-version=2023-03-01&$skiptoken=abc"}}' } }
        }
        $r = @(Get-OpsCost -SubscriptionId s -GroupBy ResourceGroupName)
        $r.Count | Should -Be 2
        $r[0].Item | Should -Be 'rg-a'
        $r[0].Cost | Should -Be 10.12
        $r[1].Item | Should -Be 'rg-b'
    }
    It 'formats daily rows as dates' {
        Mock -ModuleName OpsAdmin Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"properties":{"columns":[{"name":"Cost"},{"name":"UsageDate"},{"name":"Currency"}],"rows":[[1,20261017,"USD"]]}}' } }
        (@(Get-OpsCost -SubscriptionId s -GroupBy Day))[0].Item | Should -Be '2026-10-17'
    }
    It 'falls back to PreTaxCost when Cost is refused' {
        $script:calls = 0
        Mock -ModuleName OpsAdmin Invoke-AzRestMethod {
            if ($Payload -match 'PreTaxCost') { [pscustomobject]@{ StatusCode = 200; Content = '{"properties":{"columns":[{"name":"PreTaxCost"},{"name":"ServiceName"},{"name":"Currency"}],"rows":[[3,"Storage","USD"]]}}' } }
            else { [pscustomobject]@{ StatusCode = 400; Content = '{"error":{"message":"bad column"}}' } }
        }
        (@(Get-OpsCost -SubscriptionId s -GroupBy ServiceName))[0].Cost | Should -Be 3
    }
}
