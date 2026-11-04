BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers/LegacyAzure.ps1')
    $script:AzureTestRoot = New-LegacyAzureTestCopy -Destination (Join-Path $TestDrive 'legacy-azure')
    $script:Ps = Join-Path $script:AzureTestRoot 'scripts' 'powershell'
    $script:Manifest = Join-Path $script:Ps 'modules' 'AppDeploy' 'AppDeploy.psd1'
    $script:AutoManifest = Join-Path $script:Ps 'modules' 'AutomationAdmin' 'AutomationAdmin.psd1'
    Import-Module $script:Manifest -Force
    Import-Module $script:AutoManifest -Force
}

Describe '<_> module' -ForEach 'AppDeploy', 'AutomationAdmin' {
    BeforeAll {
        $script:M = Join-Path $script:Ps 'modules' $_ "$_.psd1"
        $script:Src = Get-Content (Join-Path $script:Ps 'modules' $_ "$_.psm1") -Raw
        $script:N = $_
    }
    It 'has a valid manifest' { { Test-ModuleManifest -Path $script:M -ErrorAction Stop } | Should -Not -Throw }
    It 'exports what the manifest lists' {
        $actual = (Get-Command -Module $script:N).Name
        foreach ($f in (Import-PowerShellDataFile $script:M).FunctionsToExport) { $actual | Should -Contain $f }
    }
    It 'every state-changing function supports -WhatIf' {
        foreach ($n in (Get-Command -Module $script:N | Where-Object { $_.Verb -in 'New', 'Set', 'Add', 'Install', 'Import', 'Invoke', 'Start', 'Grant' -and $_.Name -ne 'New-ShellAppScript' }).Name) {
            (Get-Command $n).Parameters.ContainsKey('WhatIf') | Should -BeTrue -Because "$n changes state"
        }
    }
    It 'never deletes or uninstalls' {
        $script:Src | Should -Not -Match 'Remove-Az'
        $script:Src | Should -Not -Match 'Remove-AzVMRunCommand'
        $script:Src | Should -Not -Match 'Remove-RoleAssignment|Remove-AzRoleAssignment'
        $script:Src | Should -Not -Match 'winget\S* uninstall'
    }
}

Describe 'Local store' {
    It 'adds and replaces entries and never drops others' {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) "toolbox-test-$([guid]::NewGuid()).local.json"
        try {
            $null = Set-ToolboxStoreItem -Kind AppGroups -Name 'Base' -Value @{ WingetId = @('7zip.7zip'); ShellApp = @() } -Path $path
            $null = Set-ToolboxStoreItem -Kind ShellApps -Name 'Tool' -Value @{ Detect = '$true'; Install = 'x' } -Path $path
            $r = Set-ToolboxStoreItem -Kind AppGroups -Name 'Base' -Value @{ WingetId = @('Google.Chrome'); ShellApp = @('Tool') } -Path $path
            $r.Result | Should -Be 'Replace'
            $s = Get-ToolboxStore -Path $path
            @($s.AppGroups['Base']['WingetId']) | Should -Be @('Google.Chrome')
            $s.ShellApps.ContainsKey('Tool') | Should -BeTrue
            $s.ContainsKey('Deployments') | Should -BeTrue
        } finally { Remove-Item $path -ErrorAction SilentlyContinue }
    }
    It 'rejects names that would break the file or the grid' {
        { Set-ToolboxStoreItem -Kind AppGroups -Name 'bad/name' -Value @{} -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'x.local.json') -WhatIf } | Should -Throw
    }
}

Describe 'Script library' {
    BeforeAll { $script:Lib = @(Get-GuestScriptLibrary) }
    It 'lists the repo scripts with synopsis' {
        $script:Lib.Count | Should -BeGreaterThan 5
        foreach ($l in $script:Lib | Where-Object Source -eq 'Repo') { $l.Synopsis | Should -Not -BeNullOrEmpty -Because $l.Name }
    }
    It 'reads parameters and defaults' {
        ($script:Lib | Where-Object Name -eq 'Get-DiskSpace').Parameters | Should -Be 'MinFreePercent=10'
    }
    It 'library scripts parse, take a param block and never delete' {
        foreach ($f in Get-ChildItem (Join-Path $script:Ps 'library' 'windows') -Filter '*.ps1') {
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because $f.Name
            $ast.ParamBlock | Should -Not -BeNullOrEmpty -Because $f.Name
            (Get-Content $f.FullName -Raw) | Should -Not -Match '\bRemove-Item\b|\bRemove-\w+|\bdel\s|\brmdir\b|Format-Volume|Clear-Disk' -Because $f.Name
        }
    }
}

Describe 'New-ShellAppScript' {
    It 'builds a script that parses and detects before and after installing' {
        $t = New-ShellAppScript -Name "Pat's tool" -Detect "Test-Path 'C:\x'" -Install "Start-Process msiexec.exe -ArgumentList '/i','x.msi','/qn' -Wait"
        $errors = $null; $null = [System.Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
        ([regex]::Matches($t, '& \$detect')).Count | Should -Be 2
    }
}

Describe 'winget table parsing (in-guest script)' {
    BeforeAll {
        $src = Get-Content (Join-Path $script:Ps 'modules' 'AppDeploy' 'hostconfig' 'Invoke-Winget.ps1') -Raw
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'ConvertFrom-WingetTable' }, $true) | Select-Object -First 1
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    It 'turns the fixed-width table into Name|Id|Version|Source lines' {
        $lines = @(
            'Name                 Id                  Version      Match       Source'
            '------------------------------------------------------------------------'
            'Google Chrome        Google.Chrome       131.0.6778   Tag: chrome winget'
            '7-Zip                7zip.7zip           24.09                    winget'
        )
        $out = @(ConvertFrom-WingetTable -Lines $lines)
        $out.Count | Should -Be 2
        $out[0] | Should -Be 'Google Chrome|Google.Chrome|131.0.6778|winget'
        $out[1] | Should -Be '7-Zip|7zip.7zip|24.09|winget'
    }
}
