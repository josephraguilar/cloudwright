BeforeAll {
    $script:ManifestPath = Join-Path $PSScriptRoot '..' 'scripts' 'powershell' 'modules' 'EntraAdmin' 'EntraAdmin.psd1'
    $script:Source = Get-Content (Join-Path (Split-Path $script:ManifestPath) 'EntraAdmin.psm1') -Raw
    # CI has no Az module: a stub lets Pester mock the one Az call this module makes.
    # CI has no Az module. One stub with every parameter the modules pass, shared by the test files.
    if (-not (Get-Module -ListAvailable Az.Accounts)) { function global:Invoke-AzRestMethod { param($Method, $Path, $Uri, $Payload) } }
    Import-Module $script:ManifestPath -Force
}

Describe 'EntraAdmin module' {
    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }
    It 'exports what the manifest lists' {
        $expected = (Import-PowerShellDataFile $script:ManifestPath).FunctionsToExport
        $actual = (Get-Command -Module EntraAdmin).Name
        foreach ($f in $expected) { $actual | Should -Contain $f }
    }
    It 'every state-changing function supports -WhatIf' {
        foreach ($name in (Get-Command -Module EntraAdmin | Where-Object { $_.Verb -in 'New', 'Set', 'Add', 'Reset', 'Revoke' -and $_.Name -ne 'New-EntraPassword' }).Name) {
            (Get-Command $name).Parameters.ContainsKey('WhatIf') | Should -BeTrue -Because "$name changes state"
        }
    }
    It 'never deletes a user, a group, a member or a licence' {
        $script:Source | Should -Not -Match "Method\s+'?DELETE"
        $script:Source | Should -Not -Match 'Remove-'
        $script:Source | Should -Not -Match 'removeLicenses\s*=\s*@\(\s*@'
    }
}

Describe 'New-EntraPassword' {
    It 'meets complexity and length' {
        foreach ($i in 1..20) {
            $t = [System.Net.NetworkCredential]::new('', (New-EntraPassword -Length 14)).Password
            $t.Length | Should -Be 14
            $t | Should -MatchExactly '[A-Z]'
            $t | Should -MatchExactly '[a-z]'
            $t | Should -Match '\d'
            $t | Should -Match '[!@#$%*\-_=+?]'
            $t | Should -Not -MatchExactly '[O0Il1]'
        }
    }
}

Describe 'Invoke-EntraGraph' {
    It 'follows nextLink and returns every item' {
        Mock -ModuleName EntraAdmin Invoke-AzRestMethod {
            if ($Uri -match 'page2') { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[{"id":"c"}]}' } }
            else { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[{"id":"a"},{"id":"b"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/users?page2"}' } }
        }
        $r = @(Invoke-EntraGraph -Path 'users' -All)
        $r.Count | Should -Be 3
        $r[2].id | Should -Be 'c'
    }
    It 'returns an empty array for no items' {
        Mock -ModuleName EntraAdmin Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' } }
        @(Invoke-EntraGraph -Path 'users' -All).Count | Should -Be 0
    }
    It 'throws with the Graph error message' {
        Mock -ModuleName EntraAdmin Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 403; Content = '{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges"}}' } }
        { Invoke-EntraGraph -Path 'users' } | Should -Throw '*403: Insufficient privileges*'
    }
}

Describe 'Add-EntraGroupMember' {
    It 'refuses a dynamic group without calling POST' {
        Mock -ModuleName EntraAdmin Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 200; Content = '{"id":"g1","displayName":"Dyn","groupTypes":["DynamicMembership"],"onPremisesSyncEnabled":null}' }
        }
        { Add-EntraGroupMember -GroupId g1 -User someone } | Should -Throw '*dynamic*'
        Should -Invoke -ModuleName EntraAdmin Invoke-AzRestMethod -Times 0 -ParameterFilter { $Method -eq 'POST' }
    }
}

Describe 'Set-EntraUserSignIn' {
    It 'refuses a user synced from AD' {
        Mock -ModuleName EntraAdmin Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 200; Content = '{"id":"u1","userPrincipalName":"u@x.test","accountEnabled":true,"onPremisesSyncEnabled":true}' }
        }
        { Set-EntraUserSignIn -User u1 -Enabled $false } | Should -Throw '*synced from Active Directory*'
        Should -Invoke -ModuleName EntraAdmin Invoke-AzRestMethod -Times 0 -ParameterFilter { $Method -eq 'PATCH' }
    }
}
