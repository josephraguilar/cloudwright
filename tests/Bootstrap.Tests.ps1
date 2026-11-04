BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:Bootstrap = Join-Path $script:Root 'Get-Cloudwright.ps1'
    $script:Commit = 'f' * 40
    $script:Fixture = Join-Path $TestDrive 'snapshot'
    $null = New-Item -ItemType Directory -Path $script:Fixture
    foreach ($file in 'Cloudwright.psd1', 'Cloudwright.psm1', 'Install-Cloudwright.ps1') {
        Copy-Item -LiteralPath (Join-Path $script:Root $file) -Destination $script:Fixture
    }
    foreach ($file in 'learn/Start-MsScripter.ps1', 'azure/scripts/powershell/Start-AvdConsole.ps1', 'm365/Start-Toolkit.ps1', 'm365/scripts/powershell/modules/M365Helpers/Safety.ps1') {
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
        cloudwright version | Should -Be '0.2.2'
        $record = Get-Content (Join-Path $script:Destination 'Cloudwright.download.json') -Raw | ConvertFrom-Json
        $record.Commit | Should -Be $script:Commit
        $record.SafetyBaseline | Should -Be 3
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
        cloudwright version | Should -Be '0.2.2'
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
        $output | Should -Match '2\. Azure and AVD \(disabled in the safe release\)'
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

    It 'refuses to reuse a snapshot with safety baseline <Baseline> and preserves its local files' -ForEach @(
        @{ Baseline = 0 }, @{ Baseline = 1 }, @{ Baseline = 2 }
    ) {
        & $script:Bootstrap -InstallPath $script:Destination -ModulePath $script:ModuleBase -NoLaunch
        $marker = Join-Path $script:Destination 'Cloudwright.download.json'
        $old = @{ Tool = 'Cloudwright'; SchemaVersion = 1; Commit = $script:Commit }
        if ($Baseline) { $old.SafetyBaseline = $Baseline }
        $old | ConvertTo-Json | Set-Content -LiteralPath $marker
        $local = Join-Path $script:Destination 'm365/settings.local.json'
        Set-Content -LiteralPath $local -Value '{"keep":true}'
        { & $script:Bootstrap -InstallPath $script:Destination -ModulePath $script:ModuleBase } | Should -Throw '*predates mandatory*safe mode*'
        (Get-Content -LiteralPath $local -Raw).Trim() | Should -Be '{"keep":true}'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'prints a working replacement command while keeping the old installation and settings' {
        $script:ModuleBase = Join-Path $TestDrive "modules' files"
        & $script:Bootstrap -InstallPath $script:Destination -ModulePath $script:ModuleBase -NoLaunch
        $manifest = Join-Path $script:Destination 'Cloudwright.psd1'
        (Get-Content $manifest -Raw).Replace("'0.2.2'", "'0.1.0'") | Set-Content $manifest
        Copy-Item $manifest (Join-Path $script:ModuleBase 'Cloudwright/Cloudwright.psd1') -Force
        Import-Module (Join-Path $script:ModuleBase 'Cloudwright/Cloudwright.psd1') -Force
        @{ Tool = 'Cloudwright'; SchemaVersion = 1; Commit = $script:Commit } |
            ConvertTo-Json | Set-Content (Join-Path $script:Destination 'Cloudwright.download.json')
        $local = Join-Path $script:Destination 'm365/settings.local.json'
        Set-Content $local '{"keep":true}'
        cloudwright version | Should -Be '0.1.0'

        $refusal = { & $script:Bootstrap -InstallPath $script:Destination -ModulePath $script:ModuleBase } |
            Should -Throw '*predates mandatory*safe mode*' -PassThru
        $message = $refusal.Exception.Message
        $message | Should -Match 'has NOT been updated or disabled'
        $message | Should -Match 'older code that changes Azure and Microsoft 365 tenants'
        $message | Should -Match ([regex]::Escape($script:Destination))
        cloudwright version | Should -Be '0.1.0'
        $command = @($message -split '\r?\n' | Where-Object { $_.StartsWith('& ([scriptblock]::Create(') })
        $command.Count | Should -Be 1
        Mock Invoke-RestMethod { Get-Content $script:Bootstrap -Raw } -ParameterFilter { $Uri -like 'https://raw.githubusercontent.com/*/Get-Cloudwright.ps1' }
        # Execute the exact suggested command with fake downloads and tenant entry
        # points that throw if launched. Its custom module path contains a quote.
        Invoke-Expression $command[0]
        cloudwright version | Should -Be '0.2.2'
        $location = Get-Content (Join-Path $script:ModuleBase 'Cloudwright/Cloudwright.location.json') -Raw | ConvertFrom-Json
        $location.RepositoryRoot | Should -Not -Be $script:Destination
        Test-Path (Join-Path $location.RepositoryRoot 'Cloudwright.psd1') | Should -BeTrue
        (Get-Content $local -Raw).Trim() | Should -Be '{"keep":true}'
        (Import-PowerShellDataFile $manifest).ModuleVersion | Should -Be '0.1.0'
        $pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        $output = & $pwsh -NoLogo -NoProfile -NonInteractive -Command {
            param($modules)
            $env:PSModulePath = $modules + [IO.Path]::PathSeparator + $env:PSModulePath
            cloudwright version
        } -args $script:ModuleBase 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $output
        $output.Trim() | Should -Be '0.2.2'
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

    It 'rejects an otherwise complete archive with only the older M365 safety policy' {
        Mock Expand-Archive {
            $copy = Join-Path $DestinationPath 'older'
            $null = New-Item -ItemType Directory -Path $DestinationPath -Force
            Copy-Item (Join-Path $TestDrive 'snapshot') -Destination $copy -Recurse
            $manifest = Join-Path $copy 'Cloudwright.psd1'
            (Get-Content $manifest -Raw).Replace('CloudwrightSafetyBaseline = 3', 'CloudwrightSafetyBaseline = 1') | Set-Content $manifest
        }
        { & $script:Bootstrap -InstallPath $script:Destination -ModulePath $script:ModuleBase -NoLaunch } |
            Should -Throw '*archive predates mandatory Cloudwright safe mode*'
        Test-Path -LiteralPath $script:Destination | Should -BeFalse
        Test-Path -LiteralPath $script:ModuleBase | Should -BeFalse
    }
}
