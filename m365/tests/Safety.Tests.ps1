# Exercises the actual release policy. Unlike legacy mutation-unit tests, this
# file never mocks Test-M365ReadOnly or Assert-M365WriteAllowed.
BeforeAll {
    $script:Modules = Join-Path $PSScriptRoot '..' 'scripts' 'powershell' 'modules'
    Import-Module (Join-Path $script:Modules 'M365Helpers/M365Helpers.psd1') -Force
    Import-Module (Join-Path $script:Modules 'ToolkitHelpers/ToolkitHelpers.psd1') -Force
    Import-Module (Join-Path $script:Modules 'GdapHelpers/GdapHelpers.psd1') -Force
    $script:Tenant = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    function global:Remove-SafetyObject { $global:SafetyWrites++ }
    function Invoke-SafetyMutation {
        [CmdletBinding(SupportsShouldProcess)]
        param([string]$Service = 'Graph')
        Invoke-M365Change -Caller $PSCmdlet -Service $Service -Action 'Unsafe test operation' -Command Remove-SafetyObject
    }
    function global:Get-MgContext { [CmdletBinding()] param() $global:SafetyGraph }
    function global:Connect-MgGraph {
        [CmdletBinding()] param($TenantId, $Scopes, $ContextScope, [switch]$NoWelcome)
        $global:SafetyConnects++
        $global:SafetyGraph = [pscustomobject]@{ TenantId = $TenantId; Scopes = $Scopes; ContextScope = $ContextScope; AuthType = 'Delegated'; Account = 'reader@contoso.example' }
    }
    function global:Disconnect-MgGraph { [CmdletBinding()] param() $global:SafetyDisconnects++; $global:SafetyGraph = $null }
    function global:Connect-ExchangeOnline { [CmdletBinding()] param($CommandName, $DelegatedOrganization, $UserPrincipalName, $ShowBanner) }
    function global:Disconnect-ExchangeOnline { [CmdletBinding(SupportsShouldProcess)] param() }
    function global:Get-ConnectionInformation { [CmdletBinding()] param() [pscustomobject]@{ State = 'Connected' } }
}
AfterAll {
    foreach ($name in 'Remove-SafetyObject', 'Get-MgContext', 'Connect-MgGraph', 'Disconnect-MgGraph',
        'Connect-ExchangeOnline', 'Disconnect-ExchangeOnline', 'Get-ConnectionInformation') {
        Remove-Item "Function:\$name" -ErrorAction SilentlyContinue
    }
    Remove-Variable -Scope Global -Name SafetyWrites, SafetyGraph, SafetyConnects, SafetyDisconnects, M365ToolkitTargets -ErrorAction SilentlyContinue
}

Describe 'Mandatory read-only release policy' {
    BeforeEach { $global:SafetyWrites = 0; $null = Stop-M365ChangeRecording }
    It 'is enabled without configuration or flags, and survives module reload' {
        Test-M365ReadOnly | Should -BeTrue
        Import-Module (Join-Path $script:Modules 'M365Helpers/M365Helpers.psd1') -Force
        Test-M365ReadOnly | Should -BeTrue
    }
    It 'fails module import when the policy file is missing, even with a Continue caller' {
        $copy = Join-Path $TestDrive 'broken-helpers'
        Copy-Item (Join-Path $script:Modules 'M365Helpers') $copy -Recurse
        Remove-Item (Join-Path $copy 'Safety.ps1')
        $executable = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        $probe = Join-Path $TestDrive 'probe-missing-policy.ps1'
        @'
param($ModulePath)
$ErrorActionPreference = 'Continue'
try { Import-Module $ModulePath -Force -ErrorAction Stop; exit 2 } catch { exit 0 }
'@ | Set-Content $probe
        & $executable -NoProfile -File $probe -ModulePath (Join-Path $copy 'M365Helpers.psd1')
        $LASTEXITCODE | Should -Be 0
    }
    It 'blocks <Service> writes without a plan, despite a manually supplied target and Confirm false' -ForEach @(
        @{ Service = 'Graph' }, @{ Service = 'Exchange' }, @{ Service = 'Hudu' }
    ) {
        if ($Service -ne 'Hudu') { Set-M365ChangeTarget -Service $Service -Label contoso.onmicrosoft.com }
        { Invoke-SafetyMutation -Service $Service -Confirm:$false } | Should -Throw '*safe mode*'
        $global:SafetyWrites | Should -Be 0
    }
    It 'rejects writes even with an approved wildcard plan' {
        Start-M365ChangeRecording -ApprovedPlan @([pscustomobject]@{ Status = 'Planned'; Text = 'all'; Pattern = '.*' })
        { Invoke-SafetyMutation -Confirm:$false } | Should -Throw '*safe mode*'
        $global:SafetyWrites | Should -Be 0
    }
    It 'refuses a mutation path even when the caller uses WhatIf' {
        { Invoke-SafetyMutation -WhatIf } | Should -Throw '*safe mode*'
        $global:SafetyWrites | Should -Be 0
    }
    It 'blocks direct Hudu writes before reading credentials or sending HTTP' {
        InModuleScope M365Helpers {
            Mock Invoke-RestMethod { throw 'must not reach HTTP' }
            Mock Get-M365Settings { throw 'must not read credentials' }
            { Invoke-M365HuduRequest -Method Post -Path '/api/v1/asset_passwords' } | Should -Throw '*safe mode*'
            Should -Invoke Invoke-RestMethod -Times 0
            Should -Invoke Get-M365Settings -Times 0
        }
    }
    It 'refuses GDAP approval browser launch' {
        Mock Start-Process -ModuleName GdapHelpers { throw 'must not launch a browser' }
        { Open-GdapApprovalPage -Url 'https://admin.microsoft.com/' } | Should -Throw '*Safe mode*'
        Should -Invoke Start-Process -ModuleName GdapHelpers -Times 0
    }
}

Describe 'Read-only authentication' {
    BeforeEach {
        $global:SafetyGraph = $null; $global:SafetyConnects = 0; $global:SafetyDisconnects = 0
        $global:M365ToolkitTargets = @{}
        Mock Get-Module -ModuleName M365Helpers { [pscustomobject]@{ Name = 'test dependency' } } -ParameterFilter { $ListAvailable }
    }
    It 'refuses Graph permission <Scope> before sign-in' -ForEach @(
        @{ Scope = 'User.ReadWrite.All' }, @{ Scope = 'Directory.AccessAsUser.All' },
        @{ Scope = '.default' }, @{ Scope = 'Mail.Send' }, @{ Scope = 'DeviceLocalCredential.Read.All' },
        @{ Scope = 'User.RevokeSessions.All' }, @{ Scope = 'Unknown.Read.All' }
    ) {
        { Assert-M365Graph -TenantId $script:Tenant -Scopes $Scope } | Should -Throw '*safe mode*'
        $global:SafetyConnects | Should -Be 0
    }
    It 'creates a delegated read-only context scoped to this process' {
        $r = Assert-M365Graph -TenantId $script:Tenant -Scopes 'User.Read.All'
        $r.ContextScope | Should -Be 'Process'
        $r.Scopes | Should -Be @('User.Read.All')
        $global:SafetyConnects | Should -Be 1
    }
    It 'disconnects a pre-existing write-capable session instead of reusing it' {
        $global:SafetyGraph = [pscustomobject]@{ TenantId = $script:Tenant; Scopes = @('User.Read.All', 'User.ReadWrite.All'); ContextScope = 'Process'; AuthType = 'Delegated' }
        $r = Assert-M365Graph -TenantId $script:Tenant -Scopes 'User.Read.All'
        $global:SafetyDisconnects | Should -Be 1
        $global:SafetyConnects | Should -Be 1
        $r.Scopes | Should -Be @('User.Read.All')
    }
    It 'refuses and disconnects an unexpectedly overprivileged result after sign-in' {
        Mock Connect-MgGraph -ModuleName M365Helpers {
            $global:SafetyGraph = [pscustomobject]@{ TenantId = $TenantId; Scopes = @('User.Read.All', 'User.ReadWrite.All'); ContextScope = 'Process'; AuthType = 'Delegated' }
        }
        { Assert-M365Graph -TenantId $script:Tenant -Scopes 'User.Read.All' } | Should -Throw '*refused the Graph session*'
        $global:SafetyGraph | Should -BeNullOrEmpty
        $global:SafetyDisconnects | Should -Be 1
    }
    It 'refuses and disconnects a session that lacks the requested read scope' {
        Mock Connect-MgGraph -ModuleName M365Helpers {
            $global:SafetyGraph = [pscustomobject]@{ TenantId = $TenantId; Scopes = @('Group.Read.All'); ContextScope = 'Process'; AuthType = 'Delegated' }
        }
        { Assert-M365Graph -TenantId $script:Tenant -Scopes 'User.Read.All' } | Should -Throw '*refused the Graph session*'
        $global:SafetyGraph | Should -BeNullOrEmpty
    }
    It 'disconnects a session returned in the wrong tenant' {
        Mock Connect-MgGraph -ModuleName M365Helpers {
            $global:SafetyGraph = [pscustomobject]@{ TenantId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; Scopes = @('User.Read.All'); ContextScope = 'Process'; AuthType = 'Delegated' }
        }
        { Assert-M365Graph -TenantId $script:Tenant -Scopes 'User.Read.All' } | Should -Throw '*not*aaaaaaaa*'
        $global:SafetyGraph | Should -BeNullOrEmpty
    }
    It 'rejects app-only, persistent, or incomplete contexts' {
        InModuleScope M365Helpers {
            foreach ($pair in @(@('AppOnly', 'Process'), @('Delegated', 'CurrentUser'), @('', 'Process'))) {
                $ctx = [pscustomobject]@{ AuthType = $pair[0]; ContextScope = $pair[1]; Scopes = @('User.Read.All'); TenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
                Test-M365ReadOnlyGraphContext $ctx | Should -BeFalse
            }
            Test-M365ReadOnlyGraphContext ([pscustomobject]@{ TenantId = 'x' }) | Should -BeFalse
        }
    }
    It 'replaces an unknown Exchange connection and imports only explicit read commands' {
        Mock Get-M365Settings -ModuleName M365Helpers { [pscustomobject]@{ msp = [pscustomobject]@{ homeTenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' } } }
        Mock Resolve-M365TenantId -ModuleName M365Helpers { 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
        Mock Get-M365ExchangeTenant -ModuleName M365Helpers {
            [pscustomobject]@{ InitialDomain = 'contoso.onmicrosoft.com'; TenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; ModuleName = 'FakeExo' }
        }
        Mock Connect-ExchangeOnline -ModuleName M365Helpers { }
        Mock Disconnect-ExchangeOnline -ModuleName M365Helpers { }
        $null = Assert-M365Exchange -Organization contoso.onmicrosoft.com
        Should -Invoke Disconnect-ExchangeOnline -ModuleName M365Helpers -Times 1
        Should -Invoke Connect-ExchangeOnline -ModuleName M365Helpers -Times 1 -ParameterFilter {
            $CommandName.Count -gt 0 -and @($CommandName | Where-Object { $_ -notlike 'Get-*' -or $_ -match '\*' }).Count -eq 0
        }
    }
    It 'rejects malformed tenant identifiers without making a network request' {
        Mock Invoke-RestMethod -ModuleName M365Helpers { throw 'must not make HTTP request' }
        foreach ($bad in 'contoso.com/extra', 'contoso.com?x=1', 'https://contoso.com', 'contoso.com#fragment', '../common') {
            { Resolve-M365TenantId $bad } | Should -Throw '*Tenant must be*'
        }
        Should -Invoke Invoke-RestMethod -ModuleName M365Helpers -Times 0
    }
}

Describe 'Allowlisted task execution' {
    BeforeAll {
        $script:Task = Get-M365Task -ReadOnly -Name Get-M365Group | Select-Object -First 1
        $script:Line = Format-M365CommandLine -ScriptPath $script:Task.Path -Values @{ TenantId = 'contoso.onmicrosoft.com'; Top = 25; IncludeMemberCount = [switch]::new($true) }
    }
    It 'admits the reviewed read-task catalog only' {
        $tasks = @(Get-M365Task -ReadOnly)
        $tasks.Count | Should -Be 16
        @($tasks | Where-Object IsWrite) | Should -BeNullOrEmpty
        @($tasks.Name) | Should -Not -Contain 'New-M365GdapRequest'
        @($tasks.Name) | Should -Not -Contain 'Invoke-M365UserOffboarding'
    }
    It 'accepts generated literal parameters' { { Assert-M365ReadOnlyCommand $script:Line } | Should -Not -Throw }
    It 'does not execute shell syntax embedded in a quoted name' {
        $line = Format-M365CommandLine -ScriptPath $script:Task.Path -Values @{ Name = "O$([char]0x2019)Neil; Remove-MgUser -All; `$(`$x)" }
        { Assert-M365ReadOnlyCommand $line } | Should -Not -Throw
    }
    It 'rejects a second command, pipeline, or redirection' {
        foreach ($suffix in '; Remove-MgUser', ' | Remove-MgUser', ' > stolen.txt', ' &') {
            { Assert-M365ReadOnlyCommand ($script:Line + $suffix) } | Should -Throw '*Safe mode*'
        }
    }
    It 'rejects expressions, arbitrary variables, and dot-sourcing' {
        foreach ($line in "& './scripts/powershell/entra/Get-M365Group.ps1' -Name `$(Remove-MgUser)",
            "& './scripts/powershell/entra/Get-M365Group.ps1' -Name `$anything", ". './scripts/powershell/entra/Get-M365Group.ps1'") {
            { Assert-M365ReadOnlyCommand $line } | Should -Throw '*Safe mode*'
        }
    }
    It 'rejects writes even if a UI caller classifies them as read-only' {
        $task = Get-M365Task -Name New-M365User | Select-Object -First 1
        $line = Format-M365CommandLine -ScriptPath $task.Path -Values @{}
        { Assert-M365ReadOnlyCommand $line } | Should -Throw '*allowlist*'
    }
    It 'rejects arbitrary paths and abbreviated or injected parameter names' {
        { Assert-M365ReadOnlyCommand "& '/tmp/Get-M365Group.ps1'" } | Should -Throw '*allowlist*'
        { Assert-M365ReadOnlyCommand "& './scripts/powershell/entra/Get-M365Group.ps1' -Te 'x'" } | Should -Throw '*parameter*'
    }
}
