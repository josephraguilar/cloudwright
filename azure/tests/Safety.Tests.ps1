# These tests use the real, unmodified release files. Never use LegacyAzure.ps1 here.
BeforeDiscovery {
    $azureRoot = Split-Path $PSScriptRoot -Parent
    $runtime = @(Get-ChildItem (Join-Path $azureRoot 'scripts'), (Join-Path $azureRoot 'runbooks') -Recurse -File |
        Where-Object Extension -in '.ps1', '.psm1')
    $scripts = @($runtime | Where-Object Extension -eq '.ps1' | ForEach-Object { @{ Path = $_.FullName; Name = $_.Name } })
    $modules = @(Get-ChildItem (Join-Path $azureRoot 'scripts/powershell/modules') -Recurse -Filter '*.psd1' |
        ForEach-Object { @{ Path = $_.FullName; Name = $_.BaseName } })
}
BeforeAll {
    $script:AzureRoot = Split-Path $PSScriptRoot -Parent
    $script:Guard = "& { `$ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }"
    function Get-SafetyArguments {
        param([string]$Path)
        $command = Get-Command $Path
        $set = @($command.ParameterSets | Where-Object IsDefault | Select-Object -First 1)
        if (-not $set.Count) { $set = @($command.ParameterSets | Select-Object -First 1) }
        $values = @{}
        foreach ($p in $set[0].Parameters | Where-Object IsMandatory) {
            $attributes = $command.Parameters[$p.Name].Attributes
            $valid = @($attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object ValidValues)
            $range = @($attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] })
            $values[$p.Name] = if ($p.ParameterType -eq [pscredential]) {
                [pscredential]::new('fixture', (ConvertTo-SecureString 'Fixture-only-password1!' -AsPlainText -Force))
            } elseif ($p.ParameterType -eq [securestring]) { ConvertTo-SecureString 'Fixture-only-password1!' -AsPlainText -Force
            } elseif ($valid.Count) { $valid[0]
            } elseif ($p.ParameterType -eq [switch]) { $true
            } elseif ($p.ParameterType -eq [int]) { if ($range.Count) { $range[0].MinRange } else { 1 }
            } else { 'fixture' }
        }
        if ($command.Parameters.ContainsKey('Path')) { $values.Path = $TestDrive }
        return $values
    }
}
Describe 'Azure release boundary' {
    It 'blocks every runtime PowerShell file before its first executable statement' {
        $files = @(Get-ChildItem (Join-Path $script:AzureRoot 'scripts'), (Join-Path $script:AzureRoot 'runbooks') -Recurse -File |
            Where-Object Extension -in '.ps1', '.psm1')
        $files.Count | Should -BeGreaterThan 100
        foreach ($file in $files) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $ast.BeginBlock | Should -BeNullOrEmpty
            $ast.ProcessBlock | Should -BeNullOrEmpty
            $ast.DynamicParamBlock | Should -BeNullOrEmpty
            $ast.CleanBlock | Should -BeNullOrEmpty
            $ast.ScriptRequirements | Should -BeNullOrEmpty
            $ast.UsingStatements | Should -BeNullOrEmpty
            $ast.EndBlock.Traps | Should -BeNullOrEmpty
            $first = $ast.EndBlock.Statements[0]
            $first | Should -BeOfType ([System.Management.Automation.Language.PipelineAst])
            $first.Extent.Text | Should -BeExactly $script:Guard -Because $file.FullName
            # Parameter binding precedes the block: only known local, read-only defaults are permitted.
            if ($ast.ParamBlock) {
                @($ast.ParamBlock.FindAll({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)) | Should -BeNullOrEmpty
                foreach ($call in $ast.ParamBlock.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                    @('Join-Path', 'Get-TimeZone') | Should -Contain $call.GetCommandName()
                }
                foreach ($call in $ast.ParamBlock.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
                    $call.Extent.Text | Should -BeExactly "[Environment]::GetFolderPath('MyDocuments')"
                }
            }
        }
    }
    It 'does not run module-manifest prerequisites before the release block' {
        foreach ($file in Get-ChildItem (Join-Path $script:AzureRoot 'scripts/powershell/modules') -Recurse -Filter '*.psd1') {
            $manifest = Import-PowerShellDataFile $file.FullName
            foreach ($key in 'ScriptsToProcess', 'NestedModules', 'RequiredModules', 'RequiredAssemblies') {
                $manifest[$key] | Should -BeNullOrEmpty -Because "$($file.Name): $key"
            }
        }
    }
    It 'refuses the Azure CLI entry point before invoking az' -Skip:(-not (Get-Command bash -ErrorAction SilentlyContinue)) {
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & bash (Join-Path $script:AzureRoot 'scripts/cli/compute/list-vms.sh') 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'Cloudwright safe release: Azure/AVD execution is disabled'
    }
    It 'refuses direct and dot-sourced execution of <Name>, including WhatIf/Confirm overrides' -ForEach $scripts {
        $arguments = Get-SafetyArguments $Path
        $parameters = (Get-Command $Path).Parameters
        if ($parameters.ContainsKey('Confirm')) { $arguments.Confirm = $false }
        { & $Path @arguments } | Should -Throw '*Cloudwright safe release: Azure/AVD execution is disabled*'
        { . $Path @arguments } | Should -Throw '*Cloudwright safe release: Azure/AVD execution is disabled*'
        if ($parameters.ContainsKey('WhatIf')) {
            $arguments.WhatIf = $true
            { & $Path @arguments } | Should -Throw '*Cloudwright safe release: Azure/AVD execution is disabled*'
        }
    }
    It 'cannot import <Name> through its manifest or root module even with Continue' -ForEach $modules {
        $probe = Join-Path $TestDrive 'probe-module.ps1'
        @'
param($Manifest)
$ErrorActionPreference = 'Continue'
$definition = Import-PowerShellDataFile $Manifest
foreach ($path in $Manifest, (Join-Path (Split-Path $Manifest) $definition.RootModule)) {
    $caught = $null
    try { Import-Module $path -Force -ErrorAction Continue } catch { $caught = $_ }
    if (-not $caught -or $caught.Exception.Message -notlike '*Cloudwright safe release: Azure/AVD execution is disabled*') { exit 2 }
    if (Get-Module ([IO.Path]::GetFileNameWithoutExtension($Manifest))) { exit 3 }
    foreach ($name in $definition.FunctionsToExport) {
        if (Get-Command $name -ErrorAction SilentlyContinue) { exit 4 }
    }
}
exit 0
'@ | Set-Content $probe
        $executable = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        & $executable -NoLogo -NoProfile -File $probe -Manifest $Path
        $LASTEXITCODE | Should -Be 0
    }
}
