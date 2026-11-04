BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers/LegacyAzure.ps1')
    $script:AzureTestRoot = New-LegacyAzureTestCopy -Destination (Join-Path $TestDrive 'legacy-azure')
    $script:ManifestPath = Join-Path $script:AzureTestRoot 'scripts' 'powershell' 'modules' 'AvdHelpers' 'AvdHelpers.psd1'
}

Describe 'AvdHelpers module' {
    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'imports and exports the expected functions' {
        Import-Module $script:ManifestPath -Force
        $expected = @(
            'Resolve-AvdSessionHostName', 'Find-AvdSessionHost', 'Get-AvdSessionHostInfo',
            'Set-AvdSessionHostDrain', 'Get-AvdUserSession', 'Send-AvdUserMessage',
            'Remove-AvdUserSession', 'Wait-AvdSessionHostStatus', 'Wait-AvdSessionHostEmpty',
            'Get-AvdRegistrationToken', 'Start-AvdSessionHostVm', 'Stop-AvdSessionHostVm',
            'Restart-AvdSessionHostVm', 'Get-AvdVmRetailPrice', 'Get-AvdHostPoolOverview'
        )
        $actual = (Get-Command -Module AvdHelpers).Name
        foreach ($f in $expected) { $actual | Should -Contain $f }
    }

    Context 'Resolve-AvdSessionHostName' {
        BeforeAll { Import-Module $script:ManifestPath -Force }

        It 'strips the host pool prefix' {
            Resolve-AvdSessionHostName 'hp-lab/avd-01.corp.local' | Should -Be 'avd-01.corp.local'
        }
        It 'leaves a short name alone' {
            Resolve-AvdSessionHostName 'avd-01.corp.local' | Should -Be 'avd-01.corp.local'
        }
    }
}
