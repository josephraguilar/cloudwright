BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/MsScripter/MsScripter.psd1') -Force
}
Describe 'Generated commands preserve data as data' {
    It 'escapes every PowerShell single-quote character in values, arrays, and hashtable keys' {
        InModuleScope MsScripter {
            foreach ($quote in @([char]39, [char]0x2018, [char]0x2019, [char]0x201a, [char]0x201b)) {
                $value = "name${quote}; Remove-MgUser; ${quote}"
                foreach ($case in @(
                    @{ Value = $value; Type = 'String' },
                    @{ Value = @($value); Type = 'MultiChoice' },
                    @{ Value = @{ $value = $value }; Type = 'Hashtable' }
                )) {
                    $literal = Format-MsValue @case
                    $errors = $null
                    $ast = [System.Management.Automation.Language.Parser]::ParseInput("Write-Output $literal", [ref]$null, [ref]$errors)
                    $errors | Should -BeNullOrEmpty
                    @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)).Count | Should -Be 1
                }
            }
        }
    }
    It 'rejects executable syntax in legacy raw placeholders' {
        InModuleScope MsScripter {
            foreach ($bad in '$(Remove-MgUser)', '"; Remove-MgUser; "', "O'Neil", "x`nRemove-MgUser", "x$([char]0x2019)y") {
                { Expand-MsTemplate -Text '"{{Name:raw}}"' -Answers @{ Name = $bad } -Fields @(@{ Name = 'Name'; Type = 'String' }) } | Should -Throw '*cannot safely render*'
            }
        }
    }
    It 'quotes OData values and PowerShell literals separately' {
        InModuleScope MsScripter {
            $name = "O'Neil$([char]0x2019); `$(`$bad); ' or displayName eq 'anyone"
            $filter = Expand-MsTemplate -Text '{{Name:filter:displayName}}' -Answers @{ Name = $name } -Fields @(@{ Name = 'Name'; Type = 'String' })
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput("Write-Output $filter", [ref]$null, [ref]$errors)
            $errors | Should -BeNullOrEmpty
            $commands = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
            $commands.Count | Should -Be 1
            $commands[0].CommandElements[1].Value | Should -Be ("displayName eq '" + $name.Replace("'", "''") + "'")
        }
    }
    It 'rejects comment termination and newlines in generated context headers' {
        $task = Get-MsTask azure.create.resource-group
        foreach ($bad in "lab`nRemove-MgUser", 'lab #> Remove-MgUser <#') {
            { New-MsScript -Task $task -Answers @{ Name = 'rg-lab'; Location = 'eastus2' } -Context @{ SubscriptionName = $bad; SubscriptionId = 'example' } -Style Explained } | Should -Throw '*Context values*'
        }
    }
}
Describe 'Learn Graph session checks' {
    It 'does not reuse lookup rows after switching tenants' {
        InModuleScope MsScripter {
            $script:SourceCache = @{}; $script:ContosoMode = $false; $script:LookupCount = 0
            $script:LookupContext = [pscustomobject]@{ TenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; Account = 'reader@contoso.example'; Scopes = @('Group.Read.All'); AuthType = 'Delegated'; ContextScope = 'Process' }
            function script:Get-MgContext { [CmdletBinding()] param() $script:LookupContext }
            function script:Get-MgGroup { [CmdletBinding()] param() $script:LookupCount++; [pscustomobject]@{ Id = $script:LookupContext.TenantId; DisplayName = 'Example group' } }
            try {
                $source = @{ Cmdlet = 'Get-MgGroup'; Auth = 'Graph'; Display = 'DisplayName'; Value = 'Id' }
                $first = Resolve-MsSource -Source $source -Answers @{} -Fields @()
                $script:LookupContext.TenantId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                $second = Resolve-MsSource -Source $source -Answers @{} -Fields @()
                $first.Value | Should -Be 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                $second.Value | Should -Be 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                $script:LookupCount | Should -Be 2
            } finally {
                Remove-Item Function:Get-MgContext, Function:Get-MgGroup
                $script:SourceCache = @{}
            }
        }
    }
    It 'does not accept broad, persistent, or app-only sessions' {
        InModuleScope MsScripter {
            $ctx = [pscustomobject]@{ TenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; Scopes = @('User.Read.All'); AuthType = 'Delegated'; ContextScope = 'Process' }
            Test-MsReadOnlyGraphContext $ctx | Should -BeTrue
            $ctx.Scopes += 'User.ReadWrite.All'
            Test-MsReadOnlyGraphContext $ctx | Should -BeFalse
            $ctx.Scopes = @('User.Read.All'); $ctx.AuthType = 'AppOnly'
            Test-MsReadOnlyGraphContext $ctx | Should -BeFalse
            $ctx.AuthType = 'Delegated'; $ctx.ContextScope = 'CurrentUser'
            Test-MsReadOnlyGraphContext $ctx | Should -BeFalse
        }
    }
}
