BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:Manifest = Join-Path $script:RepoRoot 'Cloudwright.psd1'
    $script:Installer = Join-Path $script:RepoRoot 'Install-Cloudwright.ps1'
    $script:Pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    Import-Module $script:Manifest -Force

    function Invoke-TestPowerShell {
        param([string[]]$Arguments)
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $script:Pwsh -NoLogo -NoProfile @Arguments 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
    }
}

Describe 'Cloudwright command contract' {
    BeforeEach {
        Mock Invoke-CloudwrightProcess -ModuleName Cloudwright
    }

    It 'exports the short command as an alias of the public launcher' {
        (Get-Command cloudwright).Definition | Should -Be 'Start-Cloudwright'
        (Test-ModuleManifest $script:Manifest).PowerShellVersion | Should -Be '7.0'
    }

    It 'reports a version without launching a tool' {
        cloudwright version | Should -Be '0.2.2'
        Should -Invoke Invoke-CloudwrightProcess -ModuleName Cloudwright -Times 0 -Exactly
    }

    It 'shows help without launching a tool' {
        cloudwright help | Out-String | Should -Match 'Contoso'
        Should -Invoke Invoke-CloudwrightProcess -ModuleName Cloudwright -Times 0 -Exactly
    }

    It 'routes offline learning to the original command builder' {
        cloudwright learn -Console -Contoso -NoSignIn
        Should -Invoke Invoke-CloudwrightProcess -ModuleName Cloudwright -Times 1 -Exactly -ParameterFilter {
            $ScriptPath -like '*Start-MsScripter.ps1' -and
            $ScriptArguments -contains '-Contoso' -and $ScriptArguments -contains '-NoSignIn' -and
            $ScriptArguments -contains '-Console' -and -not $Sta
        }
    }

    It 'refuses Azure even with tenant, subscription, and console flags' {
        { cloudwright azure -Console -TenantId '00000000-0000-0000-0000-000000000000' -SubscriptionId 'lab subscription' } | Should -Throw '*Azure/AVD administration is disabled*'
        Should -Invoke Invoke-CloudwrightProcess -ModuleName Cloudwright -Times 0
    }

    It 'refuses Azure from the main menu before launching a child' {
        Mock Read-Host -ModuleName Cloudwright { '2' }
        { cloudwright } | Should -Throw '*Azure/AVD administration is disabled*'
        Should -Invoke Invoke-CloudwrightProcess -ModuleName Cloudwright -Times 0
    }

    It 'keeps Microsoft 365 setup on its existing launcher' {
        cloudwright m365 -Console -Setup
        Should -Invoke Invoke-CloudwrightProcess -ModuleName Cloudwright -Times 1 -Exactly -ParameterFilter {
            $ScriptPath -like '*Start-Toolkit.ps1' -and
            $ScriptArguments -contains '-Setup' -and $ScriptArguments -contains '-Console'
        }
    }

    It 'rejects flags for the wrong area before launching anything' {
        { cloudwright azure -Contoso } | Should -Throw '*not supported*'
        { cloudwright learn -Setup } | Should -Throw '*not supported*'
        { cloudwright m365 -TenantId '00000000-0000-0000-0000-000000000000' } | Should -Throw '*not supported*'
        { cloudwright -Contoso } | Should -Throw '*not supported*'
        Should -Invoke Invoke-CloudwrightProcess -ModuleName Cloudwright -Times 0 -Exactly
    }

    It 'rejects an unknown area' {
        { cloudwright unknown } | Should -Throw
        Should -Invoke Invoke-CloudwrightProcess -ModuleName Cloudwright -Times 0 -Exactly
    }

    It 'previews a launch without running setup or an administrative tool' {
        cloudwright m365 -Setup -WhatIf
        Should -Invoke Invoke-CloudwrightProcess -ModuleName Cloudwright -Times 0 -Exactly
    }

    It 'quits the menu without signing in or launching anything' {
        Mock Read-Host -ModuleName Cloudwright { 'q' }
        cloudwright
        Should -Invoke Invoke-CloudwrightProcess -ModuleName Cloudwright -Times 0 -Exactly
    }

    It 'carries the console preference from the menu into the selected tool' {
        Mock Read-Host -ModuleName Cloudwright { '1' }
        cloudwright -Console
        Should -Invoke Invoke-CloudwrightProcess -ModuleName Cloudwright -Times 1 -Exactly -ParameterFilter {
            $ScriptPath -like '*Start-MsScripter.ps1' -and $ScriptArguments -contains '-Console'
        }
    }

    It 'reports a missing checkout before attempting a child process' {
        Mock Test-Path -ModuleName Cloudwright { $false }
        { cloudwright learn } | Should -Throw '*checkout moved*'
        Should -Invoke Invoke-CloudwrightProcess -ModuleName Cloudwright -Times 0 -Exactly
    }
}

Describe 'Child process isolation' {
    It 'passes arguments literally, including spaces and PowerShell syntax' {
        $entry = Join-Path $TestDrive "literal entry's script.ps1"
        Set-Content -LiteralPath $entry -Value 'param([string]$Value); Write-Output $Value'
        $value = 'a value; Write-Output unexpected $(Get-Date)'
        $module = Get-Module Cloudwright
        $result = & $module {
            param($Path, $Value)
            Invoke-CloudwrightProcess -ScriptPath $Path -ScriptArguments @('-Value', $Value)
        } $entry $value
        $result | Should -BeExactly $value
    }

    It 'reports a child failure without exiting the calling PowerShell session' {
        $entry = Join-Path $TestDrive 'failure.ps1'
        Set-Content -LiteralPath $entry -Value 'exit 7'
        $module = Get-Module Cloudwright
        { & $module { param($Path) Invoke-CloudwrightProcess -ScriptPath $Path } $entry } |
            Should -Throw '*code 7*'
        cloudwright version | Should -Be '0.2.2'
    }
}

Describe 'Current-user launcher installation' {
    BeforeEach {
        $script:ModuleBase = Join-Path $TestDrive ([guid]::NewGuid().ToString() + " modules with an apostrophe's")
        $script:Destination = Join-Path $script:ModuleBase 'Cloudwright'
    }

    It 'supports WhatIf without creating an installation directory' {
        $result = Invoke-TestPowerShell @('-File', $script:Installer, '-ModulePath', $script:ModuleBase, '-WhatIf')
        $result.ExitCode | Should -Be 0 -Because $result.Output
        Test-Path -LiteralPath $script:ModuleBase | Should -BeFalse
    }

    It 'installs only the launcher and auto-loads the short command in a fresh session' {
        $result = Invoke-TestPowerShell @('-File', $script:Installer, '-ModulePath', $script:ModuleBase)
        $result.ExitCode | Should -Be 0 -Because $result.Output
        @(Get-ChildItem -LiteralPath $script:Destination -File).Count | Should -Be 3
        $location = Get-Content (Join-Path $script:Destination 'Cloudwright.location.json') -Raw | ConvertFrom-Json
        $location.RepositoryRoot | Should -Be $script:RepoRoot
        $previousPath = $env:PSModulePath
        try {
            $env:PSModulePath = $script:ModuleBase + [IO.Path]::PathSeparator + $previousPath
            Push-Location $TestDrive
            try { $fresh = Invoke-TestPowerShell @('-Command', 'cloudwright version') }
            finally { Pop-Location }
        } finally { $env:PSModulePath = $previousPath }
        $fresh.ExitCode | Should -Be 0 -Because $fresh.Output
        $fresh.Output.Trim() | Should -Be '0.2.2'
    }

    It 'requires Force to update and preserves other files in its installation' {
        $first = Invoke-TestPowerShell @('-File', $script:Installer, '-ModulePath', $script:ModuleBase)
        $first.ExitCode | Should -Be 0 -Because $first.Output
        $sentinel = Join-Path $script:Destination 'keep.local.json'
        Set-Content -LiteralPath $sentinel -Value '{"keep":true}'
        $repeat = Invoke-TestPowerShell @('-File', $script:Installer, '-ModulePath', $script:ModuleBase)
        $repeat.ExitCode | Should -Not -Be 0
        $repeat.Output | Should -Match 'already installed'
        $update = Invoke-TestPowerShell @('-File', $script:Installer, '-ModulePath', $script:ModuleBase, '-Force')
        $update.ExitCode | Should -Be 0 -Because $update.Output
        (Get-Content -LiteralPath $sentinel -Raw).Trim() | Should -Be '{"keep":true}'
    }

    It 'refuses to overwrite an unrelated directory even with Force' {
        $null = New-Item -ItemType Directory -Path $script:Destination -Force
        $sentinel = Join-Path $script:Destination 'existing.txt'
        Set-Content -LiteralPath $sentinel -Value 'keep this'
        $result = Invoke-TestPowerShell @('-File', $script:Installer, '-ModulePath', $script:ModuleBase, '-Force')
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'not a Cloudwright launcher'
        (Get-Content -LiteralPath $sentinel -Raw).Trim() | Should -Be 'keep this'
    }
}
