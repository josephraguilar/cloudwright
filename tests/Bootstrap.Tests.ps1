BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:Bootstrap = Join-Path $script:Root 'Get-Cloudwright.ps1'
    $script:Commit = 'f' * 40
    $script:Fixture = Join-Path $TestDrive 'snapshot'
    $null = New-Item -ItemType Directory -Path $script:Fixture
    foreach ($file in 'Cloudwright.psd1', 'Cloudwright.psm1', 'Install-Cloudwright.ps1') {
        Copy-Item -LiteralPath (Join-Path $script:Root $file) -Destination $script:Fixture
    }
    foreach ($file in 'learn/Start-MsScripter.ps1', 'azure/scripts/powershell/Start-AvdConsole.ps1', 'm365/Start-Toolkit.ps1') {
        $path = Join-Path $script:Fixture $file
        $null = New-Item -ItemType Directory -Path (Split-Path $path) -Force
        Set-Content -LiteralPath $path -Value "throw 'A tenant entry point must not run during installation.'"
    }
    $script:Archive = Join-Path $TestDrive 'snapshot.zip'
    Compress-Archive -LiteralPath $script:Fixture -DestinationPath $script:Archive
}

Describe 'Cloudwright download bootstrap' {
    BeforeEach {
        $script:Destination = Join-Path $TestDrive ([guid]::NewGuid().ToString() + " toolkit's files")
        $script:ModuleBase = Join-Path $TestDrive ([guid]::NewGuid().ToString() + ' modules')
        Mock Invoke-RestMethod { [pscustomobject]@{ sha = ('f' * 40) } }
        Mock Invoke-WebRequest { Copy-Item -LiteralPath (Join-Path $TestDrive 'snapshot.zip') -Destination $OutFile }
    }

    AfterEach {
        Remove-Module Cloudwright -Force -ErrorAction SilentlyContinue
    }

    It 'downloads one pinned snapshot anonymously and installs a working command' {
        & $script:Bootstrap -InstallPath $script:Destination -ModulePath $script:ModuleBase -NoLaunch
        cloudwright version | Should -Be '0.1.0'
        $record = Get-Content (Join-Path $script:Destination 'Cloudwright.download.json') -Raw | ConvertFrom-Json
        $record.Commit | Should -Be $script:Commit
        $location = Get-Content (Join-Path $script:ModuleBase 'Cloudwright/Cloudwright.location.json') -Raw | ConvertFrom-Json
        $location.RepositoryRoot | Should -Be $script:Destination
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -like '*/commits/main' -and -not $Token -and $Headers.Keys -notcontains 'Authorization'
        }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -like "*/zipball/$($script:Commit)" -and -not $Token -and $Headers.Keys -notcontains 'Authorization'
        }
    }

    It 'executes downloaded text from another directory without changing caller preferences' {
        $code = Get-Content -LiteralPath $script:Bootstrap -Raw
        $before = $ErrorActionPreference
        Push-Location $TestDrive
        try {
            # Exercise the same evaluation as IEX while supplying isolated test directories.
            Invoke-Expression ('& {' + $code + "`n} -InstallPath `$script:Destination -ModulePath `$script:ModuleBase -NoLaunch")
        } finally { Pop-Location }
        $ErrorActionPreference | Should -Be $before
        cloudwright version | Should -Be '0.1.0'
    }

    It 'accepts a literal text-to-IEX pipeline with no script invocation context' {
        # Stop at the network boundary and mock all filesystem writes, including on Windows.
        Mock Test-Path { $false }
        Mock New-Item {}
        Mock Remove-Item {}
        Mock Invoke-RestMethod { throw 'Offline test' }
        { Get-Content -LiteralPath $script:Bootstrap -Raw | Invoke-Expression } |
            Should -Throw '*Could not download Cloudwright*'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'opens the menu after installation without running a tenant entry point' {
        & $script:Bootstrap -InstallPath $script:Destination -ModulePath $script:ModuleBase -NoLaunch
        $pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        $output = 'q' | & $pwsh -NoLogo -NoProfile -File $script:Bootstrap -InstallPath $script:Destination -ModulePath $script:ModuleBase -Console 2>&1 | Out-String
        $output = $output -replace '\x1b\[[0-9;]*m', ''
        $LASTEXITCODE | Should -Be 0 -Because $output
        # Read-Host prompts use a host stream that Windows does not include in redirected output.
        $output | Should -Match '1\. Learn Microsoft commands'
        $output | Should -Match '2\. Manage Azure and AVD'
        $output | Should -Match '3\. Manage Microsoft 365'
        $output | Should -Match 'Q\. Quit'
    }

    It 'reuses the snapshot offline and preserves local settings' {
        & $script:Bootstrap -InstallPath $script:Destination -ModulePath $script:ModuleBase -NoLaunch
        $local = Join-Path $script:Destination 'm365/settings.local.json'
        Set-Content -LiteralPath $local -Value '{"keep":true}'
        & $script:Bootstrap -InstallPath $script:Destination -ModulePath $script:ModuleBase -NoLaunch
        (Get-Content -LiteralPath $local -Raw).Trim() | Should -Be '{"keep":true}'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }

    It 'previews without network calls or filesystem changes' {
        & $script:Bootstrap -InstallPath $script:Destination -ModulePath $script:ModuleBase -WhatIf
        Test-Path -LiteralPath $script:Destination | Should -BeFalse
        Test-Path -LiteralPath $script:ModuleBase | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'refuses to replace an unrelated directory' {
        $null = New-Item -ItemType Directory -Path $script:Destination
        $sentinel = Join-Path $script:Destination 'keep.txt'
        Set-Content -LiteralPath $sentinel -Value 'keep'
        { & $script:Bootstrap -InstallPath $script:Destination -ModulePath $script:ModuleBase -NoLaunch } |
            Should -Throw '*not a Cloudwright download*'
        (Get-Content -LiteralPath $sentinel -Raw).Trim() | Should -Be 'keep'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'cleans an interrupted download without registering a broken installation' {
        Mock Invoke-WebRequest { throw 'Download interrupted' }
        { & $script:Bootstrap -InstallPath $script:Destination -ModulePath $script:ModuleBase -NoLaunch } |
            Should -Throw '*Could not download*'
        Test-Path -LiteralPath $script:Destination | Should -BeFalse
        Test-Path -LiteralPath $script:ModuleBase | Should -BeFalse
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '.cloudwright-download-*' -Force).Count | Should -Be 0
    }

    It 'rejects an archive missing a component before installing it' {
        Mock Expand-Archive {
            $null = New-Item -ItemType Directory -Path (Join-Path $DestinationPath 'incomplete') -Force
        }
        { & $script:Bootstrap -InstallPath $script:Destination -ModulePath $script:ModuleBase -NoLaunch } |
            Should -Throw '*Incomplete Cloudwright archive*'
        Test-Path -LiteralPath $script:Destination | Should -BeFalse
        Test-Path -LiteralPath $script:ModuleBase | Should -BeFalse
    }
}
