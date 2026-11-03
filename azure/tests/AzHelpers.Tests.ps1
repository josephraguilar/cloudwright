BeforeAll {
    $script:ManifestPath = Join-Path $PSScriptRoot '..' 'scripts' 'powershell' 'modules' 'AzHelpers' 'AzHelpers.psd1'
}

Describe 'AzHelpers module' {
    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    Context 'Test-AzActionAllowed' {
        BeforeAll { Import-Module $script:ManifestPath -Force }
        It 'allows under a wildcard Owner-style permission' {
            $perms = @([pscustomobject]@{ actions = @('*'); notActions = @() })
            Test-AzActionAllowed -Action 'Microsoft.Compute/virtualMachines/write' -Permissions $perms | Should -BeTrue
        }
        It 'denies role assignment writes under Contributor-style notActions' {
            $perms = @([pscustomobject]@{ actions = @('*'); notActions = @('Microsoft.Authorization/*/Write', 'Microsoft.Authorization/*/Delete') })
            Test-AzActionAllowed -Action 'Microsoft.Authorization/roleAssignments/write' -Permissions $perms | Should -BeFalse
            Test-AzActionAllowed -Action 'Microsoft.Compute/virtualMachines/write' -Permissions $perms | Should -BeTrue
        }
        It 'denies when nothing matches' {
            $perms = @([pscustomobject]@{ actions = @('Microsoft.Compute/*/read'); notActions = @() })
            Test-AzActionAllowed -Action 'Microsoft.Compute/virtualMachines/write' -Permissions $perms | Should -BeFalse
        }
    }

    It 'imports and exports the expected functions' {
        Import-Module $script:ManifestPath -Force
        $actual = (Get-Command -Module AzHelpers).Name
        foreach ($f in 'Assert-AzContext', 'Assert-AzResourceProvider', 'Find-AzSubscriptionAcrossTenant', 'Get-AzEffectivePermission', 'Test-AzActionAllowed', 'Get-AzDirectoryRoleMembership') { $actual | Should -Contain $f }
    }
}
