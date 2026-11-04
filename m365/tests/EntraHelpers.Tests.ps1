# Legacy domain behavior runs only against the fake APIs in this test file.
# Mock the release policy here so these tests still exercise plan matching and
# mutation semantics. Safety.Tests.ps1 and EndToEnd.Tests.ps1 use the real policy.
BeforeAll {
    $modules = Join-Path $PSScriptRoot '..' 'scripts' 'powershell' 'modules'
    Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
    $script:ManifestPath = Join-Path $modules 'EntraHelpers' 'EntraHelpers.psd1'
    Import-Module $script:ManifestPath -Force
    $env:M365_TOOLKIT_LOG_PATH = Join-Path $TestDrive 'logs'

    #   A fake Graph. Reads answer from $global:G; writes are recorded in $global:G.Writes and change
    #   only $global:G, so a test can assert on exactly what was sent (and that nothing was sent).
    $script:Id = @{
        jane = '0000000a-0000-0000-0000-000000000001'; bob = '0000000a-0000-0000-0000-000000000002'; bg = '0000000a-0000-0000-0000-000000000003'
        mgr = '0000000a-0000-0000-0000-000000000004'; ga = '0000000b-0000-0000-0000-000000000001'; exo = '0000000b-0000-0000-0000-000000000002'
        sales1 = '0000000c-0000-0000-0000-000000000001'; sales2 = '0000000c-0000-0000-0000-000000000002'; staff = '0000000c-0000-0000-0000-000000000003'
        dl = '0000000c-0000-0000-0000-000000000004'; admins = '0000000c-0000-0000-0000-000000000005'
    }
    function global:New-FakeUser([string]$Upn, [string]$Id, [bool]$Enabled = $true, [string[]]$Skus = @(), [string]$Usage = 'US', [object[]]$States = @()) {
        [pscustomobject]@{
            Id = $Id; UserPrincipalName = $Upn; DisplayName = ($Upn -split '@')[0]; AccountEnabled = $Enabled; UserType = 'Member'; OnPremisesSyncEnabled = $null
            AssignedLicenses = @($Skus | ForEach-Object { [pscustomobject]@{ SkuId = $_ } }); LicenseAssignmentStates = $States; UsageLocation = $Usage
            CreatedDateTime = (Get-Date).AddDays(-30); Mail = $Upn; SignInActivity = $null
        }
    }
    function global:Copy-Fake($o) { if ($null -eq $o) { return $null }; $o | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable }
    function global:Reset-FakeGraph {
        $global:G = @{
            Users = [System.Collections.Generic.List[object]]::new(); Skus = @(); Groups = @(); Members = @{}; RoleDefs = @(); RoleAssignments = @(); Eligibility = @()
            PolicyOrder = [System.Collections.Generic.List[string]]::new(); Policies = @{}; Org = $null; Domains = @(); Relationships = @(); Methods = @{}
            Writes = [System.Collections.Generic.List[object]]::new(); Reads = [System.Collections.Generic.List[string]]::new(); Fail = @{}; FailPatch = @{}; PatchMode = 'merge'; NewIds = 0
        }
    }
    function global:Test-FakeFail([string]$Name) { if ($global:G.Fail.ContainsKey($Name)) { throw $global:G.Fail[$Name] } }

    # ---- reads ----
    function global:Get-MgUser { [CmdletBinding()] param($Filter, $Property, $UserId, [switch]$All)
        $global:G.Reads.Add("Get-MgUser $Filter$UserId"); Test-FakeFail 'Get-MgUser'
        if ($UserId) { $u = @($global:G.Users | Where-Object Id -eq $UserId); if (-not $u) { throw "Request_ResourceNotFound: $UserId does not exist" }; return $u[0] }
        if ($Filter) {
            if ($Filter -notmatch "^userPrincipalName eq '((?:[^']|'')*)'$") { throw "Invalid filter clause: $Filter" }
            $upn = $Matches[1].Replace("''", "'")
            return @($global:G.Users | Where-Object { $_.UserPrincipalName -eq $upn })
        }
        $global:G.Users.ToArray()
    }
    function global:Get-MgSubscribedSku { [CmdletBinding()] param([switch]$All) Test-FakeFail 'Get-MgSubscribedSku'; $global:G.Skus }
    function global:Get-MgGroup { [CmdletBinding()] param($Filter, $GroupId, $Property, [switch]$All, $Top)
        $global:G.Reads.Add("Get-MgGroup $Filter$GroupId"); Test-FakeFail 'Get-MgGroup'
        if ($GroupId) { $g = @($global:G.Groups | Where-Object Id -eq $GroupId); if (-not $g) { throw "Request_ResourceNotFound: $GroupId" }; return $g[0] }
        if ($Filter -match "^displayName eq '((?:[^']|'')*)'$") { $n = $Matches[1].Replace("''", "'"); return @($global:G.Groups | Where-Object { $_.DisplayName -eq $n }) }
        $global:G.Groups
    }
    function global:Get-MgGroupMember { [CmdletBinding()] param($GroupId, [switch]$All) Test-FakeFail 'Get-MgGroupMember'; @($global:G.Members[$GroupId]) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Id = $_ } } }
    function global:Get-MgRoleManagementDirectoryRoleDefinition { [CmdletBinding()] param($Filter, [switch]$All)
        Test-FakeFail 'Get-MgRoleManagementDirectoryRoleDefinition'
        if ($Filter -match "^displayName eq '((?:[^']|'')*)'$") { $n = $Matches[1].Replace("''", "'"); return @($global:G.RoleDefs | Where-Object { $_.DisplayName -eq $n }) }
        $global:G.RoleDefs
    }
    function global:Get-MgRoleManagementDirectoryRoleAssignment { [CmdletBinding()] param($Filter, [switch]$All, $ExpandProperty)
        Test-FakeFail 'Get-MgRoleManagementDirectoryRoleAssignment'
        if ($Filter -match "principalId eq '([^']*)' and roleDefinitionId eq '([^']*)'") { $p = $Matches[1]; $r = $Matches[2]; return @($global:G.RoleAssignments | Where-Object { $_.PrincipalId -eq $p -and $_.RoleDefinitionId -eq $r }) }
        $global:G.RoleAssignments
    }
    function global:Get-MgRoleManagementDirectoryRoleEligibilitySchedule { [CmdletBinding()] param([switch]$All, $ExpandProperty) Test-FakeFail 'Get-MgRoleManagementDirectoryRoleEligibilitySchedule'; $global:G.Eligibility }
    function global:Get-MgDomain { [CmdletBinding()] param([switch]$All) $global:G.Domains }
    function global:Get-MgOrganization { [CmdletBinding()] param() $global:G.Org }
    function global:Get-MgUserAuthenticationMethod { [CmdletBinding()] param($UserId) @($global:G.Methods[$UserId]) | Where-Object { $_ } }
    function global:Get-MgTenantRelationshipDelegatedAdminRelationship { [CmdletBinding()] param([switch]$All) $global:G.Relationships }

    # ---- writes (recorded) ----
    function global:Add-FakeWrite([string]$Command, $Bound) {
        $h = @{}; foreach ($k in $Bound.Keys) { if ($k -notin 'ErrorAction', 'Confirm') { $h[$k] = $Bound[$k] } }
        $global:G.Writes.Add([pscustomobject]@{ Command = $Command; Params = $h })
        Test-FakeFail $Command
    }
    function global:New-MgUser { [CmdletBinding()] param($BodyParameter)
        Add-FakeWrite 'New-MgUser' $PSBoundParameters
        $global:G.NewIds++; $id = '0000000f-0000-0000-0000-{0:d12}' -f $global:G.NewIds
        $global:G.Users.Add((New-FakeUser $BodyParameter.userPrincipalName $id)); [pscustomobject]@{ Id = $id }
    }
    function global:Update-MgUser { [CmdletBinding()] param($UserId, $BodyParameter) Add-FakeWrite 'Update-MgUser' $PSBoundParameters }
    function global:Revoke-MgUserSignInSession { [CmdletBinding()] param($UserId) Add-FakeWrite 'Revoke-MgUserSignInSession' $PSBoundParameters; $true }
    function global:Set-MgUserLicense { [CmdletBinding()] param($UserId, $AddLicenses, $RemoveLicenses) Add-FakeWrite 'Set-MgUserLicense' $PSBoundParameters }
    function global:New-MgGroupMember { [CmdletBinding()] param($GroupId, $DirectoryObjectId) Add-FakeWrite 'New-MgGroupMember' $PSBoundParameters }
    function global:New-MgRoleManagementDirectoryRoleAssignment { [CmdletBinding()] param($PrincipalId, $RoleDefinitionId, $DirectoryScopeId) Add-FakeWrite 'New-MgRoleManagementDirectoryRoleAssignment' $PSBoundParameters }
    function global:Update-MgOrganization { [CmdletBinding()] param($OrganizationId, $TechnicalNotificationMails, $SecurityComplianceNotificationMails) Add-FakeWrite 'Update-MgOrganization' $PSBoundParameters }
    function global:Set-MgUserManagerByRef { [CmdletBinding()] param($UserId, $BodyParameter) Add-FakeWrite 'Set-MgUserManagerByRef' $PSBoundParameters }
    function global:New-MgUserAuthenticationTemporaryAccessPassMethod { [CmdletBinding()] param($UserId, $BodyParameter)
        Add-FakeWrite 'New-MgUserAuthenticationTemporaryAccessPassMethod' $PSBoundParameters
        [pscustomobject]@{ TemporaryAccessPass = 'TAP-123'; StartDateTime = $null; LifetimeInMinutes = $BodyParameter.lifetimeInMinutes; IsUsableOnce = $BodyParameter.isUsableOnce }
    }
    # Conditional Access through raw Graph requests: GET list, GET one, PATCH (merge or a lossy "replace").
    function global:Invoke-MgGraphRequest { [CmdletBinding()] param($Method, $Uri, $Body, $OutputType)
        $base = 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies'
        if ($Method -eq 'GET') {
            Test-FakeFail 'GET'
            if ($Uri -eq $base) { return @{ value = @($global:G.PolicyOrder | ForEach-Object { Copy-Fake $global:G.Policies[$_] }) } }
            return (Copy-Fake $global:G.Policies[($Uri -split '/')[-1]])
        }
        Add-FakeWrite "Invoke-MgGraphRequest $Method" $PSBoundParameters
        $id = ($Uri -split '/')[-1]
        if ($global:G.FailPatch.ContainsKey($id)) { throw $global:G.FailPatch[$id] }
        $users = $Body.conditions.users
        $target = $global:G.Policies[$id].conditions
        if ($global:G.PatchMode -eq 'lossy') { $target.users = @{ excludeUsers = @($users.excludeUsers); includeUsers = @($users.includeUsers); includeGroups = @(); excludeGroups = @($users.excludeGroups); includeRoles = @(); excludeRoles = @(); includeGuestsOrExternalUsers = $null; excludeGuestsOrExternalUsers = $null } }
        else { $target.users = Copy-Fake $users }
    }
    function global:Add-FakePolicy([string]$Id, [string]$Name, [hashtable]$Users, [string]$State = 'enabled') {
        $global:G.PolicyOrder.Add($Id)
        $global:G.Policies[$Id] = @{ id = $Id; displayName = $Name; state = $State; conditions = @{ users = $Users; applications = @{ includeApplications = @('All') } } }
    }
    function global:New-FakeUsersCondition([string[]]$Exclude = @(), [hashtable]$Guests = $null) {
        @{ includeUsers = @('All'); excludeUsers = $Exclude; includeGroups = @(); excludeGroups = @('0000000d-0000-0000-0000-000000000001'); includeRoles = @(); excludeRoles = @()
            includeGuestsOrExternalUsers = $null; excludeGuestsOrExternalUsers = $Guests }
    }
    $script:Guests = @{ guestOrExternalUserTypes = 'internalGuest,b2bCollaborationGuest'; externalTenants = @{ '@odata.type' = '#microsoft.graph.conditionalAccessAllExternalTenants'; membershipKind = 'all' } }
    $script:Writes = { @($global:G.Writes | ForEach-Object { $_.Command }) }
}

AfterAll {
    foreach ($f in 'New-FakeUser', 'Copy-Fake', 'Reset-FakeGraph', 'Test-FakeFail', 'Get-MgUser', 'Get-MgSubscribedSku', 'Get-MgGroup', 'Get-MgGroupMember',
        'Get-MgRoleManagementDirectoryRoleDefinition', 'Get-MgRoleManagementDirectoryRoleAssignment', 'Get-MgRoleManagementDirectoryRoleEligibilitySchedule',
        'Get-MgDomain', 'Get-MgOrganization', 'Get-MgUserAuthenticationMethod', 'Get-MgTenantRelationshipDelegatedAdminRelationship', 'Add-FakeWrite', 'New-MgUser',
        'Update-MgUser', 'Revoke-MgUserSignInSession', 'Set-MgUserLicense', 'New-MgGroupMember', 'New-MgRoleManagementDirectoryRoleAssignment', 'Update-MgOrganization',
        'Set-MgUserManagerByRef', 'New-MgUserAuthenticationTemporaryAccessPassMethod', 'Invoke-MgGraphRequest', 'Add-FakePolicy', 'New-FakeUsersCondition') {
        Remove-Item "Function:\$f" -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name G -Scope Global -ErrorAction SilentlyContinue
    Remove-Item env:M365_TOOLKIT_LOG_PATH -ErrorAction SilentlyContinue
}

Describe 'EntraHelpers module' {

    BeforeEach {
        Mock Test-M365ReadOnly -ModuleName M365Helpers { $false }
        Reset-FakeGraph
        Set-M365ChangeTarget -Service Graph -Label 'contoso.onmicrosoft.com'
    }

    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }
    It 'exports the expected functions' {
        $expected = 'Get-M365UserReview', 'New-M365CloudUser', 'Add-M365RoleAssignment', 'Add-M365ConditionalAccessExclusion',
        'New-M365BreakGlassAccount', 'New-M365AdminAccount', 'Set-M365TechnicalContact', 'Get-M365GdapRelationship',
        'Get-M365LicenseSummary', 'Disable-M365UserSignIn', 'Remove-M365UserLicense',
        'New-M365User', 'Add-M365UserLicense', 'Add-M365GroupMember', 'New-M365TemporaryAccessPass'
        $actual = (Get-Command -Module EntraHelpers).Name
        foreach ($f in $expected) { $actual | Should -Contain $f }
    }
    It 'makes no tenant write outside Invoke-M365Change (source scan)' {
        $src = Get-Content (Join-Path (Split-Path $script:ManifestPath) 'EntraHelpers.psm1') -Raw
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
        $writeVerbs = '^(New|Set|Update|Add|Remove|Revoke|Disable|Enable|Invoke)-Mg'
        $direct = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -match $writeVerbs }, $true) |
                Where-Object { $_.GetCommandName() -ne 'Invoke-MgGraphRequest' -or $_.Extent.Text -notmatch '-Method GET' })
        @($direct | ForEach-Object { $_.Extent.Text }) | Should -BeNullOrEmpty
    }

    Context 'New-M365CloudUser (H4)' {
        It 'refuses an existing UPN without -AdoptExisting and writes nothing' {
            $global:G.Users.Add((New-FakeUser 'svc@tenant.example' $script:Id.bob))
            { New-M365CloudUser -UserPrincipalName svc@tenant.example -DisplayName A } | Should -Throw '*already exists*-AdoptExisting*'
            $global:G.Writes.Count | Should -Be 0
        }
        It 'adopts only with -AdoptExisting, and says the password was not changed' {
            $global:G.Users.Add((New-FakeUser 'svc@tenant.example' $script:Id.bob))
            $r = New-M365CloudUser -UserPrincipalName svc@tenant.example -DisplayName A -AdoptExisting -WarningVariable w -WarningAction SilentlyContinue
            $r.Adopted | Should -BeTrue
            $r.Created | Should -BeFalse
            $r.PasswordChanged | Should -BeFalse
            $r.Password | Should -BeNullOrEmpty
            "$w" | Should -Match 'password NOT changed'
            $global:G.Writes.Count | Should -Be 0
        }
        It 'creates with a generated password, no expiry and the right mailNickname, and the plan hides the password' {
            Start-M365ChangeRecording
            $r = New-M365CloudUser -UserPrincipalName svc-x@tenant.example -DisplayName X -PasswordLength 40 6>$null
            $rec = Stop-M365ChangeRecording
            $r.Created | Should -BeTrue
            $r.Password.Length | Should -Be 40
            $r.WhatIf | Should -BeFalse
            $body = $global:G.Writes[0].Params.BodyParameter
            $body.mailNickname | Should -Be 'svc-x'
            $body.passwordPolicies | Should -Be 'DisablePasswordExpiration'
            $body.passwordProfile.forceChangePasswordNextSignIn | Should -BeFalse
            $rec[0].Text | Should -Match '^\[contoso\.onmicrosoft\.com\] New-MgUser -BodyParameter '
            $rec[0].Text | Should -Match 'password = <hidden>'
            $rec[0].Text | Should -Not -Match ([regex]::Escape($r.Password))
        }
        It 'plans under -WhatIf, writes nothing and returns no password' {
            Start-M365ChangeRecording
            $r = New-M365CloudUser -UserPrincipalName svc-x@tenant.example -DisplayName X -WhatIf
            $rec = Stop-M365ChangeRecording
            $global:G.Writes.Count | Should -Be 0
            @($rec.Status) | Should -Be @('Planned')
            $r.Created | Should -BeFalse
            $r.WhatIf | Should -BeTrue
            $r.Password | Should -BeNullOrEmpty
        }
        It 'escapes an apostrophe in the UPN filter' {
            $null = New-M365CloudUser -UserPrincipalName "o'brien@tenant.example" -DisplayName X -WhatIf
            $global:G.Reads[0] | Should -BeLike "*userPrincipalName eq 'o''brien@tenant.example'*"
        }
        It 'does not read a failed lookup as "not found"' {
            $global:G.Fail['Get-MgUser'] = 'Graph 503'
            { New-M365CloudUser -UserPrincipalName svc@tenant.example -DisplayName X } | Should -Throw '*503*'
            $global:G.Writes.Count | Should -Be 0
        }
    }

    Context 'Add-M365RoleAssignment' {
        BeforeEach {
            $global:G.RoleDefs = @([pscustomobject]@{ Id = $script:Id.ga; DisplayName = 'Global Administrator' })
        }
        It 'does not count an administrative-unit-scoped assignment as already assigned' {
            $global:G.RoleAssignments = @([pscustomobject]@{ PrincipalId = $script:Id.jane; RoleDefinitionId = $script:Id.ga; DirectoryScopeId = '/administrativeUnits/au1' })
            $r = Add-M365RoleAssignment -PrincipalId $script:Id.jane -RoleName 'Global Administrator' 6>$null
            $r.Assigned | Should -BeTrue
            $global:G.Writes[0].Params.DirectoryScopeId | Should -Be '/'
        }
        It 'skips a tenant-scope assignment that exists' {
            $global:G.RoleAssignments = @([pscustomobject]@{ PrincipalId = $script:Id.jane; RoleDefinitionId = $script:Id.ga; DirectoryScopeId = '/' })
            $r = Add-M365RoleAssignment -PrincipalId $script:Id.jane -RoleName 'Global Administrator'
            $r.AlreadyAssigned | Should -BeTrue
            $global:G.Writes.Count | Should -Be 0
        }
        It 'stops when the existing assignments cannot be read' {
            $global:G.Fail['Get-MgRoleManagementDirectoryRoleAssignment'] = 'Forbidden'
            { Add-M365RoleAssignment -PrincipalId $script:Id.jane -RoleName 'Global Administrator' } | Should -Throw '*Forbidden*'
            $global:G.Writes.Count | Should -Be 0
        }
        It 'refuses an unknown role and a non-GUID principal' {
            { Add-M365RoleAssignment -PrincipalId $script:Id.jane -RoleName 'Global Admin' } | Should -Throw '*not found*'
            { Add-M365RoleAssignment -PrincipalId 'jane@contoso.com' -RoleName 'Global Administrator' } | Should -Throw '*GUID*'
        }
    }

    Context 'Add-M365ConditionalAccessExclusion (H5)' {
        BeforeEach {
            Add-FakePolicy 'p1' 'Require MFA' (New-FakeUsersCondition -Exclude @('u-old') -Guests $script:Guests)
            Add-FakePolicy 'p2' 'Block legacy' (New-FakeUsersCondition -Exclude @($script:Id.bg))
        }
        It 'PATCHes back the whole users condition, guest settings included, and skips a policy that already excludes the user' {
            $r = @(Add-M365ConditionalAccessExclusion -UserId $script:Id.bg 6>$null)
            ($r | Where-Object Policy -eq 'Require MFA').Result | Should -Be 'Updated'
            ($r | Where-Object Policy -eq 'Block legacy').Result | Should -Be 'AlreadyExcluded'
            $global:G.Writes.Count | Should -Be 1
            $sent = $global:G.Writes[0].Params
            $sent.Method | Should -Be 'PATCH'
            $sent.Uri | Should -BeLike '*/policies/p1'
            $u = $sent.Body.conditions.users
            $u.excludeUsers | Should -Be @('u-old', $script:Id.bg)
            $u.includeUsers | Should -Be @('All')
            $u.excludeGroups | Should -Be @('0000000d-0000-0000-0000-000000000001')
            $u.excludeGuestsOrExternalUsers.guestOrExternalUserTypes | Should -Be 'internalGuest,b2bCollaborationGuest'
            $u.excludeGuestsOrExternalUsers.externalTenants.membershipKind | Should -Be 'all'
            $u.Contains('includeGuestsOrExternalUsers') | Should -BeTrue
        }
        It 'reports a policy without a users condition as Skipped and still does the others' {
            Add-FakePolicy 'p3' 'Workload identities' $null
            $r = @(Add-M365ConditionalAccessExclusion -UserId $script:Id.jane 6>$null)
            ($r | Where-Object Policy -eq 'Workload identities').Result | Should -Be 'Skipped'
            ($r | Where-Object Policy -eq 'Workload identities').Reason | Should -Match 'no users condition'
            @($r | Where-Object Result -eq 'Updated').Count | Should -Be 2
        }
        It 'stops before the next policy on an error, reporting Updated / Failed / NotAttempted' {
            Add-FakePolicy 'p3' 'Third' (New-FakeUsersCondition)
            $global:G.Policies['p2'].conditions.users.excludeUsers = @()
            $global:G.FailPatch['p2'] = 'Graph 400: bad request'
            $out = [System.Collections.Generic.List[object]]::new()
            { Add-M365ConditionalAccessExclusion -UserId $script:Id.jane 6>$null | ForEach-Object { $out.Add($_) } } |
                Should -Throw "*stopped at policy 'Block legacy'*Updated before it: Require MFA*Not attempted: Third*"
            @($out | ForEach-Object { "$($_.Policy)=$($_.Result)" }) | Should -Be @('Require MFA=Updated', 'Block legacy=Failed', 'Third=NotAttempted')
            @($global:G.Writes | Where-Object { $_.Params.Uri -like '*/p3' }).Count | Should -Be 0
        }
        It 'fails loudly when the read-back shows the guest settings were lost' {
            $global:G.PatchMode = 'lossy'
            $out = [System.Collections.Generic.List[object]]::new()
            { Add-M365ConditionalAccessExclusion -UserId $script:Id.jane 6>$null | ForEach-Object { $out.Add($_) } } | Should -Throw '*excludeGuestsOrExternalUsers changed*'
            $out[0].Result | Should -Be 'Failed'
            $out[1].Result | Should -Be 'NotAttempted'
        }
        It 'throws when -PolicyDisplayName matches nothing, and lists both when two policies share the name' {
            { Add-M365ConditionalAccessExclusion -UserId $script:Id.jane -PolicyDisplayName 'Nope' } | Should -Throw "*No Conditional Access policy is named 'Nope'*Require MFA*"
            Add-FakePolicy 'p9' 'Require MFA' (New-FakeUsersCondition) 'disabled'
            { Add-M365ConditionalAccessExclusion -UserId $script:Id.jane -PolicyDisplayName 'Require MFA' } | Should -Throw '*2 Conditional Access policies*id p1*id p9*-PolicyId*'
            $global:G.Writes.Count | Should -Be 0
            $r = @(Add-M365ConditionalAccessExclusion -UserId $script:Id.jane -PolicyId 'p9' 6>$null)
            $r.Count | Should -Be 1
            $r[0].PolicyId | Should -Be 'p9'
        }
        It 'plans under -WhatIf (placeholder user too), with the tenant and the full PATCH in the plan, and writes nothing' {
            Start-M365ChangeRecording
            $r = @(Add-M365ConditionalAccessExclusion -UserId (New-M365Placeholder 'id of the new account') -UserLabel 'bg@tenant.example' -WhatIf)
            $rec = Stop-M365ChangeRecording
            $global:G.Writes.Count | Should -Be 0
            @($r.Result) | Should -Be @('Planned', 'Planned')
            $rec.Count | Should -Be 2
            $rec[0].Text | Should -Match "^\[contoso\.onmicrosoft\.com\] Invoke-MgGraphRequest -Method 'PATCH' -Uri '.+/policies/p1' -Body "
            $rec[0].Text | Should -Match 'excludeGuestsOrExternalUsers = @\{'
            $rec[0].Text | Should -Match "excludeUsers = @\('u-old', <id of the new account>\)"
            $rec[0].Action | Should -Match "Exclude bg@tenant.example from Conditional Access policy 'Require MFA'"
        }
    }

    Context 'New-M365BreakGlassAccount (H4, M8)' {
        BeforeEach {
            $global:G.RoleDefs = @([pscustomobject]@{ Id = $script:Id.ga; DisplayName = 'Global Administrator' })
            Add-FakePolicy 'p1' 'Require MFA' (New-FakeUsersCondition -Guests $script:Guests)
            Add-FakePolicy 'p2' 'Block legacy' (New-FakeUsersCondition)
        }
        It '-WhatIf plans the account, the role and every exclusion for the new account, and reports honestly' {
            Start-M365ChangeRecording
            $r = New-M365BreakGlassAccount -Domain contoso.onmicrosoft.com -WhatIf
            $rec = Stop-M365ChangeRecording
            $global:G.Writes.Count | Should -Be 0
            @($rec.Status | Select-Object -Unique) | Should -Be @('Planned')
            @($rec | ForEach-Object { ($_.Command -split ' ')[0] }) | Should -Be @('New-MgUser', 'New-MgRoleManagementDirectoryRoleAssignment', 'Invoke-MgGraphRequest', 'Invoke-MgGraphRequest')
            $rec[1].Text | Should -Match '-PrincipalId <id of the new account breakglass@contoso\.onmicrosoft\.com>'
            $r.GlobalAdminAssigned | Should -BeFalse
            $r.GlobalAdmin | Should -Be 'Planned'
            $r.PoliciesPlanned | Should -Be @('Require MFA', 'Block legacy')
            $r.PoliciesUpdated.Count | Should -Be 0
            $r.WhatIf | Should -BeTrue
            $r.Password | Should -BeNullOrEmpty
        }
        It 'creates, assigns and excludes on a real run' {
            $r = New-M365BreakGlassAccount -Domain contoso.onmicrosoft.com 6>$null
            & $script:Writes | Should -Be @('New-MgUser', 'New-MgRoleManagementDirectoryRoleAssignment', 'Invoke-MgGraphRequest PATCH', 'Invoke-MgGraphRequest PATCH')
            $r.Created | Should -BeTrue
            $r.GlobalAdminAssigned | Should -BeTrue
            $r.PoliciesUpdated | Should -Be @('Require MFA', 'Block legacy')
            $r.Password.Length | Should -Be 64
            $r.Completed | Should -BeTrue
            $global:G.Writes[1].Params.PrincipalId | Should -Be $r.Id
        }
        It 'refuses an existing account without -AdoptExisting: no role, no CA change' {
            $global:G.Users.Add((New-FakeUser 'breakglass@contoso.onmicrosoft.com' $script:Id.bg))
            { New-M365BreakGlassAccount -Domain contoso.onmicrosoft.com } | Should -Throw '*already exists*'
            $global:G.Writes.Count | Should -Be 0
        }
        It 'with -AdoptExisting says "password NOT changed" in the result and the plan' {
            $global:G.Users.Add((New-FakeUser 'breakglass@contoso.onmicrosoft.com' $script:Id.bg))
            Start-M365ChangeRecording
            $r = New-M365BreakGlassAccount -Domain contoso.onmicrosoft.com -AdoptExisting -Password 'Typed-Password-123456!' -WhatIf -WarningVariable w -WarningAction SilentlyContinue
            $rec = Stop-M365ChangeRecording
            $r.Adopted | Should -BeTrue
            $r.Note | Should -Be 'existing account - password NOT changed'
            $r.PasswordChanged | Should -BeFalse
            @($rec | Where-Object { $_.Command -like 'New-MgUser*' }).Count | Should -Be 0
            @($rec | ForEach-Object { $_.Action }) | ForEach-Object { $_ | Should -Match 'password NOT changed' }
            "$w" | Should -Match 'NOT applied'
        }
        It 'returns the password (never throws it away) when the role assignment fails after creation' {
            $global:G.Fail['New-MgRoleManagementDirectoryRoleAssignment'] = 'Graph 403: insufficient privileges'
            $r = New-M365BreakGlassAccount -Domain contoso.onmicrosoft.com 6>$null 3>$null
            $r.Created | Should -BeTrue
            $r.Password.Length | Should -Be 64
            $r.Completed | Should -BeFalse
            "$($r.Errors)" | Should -Match 'insufficient privileges'
            $r.GlobalAdmin | Should -Be 'Failed'
            @($global:G.Writes | Where-Object Command -like 'Invoke-MgGraphRequest*').Count | Should -Be 0
        }
        It 'refuses a domain that is not onmicrosoft.com' {
            { New-M365BreakGlassAccount -Domain contoso.com -WhatIf } | Should -Throw '*onmicrosoft.com*'
        }
    }

    Context 'New-M365AdminAccount (H4, M2)' {
        BeforeEach {
            $global:G.RoleDefs = @([pscustomobject]@{ Id = $script:Id.ga; DisplayName = 'Global Administrator' }, [pscustomobject]@{ Id = $script:Id.exo; DisplayName = 'Exchange Administrator' })
        }
        It 'requires an onmicrosoft.com domain' {
            { New-M365AdminAccount -UpnPrefix a -DisplayName A -Roles 'Exchange Administrator' -Domain contoso.com -WhatIf } | Should -Throw '*onmicrosoft.com*'
        }
        It 'resolves every role before creating anything' {
            { New-M365AdminAccount -UpnPrefix a -DisplayName A -Roles 'Exchange Administrator', 'Exchange Admin' -Domain contoso.onmicrosoft.com } | Should -Throw "*'Exchange Admin' not found*"
            $global:G.Writes.Count | Should -Be 0
        }
        It 'refuses an existing account without -AdoptExisting' {
            $global:G.Users.Add((New-FakeUser 'a@contoso.onmicrosoft.com' $script:Id.bob))
            { New-M365AdminAccount -UpnPrefix a -DisplayName A -Roles 'Exchange Administrator' -Domain contoso.onmicrosoft.com } | Should -Throw '*already exists*'
            $global:G.Writes.Count | Should -Be 0
        }
        It 'plans every role for the new account under -WhatIf' {
            Start-M365ChangeRecording
            $r = New-M365AdminAccount -UpnPrefix a -DisplayName A -Roles 'Exchange Administrator', 'Global Administrator' -Domain contoso.onmicrosoft.com -WhatIf
            $rec = Stop-M365ChangeRecording
            $rec.Count | Should -Be 3
            $r.RolesPlanned | Should -Be @('Exchange Administrator', 'Global Administrator')
            $r.RolesAssigned.Count | Should -Be 0
            $global:G.Writes.Count | Should -Be 0
        }
    }

    Context 'Set-M365TechnicalContact' {
        It 'handles an empty contact list (no null entry is sent)' {
            $global:G.Org = [pscustomobject]@{ Id = 'org1'; DisplayName = 'Contoso'; TechnicalNotificationMails = $null; SecurityComplianceNotificationMails = $null }
            $r = Set-M365TechnicalContact -Email support@msp.example -IncludeSecurityCompliance 6>$null
            $r.Updated | Should -BeTrue
            $p = $global:G.Writes[0].Params
            , $p.TechnicalNotificationMails | Should -Be @('support@msp.example')
            , $p.SecurityComplianceNotificationMails | Should -Be @('support@msp.example')
        }
        It 'keeps existing contacts and changes nothing under -WhatIf' {
            $global:G.Org = [pscustomobject]@{ Id = 'org1'; DisplayName = 'Contoso'; TechnicalNotificationMails = @('owner@contoso.com'); SecurityComplianceNotificationMails = @() }
            Start-M365ChangeRecording
            $r = Set-M365TechnicalContact -Email support@msp.example -WhatIf
            $rec = Stop-M365ChangeRecording
            $r.Updated | Should -BeFalse
            $r.WhatIf | Should -BeTrue
            $rec[0].Text | Should -Be "[contoso.onmicrosoft.com] Update-MgOrganization -OrganizationId 'org1' -TechnicalNotificationMails @('owner@contoso.com', 'support@msp.example')"
            $global:G.Writes.Count | Should -Be 0
        }
    }

    Context 'Get-M365GdapRelationship' {
        BeforeEach {
            $global:G.Relationships = @(
                [pscustomobject]@{ DisplayName = 'r1'; Customer = [pscustomobject]@{ DisplayName = 'ABC'; TenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }; Status = 'active'; AccessDetails = [pscustomobject]@{ UnifiedRoles = @() }; EndDateTime = $null; AutoExtendDuration = $null; Id = '1' }
                [pscustomobject]@{ DisplayName = 'r2'; Customer = [pscustomobject]@{ DisplayName = 'ABC Plumbing'; TenantId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' }; Status = 'active'; AccessDetails = [pscustomobject]@{ UnifiedRoles = @() }; EndDateTime = $null; AutoExtendDuration = $null; Id = '2' }
            )
        }
        It 'matches the customer name exactly (case-insensitive), not as a substring' {
            @(Get-M365GdapRelationship -CustomerName 'abc').Id | Should -Be @('1')
        }
        It 'accepts a domain for -CustomerTenantId' {
            Mock -ModuleName EntraHelpers Resolve-M365TenantId { 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' }
            @(Get-M365GdapRelationship -CustomerTenantId abcplumbing.com).Id | Should -Be @('2')
        }
    }

    Context 'Get-M365LicenseSummary and Remove-M365UserLicense' {
        It 'computes available units per SKU' {
            $global:G.Skus = @([pscustomobject]@{ SkuPartNumber = 'SPE_E3'; SkuId = 's1'; ConsumedUnits = 7; CapabilityStatus = 'Enabled'; PrepaidUnits = [pscustomobject]@{ Enabled = 10; Warning = 0; Suspended = 0 } })
            $r = Get-M365LicenseSummary
            $r.Available | Should -Be 3
            $r.Sku | Should -Be 'SPE_E3'
        }
        It 'removes only direct licenses and reports group-assigned ones' {
            $global:G.Users.Add((New-FakeUser 'jane@customer.example' $script:Id.jane -States @([pscustomobject]@{ SkuId = 's1'; AssignedByGroup = $null }, [pscustomobject]@{ SkuId = 's2'; AssignedByGroup = 'g1' })))
            $global:G.Skus = @([pscustomobject]@{ SkuId = 's1'; SkuPartNumber = 'SPE_E3' }, [pscustomobject]@{ SkuId = 's2'; SkuPartNumber = 'VISIO' })
            $r = Remove-M365UserLicense -UserPrincipalName jane@customer.example -WarningAction SilentlyContinue 6>$null
            $r.Removed | Should -Be @('SPE_E3')
            $r.GroupAssigned | Should -Be @('VISIO')
            $global:G.Writes[0].Params.RemoveLicenses | Should -Be @('s1')
        }
        It 'does not call Set-MgUserLicense under -WhatIf, and reports nothing as removed' {
            $global:G.Users.Add((New-FakeUser 'jane@customer.example' $script:Id.jane -States @([pscustomobject]@{ SkuId = 's1'; AssignedByGroup = $null })))
            $r = Remove-M365UserLicense -UserPrincipalName jane@customer.example -WhatIf
            $global:G.Writes.Count | Should -Be 0
            $r.Removed.Count | Should -Be 0
            $r.ToRemove | Should -Be @('s1')
            $r.WhatIf | Should -BeTrue
        }
    }

    Context 'Disable-M365UserSignIn' {
        It 'plans block and revoke under -WhatIf without writing, and runs both for real' {
            $global:G.Users.Add((New-FakeUser 'jane@customer.example' $script:Id.jane))
            Start-M365ChangeRecording
            $null = Disable-M365UserSignIn -UserPrincipalName jane@customer.example -WhatIf
            $rec = Stop-M365ChangeRecording
            $global:G.Writes.Count | Should -Be 0
            $rec[0].Text | Should -Be "[contoso.onmicrosoft.com] Update-MgUser -UserId '$($script:Id.jane)' -BodyParameter @{ accountEnabled = `$false }"
            $rec[1].Text | Should -Be "[contoso.onmicrosoft.com] Revoke-MgUserSignInSession -UserId '$($script:Id.jane)'"
            $r = Disable-M365UserSignIn -UserPrincipalName jane@customer.example 6>$null
            $r.Disabled | Should -BeTrue
            $r.SessionsRevoked | Should -BeTrue
            & $script:Writes | Should -Be @('Update-MgUser', 'Revoke-MgUserSignInSession')
        }
    }

    Context 'Add-M365UserLicense (M9)' {
        BeforeEach {
            $global:G.Skus = @(
                [pscustomobject]@{ SkuPartNumber = 'SPB'; SkuId = 'spb'; ConsumedUnits = 4; PrepaidUnits = [pscustomobject]@{ Enabled = 5 } }
                [pscustomobject]@{ SkuPartNumber = 'SPE_E3'; SkuId = 'e3'; ConsumedUnits = 10; PrepaidUnits = [pscustomobject]@{ Enabled = 10 } }
            )
        }
        It 'assigns only SKUs the user lacks and matches names case-insensitively' {
            $global:G.Users.Add((New-FakeUser 'jane@customer.example' $script:Id.jane -Skus 'e3'))
            $r = Add-M365UserLicense -UserPrincipalName jane@customer.example -Sku 'spb', 'SPE_E3' 6>$null
            $r.Assigned | Should -Be @('SPB')
            $r.AlreadyHad | Should -Be @('SPE_E3')
            $add = @($global:G.Writes[0].Params.AddLicenses)
            $add.Count | Should -Be 1
            $add[0].skuId | Should -Be 'spb'
        }
        It 'reports "already licensed" instead of throwing when every SKU is held' {
            $global:G.Users.Add((New-FakeUser 'jane@customer.example' $script:Id.jane -Skus 'spb'))
            $r = Add-M365UserLicense -UserPrincipalName jane@customer.example -Sku 'SPB'
            $r.Status | Should -Be 'AlreadyLicensed'
            $r.Assigned.Count | Should -Be 0
            $global:G.Writes.Count | Should -Be 0
        }
        It 'refuses a SKU the tenant does not own and names the available ones' {
            $global:G.Users.Add((New-FakeUser 'jane@customer.example' $script:Id.jane))
            { Add-M365UserLicense -UserPrincipalName jane@customer.example -Sku 'VISIO' } | Should -Throw '*not in this tenant*SPB*'
        }
        It 'requires a usage location' {
            $global:G.Users.Add((New-FakeUser 'jane@customer.example' $script:Id.jane -Usage ''))
            { Add-M365UserLicense -UserPrincipalName jane@customer.example -Sku 'SPB' } | Should -Throw '*usageLocation*'
        }
        It 'warns when a SKU has no free units but still attempts' {
            $global:G.Users.Add((New-FakeUser 'jane@customer.example' $script:Id.jane))
            $r = Add-M365UserLicense -UserPrincipalName jane@customer.example -Sku 'SPE_E3' -WarningVariable w -WarningAction SilentlyContinue 6>$null
            $w | Should -Match 'No free units'
            $r.Assigned | Should -Be @('SPE_E3')
        }
        It 'plans for a user an earlier dry-run step would create (placeholder id), without looking the user up' {
            Start-M365ChangeRecording
            $r = Add-M365UserLicense -UserPrincipalName new@customer.example -Sku 'SPB' -UserId (New-M365Placeholder 'id of the new user') -WhatIf
            $rec = Stop-M365ChangeRecording
            $r.Status | Should -Be 'Planned'
            $rec[0].Text | Should -Be "[contoso.onmicrosoft.com] Set-MgUserLicense -UserId <id of the new user> -AddLicenses @(@{ skuId = 'spb' }) -RemoveLicenses @()"
            @($global:G.Reads | Where-Object { $_ -like 'Get-MgUser*' }).Count | Should -Be 0
        }
    }

    Context 'Add-M365GroupMember (H6)' {
        BeforeEach {
            $global:G.Users.Add((New-FakeUser 'jane@customer.example' $script:Id.jane))
            $global:G.Groups = @(
                [pscustomobject]@{ Id = $script:Id.sales1; DisplayName = 'Sales'; GroupTypes = @('Unified'); MailEnabled = $true; SecurityEnabled = $false; OnPremisesSyncEnabled = $null }
                [pscustomobject]@{ Id = $script:Id.sales2; DisplayName = 'Sales'; GroupTypes = @(); MailEnabled = $false; SecurityEnabled = $true; OnPremisesSyncEnabled = $null }
                [pscustomobject]@{ Id = $script:Id.staff; DisplayName = 'All Staff'; GroupTypes = @(); MailEnabled = $false; SecurityEnabled = $true; OnPremisesSyncEnabled = $null }
                [pscustomobject]@{ Id = $script:Id.dl; DisplayName = 'Office DL'; GroupTypes = @(); MailEnabled = $true; SecurityEnabled = $false; OnPremisesSyncEnabled = $null }
            )
        }
        It 'refuses a name that matches two groups and lists both ids, before any change' {
            { Add-M365GroupMember -UserPrincipalName jane@customer.example -GroupName 'All Staff', 'Sales' } | Should -Throw "*2 groups are named 'Sales'*$($script:Id.sales1)*$($script:Id.sales2)*"
            $global:G.Writes.Count | Should -Be 0
        }
        It 'accepts a group id' {
            $r = @(Add-M365GroupMember -UserPrincipalName jane@customer.example -GroupName $script:Id.sales2 6>$null)
            $r[0].Added | Should -BeTrue
            $global:G.Writes[0].Params.GroupId | Should -Be $script:Id.sales2
            $global:G.Writes[0].Params.DirectoryObjectId | Should -Be $script:Id.jane
        }
        It 'refuses a missing group or a distribution list before the first change' {
            { Add-M365GroupMember -UserPrincipalName jane@customer.example -GroupName 'All Staff', 'Nope' } | Should -Throw "*No group is named 'Nope'*"
            { Add-M365GroupMember -UserPrincipalName jane@customer.example -GroupName 'All Staff', 'Office DL' } | Should -Throw '*distribution list*'
            $global:G.Writes.Count | Should -Be 0
        }
        It 'skips an existing membership' {
            $global:G.Members[$script:Id.staff] = @($script:Id.jane)
            $r = @(Add-M365GroupMember -UserPrincipalName jane@customer.example -GroupName 'All Staff')
            $r[0].Reason | Should -Be 'already a member'
            $global:G.Writes.Count | Should -Be 0
        }
    }

    Context 'Get-M365UserReview (M12)' {
        BeforeEach {
            foreach ($u in 'jane', 'bob', 'mgr') { $global:G.Users.Add((New-FakeUser "$u@customer.example" $script:Id[$u])) }
            $global:G.RoleDefs = @([pscustomobject]@{ Id = $script:Id.ga; DisplayName = 'Global Administrator' }, [pscustomobject]@{ Id = $script:Id.exo; DisplayName = 'Exchange Administrator' })
            $global:G.RoleAssignments = @(
                [pscustomobject]@{ PrincipalId = $script:Id.admins; RoleDefinitionId = $script:Id.exo; DirectoryScopeId = '/'; Principal = [pscustomobject]@{ AdditionalProperties = @{ '@odata.type' = '#microsoft.graph.group'; displayName = 'Exchange Admins' } } }
            )
            $global:G.Members[$script:Id.admins] = @($script:Id.bob)
            $global:G.Eligibility = @(
                [pscustomobject]@{ PrincipalId = $script:Id.jane; RoleDefinitionId = $script:Id.ga; DirectoryScopeId = '/'; Principal = [pscustomobject]@{ AdditionalProperties = @{ '@odata.type' = '#microsoft.graph.user' } } }
            )
        }
        It 'counts group-held and PIM-eligible roles as admin' {
            $rows = @(Get-M365UserReview)
            $jane = $rows | Where-Object UserPrincipalName -eq 'jane@customer.example'
            $bob = $rows | Where-Object UserPrincipalName -eq 'bob@customer.example'
            $mgr = $rows | Where-Object UserPrincipalName -eq 'mgr@customer.example'
            $jane.IsAdmin | Should -BeTrue
            $jane.EligibleRoles | Should -Be @('Global Administrator')
            $bob.IsAdmin | Should -BeTrue
            $bob.Roles | Should -Be @('Exchange Administrator (via group Exchange Admins)')
            $mgr.IsAdmin | Should -Be $false
        }
        It 'marks IsAdmin Unknown (never False) when the roles cannot be read' {
            $global:G.Fail['Get-MgRoleManagementDirectoryRoleAssignment'] = 'Forbidden'
            $rows = @(Get-M365UserReview -WarningVariable w -WarningAction SilentlyContinue)
            ($rows | Where-Object UserPrincipalName -eq 'mgr@customer.example').IsAdmin | Should -Be 'Unknown'
            ($rows | Where-Object UserPrincipalName -eq 'jane@customer.example').IsAdmin | Should -BeTrue
            "$w" | Should -Match 'Could not read role assignments'
        }
        It 'treats "PIM needs a premium license" as no eligible roles, with a warning' {
            $global:G.Fail['Get-MgRoleManagementDirectoryRoleEligibilitySchedule'] = 'AadPremiumLicenseRequired: the tenant needs an Entra ID P2 license'
            $rows = @(Get-M365UserReview -WarningVariable w -WarningAction SilentlyContinue)
            ($rows | Where-Object UserPrincipalName -eq 'mgr@customer.example').IsAdmin | Should -Be $false
            "$w" | Should -Match 'PIM eligibility not available'
        }
    }

    Context 'New-M365User (C2 building block, lows)' {
        It 'creates a person with forced password change and the usage location' {
            $r = New-M365User -UserPrincipalName jane.doe@customer.example -DisplayName 'Jane Doe' -GivenName Jane -Surname Doe -JobTitle 'OM' 6>$null
            $r.Created | Should -BeTrue
            $r.Password.Length | Should -Be 20
            $b = $global:G.Writes[0].Params.BodyParameter
            $b.passwordProfile.forceChangePasswordNextSignIn | Should -BeTrue
            $b.usageLocation | Should -Be 'US'
            $b.mailNickname | Should -Be 'jane.doe'
            $b.givenName | Should -Be 'Jane'
            $b.jobTitle | Should -Be 'OM'
            $b.ContainsKey('passwordPolicies') | Should -BeFalse
        }
        It 'reports an existing user (AlreadyExisted) and changes nothing' {
            $global:G.Users.Add((New-FakeUser 'jane.doe@customer.example' $script:Id.jane))
            $r = New-M365User -UserPrincipalName jane.doe@customer.example -DisplayName 'Jane Doe' -WarningAction SilentlyContinue
            $r.Created | Should -BeFalse
            $r.AlreadyExisted | Should -BeTrue
            $r.Id | Should -Be $script:Id.jane
            $global:G.Writes.Count | Should -Be 0
        }
        It 'stops before creating anything when the manager does not exist' {
            { New-M365User -UserPrincipalName jane.doe@customer.example -DisplayName 'Jane Doe' -ManagerUpn nobody@customer.example } | Should -Throw '*Manager nobody@customer.example not found*'
            $global:G.Writes.Count | Should -Be 0
        }
        It 'keeps the created user and password when setting the manager fails' {
            $global:G.Users.Add((New-FakeUser 'boss@customer.example' $script:Id.mgr))
            $global:G.Fail['Set-MgUserManagerByRef'] = 'Graph 500'
            $r = New-M365User -UserPrincipalName jane.doe@customer.example -DisplayName 'Jane Doe' -ManagerUpn boss@customer.example -WarningAction SilentlyContinue 6>$null
            $r.Created | Should -BeTrue
            $r.Password.Length | Should -Be 20
            $r.ManagerSet | Should -BeFalse
            $r.ManagerError | Should -Match 'Graph 500'
        }
        It 'plans the user and the manager (placeholder id) under -WhatIf' {
            $global:G.Users.Add((New-FakeUser 'boss@customer.example' $script:Id.mgr))
            Start-M365ChangeRecording
            $r = New-M365User -UserPrincipalName jane.doe@customer.example -DisplayName 'Jane Doe' -ManagerUpn boss@customer.example -WhatIf
            $rec = Stop-M365ChangeRecording
            $global:G.Writes.Count | Should -Be 0
            $r.WhatIf | Should -BeTrue
            $r.AlreadyExisted | Should -BeFalse
            $rec[1].Text | Should -Match "Set-MgUserManagerByRef -UserId <id of the new user jane\.doe@customer\.example> -BodyParameter @\{ '@odata\.id' = '.+/users/$($script:Id.mgr)' \}"
        }
    }

    Context 'New-M365TemporaryAccessPass' {
        It 'returns the pass even when Graph sends no start time' {
            $global:G.Users.Add((New-FakeUser 'jane@customer.example' $script:Id.jane))
            $r = New-M365TemporaryAccessPass -UserPrincipalName jane@customer.example 6>$null
            $r.Pass | Should -Be 'TAP-123'
            $r.Issued | Should -BeTrue
            $r.ExpiresAt | Should -BeGreaterThan (Get-Date)
        }
        It 'plans for a placeholder user under -WhatIf' {
            Start-M365ChangeRecording
            $r = New-M365TemporaryAccessPass -UserPrincipalName new@customer.example -UserId (New-M365Placeholder 'id of the new user') -WhatIf
            $rec = Stop-M365ChangeRecording
            $r.Issued | Should -BeFalse
            $rec[0].Text | Should -Be '[contoso.onmicrosoft.com] New-MgUserAuthenticationTemporaryAccessPassMethod -UserId <id of the new user> -BodyParameter @{ isUsableOnce = $true; lifetimeInMinutes = 480 }'
            $global:G.Writes.Count | Should -Be 0
        }
    }
}

Describe 'entra/ and lifecycle/ scripts (static checks)' {
    BeforeEach {
        Mock Test-M365ReadOnly -ModuleName M365Helpers { $false }
    }

    BeforeAll {
        $root = Join-Path $PSScriptRoot '..' 'scripts' 'powershell'
        $script:Scripts = @(Get-ChildItem (Join-Path $root 'entra'), (Join-Path $root 'lifecycle') -Filter '*.ps1' | ForEach-Object {
                $errors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors)
                [pscustomobject]@{ Name = $_.BaseName; Path = $_.FullName; Ast = $ast; Errors = $errors; Text = (Get-Content $_.FullName -Raw) }
            })
        $script:CallsTo = {
            param($s, [string]$Name)
            @($s.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name }, $true))
        }
    }
    It 'every script parses' {
        foreach ($s in $script:Scripts) { @($s.Errors).Count | Should -Be 0 -Because $s.Name }
    }
    It 'Assert-M365Graph gets one scope list and no stray positional argument (the M2 scopes typo)' {
        foreach ($s in $script:Scripts) {
            foreach ($call in & $script:CallsTo $s 'Assert-M365Graph') {
                $positional = @($call.CommandElements | Select-Object -Skip 1 | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] })
                $named = @($call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] }).Count
                $positional.Count | Should -Be $named -Because "$($s.Name): every argument belongs to a named parameter"
                $call.Extent.Text | Should -Not -Match "''" -Because "$($s.Name): no empty scope"
            }
        }
    }
    It 'every variable a script reads is declared or assigned (catches the undeclared $GeneratePassword)' {
        $auto = 'true', 'false', 'null', 'PSScriptRoot', 'WhatIfPreference', 'ErrorActionPreference', 'PSCmdlet', '_', 'args', 'Matches', 'PSBoundParameters', 'this', 'input', 'env', 'script', 'global'
        foreach ($s in $script:Scripts) {
            $assigned = @($s.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
                    ForEach-Object { $_.Left.Extent.Text -replace '^\[[^\]]+\]', '' -replace '^\$(script:|global:)?', '' -replace '[\[.].*$', '' })
            $params = @($s.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true) | ForEach-Object { $_.Name.VariablePath.UserPath })
            $loops = @($s.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true) | ForEach-Object { $_.Variable.VariablePath.UserPath })
            $known = @($assigned) + @($params) + @($loops) + $auto
            $used = @($s.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.VariablePath.UserPath -replace '^(script|global|env):', '' } | Sort-Object -Unique)
            foreach ($v in $used) { $known | Should -Contain $v -Because "$($s.Name) reads `$$v" }
        }
    }
    It 'Exchange-side scripts take a mandatory -Organization and sign in with -SignInAs (H1)' {
        foreach ($s in $script:Scripts | Where-Object { (& $script:CallsTo $_ 'Assert-M365Exchange').Count -gt 0 -and $_.Name -ne 'Invoke-M365UserOnboarding' }) {
            $cmd = Get-Command $s.Path
            $cmd.Parameters.ContainsKey('Organization') | Should -BeTrue -Because $s.Name
            @($cmd.Parameters['Organization'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count | Should -Be 1 -Because "$($s.Name) -Organization is mandatory"
            $cmd.Parameters.ContainsKey('SignInAs') | Should -BeTrue -Because $s.Name
            foreach ($call in & $script:CallsTo $s 'Assert-M365Exchange') {
                $call.Extent.Text | Should -Match '-Organization \$' -Because $s.Name
                $call.Extent.Text | Should -Match '-UserPrincipalName \$SignInAs' -Because $s.Name
            }
        }
    }
    It 'scripts that use Graph and Exchange check both are the same tenant (-ExpectedTenantId)' {
        foreach ($s in $script:Scripts | Where-Object { (& $script:CallsTo $_ 'Assert-M365Exchange').Count -gt 0 -and (& $script:CallsTo $_ 'Assert-M365Graph').Count -gt 0 }) {
            foreach ($call in & $script:CallsTo $s 'Assert-M365Exchange') { $call.Extent.Text | Should -Match '-ExpectedTenantId' -Because $s.Name }
        }
    }
    It 'every userPrincipalName filter escapes apostrophes' {
        foreach ($s in $script:Scripts) {
            foreach ($m in [regex]::Matches($s.Text, "userPrincipalName eq '[^""]*'")) { $m.Value | Should -Match "Replace\(""'"", ""''""\)" -Because $s.Name }
        }
    }
    It 'scripts that can stop prompting name the switch in their Interactive note' {
        foreach ($n in 'New-M365BreakGlassAccount', 'New-M365AdminAccount', 'New-M365User', 'Invoke-M365UserOnboarding') {
            $s = $script:Scripts | Where-Object Name -eq $n
            $s.Text | Should -Match 'Interactive: yes \(.*unless -GeneratePassword\)' -Because $n
            (Get-Command $s.Path).Parameters.ContainsKey('GeneratePassword') | Should -BeTrue -Because $n
        }
    }
}
