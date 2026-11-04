BeforeDiscovery {
    $root = Split-Path $PSScriptRoot -Parent
    $targets = @(foreach ($f in Get-ChildItem (Join-Path $root 'azure/scripts'), (Join-Path $root 'azure/runbooks') -Recurse -File | Where-Object Extension -in '.ps1', '.psm1', '.psd1') {
        @{ Kind = $(if ($f.Extension -eq '.ps1') { 'AzureScript' } else { 'AzureModule' }); Target = [IO.Path]::GetRelativePath($root, $f.FullName); Expected = 'Azure/AVD execution is disabled' }
    })
    $toolkit = Join-Path $root 'm365/scripts/powershell/modules/ToolkitHelpers/ToolkitHelpers.psd1'
    Import-Module $toolkit -Force
    $writes = @((Get-M365Task | Where-Object IsWrite).Path) + (Join-Path $root 'm365/scripts/powershell/partner/Start-M365GdapOnboarding.ps1')
    $targets += @(foreach ($path in $writes) {
        @{ Kind = 'M365Script'; Target = [IO.Path]::GetRelativePath($root, $path); Expected = 'Microsoft 365 safe mode' }
    })
    foreach ($kind in 'M365Change', 'M365Guard', 'M365Graph', 'M365Scope', 'M365Hudu', 'M365Password', 'M365Browser', 'M365Command', 'M365Exchange', 'LearnSource', 'LearnGraph', 'LearnGenerate', 'Launcher') {
        $expected = switch ($kind) {
            'M365Browser' { 'Safe mode: opening' }
            'M365Command' { 'Safe mode' }
            'M365Exchange' { '-Organization must be a domain' }
            'LearnSource' { 'lookups must be read-only' }
            'LearnGraph' { 'Learn refused a Graph session' }
            'LearnGenerate' { 'Answers must be single-line' }
            'Launcher' { 'Azure/AVD administration is disabled' }
            default { 'Microsoft 365 safe mode' }
        }
        $targets += @{ Kind = $kind; Target = '.'; Expected = $expected }
    }
    $script:RefusalCases = @(foreach ($target in $targets) {
        $vectors = @('Default', 'CommonSC', 'CommonIgnore', 'CommonInquire', 'GlobalSC', 'GlobalIgnore', 'DefaultSC', 'DefaultIgnore')
        if ($target.Kind -in 'AzureScript', 'M365Script') { $vectors += 'DotSC', 'DotIgnore' }
        foreach ($vector in $vectors) {
            @{ Id = "$($target.Kind)/$($target.Target)/$vector"; Kind = $target.Kind; Target = $target.Target; Expected = $target.Expected; Vector = $vector }
        }
    })
}
Describe 'Refusals in fresh processes without try/catch' -ForEach @(@{ ProbeCases = $script:RefusalCases }) {
BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $probe = Join-Path $PSScriptRoot 'support/Invoke-RefusalProbe.ps1'
    $executable = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    $scratch = Join-Path $TestDrive 'probe'
    foreach ($name in 'Microsoft.Graph.Authentication', 'ExchangeOnlineManagement') {
        $folder = Join-Path $scratch "modules/$name"
        $null = New-Item -ItemType Directory -Path $folder -Force
        "@{ ModuleVersion = '1.0.0'; FunctionsToExport = @() }" | Set-Content (Join-Path $folder "$name.psd1")
    }
    # Parent-side parallelism saves startup time. Each tested operation still gets
    # its own pwsh process, isolated preferences and an unwrapped top-level call.
    $results = @($ProbeCases | ForEach-Object -Parallel {
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $using:executable -NoLogo -NoProfile -NonInteractive -File $using:probe -Repository $using:root -Kind $_.Kind -Target $_.Target -Vector $_.Vector -Scratch $using:scratch 2>&1 | Out-String
        [pscustomobject]@{ Id = $_.Id; ExitCode = $LASTEXITCODE; Output = $output }
    } -ThrottleLimit 8)
    $script:RefusalResults = @{}
    foreach ($result in $results) { $script:RefusalResults[$result.Id] = $result }
}
    It 'holds for <Id>' -ForEach $ProbeCases {
        $result = $script:RefusalResults[$Id]
        $result | Should -Not -BeNullOrEmpty
        $result.Output | Should -Not -Match 'BODY-CANARY|SIDE-EFFECT-CANARY|SIGN-IN-CANARY|IMPORT-CANARY|CALLER-CONTINUED|UNKNOWN-PROBE|NonInteractive mode|cannot.*prompt'
        if ($Kind -eq 'AzureModule' -and $result.ExitCode -eq 0) {
            $result.Output | Should -Match 'IMPORT-REFUSED'
        } else {
            $result.ExitCode | Should -Be 1 -Because $result.Output
            $result.Output | Should -Match ([regex]::Escape($Expected))
        }
    }
}
