BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers/LegacyAzure.ps1')
    $script:AzureTestRoot = New-LegacyAzureTestCopy -Destination (Join-Path $TestDrive 'legacy-azure')
    $script:ManifestPath = Join-Path $script:AzureTestRoot 'scripts' 'powershell' 'modules' 'ServerBuild' 'ServerBuild.psd1'
    $script:HostConfig = Join-Path $script:AzureTestRoot 'scripts' 'powershell' 'modules' 'ServerBuild' 'hostconfig'
}

Describe 'ServerBuild module' {
    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'imports and exports the expected functions' {
        Import-Module $script:ManifestPath -Force
        $expected = @(
            'Get-ServerVmInfo', 'Start-ServerVm', 'Stop-ServerVm', 'Restart-ServerVm',
            'Get-ServerImageCatalog', 'Resolve-ServerImage', 'New-ServerNic', 'New-ServerVm',
            'Invoke-ServerScript', 'Initialize-ServerDataDisk', 'Install-ServerWebRole', 'Install-ServerAdForest',
            'Set-ServerSqlConfig', 'Register-ServerSqlVm', 'Set-ServerVNetDnsServer',
            'Get-ServerCallerIp', 'Get-ServerRdpAccess', 'Grant-ServerRdpAccess', 'Revoke-ServerRdpAccess', 'New-ServerRdpFile'
        )
        $actual = (Get-Command -Module ServerBuild).Name
        foreach ($f in $expected) { $actual | Should -Contain $f }
    }

    It 'ships the in-guest role scripts next to the module' {
        foreach ($f in 'Initialize-DataDisk.ps1', 'Install-IisRole.ps1', 'Install-AdForest.ps1', 'Set-AdPostConfig.ps1', 'Set-SqlPostConfig.ps1') {
            Test-Path (Join-Path $script:HostConfig $f) | Should -BeTrue -Because "$f is run inside the VM"
        }
    }

    It 'every state-changing function supports -WhatIf' {
        Import-Module $script:ManifestPath -Force
        foreach ($name in (Get-Command -Module ServerBuild | Where-Object { $_.Verb -in 'New', 'Set', 'Install', 'Initialize', 'Register', 'Start', 'Stop', 'Restart', 'Invoke', 'Grant', 'Revoke' }).Name) {
            (Get-Command $name).Parameters.ContainsKey('WhatIf') | Should -BeTrue -Because "$name changes state"
        }
    }

    It 'in-guest scripts never delete and parse cleanly' {
        foreach ($f in Get-ChildItem $script:HostConfig -Filter *.ps1) {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because "$($f.Name) must parse"
            (Get-Content $f.FullName -Raw) | Should -Not -Match 'Remove-Item|Remove-AD|Uninstall-'
        }
    }
}
