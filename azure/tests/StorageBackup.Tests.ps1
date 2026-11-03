BeforeAll {
    $script:Root = Join-Path $PSScriptRoot '..' 'scripts' 'powershell' 'modules'
    Import-Module (Join-Path $script:Root 'FilesAdmin' 'FilesAdmin.psd1') -Force
    Import-Module (Join-Path $script:Root 'BackupAdmin' 'BackupAdmin.psd1') -Force
}

Describe '<_> module' -ForEach 'FilesAdmin', 'BackupAdmin' {
    BeforeAll {
        $script:Manifest = Join-Path $script:Root $_ "$_.psd1"
        $script:Source = Get-Content (Join-Path $script:Root $_ "$_.psm1") -Raw
        $script:Name = $_
    }
    It 'has a valid manifest' { { Test-ModuleManifest -Path $script:Manifest -ErrorAction Stop } | Should -Not -Throw }
    It 'exports what the manifest lists' {
        $expected = (Import-PowerShellDataFile $script:Manifest).FunctionsToExport
        $actual = (Get-Command -Module $script:Name).Name
        foreach ($f in $expected) { $actual | Should -Contain $f }
    }
    It 'every state-changing function supports -WhatIf' {
        foreach ($n in (Get-Command -Module $script:Name | Where-Object { $_.Verb -in 'New', 'Set', 'Enable', 'Start', 'Restore', 'Update' }).Name) {
            (Get-Command $n).Parameters.ContainsKey('WhatIf') | Should -BeTrue -Because "$n changes state"
        }
    }
    It 'never deletes or stops protection' {
        $script:Source | Should -Not -Match 'Remove-Az'
        $script:Source | Should -Not -Match 'Disable-AzRecoveryServicesBackupProtection'
    }
}

Describe 'BackupAdmin restores never overwrite' {
    BeforeAll { $script:Src = Get-Content (Join-Path $script:Root 'BackupAdmin' 'BackupAdmin.psm1') -Raw }
    It 'file share restores always resolve conflicts by skipping' {
        $script:Src | Should -Match "ResolveConflict = 'Skip'"
        $script:Src | Should -Not -Match "ResolveConflict\s*=\s*'Overwrite'"
    }
    It 'VM restores always name a target resource group (never the replace-existing set)' {
        $script:Src | Should -Match 'TargetResourceGroupName = \$TargetResourceGroupName'
    }
    It 'shorter retention needs an explicit switch' {
        (Get-Command Set-BackupPolicySchedule).Parameters.ContainsKey('AllowShorterRetention') | Should -BeTrue
    }
}

Describe 'Test-FilesAccountName' {
    It 'accepts <_>' -ForEach 'stfiles01', 'abc', ('a' * 24) { Test-FilesAccountName $_ | Should -BeTrue }
    It 'rejects <_>' -ForEach 'ab', 'StFiles', 'st-files', ('a' * 25), '' { Test-FilesAccountName $_ | Should -BeFalse }
}
