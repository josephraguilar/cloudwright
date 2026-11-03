BeforeAll {
    $modules = Join-Path $PSScriptRoot '..' 'scripts' 'powershell' 'modules'
    $script:ManifestPath = Join-Path $modules 'ToolkitHelpers' 'ToolkitHelpers.psd1'
    Import-Module $script:ManifestPath -Force
    $script:Tasks = @(Get-M365Task)
}

Describe 'ToolkitHelpers catalog' {
    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }
    It 'discovers scripts in every area folder' {
        $areas = @(Get-M365TaskArea).Name
        foreach ($a in 'partner', 'onboarding', 'entra', 'exchange', 'mailauth') { $areas | Should -Contain $a }
        $script:Tasks.Count | Should -BeGreaterThan 25
    }
    It 'every task has a synopsis, a description, an example and a Status line' {
        foreach ($t in $script:Tasks) {
            $t.Synopsis | Should -Not -BeNullOrEmpty -Because $t.Name
            $t.Description | Should -Not -BeNullOrEmpty -Because $t.Name
            $t.Examples.Count | Should -BeGreaterThan 0 -Because $t.Name
            $t.Status | Should -Not -Be 'Unknown' -Because $t.Name
        }
    }
    It 'every parameter has help text' {
        foreach ($t in $script:Tasks) {
            foreach ($p in $t.Parameters) { $p.Help | Should -Not -BeNullOrEmpty -Because "$($t.Name) -$($p.Name)" }
        }
    }
    It 'classifies scripts with SupportsShouldProcess as write' {
        ($script:Tasks | Where-Object Name -eq 'New-M365MailContact').IsWrite | Should -BeTrue
        ($script:Tasks | Where-Object Name -eq 'Test-M365SpfRecord').IsWrite | Should -BeFalse
    }
    It 'reads parameter metadata' {
        $t = $script:Tasks | Where-Object Name -eq 'Enable-M365Dkim'
        $domain = $t.Parameters | Where-Object Name -eq 'Domain'
        $domain.Mandatory | Should -BeTrue
        $domain.IsArray | Should -BeTrue
        $key = $t.Parameters | Where-Object Name -eq 'KeySize'
        $key.ValidateSet | Should -Be @('1024', '2048')
        $key.Default | Should -Be '2048'
    }
    It 'keeps array-valued properties as arrays even with one element (strict-mode .Count safety)' {
        foreach ($t in $script:Tasks) {
            $t.GraphScopes -is [array] | Should -BeTrue -Because "$($t.Name).GraphScopes"
            $t.Examples -is [array] | Should -BeTrue -Because "$($t.Name).Examples"
            $t.Parameters -is [array] | Should -BeTrue -Because "$($t.Name).Parameters"
            foreach ($p in $t.Parameters) { $p.ValidateSet -is [array] | Should -BeTrue -Because "$($t.Name) -$($p.Name).ValidateSet" }
        }
        $one = $script:Tasks | Where-Object { $_.GraphScopes.Count -eq 1 } | Select-Object -First 1
        $one | Should -Not -BeNullOrEmpty -Because 'at least one script declares a single Graph scope, which is the case that used to unroll'
    }
    It 'flags password-prompting scripts as interactive' {
        ($script:Tasks | Where-Object Name -eq 'New-M365BreakGlassAccount').IsInteractive | Should -BeTrue
        ($script:Tasks | Where-Object Name -eq 'Test-M365SpfRecord').IsInteractive | Should -BeFalse
    }
    It 'reads Graph scopes from the notes' {
        ($script:Tasks | Where-Object Name -eq 'New-M365BreakGlassAccount').GraphScopes | Should -Contain 'User.ReadWrite.All'
    }
    It 'keeps the order the script declares its parameters in' {
        foreach ($t in $script:Tasks) {
            $declared = @((Get-Command $t.Path).ScriptBlock.Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            @($t.Parameters.Name) | Should -Be $declared -Because $t.Name
        }
    }
}

Describe 'ToolkitHelpers command lines' {
    It 'quotes strings and doubles embedded quotes' {
        Format-M365Argument "O'Brien" | Should -Be "'O''Brien'"
    }
    It 'escapes the typographic quotes Outlook and Word insert, so a value can never end the string early' {
        $evil = "x$([char]0x2019); Write-Output INJECTED; $([char]0x2019)"
        $line = Format-M365CommandLine -ScriptPath 'C:\r\x.ps1' -Values @{ Name = $evil }
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($line, [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
        @($ast.EndBlock.Statements).Count | Should -Be 1
        $arg = $ast.EndBlock.Statements[0].PipelineElements[0].CommandElements[-1]
        $arg.Value | Should -Be $evil
    }
    It 'renders arrays, numbers, booleans and hashtables' {
        Format-M365Argument @('a', 'b') | Should -Be "'a', 'b'"
        Format-M365Argument 42 | Should -Be '42'
        Format-M365Argument $true | Should -Be '$true'
        Format-M365Argument @{ b = 1; a = 'x' } | Should -Be "@{ a = 'x'; b = 1 }"
    }
    It 'builds a command line, omitting empty values and false switches, emitting true switches bare' {
        $line = Format-M365CommandLine -ScriptPath 'C:\r\x.ps1' -Values @{ Name = 'N'; Hidden = [switch]::new($true); Off = [switch]::new($false); Empty = ''; Nothing = $null; List = @('a', 'b'); None = @() } -AppendWhatIf
        $line | Should -Be "& 'C:\r\x.ps1' -Hidden -List 'a', 'b' -Name 'N' -WhatIf"
    }
    It 'writes [bool] values as -Name:$true / -Name:$false, the only form a [bool] parameter binds' {
        $line = Format-M365CommandLine -ScriptPath 'C:\r\x.ps1' -Values @{ Enabled = $false; Other = $true }
        $line | Should -Be "& 'C:\r\x.ps1' -Enabled:`$false -Other:`$true"
        $d = Join-Path $TestDrive 'b.ps1'
        Set-Content $d '[CmdletBinding()] param([Parameter(Mandatory)][bool]$Enabled) "Enabled=$Enabled"'
        & ([scriptblock]::Create((Format-M365CommandLine -ScriptPath $d -Values @{ Enabled = $false }))) | Should -Be 'Enabled=False'
        & ([scriptblock]::Create((Format-M365CommandLine -ScriptPath $d -Values @{ Enabled = $true }))) | Should -Be 'Enabled=True'
    }
    It 'puts the tenant first, keeps the given order, and shortens repo paths' {
        $repo = Join-Path $TestDrive 'repo'; $script = Join-Path $repo 'scripts' 'powershell' 'exchange' 'X.ps1'
        $line = Format-M365CommandLine -ScriptPath $script -RepoRoot $repo -Values ([ordered]@{ Name = 'N'; Alias = 'a@x.example'; Organization = 'contoso.onmicrosoft.com' })
        $line | Should -Be "& './scripts/powershell/exchange/X.ps1' -Organization 'contoso.onmicrosoft.com' -Name 'N' -Alias 'a@x.example'"
    }
    It 'coerces form text by parameter type' {
        $arr = [pscustomobject]@{ Name = 'Members'; Type = 'String[]'; IsSwitch = $false; IsArray = $true }
        $int = [pscustomobject]@{ Name = 'Top'; Type = 'Int32'; IsSwitch = $false; IsArray = $false }
        $sw = [pscustomobject]@{ Name = 'Force'; Type = 'SwitchParameter'; IsSwitch = $true; IsArray = $false }
        $str = [pscustomobject]@{ Name = 'Name'; Type = 'String'; IsSwitch = $false; IsArray = $false }
        $hash = [pscustomobject]@{ Name = 'Tokens'; Type = 'Hashtable'; IsSwitch = $false; IsArray = $false }
        ConvertTo-M365TaskValue -Text 'a, b' -Parameter $arr | Should -Be @('a', 'b')
        ConvertTo-M365TaskValue -Text ' 7 ' -Parameter $int | Should -Be 7
        ConvertTo-M365TaskValue -Text 'yes' -Parameter $sw | Should -BeOfType [switch]
        (ConvertTo-M365TaskValue -Text 'yes' -Parameter $sw).IsPresent | Should -BeTrue
        (ConvertTo-M365TaskValue -Text '' -Parameter $sw).IsPresent | Should -BeFalse
        $bool = [pscustomobject]@{ Name = 'Enabled'; Type = 'Boolean'; IsSwitch = $false; IsArray = $false }
        ConvertTo-M365TaskValue -Text '' -Parameter $bool | Should -BeOfType [bool]
        ConvertTo-M365TaskValue -Text '' -Parameter $str | Should -BeNullOrEmpty
        (ConvertTo-M365TaskValue -Text 'A=1; B=two' -Parameter $hash).B | Should -Be 'two'
    }
    It 'round-trips a real task into a runnable-looking line' {
        $t = Get-M365Task -Name 'Test-M365SpfRecord' | Select-Object -First 1
        $line = Format-M365CommandLine -ScriptPath $t.Path -Values @{ Domain = @('contoso.com') }
        $line | Should -Be "& './scripts/powershell/mailauth/Test-M365SpfRecord.ps1' -Domain 'contoso.com'"
    }
}
