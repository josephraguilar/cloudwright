BeforeAll {
    $script:ManifestPath = Join-Path $PSScriptRoot '..' 'scripts' 'powershell' 'modules' 'AvdBuild' 'AvdBuild.psd1'
}

Describe 'Directory cleanup safety' {
    BeforeAll {
        Import-Module $script:ManifestPath -Force
        function global:Invoke-AzRestMethod { [CmdletBinding()] param($Method, $Uri) throw 'Unexpected live API call' }
    }
    AfterAll { Remove-Item Function:\Invoke-AzRestMethod -ErrorAction SilentlyContinue }

    It 'rejects filter-injection input before making an API request' {
        Mock Invoke-AzRestMethod -ModuleName AvdBuild { throw 'Must not call Graph' }
        { Find-AvdEntraDevice -Name "x' or id ne '" } | Should -Throw
        Should -Invoke Invoke-AzRestMethod -ModuleName AvdBuild -Times 0
    }

    It 'uses an encoded exact-name lookup and checks the returned name' {
        Mock Invoke-AzRestMethod -ModuleName AvdBuild {
            [pscustomobject]@{ StatusCode = 200; Content = '{"value":[{"id":"device-1","displayName":"avd-lab-01"}]}' }
        }
        @(Find-AvdEntraDevice -Name 'avd-lab-01').Count | Should -Be 1
        Should -Invoke Invoke-AzRestMethod -ModuleName AvdBuild -Times 1 -ParameterFilter {
            $Method -eq 'GET' -and [uri]::UnescapeDataString($Uri) -ceq "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq 'avd-lab-01'"
        }
    }

    It 'refuses unrelated results even when the server reports success' {
        Mock Invoke-AzRestMethod -ModuleName AvdBuild {
            [pscustomobject]@{ StatusCode = 200; Content = '{"value":[{"id":"device-1","displayName":"unrelated"}]}' }
        }
        { Find-AvdEntraDevice -Name 'avd-lab-01' } | Should -Throw '*different display name*'
    }

    It 'blocks name-based device and application deletion even with confirmation disabled' {
        Mock Invoke-AzRestMethod -ModuleName AvdBuild { throw 'Must not call Graph' }
        { Remove-AvdEntraDevice -Name 'avd-lab-01' -Confirm:$false } | Should -Throw '*disabled*'
        { Remove-AvdEntraDevice -Name "x' or id ne '" -WhatIf } | Should -Throw '*disabled*'
        { Remove-AvdStorageKerberosApp -StorageAccountName 'stlab' -Confirm:$false } | Should -Throw '*disabled*'
        { Remove-AvdStorageKerberosApp -StorageAccountName "x' or id ne '" -WhatIf } | Should -Throw '*disabled*'
        Should -Invoke Invoke-AzRestMethod -ModuleName AvdBuild -Times 0
    }
}

Describe 'AvdBuild module' {
    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'imports and exports one function per build step' {
        Import-Module $script:ManifestPath -Force
        $expected = @(
            'Resolve-AvdImage', 'New-AvdSessionHostNic', 'New-AvdSessionHostVm', 'Join-AvdSessionHost',
            'Install-AvdAgent', 'Set-AvdSessionHostFsLogix', 'Set-AvdProfileShareAcl', 'Grant-AvdVmLogin',
            'Find-AvdEntraDevice', 'Remove-AvdEntraDevice', 'Test-AvdEntraJoin', 'Get-AvdEntraJoinLogTail',
            'Test-AvdBuildPermission', 'Grant-AvdStorageKerberosConsent', 'Remove-AvdStorageKerberosApp',
            'Get-AvdVmQuota', 'Test-AvdVmSizeQuota', 'Get-AvdVmSizeCatalog', 'Get-AvdMarketplaceImageSku', 'Test-AvdVmCredentialPolicy',
            'Test-AvdAutoscaleRole', 'Grant-AvdAutoscaleRole', 'Get-AvdScalingPlan', 'New-AvdScalingPlanResource', 'Set-AvdScalingPlanEnabled', 'Get-AvdScalingPlanSchedule', 'Set-AvdScalingPlanResource', 'Set-AvdHostPoolAgentUpdate',
            'New-AvdHostPoolResource', 'New-AvdApplicationGroupResource', 'New-AvdWorkspaceResource',
            'Register-AvdApplicationGroupToWorkspace', 'Grant-AvdDesktopAccess'
        )
        $actual = (Get-Command -Module AvdBuild).Name
        foreach ($f in $expected) { $actual | Should -Contain $f }
    }

    It 'does not export the internal role helper' {
        Import-Module $script:ManifestPath -Force
        (Get-Command -Module AvdBuild).Name | Should -Not -Contain 'Grant-AvdRoleAssignment'
    }

    It 'ships the host-side FSLogix script next to the module' {
        $hostScript = Join-Path (Split-Path $script:ManifestPath) 'hostconfig' 'Set-FsLogixProfile.ps1'
        Test-Path $hostScript | Should -BeTrue
    }

    It 'every state-changing function supports -WhatIf' {
        Import-Module $script:ManifestPath -Force
        foreach ($name in 'New-AvdSessionHostNic', 'New-AvdSessionHostVm', 'Join-AvdSessionHost', 'Install-AvdAgent',
                          'Set-AvdSessionHostFsLogix', 'Set-AvdProfileShareAcl', 'Grant-AvdVmLogin', 'Remove-AvdEntraDevice', 'New-AvdHostPoolResource',
                          'New-AvdApplicationGroupResource', 'New-AvdWorkspaceResource',
                          'Register-AvdApplicationGroupToWorkspace', 'Grant-AvdDesktopAccess') {
            (Get-Command $name).Parameters.ContainsKey('WhatIf') | Should -BeTrue -Because "$name changes state"
        }
    }
}
