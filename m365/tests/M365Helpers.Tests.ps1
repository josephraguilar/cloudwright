# Legacy domain behavior runs only against the fake APIs in this test file.
# Mock the release policy here so these tests still exercise plan matching and
# mutation semantics. Safety.Tests.ps1 and EndToEnd.Tests.ps1 use the real policy.
BeforeAll {
    $script:ModulesPath = Join-Path $PSScriptRoot '..' 'scripts' 'powershell' 'modules'
    $script:ManifestPath = Join-Path $script:ModulesPath 'M365Helpers' 'M365Helpers.psd1'
    Import-Module $script:ManifestPath -Force
}

Describe 'M365Helpers module' {
    BeforeEach {
        Mock Test-M365ReadOnly -ModuleName M365Helpers { $false }
    }

    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'exports the expected functions' {
        $expected = 'Get-M365Settings', 'Get-M365ClientConfig', 'Resolve-M365TenantId', 'Assert-M365Graph', 'Assert-M365Exchange',
        'Disconnect-M365Tenant', 'Resolve-DnsRecord', 'New-StrongPassword', 'Add-HuduPassword', 'Write-M365Step',
        'Assert-M365SameTenant', 'Invoke-M365Change', 'Format-M365Command', 'New-M365Placeholder', 'Start-M365ChangeRecording', 'Stop-M365ChangeRecording'
        $actual = (Get-Command -Module M365Helpers).Name
        foreach ($f in $expected) { $actual | Should -Contain $f }
    }

    Context 'New-StrongPassword' {
        It 'returns the requested length' {
            (New-StrongPassword -Length 40).Length | Should -Be 40
        }
        It 'contains upper, lower, digit and symbol' {
            $p = New-StrongPassword -Length 16
            $p | Should -Match '[A-Z]'
            $p | Should -Match '[a-z]'
            $p | Should -Match '[0-9]'
            $p | Should -Match '[!@#$%^&*\-_=+?]'
        }
        It 'does not repeat' {
            (New-StrongPassword) | Should -Not -Be (New-StrongPassword)
        }
        It 'can return a SecureString' {
            (New-StrongPassword -AsSecureString) | Should -BeOfType [securestring]
        }
    }

    Context 'Test-M365PasswordComplexity' {
        It 'accepts a long mixed password' { (Test-M365PasswordComplexity -Password 'Correct-Horse-Battery-9' -MinimumLength 16).Ok | Should -BeTrue }
        It 'rejects short, single-class and spaced passwords with reasons' {
            $r = Test-M365PasswordComplexity -Password 'short' -MinimumLength 16
            $r.Ok | Should -BeFalse
            ($r.Problems -join '; ') | Should -Match 'at least 16'
            ($r.Problems -join '; ') | Should -Match 'three of'
            ((Test-M365PasswordComplexity -Password 'Has A Space In It 123!' -MinimumLength 16).Problems -join '; ') | Should -Match 'no spaces'
        }
    }

    Context 'Get-M365Settings' {
        BeforeAll {
            $script:Example = Join-Path $PSScriptRoot '..' 'config' 'msp.settings.example.json'
        }
        It 'rejects the example file because of placeholders' {
            { Get-M365Settings -Path $script:Example -Force } | Should -Throw '*placeholder*'
        }
        It 'loads a filled-in file and caches it' {
            $json = Get-Content $script:Example -Raw | ConvertFrom-Json
            $json.msp.adminUpn = 'tech@msp.example'
            $path = Join-Path $TestDrive 'msp.json'
            $json | ConvertTo-Json -Depth 6 | Set-Content $path
            $s = Get-M365Settings -Path $path -Force
            $s.msp.sharedClientsMailbox | Should -Be 'clients@msp.example'
            (Get-M365Settings -Path $path) | Should -Be $s
        }
        It 'throws a helpful error when the file is missing' {
            { Get-M365Settings -Path (Join-Path $TestDrive 'nope.json') -Force } | Should -Throw '*msp.settings.example.json*'
        }
    }

    Context 'Get-M365ClientConfig' {
        BeforeAll {
            $json = Get-Content (Join-Path $PSScriptRoot '..' 'config' 'msp.settings.example.json') -Raw | ConvertFrom-Json
            $json.msp.supportEmail = 'support@msp.example'; $json.msp.adminUpn = 'tech@msp.example'
            $settingsPath = Join-Path $TestDrive 'msp.json'
            $json | ConvertTo-Json -Depth 6 | Set-Content $settingsPath
            $script:Settings = Get-M365Settings -Path $settingsPath -Force
            $script:ExampleClient = Join-Path $PSScriptRoot '..' 'config' 'clients' 'example.client.json'
        }
        It 'keeps an explicit internalAlias from the client file' {
            $c = Get-M365ClientConfig -Path $script:ExampleClient -Settings $script:Settings
            $c.internalAlias | Should -Be 'contoso.clients@msp.example'
        }
        It 'derives the alias from msp.clientAliasPattern when the client file has none' {
            $minimal = @{ name = 'Pat'; shortName = 'pat'; tenantId = 'pat.onmicrosoft.com'; primaryDomain = 'pat.example' } | ConvertTo-Json
            $path = Join-Path $TestDrive 'pat.local.json'
            $minimal | Set-Content $path
            (Get-M365ClientConfig -Path $path -Settings $script:Settings).internalAlias | Should -Be 'pat.clients@msp.example'
        }
        It 'reads the explicit onmicrosoftDomain from the example (tenantId is a GUID there)' {
            $c = Get-M365ClientConfig -Path $script:ExampleClient -Settings $script:Settings
            $c.onmicrosoftDomain | Should -Be 'contoso.onmicrosoft.com'
            $c.tenantId | Should -Be '11111111-2222-3333-4444-555555555555'
        }
        It 'reuses tenantId as onmicrosoftDomain when tenantId is one' {
            $cfg = @{ name = 'Re'; shortName = 're'; tenantId = 're.onmicrosoft.com'; primaryDomain = 're.example' } | ConvertTo-Json
            $path = Join-Path $TestDrive 're.local.json'
            $cfg | Set-Content $path
            (Get-M365ClientConfig -Path $path -Settings $script:Settings).onmicrosoftDomain | Should -Be 're.onmicrosoft.com'
        }
        It 'requires onmicrosoftDomain when tenantId is a GUID' {
            $cfg = @{ name = 'G'; shortName = 'gg'; tenantId = '11111111-2222-3333-4444-555555555555'; primaryDomain = 'g.example' } | ConvertTo-Json
            $path = Join-Path $TestDrive 'g.local.json'
            $cfg | Set-Content $path
            { Get-M365ClientConfig -Path $path -Settings $script:Settings } | Should -Throw '*onmicrosoftDomain*'
        }
        It 'rejects an onmicrosoftDomain that is not one' {
            $cfg = @{ name = 'X'; shortName = 'xx'; tenantId = '11111111-2222-3333-4444-555555555555'; onmicrosoftDomain = 'x.example'; primaryDomain = 'x.example' } | ConvertTo-Json
            $path = Join-Path $TestDrive 'x.local.json'
            $cfg | Set-Content $path
            { Get-M365ClientConfig -Path $path -Settings $script:Settings } | Should -Throw '*onmicrosoft.com*'
        }
        It 'fills defaults for optional keys' {
            $minimal = @{ name = 'Min'; shortName = 'min'; tenantId = '11111111-2222-3333-4444-555555555555'; onmicrosoftDomain = 'min.onmicrosoft.com'; primaryDomain = 'min.example' } | ConvertTo-Json
            $path = Join-Path $TestDrive 'min.local.json'
            $minimal | Set-Content $path
            $c = Get-M365ClientConfig -Path $path -Settings $script:Settings
            $c.ironScales | Should -BeFalse
            $c.support24x7 | Should -BeFalse
            $c.newUserDefaults.usageLocation | Should -Be 'US'
            $c.newUserDefaults.issueTemporaryAccessPass | Should -BeTrue
            $c.domains | Should -Be @('min.example')
            $c.poc.Count | Should -Be 0
        }
        It 'rejects a shortName that cannot be a mail alias' {
            $bad = @{ name = 'Bad'; shortName = 'Bad Name!'; tenantId = 'bad.onmicrosoft.com'; primaryDomain = 'bad.example' } | ConvertTo-Json
            $path = Join-Path $TestDrive 'bad.local.json'
            $bad | Set-Content $path
            { Get-M365ClientConfig -Path $path -Settings $script:Settings } | Should -Throw '*shortName*'
        }
        It 'puts primaryDomain first in domains' {
            $cfg = @{ name = 'Two'; shortName = 'two'; tenantId = 'two.onmicrosoft.com'; primaryDomain = 'two.example'; domains = @('other.example') } | ConvertTo-Json
            $path = Join-Path $TestDrive 'two.local.json'
            $cfg | Set-Content $path
            (Get-M365ClientConfig -Path $path -Settings $script:Settings).domains | Should -Be @('two.example', 'other.example')
        }
    }

    Context 'Config placeholders' {
        It 'lists placeholder key paths including array indexes and skips _comment keys' {
            $json = '{ "_comment": "<ignored>", "msp": { "adminUpn": "<fill>", "name": "x" }, "groups": [ { "id": "<g0>" }, { "id": "real" } ] }'
            $path = Join-Path $TestDrive 'ph.json'; $json | Set-Content $path
            $found = Get-M365ConfigPlaceholder -Path $path
            $found | Should -Be @('msp.adminUpn', 'groups[0].id')
        }
        It 'reads nested and indexed values, null when absent' {
            $json = '{ "msp": { "adminUpn": "<fill>" }, "groups": [ { "id": "g0" } ] }'
            $path = Join-Path $TestDrive 'get.json'; $json | Set-Content $path
            Get-M365ConfigValue -Path $path -Key 'groups[0].id' | Should -Be 'g0'
            Get-M365ConfigValue -Path $path -Key 'msp.adminUpn' | Should -Be '<fill>'
            Get-M365ConfigValue -Path $path -Key 'msp.nope' | Should -BeNullOrEmpty
            Get-M365ConfigValue -Path $path -Key 'groups[5].id' | Should -BeNullOrEmpty
        }
        It 'sets a nested value and an indexed value' {
            $json = '{ "msp": { "adminUpn": "<fill>" }, "groups": [ { "id": "<g0>" } ] }'
            $path = Join-Path $TestDrive 'set.json'; $json | Set-Content $path
            Set-M365ConfigValue -Path $path -Key 'msp.adminUpn' -Value 'tech@msp.example'
            Set-M365ConfigValue -Path $path -Key 'groups[0].id' -Value 'abc'
            $doc = Get-Content $path -Raw | ConvertFrom-Json
            $doc.msp.adminUpn | Should -Be 'tech@msp.example'
            $doc.groups[0].id | Should -Be 'abc'
            @(Get-M365ConfigPlaceholder -Path $path).Count | Should -Be 0
        }
        It 'the example settings file has exactly the placeholders setup asks for' {
            $found = Get-M365ConfigPlaceholder -Path (Join-Path $PSScriptRoot '..' 'config' 'msp.settings.example.json')
            $found | Should -Be @('msp.adminUpn')
        }
    }

    Context 'Resolve-M365TenantId' {
        It 'passes a GUID through, lower-cased' {
            Resolve-M365TenantId -TenantId '72F988BF-86F1-41AF-91AB-2D7CD011DB47' | Should -Be '72f988bf-86f1-41af-91ab-2d7cd011db47'
        }
        It 'extracts the GUID from the OpenID issuer' {
            Mock -ModuleName M365Helpers Invoke-RestMethod { [pscustomobject]@{ issuer = 'https://login.microsoftonline.com/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/v2.0' } }
            Resolve-M365TenantId -TenantId contoso.onmicrosoft.com | Should -Be 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        }
    }

    Context 'Resolve-DnsRecord' {
        It 'joins split TXT strings and strips quotes' {
            Mock -ModuleName M365Helpers Invoke-RestMethod {
                [pscustomobject]@{ Answer = @([pscustomobject]@{ type = 16; data = '"v=spf1 include:a.example" " include:b.example -all"' }) }
            }
            Resolve-DnsRecord -Name x.example -Type TXT | Should -Be 'v=spf1 include:a.example include:b.example -all'
        }
        It 'strips the trailing dot from CNAME targets and ignores other types' {
            Mock -ModuleName M365Helpers Invoke-RestMethod {
                [pscustomobject]@{ Answer = @(
                        [pscustomobject]@{ type = 5; data = 'selector1-x-example._domainkey.x.onmicrosoft.com.' },
                        [pscustomobject]@{ type = 16; data = '"ignored"' }) }
            }
            Resolve-DnsRecord -Name selector1._domainkey.x.example -Type CNAME | Should -Be @('selector1-x-example._domainkey.x.onmicrosoft.com')
        }
        It 'returns an empty array when there is no answer' {
            Mock -ModuleName M365Helpers Invoke-RestMethod { [pscustomobject]@{ Status = 3 } }
            @(Resolve-DnsRecord -Name none.example -Type TXT).Count | Should -Be 0
        }
    }
}

Describe 'Plan and run (Invoke-M365Change)' {

    BeforeAll {
        $env:M365_TOOLKIT_LOG_PATH = Join-Path $TestDrive 'logs'
        $global:StubCalls = [System.Collections.Generic.List[string]]::new()
        function global:New-StubThing { [CmdletBinding(SupportsShouldProcess)] param($Name, $Password, [switch]$Hidden, $Tags) $global:StubCalls.Add("New:$Name|$Password"); [pscustomobject]@{ Id = 'real-id-1' } }
        function global:Set-StubThing { [CmdletBinding(SupportsShouldProcess)] param($Identity, [switch]$Locked) $global:StubCalls.Add("Set:$Identity") }
        New-Module -Name PlanDemo -ScriptBlock {
            function New-Thing {
                [CmdletBinding(SupportsShouldProcess)]
                param([string]$Name, [string]$Secret)
                $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Create thing '$Name'" -Command 'New-StubThing' -Parameters ([ordered]@{ Name = $Name; Password = $Secret; Hidden = $true })
                $id = if ($run.Ran) { $run.Output.Id } else { New-M365Placeholder 'id of the thing created above' }
                $null = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Lock thing '$Name'" -Command 'Set-StubThing' -Parameters ([ordered]@{ Identity = $id; Locked = [switch]::new($true) })
            }
            Export-ModuleMember -Function New-Thing
        } | Import-Module -Force
    }
    AfterAll {
        Remove-Item Function:\New-StubThing, Function:\Set-StubThing -ErrorAction SilentlyContinue
        Remove-Module PlanDemo -ErrorAction SilentlyContinue
        Remove-Item env:M365_TOOLKIT_LOG_PATH -ErrorAction SilentlyContinue
    }
    BeforeEach {
        Mock Test-M365ReadOnly -ModuleName M365Helpers { $false }
        $global:StubCalls.Clear()
        Set-M365ChangeTarget -Service Exchange -Label 'contoso.onmicrosoft.com'
    }

    It 'renders strings with every PowerShell quote character escaped, so a value is always one argument' {
        $text = Format-M365Command -Command 'New-X' -Parameters ([ordered]@{ Name = "x$([char]0x2019); Remove-Thing; $([char]0x2019)" })
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
        @($ast.EndBlock.Statements).Count | Should -Be 1
    }
    It 'renders booleans as -Name:$true, switches bare, hashtables and arrays as literals, secrets hidden' {
        Format-M365Command -Command 'X' -Parameters ([ordered]@{ A = $true; B = [switch]::new($true); C = @{ password = 'p'; z = 1 }; D = @('a', 'b') }) |
            Should -Be "X -A:`$true -B -C @{ password = <hidden>; z = 1 } -D @('a', 'b')"
    }
    It 'plans under -WhatIf: records every change with the tenant and runs nothing' {
        Start-M365ChangeRecording
        New-Thing -Name 'Vendor' -Secret 'S3cr3t!' -WhatIf
        $plan = Stop-M365ChangeRecording
        $global:StubCalls.Count | Should -Be 0
        @($plan.Status) | Should -Be @('Planned', 'Planned')
        $plan[0].Text | Should -Be "[contoso.onmicrosoft.com] New-StubThing -Name 'Vendor' -Password <hidden> -Hidden:`$true"
        $plan[1].Text | Should -Be '[contoso.onmicrosoft.com] Set-StubThing -Identity <id of the thing created above> -Locked'
    }
    It 'runs an approved plan, filling placeholders with the real values' {
        Start-M365ChangeRecording; New-Thing -Name 'Vendor' -Secret 'S3cr3t!' -WhatIf; $plan = Stop-M365ChangeRecording
        Start-M365ChangeRecording -ApprovedPlan $plan
        New-Thing -Name 'Vendor' -Secret 'S3cr3t!' 6>$null
        $done = Stop-M365ChangeRecording
        @($done.Status) | Should -Be @('Done', 'Done')
        $global:StubCalls | Should -Be @('New:Vendor|S3cr3t!', 'Set:real-id-1')
    }
    It 'refuses, before running it, any change that is not in the approved plan' {
        Start-M365ChangeRecording; New-Thing -Name 'Vendor' -Secret 's' -WhatIf; $plan = Stop-M365ChangeRecording
        Start-M365ChangeRecording -ApprovedPlan $plan
        { New-Thing -Name 'Somebody Else' -Secret 's' 6>$null } | Should -Throw '*not in the reviewed plan*'
        $null = Stop-M365ChangeRecording
        $global:StubCalls.Count | Should -Be 0
    }
    It 'allows nothing when the approved plan is empty' {
        Start-M365ChangeRecording -ApprovedPlan @()
        { New-Thing -Name 'Vendor' -Secret 's' 6>$null } | Should -Throw '*not in the reviewed plan*'
        $null = Stop-M365ChangeRecording
        $global:StubCalls.Count | Should -Be 0
    }
    It 'refuses when the verified Exchange connection is no longer the one the cmdlet comes from' {
        $global:M365ToolkitTargets['Exchange'] = [pscustomobject]@{ Label = 'contoso.onmicrosoft.com'; TenantId = 'x'; ModuleName = 'tmpEXO_contoso'; Verified = 'live' }
        { New-Thing -Name 'Vendor' -Secret 's' 6>$null } | Should -Throw '*different Exchange connection*'
        $global:StubCalls.Count | Should -Be 0
    }
    It 'refuses when nobody signed in to the service' {
        $global:M365ToolkitTargets.Remove('Exchange')
        { New-Thing -Name 'Vendor' -Secret 's' 6>$null } | Should -Throw '*Not signed in to Exchange*'
        $global:StubCalls.Count | Should -Be 0
    }
    It 'runs the command the way the calling module would see it (module-scoped mocks and private functions)' {
        Mock -ModuleName PlanDemo New-StubThing { $global:StubCalls.Add('MOCK'); [pscustomobject]@{ Id = 'mock-id' } }
        New-Thing -Name 'Vendor' -Secret 's' 6>$null
        $global:StubCalls | Should -Be @('MOCK', 'Set:mock-id')
    }
    It 'never writes the secret to the audit log' {
        New-Thing -Name 'Vendor' -Secret 'S3cr3t!' 6>$null
        $log = Get-ChildItem (Join-Path $TestDrive 'logs') -Filter '*.jsonl' | Get-Content -Raw
        $log | Should -Match 'DONE \[contoso.onmicrosoft.com\] New-StubThing'
        $log | Should -Not -Match 'S3cr3t'
    }
    It 'Write-M365Log returns nothing unless -PassThru, so it cannot leak into output' {
        $out = @(Write-M365Log -Message 'x' -LogPath (Join-Path $TestDrive 'l2'))
        $out.Count | Should -Be 0
        Write-M365Log -Message 'x' -LogPath (Join-Path $TestDrive 'l2') -PassThru | Should -BeLike '*.jsonl'
    }
    It 'Invoke-M365WithRetry -Write does not retry a timeout (the change may have happened) but does retry 429' {
        $script:n = 0
        { Invoke-M365WithRetry -Write -BaseDelaySeconds 1 { $script:n++; throw 'The operation has timed out.' } } | Should -Throw '*timed out*'
        $script:n | Should -Be 1
        $script:n = 0
        Invoke-M365WithRetry -Write -BaseDelaySeconds 1 { $script:n++; if ($script:n -lt 2) { throw 'Response status code 429 (TooManyRequests).' }; 'ok' } 3>$null | Should -Be 'ok'
    }
}

Describe 'Tenant checks' {

    BeforeAll {
        $script:Guids = @{ 'home.onmicrosoft.com' = '11111111-1111-1111-1111-111111111111'; 'a.onmicrosoft.com' = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; 'b.onmicrosoft.com' = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; 'a.example' = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
        # A fake ExchangeOnlineManagement that behaves like the real one: several connections can be
        # open, and un-prefixed cmdlets always go to the MOST RECENT one.
        $global:FakeExo = @{ Connections = [System.Collections.Generic.List[object]]::new(); Active = $null; Connects = 0 }
        function global:Connect-ExchangeOnline { param($DelegatedOrganization, $UserPrincipalName, $ShowBanner, $ErrorAction)
            $org = if ($DelegatedOrganization) { $DelegatedOrganization } else { 'home.onmicrosoft.com' }
            if ($global:FakeExo.ConnectTo) { $org = $global:FakeExo.ConnectTo }
            $global:FakeExo.Connections.Add([pscustomobject]@{ State = 'Connected'; TokenStatus = 'Active'; DelegatedOrganization = $DelegatedOrganization })
            $global:FakeExo.Active = $org; $global:FakeExo.Connects++ }
        function global:Disconnect-ExchangeOnline { param($Confirm, $ErrorAction) $global:FakeExo.Connections.Clear(); $global:FakeExo.Active = $null }
        function global:Get-ConnectionInformation { param($ErrorAction) $global:FakeExo.Connections.ToArray() }
        function global:Get-AcceptedDomain { param($ErrorAction) if ($global:FakeExo.Active) { [pscustomobject]@{ DomainName = $global:FakeExo.Active; InitialDomain = $true } } else { throw 'Not connected' } }
    }
    AfterAll {
        Remove-Item Function:\Connect-ExchangeOnline, Function:\Disconnect-ExchangeOnline, Function:\Get-ConnectionInformation, Function:\Get-AcceptedDomain -ErrorAction SilentlyContinue
    }
    BeforeEach {
        Mock Test-M365ReadOnly -ModuleName M365Helpers { $false }
        $global:FakeExo.Connections.Clear(); $global:FakeExo.Active = $null; $global:FakeExo.Connects = 0; $global:FakeExo.ConnectTo = $null
        Mock -ModuleName M365Helpers Get-Module { [pscustomobject]@{ Name = 'ExchangeOnlineManagement' } } -ParameterFilter { $ListAvailable }
        Mock -ModuleName M365Helpers Get-M365Settings { [pscustomobject]@{ msp = [pscustomobject]@{ homeTenantId = 'home.onmicrosoft.com' } } }
        Mock -ModuleName M365Helpers Invoke-RestMethod { $d = ($Uri -split '/')[3]; [pscustomobject]@{ issuer = "https://login.microsoftonline.com/$($script:Guids[$d])/v2.0" } }
    }

    It 'client A, then B, then A again: the third session really is in A (one connection at a time)' {
        $null = Assert-M365Exchange -Organization a.onmicrosoft.com
        $null = Assert-M365Exchange -Organization b.onmicrosoft.com
        $r = Assert-M365Exchange -Organization a.onmicrosoft.com
        $r.InitialDomain | Should -Be 'a.onmicrosoft.com'
        $global:FakeExo.Active | Should -Be 'a.onmicrosoft.com'
        $global:FakeExo.Connections.Count | Should -Be 1
        $global:M365ToolkitTargets['Exchange'].Label | Should -Be 'a.onmicrosoft.com'
    }
    It 'reuses the open session only when it is verified to be in the requested tenant' {
        $null = Assert-M365Exchange -Organization a.onmicrosoft.com
        $null = Assert-M365Exchange -Organization a.example
        $global:FakeExo.Connects | Should -Be 1
    }
    It 'connects to our own tenant without delegation when -Organization is our tenant' {
        $null = Assert-M365Exchange -Organization home.onmicrosoft.com
        $global:FakeExo.Connections[0].DelegatedOrganization | Should -BeNullOrEmpty
    }
    It 'stops when the new session lands in a different tenant than requested' {
        $global:FakeExo.ConnectTo = 'b.onmicrosoft.com'
        { Assert-M365Exchange -Organization a.onmicrosoft.com } | Should -Throw '*not a.onmicrosoft.com*'
    }
    It 'stops when -Organization and the Graph tenant are different clients' {
        { Assert-M365Exchange -Organization a.onmicrosoft.com -ExpectedTenantId b.onmicrosoft.com } | Should -Throw '*not belong to the same tenant*'
        $global:FakeExo.Connects | Should -Be 0
    }
    It 'requires -Organization (no blank means our tenant)' {
        (Get-Command Assert-M365Exchange).Parameters['Organization'].Attributes.Mandatory | Should -Contain $true
    }
    It 'Assert-M365SameTenant passes matching values and names the odd one out' {
        Assert-M365SameTenant -Identifier ([ordered]@{ tenantId = 'a.onmicrosoft.com'; primaryDomain = 'a.example' }) | Should -Be 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        { Assert-M365SameTenant -Identifier ([ordered]@{ tenantId = 'a.onmicrosoft.com'; onmicrosoftDomain = 'b.onmicrosoft.com' }) } | Should -Throw "*onmicrosoftDomain 'b.onmicrosoft.com'*"
    }
}
