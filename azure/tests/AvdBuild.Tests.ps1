BeforeAll {
    $script:ManifestPath = Join-Path $PSScriptRoot '..' 'scripts' 'powershell' 'modules' 'AvdBuild' 'AvdBuild.psd1'
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
