# Legacy domain behavior runs only against the fake APIs in this test file.
# Mock the release policy here so these tests still exercise plan matching and
# mutation semantics. Safety.Tests.ps1 and EndToEnd.Tests.ps1 use the real policy.
BeforeAll {
    $script:RepoRoot = Join-Path $PSScriptRoot '..'
    $modules = Join-Path $script:RepoRoot 'scripts' 'powershell' 'modules'
    Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
    $script:ManifestPath = Join-Path $modules 'GdapHelpers' 'GdapHelpers.psd1'
    Import-Module $script:ManifestPath -Force
    $env:M365_TOOLKIT_LOG_PATH = Join-Path $TestDrive 'logs'

    $script:HomeGuid = '11111111-1111-1111-1111-111111111111'
    $script:Tid = 'cccccccc-0000-0000-0000-000000000001'
    $script:AdminAgents = 'aaaaaaaa-0000-0000-0000-000000000003'

    # Fake Graph. Writes are GLOBAL functions: Invoke-M365Change resolves the command it runs
    # itself, so Pester mocks (aliases) never see writes. Every write lands in $global:GdapFake.Writes.
    # The same source is loaded into the hostless runspaces of the end-to-end tests.
    $script:StubSource = @'
function global:Reset-GdapFake {
    param([string]$HomeGuid, [string]$CustomerGuid)
    $global:GdapFake = @{
        HomeGuid = $HomeGuid; CustomerGuid = $CustomerGuid; Relationships = @{}; Assignments = [System.Collections.Generic.List[object]]::new()
        Groups = @{}; Tenants = @{}; Customers = @(); Writes = [System.Collections.Generic.List[object]]::new(); LockThrows = $false; CreateThrows = $null; NoEtag = $false; Attempts = 0
    }
    $global:GdapFake.Tenants[$CustomerGuid] = [pscustomobject]@{ tenantId = $CustomerGuid; displayName = 'Contoso Ltd'; defaultDomainName = 'contoso.onmicrosoft.com'; federationBrandName = $null }
}
function global:New-FakeRel {
    param($Id, $Status, $RoleIds, $Name = "rel-$Id", $TenantId = $global:GdapFake.CustomerGuid, $CustomerName = 'Contoso Ltd', $Days = 700)
    [pscustomobject]@{ Id = $Id; DisplayName = $Name; Status = $Status; Duration = 'P730D'; AutoExtendDuration = 'PT0S'
        Customer = [pscustomobject]@{ TenantId = $TenantId; DisplayName = $CustomerName }
        AccessDetails = [pscustomobject]@{ UnifiedRoles = @($RoleIds | ForEach-Object { [pscustomobject]@{ RoleDefinitionId = $_ } }) }
        CreatedDateTime = (Get-Date).AddDays(-1); ActivatedDateTime = $null; EndDateTime = $(if ($Status -in 'active', 'expiring') { (Get-Date).AddDays($Days) } else { $null }) }
}
function global:New-FakeAsg {
    param($Id, $RelationshipId, $GroupId, $RoleIds, $Status = 'active')
    [pscustomobject]@{ Id = $Id; RelationshipId = $RelationshipId; Status = $Status; CreatedDateTime = (Get-Date)
        AccessContainer = [pscustomobject]@{ AccessContainerId = $GroupId; AccessContainerType = 'securityGroup' }
        AccessDetails = [pscustomobject]@{ UnifiedRoles = @($RoleIds | ForEach-Object { [pscustomobject]@{ RoleDefinitionId = $_ } }) } }
}
function global:Get-MgContext { [CmdletBinding()] param() [pscustomobject]@{ TenantId = $global:GdapFake.HomeGuid; Account = 'tech@msp.example'; Scopes = @('DelegatedAdminRelationship.ReadWrite.All', 'DelegatedAdminRelationship.Read.All', 'Group.Read.All', 'RoleManagement.Read.Directory', 'CrossTenantInformation.ReadBasic.All') } }
function global:Connect-MgGraph { [CmdletBinding()] param($TenantId, $Scopes, [switch]$NoWelcome) throw "unexpected Connect-MgGraph $TenantId $Scopes $NoWelcome" }
function global:Get-MgTenantRelationshipDelegatedAdminCustomer { [CmdletBinding()] param([switch]$All) $null = $All; @($global:GdapFake.Customers) }
function global:Get-MgTenantRelationshipDelegatedAdminRelationship {
    [CmdletBinding()] param($DelegatedAdminRelationshipId, [switch]$All)
    $null = $All
    if ($DelegatedAdminRelationshipId) {
        $r = $global:GdapFake.Relationships[$DelegatedAdminRelationshipId]
        if (-not $r) { throw 'Response status code does not indicate success: NotFound (Not Found).' }
        return $r
    }
    @($global:GdapFake.Relationships.Values | Sort-Object Id)
}
function global:Get-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment { [CmdletBinding()] param($DelegatedAdminRelationshipId, [switch]$All) $null = $All; @($global:GdapFake.Assignments | Where-Object { $_.RelationshipId -eq $DelegatedAdminRelationshipId }) }
function global:Get-MgGroup { [CmdletBinding()] param($GroupId) $g = $global:GdapFake.Groups[$GroupId]; if (-not $g) { throw "Resource '$GroupId' does not exist." }; $g }
function global:Get-MgRoleManagementDirectoryRoleDefinition { [CmdletBinding()] param([switch]$All) $null = $All; $global:GdapFake.RoleDefinitionReads++; 1..60 | ForEach-Object { [pscustomobject]@{ DisplayName = "Extra Role $_ Administrator"; Id = [guid]::NewGuid().ToString(); IsBuiltIn = $true } } }
function global:New-MgTenantRelationshipDelegatedAdminRelationship {
    [CmdletBinding()] param($BodyParameter)
    $global:GdapFake.Attempts++
    if ($global:GdapFake.CreateThrows) { throw $global:GdapFake.CreateThrows }
    $global:GdapFake.Writes.Add([pscustomobject]@{ Command = 'CreateRelationship'; Target = $null; Body = $BodyParameter; Headers = $null })
    $id = "new-$($global:GdapFake.Writes.Count)"
    $rel = New-FakeRel -Id $id -Status 'created' -RoleIds @($BodyParameter.accessDetails.unifiedRoles | ForEach-Object { $_.roleDefinitionId }) -Name $BodyParameter.displayName -TenantId $BodyParameter.customer.tenantId
    $global:GdapFake.Relationships[$id] = $rel
    $rel
}
function global:New-MgTenantRelationshipDelegatedAdminRelationshipRequest {
    [CmdletBinding()] param($DelegatedAdminRelationshipId, $BodyParameter)
    $global:GdapFake.Writes.Add([pscustomobject]@{ Command = 'Lock'; Target = $DelegatedAdminRelationshipId; Body = $BodyParameter; Headers = $null })
    if ($global:GdapFake.LockThrows) { throw 'Response status code does not indicate success: BadRequest (Bad Request).' }
    $global:GdapFake.Relationships[$DelegatedAdminRelationshipId].Status = 'approvalPending'
    [pscustomobject]@{ Id = 'req-1'; Action = $BodyParameter.action; Status = 'created' }
}
function global:New-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment {
    [CmdletBinding()] param($DelegatedAdminRelationshipId, $BodyParameter)
    $global:GdapFake.Writes.Add([pscustomobject]@{ Command = 'CreateAssignment'; Target = $DelegatedAdminRelationshipId; Body = $BodyParameter; Headers = $null })
    [pscustomobject]@{ Id = 'asg-new'; Status = 'pending' }
}
function global:Invoke-MgGraphRequest {
    [CmdletBinding()] param($Method, $Uri, $Headers, $Body, $OutputType)
    if ($Method -ne 'GET') { $global:GdapFake.Writes.Add([pscustomobject]@{ Command = "$Method"; Target = $Uri; Body = $Body; Headers = $Headers }); return }
    if ($OutputType -ne 'PSObject') { throw "expected -OutputType PSObject, got $OutputType" }
    if ($Uri -match "findTenantInformationByTenantId\(tenantId='([^']+)'\)") {
        $t = $global:GdapFake.Tenants[$Matches[1]]
        if (-not $t) { throw 'Response status code does not indicate success: NotFound (Not Found).' }
        return $t
    }
    if ($Uri -match 'accessAssignments/([^/]+)$') {
        $id = $Matches[1]
        $a = $global:GdapFake.Assignments | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        $o = [ordered]@{ id = $a.Id; status = "$($a.Status)"; accessDetails = [pscustomobject]@{ unifiedRoles = @($a.AccessDetails.UnifiedRoles | ForEach-Object { [pscustomobject]@{ roleDefinitionId = $_.RoleDefinitionId } }) } }
        if (-not $global:GdapFake.NoEtag) { $o['@odata.etag'] = 'W/"etag-1"' }
        return [pscustomobject]$o
    }
    throw "unexpected GET $Uri"
}
'@
    . ([scriptblock]::Create($script:StubSource))

    function script:Reset-Fake {
        Reset-GdapFake -HomeGuid $script:HomeGuid -CustomerGuid $script:Tid
        $script:Fake = Get-Variable -Name GdapFake -Scope Global -ValueOnly
        $script:Fake.Groups['aaaaaaaa-0000-0000-0000-000000000001'] = [pscustomobject]@{ Id = 'aaaaaaaa-0000-0000-0000-000000000001'; DisplayName = 'Tier 1'; SecurityEnabled = $true }
        $script:Fake.Groups['aaaaaaaa-0000-0000-0000-000000000002'] = [pscustomobject]@{ Id = 'aaaaaaaa-0000-0000-0000-000000000002'; DisplayName = 'Tier 2'; SecurityEnabled = $true }
        $script:Fake.Groups[$script:AdminAgents] = [pscustomobject]@{ Id = $script:AdminAgents; DisplayName = 'Admin Agents'; SecurityEnabled = $true }
        $script:Fake.RoleDefinitionReads = 0
    }
    Reset-Fake

    # Explicit legacy fixture keeps broad-role algorithm tests separate from the
    # shipped read-only default and from real group/tenant identifiers.
    $legacy = Get-Content (Join-Path $script:RepoRoot 'config' 'gdap-roles.example.json') -Raw | ConvertFrom-Json
    $legacy.roles = 'allAdmin'
    $legacy.name = 'MSP standard GDAP'
    $legacy.displayNamePattern = 'MSP GDAP - {customer}'
    $legacy.groups[0].name = 'Admin Agents'
    $legacy.groups[0].id = $script:AdminAgents
    $script:ExamplePath = Join-Path $TestDrive 'legacy-gdap.json'
    $legacy | ConvertTo-Json -Depth 6 | Set-Content $script:ExamplePath

    # A two-tier fixture under TestDrive so the matrix tests cover partial role coverage per group.
    $t = Get-Content (Join-Path $script:RepoRoot 'config' 'gdap-roles.example.json') -Raw | ConvertFrom-Json
    $t.name = 'MSP standard GDAP'
    $t.displayNamePattern = 'MSP GDAP - {customer}'
    $t.roles = @('Global Reader', 'Helpdesk Administrator', 'Service Support Administrator', 'User Administrator', 'License Administrator', 'Groups Administrator',
        'Exchange Administrator', 'SharePoint Administrator', 'Teams Administrator', 'Intune Administrator', 'Security Administrator', 'Conditional Access Administrator',
        'Authentication Administrator', 'Privileged Authentication Administrator', 'Cloud Application Administrator', 'Application Administrator', 'Domain Name Administrator',
        'Privileged Role Administrator', 'Reports Reader', 'Directory Readers')
    $t.autoExtendDuration = 'P180D'
    $t.groups = @(
        [pscustomobject]@{ name = 'Tier 1'; id = 'aaaaaaaa-0000-0000-0000-000000000001'; roles = @('Global Reader', 'Helpdesk Administrator', 'Service Support Administrator', 'Reports Reader', 'Directory Readers') }
        [pscustomobject]@{ name = 'Tier 2'; id = 'aaaaaaaa-0000-0000-0000-000000000002'; roles = @($t.roles) }
    )
    $script:TemplatePath = Join-Path $TestDrive 'gdap-roles.json'
    $t | ConvertTo-Json -Depth 6 | Set-Content $script:TemplatePath
    $script:Template = Get-GdapTemplate -Path $script:TemplatePath
    $script:Example = Get-GdapTemplate -Path $script:ExamplePath
    $script:TenantInfo = [pscustomobject]@{ TenantId = $script:Tid; DisplayName = 'Contoso Ltd'; DefaultDomainName = 'contoso.onmicrosoft.com' }

    $script:GlobalAdmin = Get-GdapRoleId 'Global Administrator'
    $script:GlobalReader = Get-GdapRoleId 'Global Reader'
    $script:Helpdesk = Get-GdapRoleId 'Helpdesk Administrator'
    $script:Exchange = Get-GdapRoleId 'Exchange Administrator'

    function script:New-Rel {
        param($Id, $Status, $RoleIds, $Assignments = @(), $Days = 400, $AutoExtend = 'P180D', $Name = "rel-$Id")
        [pscustomobject]@{
            Id = $Id; DisplayName = $Name; Customer = 'Contoso'; CustomerTenantId = 'cccccccc-0000-0000-0000-000000000001'
            Status = $Status; RoleIds = @($RoleIds); Roles = @($RoleIds | Get-GdapRoleName); Duration = 'P730D'; AutoExtend = $AutoExtend
            Created = (Get-Date).AddDays(-10); Activated = $null; EndDateTime = (Get-Date).AddDays($Days); DaysToExpiry = $Days
            ApprovalUrl = if ($Status -eq 'approvalPending') { Get-GdapApprovalUrl -RelationshipId $Id } else { $null }
            Assignments = @($Assignments)
        }
    }
    function script:New-Asg {
        param($GroupId, $RoleIds, $Status = 'active')
        [pscustomobject]@{ Id = "asg-$GroupId"; RelationshipId = 'x'; GroupId = $GroupId; ContainerType = 'securityGroup'; Status = $Status; RoleIds = @($RoleIds); Roles = @(); Created = (Get-Date) }
    }
}

AfterAll {
    Remove-Item env:M365_TOOLKIT_LOG_PATH -ErrorAction SilentlyContinue
    foreach ($f in 'Reset-GdapFake', 'New-FakeRel', 'New-FakeAsg', 'Get-MgContext', 'Connect-MgGraph', 'Get-MgTenantRelationshipDelegatedAdminCustomer', 'Get-MgTenantRelationshipDelegatedAdminRelationship',
        'Get-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment', 'Get-MgGroup', 'Get-MgRoleManagementDirectoryRoleDefinition', 'New-MgTenantRelationshipDelegatedAdminRelationship',
        'New-MgTenantRelationshipDelegatedAdminRelationshipRequest', 'New-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment', 'Invoke-MgGraphRequest') {
        Remove-Item "Function:\$f" -ErrorAction SilentlyContinue
    }
}

Describe 'GdapHelpers module' {

    BeforeEach {
        Mock Test-M365ReadOnly -ModuleName M365Helpers { $false }
        Mock Test-M365ReadOnly -ModuleName GdapHelpers { $false }
        Reset-Fake
        Set-M365ChangeTarget -Service Graph -Label 'examplemsp.onmicrosoft.com' -TenantId $script:HomeGuid
    }

    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }
    It 'exports the expected functions' {
        $expected = 'Get-GdapRoleId', 'Get-GdapRoleName', 'Get-GdapAdminRoleName', 'Get-GdapRoleList', 'Format-GdapRoleList', 'Get-GdapTemplate', 'Get-GdapApprovalUrl', 'Get-GdapRequestSummary',
        'Open-GdapApprovalPage', 'Test-GdapDuration', 'Get-GdapTenantInfo', 'Get-GdapCustomer', 'Get-GdapAccessAssignment', 'Get-GdapRelationship', 'Compare-GdapRelationship', 'Test-GdapCompliance',
        'New-GdapRequest', 'Lock-GdapRelationship', 'Wait-GdapApproval', 'Set-GdapAccessAssignment', 'Get-GdapState', 'Save-GdapState'
        $actual = (Get-Command -Module GdapHelpers).Name
        foreach ($f in $expected) { $actual | Should -Contain $f }
    }

    Context 'Roles' {
        It 'resolves well-known role names to template ids' {
            Get-GdapRoleId 'Global Administrator' | Should -Be '62e90394-69f5-4237-9190-012177145e10'
            Get-GdapRoleId 'exchange administrator' | Should -Be '29232cdf-9323-42fd-ade2-1d097af3e4de'
        }
        It 'passes GUIDs through lower-cased and round-trips names' {
            Get-GdapRoleId '62E90394-69F5-4237-9190-012177145E10' | Should -Be '62e90394-69f5-4237-9190-012177145e10'
            Get-GdapRoleName '62e90394-69f5-4237-9190-012177145e10' | Should -Be 'Global Administrator'
        }
        It 'throws on an unknown role name' {
            { Get-GdapRoleId 'Mail Czar' } | Should -Throw '*Unknown Entra role*'
        }
        It 'H12: allAdmin is the same fixed 27-role table whether or not a Graph session exists, and never reads the live list' {
            # Get-MgContext (stub) answers with a session, and the live role list would add 60 roles.
            Get-MgContext | Should -Not -BeNullOrEmpty
            $names = Get-GdapAdminRoleName
            $names.Count | Should -Be 27
            $names | Should -Contain 'Global Administrator'
            $names | Should -Contain 'Privileged Role Administrator'
            $names | Should -Contain 'Privileged Authentication Administrator'
            (Get-GdapTemplate -Path $script:ExamplePath).RoleIds.Count | Should -Be 27
            $script:Fake.RoleDefinitionReads | Should -Be 0
        }
        It 'lists Global Administrator, Privileged Role and Privileged Authentication Administrator first and flags them' {
            $rows = Get-GdapRoleList -RoleIds $script:Example.RoleIds
            @($rows | Select-Object -First 3 | ForEach-Object { $_.Name }) | Should -Be @('Global Administrator', 'Privileged Role Administrator', 'Privileged Authentication Administrator')
            @($rows | Where-Object { $_.Privileged }).Count | Should -Be 3
            $text = Format-GdapRoleList -RoleIds $script:Example.RoleIds
            $text | Should -BeLike '27 roles - HIGHLY PRIVILEGED: Global Administrator, Privileged Role Administrator, Privileged Authentication Administrator; also: *'
            foreach ($n in $script:Example.RoleNames) { $text | Should -BeLike "*$n*" }
            Format-GdapRoleList -RoleIds @($script:GlobalReader) | Should -Be '1 role: Global Reader'
        }
    }

    Context 'Durations and URL' {
        It 'accepts P1D..P730D and rejects outside' {
            Test-GdapDuration -Duration P730D | Should -BeTrue
            Test-GdapDuration -Duration P1D | Should -BeTrue
            Test-GdapDuration -Duration P731D | Should -BeFalse
            Test-GdapDuration -Duration P0D | Should -BeFalse
            Test-GdapDuration -Duration '2 years' | Should -BeFalse
        }
        It 'accepts only PT0S or P180D for auto-extend' {
            Test-GdapDuration -Duration PT0S -AutoExtend | Should -BeTrue
            Test-GdapDuration -Duration P180D -AutoExtend | Should -BeTrue
            Test-GdapDuration -Duration P90D -AutoExtend | Should -BeFalse
        }
        It 'builds the documented approval link' {
            Get-GdapApprovalUrl -RelationshipId 'abc-123' | Should -Be 'https://admin.microsoft.com/AdminPortal/Home#/partners/invitation/granularAdminRelationships/abc-123'
        }
    }

    Context 'Open-GdapApprovalPage' {
        It 'launches nothing under -WhatIf and reports the chosen browser' {
            $r = Open-GdapApprovalPage -Url 'https://admin.microsoft.com/x' -WhatIf
            $r.Launched | Should -BeFalse
            $r.Browser | Should -BeIn 'Edge', 'Chrome', 'Default'
        }
        It 'uses the default browser when -NoPrivate' {
            (Open-GdapApprovalPage -Url 'https://admin.microsoft.com/x' -NoPrivate -WhatIf).Private | Should -BeFalse
        }
    }

    Context 'Get-GdapTemplate' {
        It 'ships a read-only role set and prompts for a real group id' {
            $path = Join-Path $script:RepoRoot 'config' 'gdap-roles.example.json'
            $default = Get-Content $path -Raw | ConvertFrom-Json
            @($default.roles) | Should -Be @('Global Reader')
            @(Get-M365ConfigPlaceholder -Path $path) | Should -Contain 'groups[0].id'
            { Get-GdapTemplate -Path $path } | Should -Throw '*placeholder*'
            $script:HomeGuid | Should -Not -Be $script:AdminAgents
        }

        It 'loads the explicit legacy fixture for broad-role algorithm coverage' {
            $ex = $script:Example
            $ex.RoleNames | Should -Contain 'Global Administrator'
            $ex.RoleNames | Should -Contain 'Exchange Administrator'
            $ex.RoleNames | Should -Contain 'Global Reader'
            $ex.RoleNames | Should -Not -Contain 'Partner Tier1 Support'
            $ex.RoleIds.Count | Should -Be 27
            $ex.RoleIds.Count | Should -Be (Get-GdapAdminRoleName).Count
            $ex.autoExtendDuration | Should -Be 'PT0S'
            $ex.Groups.Count | Should -Be 1
            $ex.Groups[0].Name | Should -Be 'Admin Agents'
            $ex.Groups[0].RoleIds.Count | Should -Be $ex.RoleIds.Count
        }
        It 'refuses allAdmin with auto-extend (Global Administrator rule)' {
            $bad = Get-Content $script:ExamplePath -Raw | ConvertFrom-Json
            $bad.autoExtendDuration = 'P180D'
            $path = Join-Path $TestDrive 'ga-ext.json'; $bad | ConvertTo-Json -Depth 6 | Set-Content $path
            { Get-GdapTemplate -Path $path } | Should -Throw '*cannot auto-extend*'
        }
        It 'rejects a placeholder group id' {
            $bad = Get-Content $script:TemplatePath -Raw | ConvertFrom-Json
            $bad.groups[0].id = '<fill-me>'
            $path = Join-Path $TestDrive 'ph.json'; $bad | ConvertTo-Json -Depth 6 | Set-Content $path
            { Get-GdapTemplate -Path $path } | Should -Throw '*placeholder*'
        }
        It 'resolves role ids and group role ids' {
            $script:Template.RoleIds.Count | Should -Be 20
            $script:Template.Groups.Count | Should -Be 2
            $script:Template.Groups[0].RoleIds | Should -Contain $script:GlobalReader
            $script:Template.Groups[0].RoleIds | Should -Not -Contain $script:Exchange
        }
        It 'refuses auto-extend when Global Administrator is included' {
            $t = Get-Content $script:TemplatePath -Raw | ConvertFrom-Json
            $t.roles += 'Global Administrator'
            $path = Join-Path $TestDrive 'ga.json'; $t | ConvertTo-Json -Depth 6 | Set-Content $path
            { Get-GdapTemplate -Path $path } | Should -Throw '*cannot auto-extend*'
            $t.autoExtendDuration = 'PT0S'
            $t | ConvertTo-Json -Depth 6 | Set-Content $path
            { Get-GdapTemplate -Path $path } | Should -Not -Throw
        }
        It 'refuses a group that asks for roles outside the template' {
            $t = Get-Content $script:TemplatePath -Raw | ConvertFrom-Json
            $t.groups[0].roles += 'Billing Administrator'
            $path = Join-Path $TestDrive 'outside.json'; $t | ConvertTo-Json -Depth 6 | Set-Content $path
            { Get-GdapTemplate -Path $path } | Should -Throw '*not in the template*'
        }
    }

    Context 'Request summary and relationship name (G-M4, G-M6)' {
        It 'G-M4: appends the date and stays within 50 characters, shortening the customer part, never the date' {
            $s = Get-GdapRequestSummary -CustomerTenantId $script:Tid -CustomerName ('Very Long Customer Name ' * 4) -Template $script:Example -TenantInfo $script:TenantInfo -Date ([datetime]'2026-10-19')
            $s.DisplayName.Length | Should -BeLessOrEqual 50
            $s.DisplayName | Should -Match '^MSP GDAP - Very Long Customer.* 2026-10-19$'
            (Get-GdapRequestSummary -CustomerTenantId $script:Tid -CustomerName 'Contoso' -Template $script:Example -TenantInfo $script:TenantInfo -Date ([datetime]'2026-10-19')).DisplayName | Should -Be 'MSP GDAP - Contoso 2026-10-19'
        }
        It 'G-M4: strips characters Partner Center rejects and refuses an invalid explicit name' {
            (Get-GdapRequestSummary -CustomerTenantId $script:Tid -CustomerName "O$([char]0x2019)Brien & Sons" -Template $script:Example -TenantInfo $script:TenantInfo -Date ([datetime]'2026-10-19')).DisplayName | Should -Be 'MSP GDAP - OBrien Sons 2026-10-19'
            { Get-GdapRequestSummary -CustomerTenantId $script:Tid -CustomerName 'X' -Template $script:Example -TenantInfo $script:TenantInfo -DisplayName ('Y' * 51) } | Should -Throw '*at most 50*'
        }
        It 'G-M6: the text names the tenant, its domain, the duration, auto-extend and every role, highly privileged first' {
            $s = Get-GdapRequestSummary -CustomerTenantId $script:Tid -CustomerName 'Contoso Dental' -Template $script:Example -TenantInfo $script:TenantInfo
            $s.Text | Should -BeLike "*customer 'Contoso Dental' = tenant 'Contoso Ltd' (contoso.onmicrosoft.com, tenant $($script:Tid))*"
            $s.Text | Should -BeLike '*730 days (P730D), no auto-extend, 27 roles - HIGHLY PRIVILEGED: Global Administrator, Privileged Role Administrator, Privileged Authentication Administrator; also: *'
            $s.PrivilegedRoleNames | Should -Be @('Global Administrator', 'Privileged Role Administrator', 'Privileged Authentication Administrator')
        }
        It 'refuses tenant information that belongs to another tenant' {
            $other = [pscustomobject]@{ TenantId = 'dddddddd-0000-0000-0000-000000000001'; DisplayName = 'Fabrikam'; DefaultDomainName = 'fabrikam.onmicrosoft.com' }
            { Get-GdapRequestSummary -CustomerTenantId $script:Tid -CustomerName 'Contoso' -Template $script:Example -TenantInfo $other } | Should -Throw '*not cccccccc*'
        }
    }

    Context 'Get-GdapTenantInfo (G-M6)' {
        It 'returns the tenant display name and default domain' {
            $i = Get-GdapTenantInfo -TenantId $script:Tid.ToUpperInvariant()
            $i.TenantId | Should -Be $script:Tid
            $i.DisplayName | Should -Be 'Contoso Ltd'
            $i.DefaultDomainName | Should -Be 'contoso.onmicrosoft.com'
        }
        It 'throws (never guesses) when the lookup fails, naming the scope it needs' {
            { Get-GdapTenantInfo -TenantId 'dddddddd-0000-0000-0000-000000000009' } | Should -Throw '*CrossTenantInformation.ReadBasic.All*'
        }
        It 'throws when Graph answers for a different tenant' {
            $script:Fake.Tenants[$script:Tid] = [pscustomobject]@{ tenantId = 'dddddddd-0000-0000-0000-000000000001'; displayName = 'Fabrikam'; defaultDomainName = 'fabrikam.onmicrosoft.com' }
            { Get-GdapTenantInfo -TenantId $script:Tid } | Should -Throw '*answered for tenant*'
        }
    }

    Context 'Compare-GdapRelationship (idempotency matrix)' {
        It 'NoRelationship -> CreateRequest' {
            $r = Compare-GdapRelationship -Relationships @() -Template $script:Template
            $r.State | Should -Be 'NoRelationship'
            $r.ProposedActions.Action | Should -Contain 'CreateRequest'
        }
        It 'PendingApproval -> reuse the existing link, no create' {
            $pending = New-Rel -Id 'p1' -Status 'approvalPending' -RoleIds $script:Template.RoleIds
            $r = Compare-GdapRelationship -Relationships @($pending) -Template $script:Template
            $r.State | Should -Be 'PendingApproval'
            $r.ProposedActions.Action | Should -Be @('AwaitApproval')
            $r.ProposedActions[0].Detail | Should -Match 'granularAdminRelationships/p1'
        }
        It "G-M3: a 'created' (never locked) request says so instead of offering a link the customer cannot use" {
            $r = Compare-GdapRelationship -Relationships @(New-Rel -Id 'c1' -Status 'created' -RoleIds $script:Template.RoleIds) -Template $script:Template
            $r.State | Should -Be 'PendingApproval'
            $r.ProposedActions[0].Detail | Should -Match 'never locked'
            $r.ProposedActions[0].Detail | Should -Not -Match 'granularAdminRelationships'
        }
        It 'Active with all roles and all group assignments -> Compliant, no actions' {
            $asg = @(
                New-Asg -GroupId $script:Template.Groups[0].Id -RoleIds $script:Template.Groups[0].RoleIds
                New-Asg -GroupId $script:Template.Groups[1].Id -RoleIds $script:Template.Groups[1].RoleIds
            )
            $r = Compare-GdapRelationship -Relationships @(New-Rel -Id 'a1' -Status 'active' -RoleIds $script:Template.RoleIds -Assignments $asg) -Template $script:Template
            $r.State | Should -Be 'Compliant'
            $r.Compliant | Should -BeTrue
            $r.ProposedActions.Count | Should -Be 0
        }
        It 'Active with roles but one group missing -> MissingAssignments for that group only' {
            $asg = @(New-Asg -GroupId $script:Template.Groups[0].Id -RoleIds $script:Template.Groups[0].RoleIds)
            $r = Compare-GdapRelationship -Relationships @(New-Rel -Id 'a1' -Status 'active' -RoleIds $script:Template.RoleIds -Assignments $asg) -Template $script:Template
            $r.State | Should -Be 'MissingAssignments'
            $r.MissingAssignments.Count | Should -Be 1
            $r.MissingAssignments[0].GroupId | Should -Be $script:Template.Groups[1].Id
            $r.MissingAssignments[0].RelationshipId | Should -Be 'a1'
        }
        It 'Partial assignment -> only the missing roles are proposed' {
            $partial = @($script:Template.Groups[0].RoleIds | Select-Object -First 2)
            $asg = @(New-Asg -GroupId $script:Template.Groups[0].Id -RoleIds $partial; New-Asg -GroupId $script:Template.Groups[1].Id -RoleIds $script:Template.Groups[1].RoleIds)
            $r = Compare-GdapRelationship -Relationships @(New-Rel -Id 'a1' -Status 'active' -RoleIds $script:Template.RoleIds -Assignments $asg) -Template $script:Template
            $r.State | Should -Be 'MissingAssignments'
            $r.MissingAssignments[0].RoleIds.Count | Should -Be ($script:Template.Groups[0].RoleIds.Count - 2)
        }
        It 'Active but missing template roles -> MissingRoles, supplementary request' {
            $few = @($script:GlobalReader, $script:Helpdesk)
            $r = Compare-GdapRelationship -Relationships @(New-Rel -Id 'a1' -Status 'active' -RoleIds $few) -Template $script:Template
            $r.State | Should -Be 'MissingRoles'
            $r.MissingRoleIds.Count | Should -Be ($script:Template.RoleIds.Count - 2)
            $r.ProposedActions.Action | Should -Contain 'CreateSupplementary'
        }
        It 'H13: missing roles already in a pending request count as covered-pending: AwaitApproval, never another request' {
            $few = @($script:GlobalReader, $script:Helpdesk)
            $rest = @($script:Template.RoleIds | Where-Object { $few -notcontains $_ })
            $r = Compare-GdapRelationship -Relationships @((New-Rel -Id 'a1' -Status 'active' -RoleIds $few), (New-Rel -Id 'p1' -Status 'approvalPending' -RoleIds $rest)) -Template $script:Template
            $r.State | Should -Be 'PendingApproval'
            $r.ProposedActions.Action | Should -Not -Contain 'CreateSupplementary'
            $r.ProposedActions.Action | Should -Contain 'AwaitApproval'
            $r.MissingRoleIds.Count | Should -Be 0
            $r.PendingRoleIds.Count | Should -Be $rest.Count
        }
        It 'H13: with a request in flight covering only part, still waits (one request at a time) and names what will remain' {
            $few = @($script:GlobalReader, $script:Helpdesk)
            $r = Compare-GdapRelationship -Relationships @((New-Rel -Id 'a1' -Status 'active' -RoleIds $few), (New-Rel -Id 'p1' -Status 'approvalPending' -RoleIds @($script:Exchange))) -Template $script:Template
            $r.State | Should -Be 'PendingApproval'
            $r.ProposedActions.Action | Should -Not -Contain 'CreateSupplementary'
            $r.MissingRoleIds.Count | Should -Be ($script:Template.RoleIds.Count - 3)
            ($r.ProposedActions | Where-Object { $_.Action -eq 'AwaitApproval' }).Detail | Should -Match 'still be missing'
        }
        It 'Two active relationships are evaluated together and warn about overlap' {
            $half = $script:Template.RoleIds.Count / 2
            $a = @($script:Template.RoleIds | Select-Object -First ($half + 1))
            $b = @($script:Template.RoleIds | Select-Object -Last ($half + 1))
            $r = Compare-GdapRelationship -Relationships @((New-Rel -Id 'a1' -Status 'active' -RoleIds $a), (New-Rel -Id 'a2' -Status 'active' -RoleIds $b)) -Template $script:Template
            $r.MissingRoles.Count | Should -Be 0
            $r.State | Should -Be 'MissingAssignments'
            $r.Warnings | Should -Match 'overlap'
            foreach ($m in $r.MissingAssignments) { $m.RelationshipId | Should -BeIn 'a1', 'a2' }
            # Tier 2 needs roles from both relationships: one assignment on each.
            @($r.MissingAssignments | Where-Object { $_.GroupName -eq 'Tier 2' }).Count | Should -Be 2
            @($r.MissingAssignments | Where-Object { $_.GroupName -eq 'Tier 2' } | ForEach-Object { $_.RoleIds } | Sort-Object -Unique).Count | Should -Be $script:Template.RoleIds.Count
        }
        It "never picks an 'expiring' relationship as the assignment target (Set-GdapAccessAssignment would refuse it)" {
            $r = Compare-GdapRelationship -Relationships @(New-Rel -Id 'x1' -Status 'expiring' -RoleIds $script:Template.RoleIds -Days 10) -Template $script:Template
            $r.MissingRoles.Count | Should -Be 0
            $r.MissingAssignments.Count | Should -Be 0
            $r.Warnings | Should -Match 'only an expiring relationship'
        }
        It 'Only expired/terminated -> Expired, replacement proposed' {
            $r = Compare-GdapRelationship -Relationships @((New-Rel -Id 'e1' -Status 'expired' -RoleIds $script:Template.RoleIds -Days -5), (New-Rel -Id 't1' -Status 'terminated' -RoleIds $script:Template.RoleIds)) -Template $script:Template
            $r.State | Should -Be 'Expired'
            $r.ProposedActions.Action | Should -Be @('CreateReplacement')
        }
        It 'warns when an active relationship without auto-extend is close to expiry' {
            $r = Compare-GdapRelationship -Relationships @(New-Rel -Id 'a1' -Status 'active' -RoleIds $script:Template.RoleIds -Days 30 -AutoExtend 'PT0S') -Template $script:Template
            $r.Warnings | Should -Match 'expires in 30'
        }
        It 'does not count expired relationships as covering roles' {
            $r = Compare-GdapRelationship -Relationships @((New-Rel -Id 'e1' -Status 'expired' -RoleIds $script:Template.RoleIds), (New-Rel -Id 'a1' -Status 'active' -RoleIds @($script:GlobalReader))) -Template $script:Template
            $r.State | Should -Be 'MissingRoles'
        }
        It 'returns real arrays for every list (GUI reads .Count under StrictMode), even with zero or one entry' {
            Set-StrictMode -Version Latest
            $r = Compare-GdapRelationship -Relationships @(New-Rel -Id 'a1' -Status 'active' -RoleIds @($script:GlobalReader)) -Template $script:Template
            $r.CoveredRoles.Count | Should -Be 1
            $r.PendingRoles.Count | Should -Be 0
            $r.MissingRoles.Count | Should -Be ($script:Template.RoleIds.Count - 1)
            $r.MissingAssignments[0].Roles.Count | Should -Be 1
            $r.Warnings.Count | Should -BeGreaterOrEqual 0
        }
        It 'G.8: proposed action details survive a dry run (no member-name ForEach-Object)' {
            $WhatIfPreference = $true
            $r = Compare-GdapRelationship -Relationships @() -Template $script:Template
            (@($r.ProposedActions) | ForEach-Object { $_.Detail }) -join ' | ' | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Get-GdapRelationship records' {
        It "gives an approval link only to a locked request (approvalPending), not to 'created'" {
            $script:Fake.Relationships['c1'] = New-FakeRel -Id 'c1' -Status 'created' -RoleIds @($script:GlobalReader)
            $script:Fake.Relationships['p1'] = New-FakeRel -Id 'p1' -Status 'approvalPending' -RoleIds @($script:GlobalReader)
            (Get-GdapRelationship -RelationshipId 'c1').ApprovalUrl | Should -BeNullOrEmpty
            (Get-GdapRelationship -RelationshipId 'p1').ApprovalUrl | Should -Match 'granularAdminRelationships/p1$'
        }
    }

    Context 'New-GdapRequest (plan and run through Invoke-M365Change)' {
        BeforeAll { $script:StateDir = Join-Path $TestDrive 'gdap-state' }
        BeforeEach { Remove-Item $script:StateDir -Recurse -Force -ErrorAction SilentlyContinue }

        It 'under -WhatIf makes no write and plans create + lock, the lock on a placeholder id' {
            Start-M365ChangeRecording
            $r = New-GdapRequest -CustomerTenantId $script:Tid -CustomerName 'Contoso Dental' -Template $script:Example -StatePath $script:StateDir -WhatIf
            $plan = Stop-M365ChangeRecording
            $script:Fake.Writes.Count | Should -Be 0
            $r.WhatIf | Should -BeTrue
            $r.Status | Should -Be 'WhatIf'
            $r.RoleIds.Count | Should -Be 27
            @($plan.Status) | Should -Be @('Planned', 'Planned')
            $plan[0].Tenant | Should -Be 'examplemsp.onmicrosoft.com'
            $plan[0].Command | Should -BeLike "New-MgTenantRelationshipDelegatedAdminRelationship -BodyParameter @{ displayName = 'MSP GDAP - Contoso Dental $((Get-Date).ToString('yyyy-MM-dd'))'; duration = 'P730D'; autoExtendDuration = 'PT0S'; customer = @{ tenantId = '$($script:Tid)' }; accessDetails = @{ unifiedRoles = @(*"
            $plan[0].Action | Should -BeLike "*'Contoso Ltd' (contoso.onmicrosoft.com, tenant $($script:Tid))*730 days*no auto-extend*27 roles - HIGHLY PRIVILEGED: Global Administrator, Privileged Role Administrator, Privileged Authentication Administrator; also: *"
            $plan[1].Command | Should -Be "New-MgTenantRelationshipDelegatedAdminRelationshipRequest -DelegatedAdminRelationshipId <id of the relationship created above> -BodyParameter @{ action = 'lockForApproval' }"
            Test-Path $script:StateDir | Should -BeFalse
        }
        It 'rejects a non-GUID tenant id before any call' {
            { New-GdapRequest -CustomerTenantId 'contoso.onmicrosoft.com' -CustomerName 'Contoso' -Template $script:Template -WhatIf } | Should -Throw '*GUID*'
        }
        It 'H11: a real run returns ONE record even when the log and state writers return text, posts the Graph body, locks and gives the link' {
            Mock -ModuleName GdapHelpers Write-M365Log { 'C:\leaked\log.jsonl' }
            Mock -ModuleName GdapHelpers Save-GdapState { 'C:\leaked\state.json' }
            $out = @(New-GdapRequest -CustomerTenantId $script:Tid.ToUpperInvariant() -CustomerName 'Contoso' -Template $script:Template -TenantInfo $script:TenantInfo -StatePath $script:StateDir -Confirm:$false 6>$null)
            $out.Count | Should -Be 1
            $r = $out[0]
            $r.WhatIf | Should -BeFalse
            $r.Locked | Should -BeTrue
            $r.Status | Should -Be 'approvalPending'
            $r.ApprovalUrl | Should -Be "https://admin.microsoft.com/AdminPortal/Home#/partners/invitation/granularAdminRelationships/$($r.Id)"
            $script:Fake.Writes.Command | Should -Be @('CreateRelationship', 'Lock')
            $body = $script:Fake.Writes[0].Body
            $body.displayName | Should -Be "MSP GDAP - Contoso $((Get-Date).ToString('yyyy-MM-dd'))"
            $body.duration | Should -Be 'P730D'
            $body.autoExtendDuration | Should -Be 'P180D'
            $body.customer.tenantId | Should -Be $script:Tid
            @($body.accessDetails.unifiedRoles).Count | Should -Be 20
            $script:Fake.Writes[1].Target | Should -Be $r.Id
            $script:Fake.Writes[1].Body.action | Should -Be 'lockForApproval'
        }
        It 'runs a reviewed plan, filling the placeholder with the new id' {
            Start-M365ChangeRecording
            $null = New-GdapRequest -CustomerTenantId $script:Tid -CustomerName 'Contoso' -Template $script:Example -StatePath $script:StateDir -WhatIf
            $plan = Stop-M365ChangeRecording
            Start-M365ChangeRecording -ApprovedPlan $plan
            $r = New-GdapRequest -CustomerTenantId $script:Tid -CustomerName 'Contoso' -Template $script:Example -StatePath $script:StateDir -Confirm:$false 6>$null
            $done = Stop-M365ChangeRecording
            @($done.Status) | Should -Be @('Done', 'Done')
            $done[1].Text | Should -BeLike "*-DelegatedAdminRelationshipId '$($r.Id)'*"
        }
        It 'G-M3: when the lock fails, keeps the record honest (no link) and saves state naming the relationship as ours' {
            $script:Fake.LockThrows = $true
            $out = @(New-GdapRequest -CustomerTenantId $script:Tid -CustomerName 'Contoso' -Template $script:Template -TenantInfo $script:TenantInfo -StatePath $script:StateDir -Confirm:$false 6>$null 3>$null)
            $out.Count | Should -Be 1
            $out[0].Locked | Should -BeFalse
            $out[0].LockError | Should -Match 'BadRequest'
            $out[0].ApprovalUrl | Should -BeNullOrEmpty
            $s = Get-GdapState -CustomerTenantId $script:Tid -StatePath $script:StateDir
            @($s.createdRelationshipIds) | Should -Contain $out[0].Id
            $s.lockError | Should -Match 'BadRequest'
        }
        It 'never retries a create that timed out (it may have happened)' {
            $script:Fake.CreateThrows = 'The operation has timed out.'
            { New-GdapRequest -CustomerTenantId $script:Tid -CustomerName 'Contoso' -Template $script:Template -TenantInfo $script:TenantInfo -StatePath $script:StateDir -Confirm:$false 6>$null } | Should -Throw '*timed out*'
            $script:Fake.Attempts | Should -Be 1
        }
    }

    Context 'Lock-GdapRelationship (G-M3 lock retry)' {
        BeforeAll { $script:StateDir = Join-Path $TestDrive 'lock-state' }
        BeforeEach {
            Remove-Item $script:StateDir -Recurse -Force -ErrorAction SilentlyContinue
            $script:Fake.Relationships['c1'] = New-FakeRel -Id 'c1' -Status 'created' -RoleIds $script:Template.RoleIds -Name 'MSP GDAP - Contoso 2026-10-01'
        }
        It 'retries the lock on a created relationship our state names, and only plans it under -WhatIf' {
            Save-GdapState -CustomerTenantId $script:Tid -State @{ relationshipId = 'c1'; createdRelationshipIds = @('c1') } -StatePath $script:StateDir
            Start-M365ChangeRecording
            $w = Lock-GdapRelationship -RelationshipId 'c1' -TenantInfo $script:TenantInfo -StatePath $script:StateDir -WhatIf
            $plan = Stop-M365ChangeRecording
            $w.WhatIf | Should -BeTrue
            $script:Fake.Writes.Count | Should -Be 0
            $plan[0].Command | Should -Be "New-MgTenantRelationshipDelegatedAdminRelationshipRequest -DelegatedAdminRelationshipId 'c1' -BodyParameter @{ action = 'lockForApproval' }"
            $out = @(Lock-GdapRelationship -RelationshipId 'c1' -TenantInfo $script:TenantInfo -StatePath $script:StateDir -Confirm:$false 6>$null)
            $out.Count | Should -Be 1
            $out[0].Locked | Should -BeTrue
            $out[0].ApprovalUrl | Should -Match 'granularAdminRelationships/c1$'
            $script:Fake.Writes.Command | Should -Be @('Lock')
        }
        It 'never locks a created relationship the toolkit did not create' {
            { Lock-GdapRelationship -RelationshipId 'c1' -StatePath $script:StateDir -Confirm:$false 6>$null } | Should -Throw '*does not name it as one we created*'
            $script:Fake.Writes.Count | Should -Be 0
        }
        It "refuses a relationship that is not in status 'created'" {
            $script:Fake.Relationships['c1'].Status = 'approvalPending'
            Save-GdapState -CustomerTenantId $script:Tid -State @{ relationshipId = 'c1' } -StatePath $script:StateDir
            { Lock-GdapRelationship -RelationshipId 'c1' -StatePath $script:StateDir -Confirm:$false } | Should -Throw "*only a relationship in status 'created'*"
            $script:Fake.Writes.Count | Should -Be 0
        }
    }

    Context 'Set-GdapAccessAssignment (create, extend, refuse)' {
        BeforeEach {
            $script:Fake.Relationships['a1'] = New-FakeRel -Id 'a1' -Status 'active' -RoleIds $script:Template.RoleIds -Name 'MSP GDAP - Contoso 2026-01-01'
            $script:G1 = $script:Template.Groups[0]
        }
        It 'does nothing when the group already holds the roles' {
            $script:Fake.Assignments.Add((New-FakeAsg -Id 'asg-1' -RelationshipId 'a1' -GroupId $script:G1.Id -RoleIds $script:G1.RoleIds))
            $r = Set-GdapAccessAssignment -RelationshipId 'a1' -GroupId $script:G1.Id -RoleIds $script:G1.RoleIds -Confirm:$false
            $r.Change | Should -Be 'None'
            $r.Created | Should -BeFalse
            $script:Fake.Writes.Count | Should -Be 0
        }
        It 'refuses roles the relationship does not grant' {
            $script:Fake.Relationships['a1'] = New-FakeRel -Id 'a1' -Status 'active' -RoleIds @($script:GlobalReader)
            { Set-GdapAccessAssignment -RelationshipId 'a1' -GroupId $script:G1.Id -RoleIds $script:G1.RoleIds -Confirm:$false } | Should -Throw '*not in relationship*'
            $script:Fake.Writes.Count | Should -Be 0
        }
        It 'refuses when the relationship is not active (pending or expiring)' {
            $script:Fake.Relationships['a1'].Status = 'approvalPending'
            { Set-GdapAccessAssignment -RelationshipId 'a1' -GroupId $script:G1.Id -RoleIds @($script:GlobalReader) -Confirm:$false } | Should -Throw '*active*'
            $script:Fake.Relationships['a1'].Status = 'expiring'
            { Set-GdapAccessAssignment -RelationshipId 'a1' -GroupId $script:G1.Id -RoleIds @($script:GlobalReader) -Confirm:$false } | Should -Throw '*active*'
            $script:Fake.Writes.Count | Should -Be 0
        }
        It 'refuses a group that is not a security group' {
            $script:Fake.Groups[$script:G1.Id].SecurityEnabled = $false
            { Set-GdapAccessAssignment -RelationshipId 'a1' -GroupId $script:G1.Id -RoleIds @($script:GlobalReader) -Confirm:$false } | Should -Throw '*not a security group*'
            $script:Fake.Writes.Count | Should -Be 0
        }
        It 'H11: creates the assignment with the Graph body shape (one record out even when the log writer returns text), and not under -WhatIf' {
            Mock -ModuleName GdapHelpers Write-M365Log { 'C:\leaked\log.jsonl' }
            $w = Set-GdapAccessAssignment -RelationshipId 'a1' -GroupId $script:G1.Id -RoleIds $script:G1.RoleIds -WhatIf
            $w.WhatIf | Should -BeTrue
            $w.Created | Should -BeFalse
            $script:Fake.Writes.Count | Should -Be 0
            $out = @(Set-GdapAccessAssignment -RelationshipId 'a1' -GroupId $script:G1.Id -RoleIds $script:G1.RoleIds -Confirm:$false 6>$null)
            $out.Count | Should -Be 1
            $out[0].Created | Should -BeTrue
            $out[0].WhatIf | Should -BeFalse
            $script:Fake.Writes.Command | Should -Be @('CreateAssignment')
            $b = $script:Fake.Writes[0].Body
            $b.accessContainer.accessContainerType | Should -Be 'securityGroup'
            $b.accessContainer.accessContainerId | Should -Be $script:G1.Id
            @($b.accessDetails.unifiedRoles).Count | Should -Be $script:G1.RoleIds.Count
        }
        It 'G-M9: extends an existing partial assignment with a PATCH of the union (If-Match etag), never a second POST' {
            $have = @($script:G1.RoleIds | Select-Object -First 2)
            $script:Fake.Assignments.Add((New-FakeAsg -Id 'asg-1' -RelationshipId 'a1' -GroupId $script:G1.Id -RoleIds $have))
            Start-M365ChangeRecording
            $null = Set-GdapAccessAssignment -RelationshipId 'a1' -GroupId $script:G1.Id -RoleIds $script:G1.RoleIds -WhatIf
            $plan = Stop-M365ChangeRecording
            $plan[0].Command | Should -BeLike "Invoke-MgGraphRequest -Method 'PATCH' -Uri 'https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/a1/accessAssignments/asg-1' -Headers @{ 'If-Match' = 'W/`"etag-1`"' } -Body @{ accessDetails = @{ unifiedRoles = @(*"
            $plan[0].Action | Should -BeLike "Extend our group 'Tier 1'*Adding 3 roles:*"
            $script:Fake.Writes.Count | Should -Be 0
            $r = Set-GdapAccessAssignment -RelationshipId 'a1' -GroupId $script:G1.Id -RoleIds $script:G1.RoleIds -Confirm:$false 6>$null
            $r.Change | Should -Be 'Update'
            $r.Updated | Should -BeTrue
            $script:Fake.Writes.Command | Should -Be @('PATCH')
            $script:Fake.Writes[0].Headers['If-Match'] | Should -Be 'W/"etag-1"'
            $sent = @($script:Fake.Writes[0].Body.accessDetails.unifiedRoles | ForEach-Object { $_.roleDefinitionId })
            $sent.Count | Should -Be $script:G1.RoleIds.Count
            foreach ($id in $have) { $sent | Should -Contain $id }
        }
        It 'G-M9: refuses (no write) when the etag cannot be read' {
            $script:Fake.Assignments.Add((New-FakeAsg -Id 'asg-1' -RelationshipId 'a1' -GroupId $script:G1.Id -RoleIds @($script:G1.RoleIds | Select-Object -First 1)))
            $script:Fake.NoEtag = $true
            { Set-GdapAccessAssignment -RelationshipId 'a1' -GroupId $script:G1.Id -RoleIds $script:G1.RoleIds -Confirm:$false } | Should -Throw '*no etag*'
            $script:Fake.Writes.Count | Should -Be 0
        }
        It 'G-M9: refuses to extend an assignment that is still pending' {
            $script:Fake.Assignments.Add((New-FakeAsg -Id 'asg-1' -RelationshipId 'a1' -GroupId $script:G1.Id -RoleIds @($script:G1.RoleIds | Select-Object -First 1) -Status 'pending'))
            { Set-GdapAccessAssignment -RelationshipId 'a1' -GroupId $script:G1.Id -RoleIds $script:G1.RoleIds -Confirm:$false } | Should -Throw "*status 'pending'*"
            $script:Fake.Writes.Count | Should -Be 0
        }
        It 'plans the post-approval assignment on a not-yet-created relationship only in a dry run' {
            $planned = [pscustomobject]@{ Id = $null; DisplayName = 'MSP GDAP - Contoso 2026-10-19'; Customer = 'Contoso'; TenantDisplayName = 'Contoso Ltd'; CustomerTenantId = $script:Tid; RoleIds = $script:Template.RoleIds }
            Start-M365ChangeRecording
            $r = Set-GdapAccessAssignment -PlannedRelationship $planned -GroupId $script:G1.Id -RoleIds $script:G1.RoleIds -WhatIf
            $plan = Stop-M365ChangeRecording
            $r.WhatIf | Should -BeTrue
            $plan[0].Command | Should -BeLike 'New-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment -DelegatedAdminRelationshipId <id of the relationship created above, once the customer approves it> -BodyParameter*'
            { Set-GdapAccessAssignment -PlannedRelationship $planned -GroupId $script:G1.Id -RoleIds $script:G1.RoleIds -Confirm:$false } | Should -Throw '*dry run*'
            $script:Fake.Writes.Count | Should -Be 0
        }
    }

    Context 'Wait-GdapApproval' {
        It 'H11: returns one record even when the state writer returns text, and updates state only for the same relationship' {
            $script:Fake.Relationships['a1'] = New-FakeRel -Id 'a1' -Status 'active' -RoleIds @($script:GlobalReader)
            Mock -ModuleName GdapHelpers Get-GdapState { [pscustomobject]@{ relationshipId = 'a1' } }
            Mock -ModuleName GdapHelpers Save-GdapState { 'C:\leaked\state.json' }
            $out = @(Wait-GdapApproval -RelationshipId 'a1' -TimeoutMinutes 1 -PollSeconds 5)
            $out.Count | Should -Be 1
            $out[0].Result | Should -Be 'Active'
            Should -Invoke -ModuleName GdapHelpers Save-GdapState -Times 1 -Exactly
            Mock -ModuleName GdapHelpers Get-GdapState { [pscustomobject]@{ relationshipId = 'someone-else' } }
            $null = Wait-GdapApproval -RelationshipId 'a1' -TimeoutMinutes 1 -PollSeconds 5
            Should -Invoke -ModuleName GdapHelpers Save-GdapState -Times 1 -Exactly
        }
    }

    Context 'State' {
        It 'saves, merges and reads state without secrets; returns nothing unless -PassThru' {
            $dir = Join-Path $TestDrive 'state'
            $file = Save-GdapState -CustomerTenantId 'CCCCCCCC-0000-0000-0000-000000000001' -State @{ relationshipId = 'r1'; status = 'approvalPending' } -StatePath $dir -PassThru
            @(Save-GdapState -CustomerTenantId 'cccccccc-0000-0000-0000-000000000001' -State @{ status = 'active' } -StatePath $dir).Count | Should -Be 0
            $s = Get-GdapState -CustomerTenantId 'cccccccc-0000-0000-0000-000000000001' -StatePath $dir
            $s.relationshipId | Should -Be 'r1'
            $s.status | Should -Be 'active'
            $s.customerTenantId | Should -Be 'cccccccc-0000-0000-0000-000000000001'
            (Split-Path $file -Leaf) | Should -Be 'cccccccc-0000-0000-0000-000000000001.json'
        }
        It 'returns null when there is no state' {
            Get-GdapState -CustomerTenantId 'dddddddd-0000-0000-0000-000000000001' -StatePath (Join-Path $TestDrive 'none') | Should -BeNullOrEmpty
        }
    }
}

Describe 'M365Helpers retry and logging' {
    BeforeEach {
        Mock Test-M365ReadOnly -ModuleName M365Helpers { $false }
        Mock Test-M365ReadOnly -ModuleName GdapHelpers { $false }
    }

    It 'retries transient errors and then succeeds' {
        $script:calls = 0
        $r = Invoke-M365WithRetry -BaseDelaySeconds 1 -MaxAttempts 3 -Operation test { $script:calls++; if ($script:calls -lt 2) { throw 'Response status code does not indicate success: 429 (TooManyRequests).' }; 'ok' } 3>$null
        $r | Should -Be 'ok'
        $script:calls | Should -Be 2
    }
    It 'does not retry non-transient errors' {
        $script:calls = 0
        { Invoke-M365WithRetry -MaxAttempts 3 { $script:calls++; throw 'Insufficient privileges to complete the operation.' } } | Should -Throw '*Insufficient*'
        $script:calls | Should -Be 1
    }
    It 'writes JSON lines and redacts tokens' {
        $dir = Join-Path $TestDrive 'logs'
        # Build a deliberately unsigned fixture; no real credential belongs in this test.
        $header = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"alg":"none","typ":"JWT"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"sub":"fictional-test"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $fixture = "$header.$payload.not-a-signature"
        $file = Write-M365Log -PassThru -Operation 'test' -TenantId 't' -CorrelationId 'c1' -Message "Authorization: Bearer $fixture" -Data @{ id = 'x' } -LogPath $dir
        $line = Get-Content $file -Raw | ConvertFrom-Json
        $line.correlationId | Should -Be 'c1'
        $line.message | Should -Not -Match 'eyJ'
        $line.message | Should -Match 'REDACTED'
        $line.data.id | Should -Be 'x'
    }
}

Describe 'Partner scripts end to end (stubbed Graph)' {

    # The scripts re-import the modules with -Force and read settings from <repo>/config, so
    # they run from a copy under TestDrive with a filled settings file. Graph is the fake above;
    # a fake Microsoft.Graph.Authentication folder satisfies Assert-M365Graph's install check.
    BeforeAll {
        $script:Mirror = Join-Path $TestDrive 'repo'
        foreach ($m in 'M365Helpers', 'GdapHelpers') {
            $dest = Join-Path $script:Mirror 'scripts' 'powershell' 'modules' $m
            $null = New-Item -ItemType Directory -Path $dest -Force
            Copy-Item (Join-Path $script:RepoRoot 'scripts' 'powershell' 'modules' $m '*') $dest -Recurse
        }
        # This mirror exercises legacy GDAP mutation semantics in hostless runspaces
        # against the fake Graph. Pester mocks cannot cross runspaces or -Force imports.
        # Override only the mirror's policy; the shipped source remains read-only and
        # EndToEnd.Tests.ps1 independently exercises every script with the real policy.
        Add-Content (Join-Path $script:Mirror 'scripts/powershell/modules/M365Helpers/Safety.ps1') `
            'function Test-M365ReadOnly { [CmdletBinding()] param() return $false }'
        Copy-Item (Join-Path $script:RepoRoot 'scripts' 'powershell' 'partner') (Join-Path $script:Mirror 'scripts' 'powershell' 'partner') -Recurse
        $config = Join-Path $script:Mirror 'config'
        $null = New-Item -ItemType Directory -Path $config -Force
        $settings = Get-Content (Join-Path $script:RepoRoot 'config' 'msp.settings.example.json') -Raw | ConvertFrom-Json
        $settings.msp.homeTenantId = $script:HomeGuid
        $settings.msp.adminUpn = 'tech@msp.example'
        $settings | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $config 'msp.settings.local.json')
        Copy-Item $script:ExamplePath (Join-Path $config 'gdap-roles.local.json')
        $fake = Join-Path $TestDrive 'fakemods' 'Microsoft.Graph.Authentication'
        $null = New-Item -ItemType Directory -Path $fake -Force
        Set-Content (Join-Path $fake 'Microsoft.Graph.Authentication.psd1') "@{ ModuleVersion = '2.0.0' }"
        $script:OldModulePath = $env:PSModulePath
        $env:PSModulePath = (Join-Path $TestDrive 'fakemods') + [IO.Path]::PathSeparator + $env:PSModulePath
        $script:Partner = Join-Path $script:Mirror 'scripts' 'powershell' 'partner'
        $script:StateFile = Join-Path $script:Mirror 'runs' 'gdap' "$($script:Tid).json"
        $script:AllRoles = $script:Example.RoleIds

        # Runs a script in a runspace with NO host UI (like the GUI's worker): a confirmation
        # prompt there throws instead of waiting at a keyboard.
        function script:Invoke-Hostless {
            param([string]$Script, [hashtable]$Parameters, [string]$Prelude = '$null')
            $rs = [runspacefactory]::CreateRunspace()
            $rs.Open()
            $ps = [powershell]::Create()
            try {
                $ps.Runspace = $rs
                $rs.SessionStateProxy.SetVariable('GdapFake', $script:Fake)
                $null = $ps.AddScript($script:StubSource).AddStatement().AddScript($Prelude).AddStatement().AddCommand($Script).AddParameters($Parameters)
                $err = $null
                $out = @()
                try { $out = $ps.Invoke() } catch { $err = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message } }
                if (-not $err -and $ps.Streams.Error.Count -gt 0) { $err = "$($ps.Streams.Error[0])" }
                [pscustomobject]@{ Output = @($out); Error = $err }
            } finally { $ps.Dispose(); $rs.Dispose() }
        }
    }
    AfterAll {
        $env:PSModulePath = $script:OldModulePath
        #   WHY    The scripts imported modules from the mirror copy; unload them so the next
        #          test file does not see two modules with the same name.
        Get-Module | Where-Object { $_.ModuleBase -and $_.ModuleBase.StartsWith($script:Mirror, [StringComparison]::OrdinalIgnoreCase) } | Remove-Module -Force -ErrorAction SilentlyContinue
        $modules = Join-Path $script:RepoRoot 'scripts' 'powershell' 'modules'
        Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
        Import-Module (Join-Path $modules 'GdapHelpers' 'GdapHelpers.psd1') -Force
    }
    BeforeEach {
        Reset-Fake
        Remove-Item (Join-Path $script:Mirror 'runs') -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Start-M365GdapOnboarding -WhatIf, new customer: zero writes; plans create, lock and the post-approval assignment; no "Declined"; G.8 detail filled' {
        Start-M365ChangeRecording
        $out = & (Join-Path $script:Partner 'Start-M365GdapOnboarding.ps1') -CustomerTenantId $script:Tid -WhatIf -InformationVariable info 6>$null
        $plan = Stop-M365ChangeRecording
        $script:Fake.Writes.Count | Should -Be 0
        @($plan.Status) | Should -Be @('Planned', 'Planned', 'Planned')
        $plan[0].Command | Should -BeLike 'New-MgTenantRelationshipDelegatedAdminRelationship *'
        $plan[1].Command | Should -BeLike '*-DelegatedAdminRelationshipId <id of the relationship created above> *'
        $plan[2].Command | Should -BeLike "New-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment -DelegatedAdminRelationshipId <id of the relationship created above, once the customer approves it> -BodyParameter @{ accessContainer = @{ accessContainerId = '$($script:AdminAgents)'*"
        $plan[0].Action | Should -BeLike "*'Contoso Ltd' (contoso.onmicrosoft.com*HIGHLY PRIVILEGED: Global Administrator*"
        $text = ($info | ForEach-Object { "$($_.MessageData)" }) -join "`n"
        $text | Should -Not -Match 'Declined'
        $text | Should -Match "Final state: NoRelationship[^\n]*\n\s+Create 'MSP standard GDAP' relationship"
        $out.WhatIf | Should -BeTrue
        Test-Path $script:StateFile | Should -BeFalse
    }
    It 'H11 + G-M2: the real run with -NoWait in a hostless runspace (no console, like the GUI worker): no prompt, creates and locks, reports the link' {
        $r = Invoke-Hostless -Script (Join-Path $script:Partner 'Start-M365GdapOnboarding.ps1') -Parameters @{ CustomerTenantId = $script:Tid; NoWait = $true; NoBrowser = $true }
        $r.Error | Should -BeNullOrEmpty
        $script:Fake.Writes.Command | Should -Be @('CreateRelationship', 'Lock')
        $final = $r.Output | Where-Object { $_.PSObject.Properties.Name -contains 'State' } | Select-Object -Last 1
        $final.State | Should -Be 'PendingApproval'
        $final.ApprovalUrl | Should -Match 'granularAdminRelationships/new-1$'
        (Get-Content $script:StateFile -Raw | ConvertFrom-Json).createdRelationshipIds | Should -Contain 'new-1'
    }
    It 'runs only what the reviewed plan showed (approved-plan run in this session)' {
        Start-M365ChangeRecording
        $null = & (Join-Path $script:Partner 'Start-M365GdapOnboarding.ps1') -CustomerTenantId $script:Tid -NoWait -WhatIf 6>$null
        $plan = Stop-M365ChangeRecording
        Start-M365ChangeRecording -ApprovedPlan $plan
        $null = & (Join-Path $script:Partner 'Start-M365GdapOnboarding.ps1') -CustomerTenantId $script:Tid -NoWait -NoBrowser 6>$null 3>$null
        $done = Stop-M365ChangeRecording
        @($done.Status) | Should -Be @('Done', 'Done')
    }
    It 'H13: active relationship lacking roles plus a request in flight for them: no new request' {
        $few = @($script:AllRoles | Select-Object -First 3)
        $script:Fake.Relationships['a1'] = New-FakeRel -Id 'a1' -Status 'active' -RoleIds $few
        $script:Fake.Assignments.Add((New-FakeAsg -Id 'asg-a1' -RelationshipId 'a1' -GroupId $script:AdminAgents -RoleIds $few))
        $script:Fake.Relationships['p1'] = New-FakeRel -Id 'p1' -Status 'approvalPending' -RoleIds @($script:AllRoles | Select-Object -Skip 3)
        $out = & (Join-Path $script:Partner 'Start-M365GdapOnboarding.ps1') -CustomerTenantId $script:Tid -NoWait -NoBrowser 6>$null 3>$null
        $script:Fake.Writes.Count | Should -Be 0
        $out.State | Should -Be 'PendingApproval'
        { & (Join-Path $script:Partner 'New-M365GdapRequest.ps1') -CustomerTenantId $script:Tid -CustomerName 'Contoso' -NoBrowser -Confirm:$false 6>$null } | Should -Throw '*already in flight*'
        $script:Fake.Writes.Count | Should -Be 0
    }
    It 'G-M3: retries the lock on our own unlocked request; never locks someone else''s' {
        $script:Fake.Relationships['c1'] = New-FakeRel -Id 'c1' -Status 'created' -RoleIds $script:AllRoles -Name 'MSP GDAP - Contoso 2026-10-01'
        $null = & (Join-Path $script:Partner 'Start-M365GdapOnboarding.ps1') -CustomerTenantId $script:Tid -NoWait -NoBrowser -InformationVariable info 6>$null 3>$null
        $script:Fake.Writes.Count | Should -Be 0
        (($info | ForEach-Object { "$($_.MessageData)" }) -join "`n") | Should -Match 'does not name it as one we created'
        $null = New-Item -ItemType Directory -Path (Split-Path $script:StateFile) -Force
        @{ customerTenantId = $script:Tid; relationshipId = 'c1'; createdRelationshipIds = @('c1') } | ConvertTo-Json | Set-Content $script:StateFile
        $out = & (Join-Path $script:Partner 'Start-M365GdapOnboarding.ps1') -CustomerTenantId $script:Tid -NoWait -NoBrowser 6>$null 3>$null
        $script:Fake.Writes.Command | Should -Be @('Lock')
        $script:Fake.Writes[0].Target | Should -Be 'c1'
        $out.ApprovalUrl | Should -Match 'granularAdminRelationships/c1$'
    }
    It 'G-M1: New-M365GdapRequest asks before creating (fails in a hostless runspace without -Confirm:$false, nothing written); runs when confirmation is off' {
        $r = Invoke-Hostless -Script (Join-Path $script:Partner 'New-M365GdapRequest.ps1') -Parameters @{ CustomerTenantId = $script:Tid; CustomerName = 'Contoso'; NoBrowser = $true }
        $r.Error | Should -Match 'does not support user interaction'
        $r.Error | Should -Match 'Global Administrator, Privileged Role Administrator, Privileged Authentication Administrator'
        $script:Fake.Writes.Count | Should -Be 0
        $r = Invoke-Hostless -Script (Join-Path $script:Partner 'New-M365GdapRequest.ps1') -Parameters @{ CustomerTenantId = $script:Tid; CustomerName = 'Contoso'; NoBrowser = $true } -Prelude '$ConfirmPreference = ''None'''
        $r.Error | Should -BeNullOrEmpty
        $script:Fake.Writes.Command | Should -Be @('CreateRelationship', 'Lock')
    }
    It 'New-M365GdapRequest -Force with an active relationship requests only the roles it lacks' {
        $few = @($script:AllRoles | Select-Object -First 5)
        $script:Fake.Relationships['a1'] = New-FakeRel -Id 'a1' -Status 'active' -RoleIds $few
        $script:Fake.Relationships['p1'] = New-FakeRel -Id 'p1' -Status 'approvalPending' -RoleIds @($script:AllRoles | Select-Object -Skip 5)
        $r = & (Join-Path $script:Partner 'New-M365GdapRequest.ps1') -CustomerTenantId $script:Tid -CustomerName 'Contoso' -NoBrowser -Force -Confirm:$false 6>$null 3>$null
        $r.RoleIds.Count | Should -Be ($script:AllRoles.Count - 5)
        @($script:Fake.Writes[0].Body.accessDetails.unifiedRoles).Count | Should -Be ($script:AllRoles.Count - 5)
    }
    It 'G-M1: Set-M365GdapAccessAssignment asks before assigning (hostless: fails, nothing written); -WhatIf plans a PATCH for a partial assignment' {
        $script:Fake.Relationships['a1'] = New-FakeRel -Id 'a1' -Status 'active' -RoleIds $script:AllRoles
        $script:Fake.Assignments.Add((New-FakeAsg -Id 'asg-1' -RelationshipId 'a1' -GroupId $script:AdminAgents -RoleIds @($script:AllRoles | Select-Object -First 4)))
        $r = Invoke-Hostless -Script (Join-Path $script:Partner 'Set-M365GdapAccessAssignment.ps1') -Parameters @{ RelationshipId = 'a1' }
        $r.Error | Should -Match 'does not support user interaction'
        $script:Fake.Writes.Count | Should -Be 0
        Start-M365ChangeRecording
        $null = & (Join-Path $script:Partner 'Set-M365GdapAccessAssignment.ps1') -RelationshipId 'a1' -WhatIf 6>$null
        $plan = Stop-M365ChangeRecording
        @($plan.Status) | Should -Be @('Planned')
        $plan[0].Command | Should -BeLike "Invoke-MgGraphRequest -Method 'PATCH' *accessAssignments/asg-1*If-Match*"
        $script:Fake.Writes.Count | Should -Be 0
    }
    It 'G-M5: Get-M365GdapRelationship -CustomerName matches the exact name only' {
        $script:Fake.Relationships['a1'] = New-FakeRel -Id 'a1' -Status 'active' -RoleIds @($script:GlobalReader) -CustomerName 'ABC Plumbing'
        $none = @(& (Join-Path $script:Partner 'Get-M365GdapRelationship.ps1') -CustomerName 'ABC' -WarningVariable wv 3>$null)
        $none.Count | Should -Be 0
        "$wv" | Should -Match "named exactly 'ABC'.*ABC Plumbing"
        @(& (Join-Path $script:Partner 'Get-M365GdapRelationship.ps1') -CustomerName 'abc plumbing' 3>$null).Count | Should -Be 1
        { & (Join-Path $script:Partner 'Get-M365GdapRelationship.ps1') -CustomerName 'ABC*' } | Should -Throw '*without wildcards*'
        $script:Fake.Relationships['b1'] = New-FakeRel -Id 'b1' -Status 'active' -RoleIds @($script:GlobalReader) -CustomerName 'ABC Plumbing' -TenantId 'dddddddd-0000-0000-0000-000000000001'
        { & (Join-Path $script:Partner 'Get-M365GdapRelationship.ps1') -CustomerName 'ABC Plumbing' 3>$null } | Should -Throw '*Pass -CustomerTenantId*'
    }
}
