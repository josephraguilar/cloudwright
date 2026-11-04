BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers/LegacyAzure.ps1')
    $script:AzureTestRoot = New-LegacyAzureTestCopy -Destination (Join-Path $TestDrive 'legacy-azure')
    $script:ManifestPath = Join-Path $script:AzureTestRoot 'scripts' 'powershell' 'modules' 'ImageBuild' 'ImageBuild.psd1'
    $script:Source = Get-Content (Join-Path (Split-Path $script:ManifestPath) 'ImageBuild.psm1') -Raw
    Import-Module $script:ManifestPath -Force
}

Describe 'ImageBuild module' {
    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }
    It 'exports what the manifest lists' {
        $expected = (Import-PowerShellDataFile $script:ManifestPath).FunctionsToExport
        $actual = (Get-Command -Module ImageBuild).Name
        foreach ($f in $expected) { $actual | Should -Contain $f }
    }
    It 'every state-changing function supports -WhatIf' {
        foreach ($name in (Get-Command -Module ImageBuild | Where-Object { $_.Verb -in 'New', 'Set', 'Invoke' -and $_.Name -ne 'New-GalleryVersionNumber' }).Name) {
            (Get-Command $name).Parameters.ContainsKey('WhatIf') | Should -BeTrue -Because "$name changes state"
        }
    }
    It 'never deletes' {
        $script:Source | Should -Not -Match 'Remove-Az'
        $script:Source | Should -Not -Match "Method\s+'?DELETE"
    }
    It 'refuses to sysprep a VM without the image-builder tag unless told' {
        (Get-Command Invoke-GalleryVmSysprep).Parameters.ContainsKey('AllowUntaggedVm') | Should -BeTrue
        $script:Source | Should -Match "purpose'\] -eq 'image-builder'"
    }
}

Describe 'New-GalleryVersionNumber' {
    It 'makes three whole numbers from the date' {
        New-GalleryVersionNumber -At ([datetime]'2026-10-17 14:30') | Should -Be '2026.1017.1430'
    }
    It 'sorts after midnight and in January correctly' {
        [version](New-GalleryVersionNumber -At ([datetime]'2027-01-02 00:05')) | Should -BeGreaterThan ([version](New-GalleryVersionNumber -At ([datetime]'2026-12-31 23:59')))
    }
}
