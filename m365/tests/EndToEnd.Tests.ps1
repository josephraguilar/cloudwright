#   WHAT   Runs EVERY task script end to end against stub Microsoft cmdlets and checks the
#          three promises the toolkit makes:
#            1. A dry run (-WhatIf) changes nothing (no write cmdlet, REST write or browser).
#            2. No script can change anything except through Invoke-M365Change: with an empty
#               approved plan every attempted change is refused and no write cmdlet is reached.
#            3. No script fails on a parameter-binding mistake against toolkit code.
#          Plus a static check that no write cmdlet is called directly anywhere.
#   WHY    The unit tests call module functions with mocks; these run the real scripts, the
#          way the GUI and console do. No real tenant is ever contacted: every Microsoft
#          cmdlet is a recording stub, and login/DNS lookups are answered locally.
#   GOTCHA Scripts re-import their modules with -Force, which drops Pester mocks. So the stubs
#          are plain global functions, and the scripts run from a copy of the repo with its
#          own settings and client config.

BeforeDiscovery {
    $repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    Import-Module (Join-Path $repo 'scripts' 'powershell' 'modules' 'ToolkitHelpers' 'ToolkitHelpers.psd1') -Force
    $script:TaskCases = @(Get-M365Task | ForEach-Object { @{ Name = $_.Name; RelativePath = $_.RelativePath; IsWrite = $_.IsWrite } })
    $script:WriteCases = @($script:TaskCases | Where-Object { $_.IsWrite })
}

BeforeAll {
    $script:SourceRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:Repo = Join-Path $TestDrive 'repo'
    $null = New-Item -ItemType Directory -Path $script:Repo
    foreach ($item in 'scripts', 'config', 'templates') { Copy-Item (Join-Path $script:SourceRepo $item) $script:Repo -Recurse }
    Get-ChildItem (Join-Path $script:Repo 'config') -Recurse -Filter '*.local.json' | Remove-Item -Force

    #region Settings and one client, all values fake ---------------------------------
    $settings = Get-Content (Join-Path $script:Repo 'config' 'msp.settings.example.json') -Raw | ConvertFrom-Json
    $settings.msp.adminUpn = 'tech@msp.example'
    $settings | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:Repo 'config' 'msp.settings.local.json')
    $gdap = Get-Content (Join-Path $script:Repo 'config' 'gdap-roles.example.json') -Raw | ConvertFrom-Json
    $gdap | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:Repo 'config' 'gdap-roles.local.json')
    $client = Get-Content (Join-Path $script:Repo 'config' 'clients' 'example.client.json') -Raw | ConvertFrom-Json
    $client.tenantId = 'contoso.onmicrosoft.com'; $client.onmicrosoftDomain = 'contoso.onmicrosoft.com'; $client.primaryDomain = 'contoso.com'
    $client.domains = @('contoso.com'); $client.shortName = 'contoso'
    $script:ClientPath = Join-Path $script:Repo 'config' 'clients' 'contoso.local.json'
    $client | ConvertTo-Json -Depth 10 | Set-Content $script:ClientPath
    #endregion

    #region Fake module folders so "is the module installed?" checks pass ------------------
    $fake = Join-Path $TestDrive 'fakemodules'
    foreach ($m in 'Microsoft.Graph.Authentication', 'ExchangeOnlineManagement') {
        $d = Join-Path $fake $m '9.9.9'; $null = New-Item -ItemType Directory -Path $d -Force
        Set-Content (Join-Path $d "$m.psd1") "@{ ModuleVersion = '9.9.9'; GUID = '$([guid]::NewGuid())'; FunctionsToExport = @() }"
    }
    $script:OldModulePath = $env:PSModulePath
    $env:PSModulePath = $fake + [IO.Path]::PathSeparator + $env:PSModulePath
    $script:OldLogPath = $env:M365_TOOLKIT_LOG_PATH
    $env:M365_TOOLKIT_LOG_PATH = Join-Path $TestDrive 'logs'
    $env:HUDU_API_KEY = 'test-key'
    #endregion

    #region Stub layer -------------------------------------------------------------------
    $global:E2E = @{ Writes = [System.Collections.Generic.List[string]]::new(); Graph = $null; Exo = $null }
    $global:E2ETenants = @{ contoso = 'cccccccc-0000-0000-0000-000000000001'; examplemsp = '11111111-0000-0000-0000-000000000001' }
    function global:ConvertFrom-E2EArgs {
        # Simple functions get "-Name value" pairs in $args; turn them into a hashtable.
        param([object[]]$A)
        $h = @{}; $i = 0
        while ($i -lt $A.Count) {
            $t = $A[$i]
            if ($t -is [string] -and $t -match '^-([A-Za-z]\w*):?$') {
                $n = $Matches[1]
                if ($i + 1 -lt $A.Count -and -not ($A[$i + 1] -is [string] -and $A[$i + 1] -match '^-[A-Za-z]\w*:?$')) { $h[$n] = $A[$i + 1]; $i += 2 } else { $h[$n] = $true; $i++ }
            } else { $i++ }
        }
        $h
    }
    function global:Resolve-E2ETenant { param([string]$Name) foreach ($k in $global:E2ETenants.Keys) { if ($Name -match "(^|\.)$k\.") { return $global:E2ETenants[$k] } }; $null }
    function global:Add-E2EWrite { param([string]$Name, [hashtable]$Args2) if (-not ($Args2.ContainsKey('WhatIf') -and $Args2.WhatIf -and "$($Args2.WhatIf)" -ne 'False')) { $global:E2E.Writes.Add($Name) } }

    # Session cmdlets
    function global:Connect-MgGraph { $a = ConvertFrom-E2EArgs $args; $global:E2E.Graph = [pscustomobject]@{ TenantId = "$($a.TenantId)"; Scopes = @($a.Scopes); Account = 'tech@msp.example' } }
    function global:Get-MgContext { $global:E2E.Graph }
    function global:Disconnect-MgGraph { $global:E2E.Graph = $null }
    function global:Connect-ExchangeOnline { $a = ConvertFrom-E2EArgs $args; $global:E2E.Exo = if ($a.DelegatedOrganization) { "$($a.DelegatedOrganization)" } else { 'examplemsp.onmicrosoft.com' } }
    function global:Disconnect-ExchangeOnline { $global:E2E.Exo = $null }
    function global:Get-ConnectionInformation { if ($global:E2E.Exo) { [pscustomobject]@{ State = 'Connected'; TokenStatus = 'Active'; DelegatedOrganization = $global:E2E.Exo } } }
    function global:Get-AcceptedDomain { if (-not $global:E2E.Exo) { throw 'Not connected' }; [pscustomobject]@{ DomainName = $global:E2E.Exo; InitialDomain = $true } }

    # Network: tenant lookups and DNS answered locally; any write is recorded
    function global:Invoke-RestMethod {
        $a = ConvertFrom-E2EArgs $args
        $method = if ($a.Method) { "$($a.Method)" } else { 'Get' }
        if ($method -ne 'Get') { $global:E2E.Writes.Add("Invoke-RestMethod $method $($a.Uri)"); return [pscustomobject]@{ asset_password = [pscustomobject]@{ id = 1 } } }
        if ("$($a.Uri)" -match 'login\.microsoftonline\.com/([^/]+)/') {
            $g = Resolve-E2ETenant $Matches[1]
            if (-not $g) { throw "AADSTS90002: Tenant '$($Matches[1])' not found." }
            return [pscustomobject]@{ issuer = "https://login.microsoftonline.com/$g/v2.0" }
        }
        return [pscustomobject]@{ Status = 3 }
    }
    function global:Invoke-WebRequest { $a = ConvertFrom-E2EArgs $args; $global:E2E.Writes.Add("Invoke-WebRequest $($a.Uri)") }
    function global:Invoke-MgGraphRequest { $a = ConvertFrom-E2EArgs $args; if ("$($a.Method)" -notin '', 'GET', 'Get') { Add-E2EWrite "Invoke-MgGraphRequest $($a.Method)" $a; return [pscustomobject]@{ id = 'stub-id' } }; $null }
    function global:Start-Process { $global:E2E.Writes.Add('Start-Process (browser)') }
    function global:Read-Host { throw 'E2E: a script asked for keyboard input.' }
    function global:Start-Sleep { throw 'E2E: a script tried to wait/poll.' }

    # Every other Microsoft cmdlet the code calls: reads return nothing, writes are recorded.
    $known = @{}
    foreach ($f in Get-ChildItem (Join-Path $script:Repo 'scripts' 'powershell') -Recurse -Include '*.ps1', '*.psm1') {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        foreach ($d in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $known[$d.Name] = $true }
        foreach ($c in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $n = $c.GetCommandName()
            if ($n -and $n -match '^[A-Za-z]+-[A-Za-z0-9]+$' -and -not $known.ContainsKey($n)) { $known[$n] = $false }
        }
    }
    $script:Stubbed = @()
    foreach ($n in @($known.Keys | Where-Object { -not $known[$_] })) {
        if (Get-Command -Name $n -CommandType Function -ErrorAction SilentlyContinue) { continue }
        if (Get-Command -Name $n -CommandType Cmdlet -ErrorAction SilentlyContinue) { continue }
        $verb = ($n -split '-')[0]
        $body = if ($verb -in 'Get', 'Test', 'Find', 'Search', 'Resolve', 'Select') { '$null' } else { "`$a = ConvertFrom-E2EArgs `$args; Add-E2EWrite '$n' `$a; [pscustomobject]@{ Id = 'stub-id'; Identity = 'stub-id' }" }
        Set-Item -Path "function:global:$n" -Value ([scriptblock]::Create($body))
        $script:Stubbed += $n
    }
    #endregion

    function script:Get-E2EArgument {
        # A plausible value for each mandatory parameter, by name and type.
        param($Parameter)
        $n = $Parameter.Name
        if ($Parameter.ValidateSet.Count -gt 0) { return $Parameter.ValidateSet[0] }
        $value = switch -Regex ($n) {
            '^(TenantId|CustomerTenantId|Organization|HomeTenantId)$' { 'contoso.onmicrosoft.com'; break }
            '^Domain$' { 'contoso.onmicrosoft.com'; break }
            '^ConfigPath$' { $script:ClientPath; break }
            '^Client$' { 'contoso'; break }
            '^RelationshipId$' { 'aaaaaaaa-0000-0000-0000-000000000001'; break }
            '^HuduCompanyId$' { 1; break }
            'Path$' { Join-Path $TestDrive 'out.csv'; break }
            'Template' { Join-Path $script:Repo 'templates' 'welcome-letter.html'; break }
            '(Email|Address|Upn|UserPrincipalName|Mailbox|Identity|Member|ForwardTo|User|Alias|To|GrantAccessTo|Manager)' { 'jane@contoso.com'; break }
            '^(FirstName|GivenName)$' { 'Jane'; break }
            '^(LastName|Surname)$' { 'Doe'; break }
            default { 'Test value' }
        }
        if ($Parameter.Type -in 'Int32', 'Int64') { return 1 }
        if ($Parameter.Type -eq 'Boolean') { return $true }
        if ($Parameter.IsArray) { return @($value) }
        return $value
    }
    function script:Invoke-E2EScript {
        param([string]$RelativePath, [switch]$WhatIf)
        $global:E2E.Writes.Clear(); $global:E2E.Graph = $null; $global:E2E.Exo = $null
        $targets = Get-Variable -Name M365ToolkitTargets -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if ($targets) { $targets.Clear() }
        $path = Join-Path $script:Repo $RelativePath
        $cmd = Get-Command $path
        $params = @{}
        foreach ($p in $cmd.Parameters.Values) {
            $attr = $p.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | Select-Object -First 1
            if (-not ($attr -and $attr.Mandatory)) { continue }
            $info = [pscustomobject]@{ Name = $p.Name; Type = $p.ParameterType.Name; IsArray = $p.ParameterType.IsArray
                ValidateSet = @($p.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object { $_.ValidValues }) }
            $params[$p.Name] = Get-E2EArgument $info
        }
        if ($cmd.Parameters.ContainsKey('NoWait')) { $params.NoWait = $true }
        if ($cmd.Parameters.ContainsKey('NoBrowser')) { $params.NoBrowser = $true }
        if ($WhatIf) { $params.WhatIf = $true }
        $failure = $null
        Push-Location $script:Repo
        try { $null = & $path @params 6>$null 3>$null *>$null } catch { $failure = $_ } finally { Pop-Location }
        [pscustomobject]@{ Writes = @($global:E2E.Writes); Failure = $failure }
    }
    function script:Test-BindingFailure {
        param($ErrorRecord)
        if (-not $ErrorRecord) { return $false }
        "$($ErrorRecord.FullyQualifiedErrorId)" -match 'NamedParameterNotFound|PositionalParameterNotFound|ParameterArgumentTransformationError|MissingArgument|AmbiguousParameter|ParameterBindingFailed|MissingMandatoryParameter'
    }
    Import-Module (Join-Path $script:Repo 'scripts' 'powershell' 'modules' 'M365Helpers' 'M365Helpers.psd1') -Force
}

AfterAll {
    #   WHY    The scripts imported their modules from the temporary copy. Unload them, or the
    #          next test file sees two modules with the same name.
    Get-Module | Where-Object { $_.ModuleBase -and $_.ModuleBase.StartsWith($script:Repo, [StringComparison]::OrdinalIgnoreCase) } | Remove-Module -Force -ErrorAction SilentlyContinue
    foreach ($n in @($script:Stubbed) + @('ConvertFrom-E2EArgs', 'Resolve-E2ETenant', 'Add-E2EWrite', 'Connect-MgGraph', 'Get-MgContext', 'Disconnect-MgGraph', 'Connect-ExchangeOnline',
            'Disconnect-ExchangeOnline', 'Get-ConnectionInformation', 'Get-AcceptedDomain', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Invoke-MgGraphRequest', 'Start-Process', 'Read-Host', 'Start-Sleep')) {
        Remove-Item "Function:\$n" -ErrorAction SilentlyContinue
    }
    $env:PSModulePath = $script:OldModulePath
    $env:M365_TOOLKIT_LOG_PATH = $script:OldLogPath
    Remove-Item env:HUDU_API_KEY -ErrorAction SilentlyContinue
}

Describe 'Dry runs change nothing' {
    It '<Name> -WhatIf makes no change and opens no browser' -ForEach $WriteCases {
        Start-M365ChangeRecording
        $r = Invoke-E2EScript -RelativePath $RelativePath -WhatIf
        $records = Stop-M365ChangeRecording
        $r.Writes | Should -BeNullOrEmpty -Because 'a dry run must not change anything'
        @($records | Where-Object Status -in 'Done', 'Failed') | Should -BeNullOrEmpty
        Test-BindingFailure $r.Failure | Should -BeFalse -Because "$($r.Failure)"
    }
}

Describe 'Nothing changes outside the reviewed plan' {
    It '<Name> with an empty approved plan reaches no write cmdlet' -ForEach $TaskCases {
        Start-M365ChangeRecording -ApprovedPlan @()
        $r = Invoke-E2EScript -RelativePath $RelativePath
        $records = Stop-M365ChangeRecording
        $r.Writes | Should -BeNullOrEmpty -Because 'every change must go through Invoke-M365Change, which refuses it here'
        @($records | Where-Object Status -eq 'Done') | Should -BeNullOrEmpty
        Test-BindingFailure $r.Failure | Should -BeFalse -Because "$($r.Failure)"
    }
}

Describe 'No direct write calls' {
    It 'no script or module calls a tenant-write cmdlet except through Invoke-M365Change' {
        $write = '^(New|Set|Update|Add|Enable|Disable|Remove|Revoke|Send|Grant|Clear|Reset|Restore)-(Mg[A-Za-z]+|Mailbox[A-Za-z]*|MailContact|MailUser|DistributionGroup[A-Za-z]*|InboxRule|DkimSigningConfig|TransportConfig|HostedOutboundSpamFilterPolicy|ExternalInOutlook|OrganizationConfig|AdminAuditLogConfig|CASMailbox|RecipientPermission|MailboxFolder[A-Za-z]*|AuthenticationPolicy|UnifiedGroup[A-Za-z]*)$'
        $offenders = foreach ($f in Get-ChildItem (Join-Path $script:SourceRepo 'scripts' 'powershell') -Recurse -Include '*.ps1', '*.psm1') {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            foreach ($c in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $n = $c.GetCommandName()
                $direct = ($n -and $n -match $write) -or
                    ($n -in 'Invoke-MgGraphRequest', 'Invoke-RestMethod', 'Invoke-WebRequest' -and $c.Extent.Text -match '-Method\s+[''"]?(Post|Patch|Put|Delete)')
                if (-not $direct) { continue }
                $fn = $c.Parent; while ($fn -and -not ($fn -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $fn = $fn.Parent }
                if ($fn -and $fn.Name -eq 'Invoke-M365HuduRequest') { continue }
                "$($f.Name):$($c.Extent.StartLineNumber) $n"
            }
        }
        @($offenders) | Should -BeNullOrEmpty
    }
}
