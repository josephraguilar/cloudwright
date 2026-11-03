#region Module setup ----------------------------------------------------------
#   WHAT   Strict mode. Graph scopes each function needs are listed in its help so
#          the calling script can pass them to Assert-M365Graph up front.
#   WHY    One consent prompt at the start of a run beats one per step.
#   GOTCHA Every change goes through Invoke-M365Change (M365Helpers): it shows the exact
#          Graph command with the verified tenant, asks ShouldProcess, and on a real run
#          runs exactly that. Nothing in this module calls a Graph write directly.
Set-StrictMode -Version Latest
#   GOTCHA The repo is not on PSModulePath, so M365Helpers cannot be a manifest
#          RequiredModule (Test-ModuleManifest would fail). Load it by path instead.
if (-not (Get-Module -Name M365Helpers)) {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Helpers' 'M365Helpers.psd1') -ErrorAction Stop
}
$script:GraphBase = 'https://graph.microsoft.com/v1.0'
$script:GuidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
#endregion

#region Internal helpers ----------------------------------------------------------
function Test-M365Placeholder {
    # Internal. True when the value is a New-M365Placeholder stand-in (a dry run's "id of the user created above").
    param($Value)
    return ($null -ne $Value -and $Value.PSObject.TypeNames -contains 'M365.Placeholder')
}

function Get-M365ObjectProperty {
    # Internal. One property of a Graph object or hashtable; $null when it is absent (strict-mode safe).
    param($InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject[$Name] }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Assert-M365UpnShape {
    # Internal. Throws unless the value is one plain address: no spaces, no wildcards.
    param([string]$UserPrincipalName, [string]$What = 'User principal name')
    if ($UserPrincipalName -notmatch '^[^@\s*?]+@[^@\s*?]+\.[^@\s*?]+$') {
        throw "$What '$UserPrincipalName' is not one exact address (no spaces or wildcards). Nothing was changed."
    }
}

function Get-M365EntraUserByUpn {
    # Internal. Exactly one user by UPN, or $null when there is none. The UPN is escaped for the OData
    # filter (o'brien@), a read error is thrown (never read as "not found"), and a result that is not
    # that exact UPN is refused.
    param([Parameter(Mandatory)][string]$UserPrincipalName, [string[]]$Property = @())
    Assert-M365UpnShape -UserPrincipalName $UserPrincipalName
    $props = @(@('id', 'userPrincipalName', 'displayName') + @($Property) | Where-Object { $_ } | Select-Object -Unique)
    $safe = $UserPrincipalName.Replace("'", "''")
    $found = @(Get-MgUser -Filter "userPrincipalName eq '$safe'" -Property $props -ErrorAction Stop)
    if ($found.Count -eq 0) { return $null }
    if ($found.Count -gt 1) { throw "$($found.Count) users match '$UserPrincipalName' (ids: $(($found | ForEach-Object { $_.Id }) -join ', ')). Nothing was changed." }
    $upn = Get-M365ObjectProperty $found[0] 'UserPrincipalName'
    if ($upn -and "$upn" -ne $UserPrincipalName) { throw "Looked up '$UserPrincipalName' but Graph returned '$upn'. Nothing was changed." }
    return $found[0]
}

function Resolve-M365TargetUser {
    # Internal. The one user a change is for.
    #   -UserId placeholder: a user an earlier step of this dry run would create. Returned as Planned,
    #                        with nothing to read (no licenses, no groups yet).
    #   -UserId real id:     read by id, retried briefly (a user created seconds ago may not be readable
    #                        yet), and checked to carry -UserPrincipalName.
    #   otherwise:           exact UPN lookup. Throws when there is no such user.
    param([Parameter(Mandatory)][string]$UserPrincipalName, $UserId, [string[]]$Property = @())
    if (Test-M365Placeholder $UserId) {
        return [pscustomobject]@{ Id = $UserId; UserPrincipalName = $UserPrincipalName; Planned = $true; User = $null }
    }
    if ($UserId) {
        if ("$UserId" -notmatch $script:GuidPattern) { throw "-UserId must be the user's object id (GUID), not '$UserId'." }
        $props = @(@('id', 'userPrincipalName', 'displayName') + @($Property) | Where-Object { $_ } | Select-Object -Unique)
        $user = $null
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try { $user = Get-MgUser -UserId "$UserId" -Property $props -ErrorAction Stop; break }
            catch {
                if ($attempt -eq 5 -or $_.Exception.Message -notmatch 'ResourceNotFound|does not exist|\b404\b') { throw }
                Start-Sleep -Seconds 3
            }
        }
        $upn = Get-M365ObjectProperty $user 'UserPrincipalName'
        if ($upn -and "$upn" -ne $UserPrincipalName) { throw "User id $UserId is '$upn', not '$UserPrincipalName'. Nothing was changed." }
    } else {
        $user = Get-M365EntraUserByUpn -UserPrincipalName $UserPrincipalName -Property $Property
        if (-not $user) { throw "User $UserPrincipalName not found. Nothing was changed." }
    }
    return [pscustomobject]@{ Id = "$($user.Id)"; UserPrincipalName = $UserPrincipalName; Planned = $false; User = $user }
}

function Get-M365PrincipalInfo {
    # Internal. Type (user, group, servicePrincipal) and display name of an expanded role principal.
    param($Principal)
    $extra = Get-M365ObjectProperty $Principal 'AdditionalProperties'
    $type = $null; $name = $null
    if ($null -ne $extra) {
        try { $type = $extra['@odata.type']; $name = $extra['displayName'] } catch { $type = $null }
    }
    if (-not $type) { $type = Get-M365ObjectProperty $Principal '@odata.type' }
    if (-not $type) { $type = Get-M365ObjectProperty $Principal 'OdataType' }
    if (-not $name) { $name = Get-M365ObjectProperty $Principal 'DisplayName' }
    [pscustomobject]@{ Type = $(if ($type) { "$type" -replace '^#?microsoft\.graph\.', '' } else { $null }); DisplayName = $name }
}

function Get-M365RoleDefinitionExact {
    # Internal. Exactly one Entra role definition by display name; throws on none or several.
    param([Parameter(Mandatory)][string]$RoleName)
    if ($RoleName -match '[*?]') { throw "Role name '$RoleName' must be an exact name, not a wildcard." }
    $safe = $RoleName.Replace("'", "''")
    $roles = @(Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq '$safe'" -ErrorAction Stop |
            Where-Object { "$(Get-M365ObjectProperty $_ 'DisplayName')" -eq $RoleName })
    if ($roles.Count -eq 0) { throw "Role '$RoleName' not found. Check the spelling against Entra's role list. Nothing was changed." }
    if ($roles.Count -gt 1) { throw "$($roles.Count) roles are named '$RoleName' (ids: $(($roles | ForEach-Object { $_.Id }) -join ', ')). Nothing was changed." }
    return $roles[0]
}
#endregion

#region Review -----------------------------------------------------------------
function Get-M365UserReview {
    <#
    .SYNOPSIS
        Lists every user in the tenant with the facts needed to decide keep / remove / de-admin.
    .DESCRIPTION
        One row per user: enabled, type (Member/Guest), synced from AD, licenses (SKU part
        numbers), directory roles held, last sign-in, days since sign-in, and optionally
        registered MFA methods. This is the input to SOP #5 step 1 (review accounts) and
        step 2 (who holds admin rights). It never changes anything.

        Roles come from the unified role API, so they include roles held through a
        role-assignable group ("via group ...") and roles scoped to an administrative unit,
        and PIM-eligible roles are listed in EligibleRoles. IsAdmin is $true, $false, or
        'Unknown' when the roles could not be read (never a silent $false).

        Graph scopes: User.Read.All, Directory.Read.All, RoleManagement.Read.Directory,
        AuditLog.Read.All (sign-in dates; needs Entra ID P1 or the column is blank),
        UserAuthenticationMethod.Read.All when -IncludeMfa.
    .PARAMETER IncludeMfa
        Also fetch each user's authentication methods. One extra call per user.
    .PARAMETER StaleDays
        Flag users with no sign-in in this many days. Default 90.
    .EXAMPLE
        Get-M365UserReview | Sort-Object DaysSinceSignIn -Descending | Format-Table
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$IncludeMfa,

        [Parameter()]
        [int]$StaleDays = 90
    )

    #region 1. Users and licenses -------------------------------------------
    #   WHAT   Pull users once with the properties we need. Try signInActivity,
    #          fall back without it.
    #   WHY    signInActivity throws on tenants without a P1 license. Better a
    #          blank column than a dead script.
    $props = 'id', 'displayName', 'userPrincipalName', 'accountEnabled', 'userType', 'assignedLicenses', 'onPremisesSyncEnabled', 'createdDateTime', 'mail'
    $users = $null
    try {
        $users = @(Get-MgUser -All -Property ($props + 'signInActivity') -ErrorAction Stop)
        $haveSignIn = $true
    } catch {
        Write-Warning "Could not read signInActivity ($($_.Exception.Message)). Last sign-in will be blank."
        $users = @(Get-MgUser -All -Property $props -ErrorAction Stop)
        $haveSignIn = $false
    }
    $userIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($u in $users) { $null = $userIds.Add("$($u.Id)") }
    $skuNames = @{}
    try { foreach ($sku in Get-MgSubscribedSku -All -ErrorAction Stop) { $skuNames[$sku.SkuId] = $sku.SkuPartNumber } }
    catch { Write-Warning "Could not read license names ($($_.Exception.Message)). Licenses show as SKU ids." }
    #endregion

    #region 2. Role assignments, eligibility and role-assignable groups --------------
    #   WHAT   Map user id -> role names from every active assignment (direct, or through a
    #          role-assignable group) and every PIM-eligible assignment.
    #   WHY    Step 2 of the SOP is about who keeps admin rights. The old activated-role list
    #          missed PIM-eligible admins and group-held roles, and hid read errors.
    #   GOTCHA A read error marks every user without a found role as IsAdmin 'Unknown'. PIM
    #          eligibility needs Entra ID P2: without it there is nothing to activate, so a
    #          "needs a premium license" reply is a warning, not Unknown.
    $active = @{}; $eligible = @{}
    $rolesKnown = $true
    $roleNames = @{}
    $groupMembers = @{}
    $add = {
        param([hashtable]$Map, [string]$UserId, [string]$Text)
        if (-not $Map.ContainsKey($UserId)) { $Map[$UserId] = [System.Collections.Generic.List[string]]::new() }
        if (-not $Map[$UserId].Contains($Text)) { $Map[$UserId].Add($Text) }
    }
    $record = {
        param([hashtable]$Map, $Assignment)
        $roleId = "$(Get-M365ObjectProperty $Assignment 'RoleDefinitionId')"
        $label = if ($roleNames.ContainsKey($roleId)) { $roleNames[$roleId] } else { $roleId }
        $scope = "$(Get-M365ObjectProperty $Assignment 'DirectoryScopeId')"
        if ($scope -and $scope -ne '/') { $label += " (scope $scope)" }
        $principalId = "$(Get-M365ObjectProperty $Assignment 'PrincipalId')"
        $info = Get-M365PrincipalInfo (Get-M365ObjectProperty $Assignment 'Principal')
        if ($userIds.Contains($principalId) -or $info.Type -eq 'user') { & $add $Map $principalId $label; return }
        if ($info.Type -ne 'group') { return }
        if (-not $groupMembers.ContainsKey($principalId)) {
            $groupMembers[$principalId] = @(Get-MgGroupMember -GroupId $principalId -All -ErrorAction Stop | ForEach-Object { "$($_.Id)" })
        }
        $via = if ($info.DisplayName) { $info.DisplayName } else { $principalId }
        foreach ($memberId in $groupMembers[$principalId]) { & $add $Map $memberId "$label (via group $via)" }
    }
    try {
        foreach ($def in Get-MgRoleManagementDirectoryRoleDefinition -All -ErrorAction Stop) { $roleNames["$($def.Id)"] = $def.DisplayName }
        foreach ($a in @(Get-MgRoleManagementDirectoryRoleAssignment -All -ExpandProperty principal -ErrorAction Stop)) { & $record $active $a }
    } catch {
        $rolesKnown = $false
        Write-Warning "Could not read role assignments ($($_.Exception.Message)). IsAdmin is 'Unknown' for users without a role found."
    }
    try {
        foreach ($e in @(Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All -ExpandProperty principal -ErrorAction Stop)) { & $record $eligible $e }
    } catch {
        if ($_.Exception.Message -match '(?i)premium|P2|license') {
            Write-Warning "PIM eligibility not available in this tenant ($($_.Exception.Message)); without Entra ID P2 no role can be activated, so none are listed."
        } else {
            $rolesKnown = $false
            Write-Warning "Could not read PIM-eligible roles ($($_.Exception.Message)). IsAdmin is 'Unknown' for users without a role found."
        }
    }
    #endregion

    #region 3. Shape rows --------------------------------------------------------
    $mfaWarned = $false
    foreach ($user in $users) {
        $id = "$($user.Id)"
        $lastSignIn = $null
        $activity = Get-M365ObjectProperty $user 'SignInActivity'
        if ($haveSignIn -and $activity -and (Get-M365ObjectProperty $activity 'LastSignInDateTime')) {
            $lastSignIn = $activity.LastSignInDateTime
        }
        $days = if ($lastSignIn) { [int]((Get-Date) - $lastSignIn).TotalDays } else { $null }
        $mfa = $null
        if ($IncludeMfa) {
            try {
                $methods = @(Get-MgUserAuthenticationMethod -UserId $id -ErrorAction Stop)
                $mfa = @($methods | ForEach-Object { ($_.AdditionalProperties['@odata.type'] -replace '#microsoft.graph.', '') -replace 'AuthenticationMethod', '' } |
                        Where-Object { $_ -ne 'password' })
            } catch {
                $mfa = @('(could not read)')
                if (-not $mfaWarned) { Write-Warning "Could not read authentication methods for some users ($($_.Exception.Message))."; $mfaWarned = $true }
            }
        }
        $roles = @(if ($active.ContainsKey($id)) { $active[$id] })
        $eligibleRoles = @(if ($eligible.ContainsKey($id)) { $eligible[$id] })
        $isAdmin = if ($roles.Count -gt 0 -or $eligibleRoles.Count -gt 0) { $true } elseif ($rolesKnown) { $false } else { 'Unknown' }
        [pscustomobject]@{
            DisplayName       = $user.DisplayName
            UserPrincipalName = $user.UserPrincipalName
            Enabled           = $user.AccountEnabled
            UserType          = $user.UserType
            Synced            = [bool]$user.OnPremisesSyncEnabled
            Licenses          = @($user.AssignedLicenses | ForEach-Object { if ($skuNames[$_.SkuId]) { $skuNames[$_.SkuId] } else { $_.SkuId } })
            Roles             = $roles
            EligibleRoles     = $eligibleRoles
            IsAdmin           = $isAdmin
            LastSignIn        = $lastSignIn
            DaysSinceSignIn   = $days
            Stale             = ($null -ne $days -and $days -ge $StaleDays) -or ($haveSignIn -and $null -eq $days -and $user.AccountEnabled)
            MfaMethods        = $mfa
            Created           = $user.CreatedDateTime
            Id                = $user.Id
        }
    }
    #endregion
}
#endregion

#region Accounts -----------------------------------------------------------------
function New-M365CloudUser {
    <#
    .SYNOPSIS
        Creates a cloud-only user. Refuses when the UPN already exists unless -AdoptExisting. Returns the user and the password.
    .DESCRIPTION
        The building block under break-glass and admin accounts. Password defaults to a
        fresh New-StrongPassword. No license is assigned. Password expiration is disabled
        by default because these are service/emergency identities, not people.

        An account with the same UPN is never silently taken over: without -AdoptExisting
        this throws. With it, the existing account is returned (Adopted = $true) and its
        password is NOT changed (PasswordChanged = $false, Password = $null).

        Graph scopes: User.ReadWrite.All.
    .PARAMETER UserPrincipalName
        Full UPN. Use the onmicrosoft.com domain for break-glass accounts so a custom
        domain outage or federation change can never lock you out.
    .PARAMETER DisplayName
        Display name.
    .PARAMETER Password
        Plain text password. Generated if omitted.
    .PARAMETER PasswordLength
        Length when generating. Default 32.
    .PARAMETER UsageLocation
        Two-letter country code. Required by Graph before any license can be assigned.
    .PARAMETER PasswordNeverExpires
        Set DisablePasswordExpiration. Default on.
    .PARAMETER AdoptExisting
        An account with this UPN already exists and is the one you mean: return it instead of
        throwing. Its password is not changed.
    .EXAMPLE
        New-M365CloudUser -UserPrincipalName svc-admin@contoso.onmicrosoft.com -DisplayName 'Service Admin' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'Generated in memory and handed straight to Graph and to the password vault.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Graph passwordProfile takes plain text; the value is generated, not typed.')]
    param(
        [Parameter(Mandatory)]
        [string]$UserPrincipalName,

        [Parameter(Mandatory)]
        [string]$DisplayName,

        [Parameter()]
        [string]$Password,

        [Parameter()]
        [int]$PasswordLength = 32,

        [Parameter()]
        [string]$UsageLocation = 'US',

        [Parameter()]
        [bool]$PasswordNeverExpires = $true,

        [Parameter()]
        [switch]$AdoptExisting
    )

    #region 1. Never take over an existing account silently ---------------------
    $existing = Get-M365EntraUserByUpn -UserPrincipalName $UserPrincipalName
    if ($existing) {
        $what = "$UserPrincipalName already exists (id $($existing.Id), '$(Get-M365ObjectProperty $existing 'DisplayName')')"
        if (-not $AdoptExisting) {
            throw "$what. Nothing was changed. If it really is the account you mean, re-run with -AdoptExisting: its password is NOT changed."
        }
        Write-Warning "$what. Adopting it as asked (-AdoptExisting): existing account - password NOT changed."
        return [pscustomobject]@{ UserPrincipalName = $UserPrincipalName; Id = "$($existing.Id)"; Created = $false; Adopted = $true; PasswordChanged = $false; Password = $null; WhatIf = [bool]$WhatIfPreference }
    }
    #endregion

    #region 2. Create -------------------------------------------------------------
    #   GOTCHA The password sits under the key 'password' so the plan shows <hidden>. The key
    #          passwordPolicies is hidden too (name match), so the Action text says it.
    if (-not $Password) { $Password = New-StrongPassword -Length $PasswordLength }
    $body = @{
        accountEnabled    = $true
        displayName       = $DisplayName
        userPrincipalName = $UserPrincipalName
        mailNickname      = ($UserPrincipalName -split '@')[0]
        usageLocation     = $UsageLocation
        passwordProfile   = @{ password = $Password; forceChangePasswordNextSignIn = $false }
    }
    if ($PasswordNeverExpires) { $body.passwordPolicies = 'DisablePasswordExpiration' }
    $expiry = if ($PasswordNeverExpires) { ', password never expires' } else { '' }
    $run = Invoke-M365Change -Caller $PSCmdlet -Service Graph -Action "Create cloud account '$DisplayName' ($UserPrincipalName), enabled$expiry" `
        -Command 'New-MgUser' -Parameters ([ordered]@{ BodyParameter = $body })
    #endregion

    [pscustomobject]@{
        UserPrincipalName = $UserPrincipalName
        Id                = $(if ($run.Ran) { "$($run.Output.Id)" } else { $null })
        Created           = $run.Ran
        Adopted           = $false
        PasswordChanged   = $run.Ran
        Password          = $(if ($run.Ran) { $Password } else { $null })
        WhatIf            = -not $run.Ran
    }
}

function Add-M365RoleAssignment {
    <#
    .SYNOPSIS
        Assigns an Entra directory role to a principal at tenant scope, unless it already holds it at tenant scope.
    .DESCRIPTION
        Uses the unified role management API, so it works whether or not the role template
        has ever been activated in the tenant. Permanent (active) assignment; PIM eligible
        assignments are out of scope for onboarding. An assignment scoped to an
        administrative unit does not count as "already assigned".

        Graph scopes: RoleManagement.ReadWrite.Directory.
    .PARAMETER PrincipalId
        Object id of the user or group, or New-M365Placeholder in a dry run where an earlier
        step would create the principal.
    .PARAMETER RoleName
        Role display name, e.g. 'Global Administrator', 'Exchange Administrator'. Must match
        exactly one role.
    .PARAMETER PrincipalLabel
        How to name the principal in the plan, e.g. its UPN. Default: the id.
    .EXAMPLE
        Add-M365RoleAssignment -PrincipalId $user.Id -PrincipalLabel $user.UserPrincipalName -RoleName 'Global Administrator' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [object]$PrincipalId,

        [Parameter(Mandatory)]
        [string]$RoleName,

        [Parameter()]
        [string]$PrincipalLabel
    )

    $planned = Test-M365Placeholder $PrincipalId
    if (-not $planned -and "$PrincipalId" -notmatch $script:GuidPattern) { throw "PrincipalId must be an object id (GUID), not '$PrincipalId'. Nothing was changed." }
    $who = if ($PrincipalLabel) { $PrincipalLabel } elseif ($planned) { "<$($PrincipalId.Name)>" } else { "$PrincipalId" }
    $role = Get-M365RoleDefinitionExact -RoleName $RoleName

    #   WHAT   "Already assigned" means at tenant scope ('/'). A read error stops here.
    if (-not $planned) {
        $existing = @(Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$PrincipalId' and roleDefinitionId eq '$($role.Id)'" -All -ErrorAction Stop |
                Where-Object { "$(Get-M365ObjectProperty $_ 'DirectoryScopeId')" -eq '/' })
        if ($existing.Count -gt 0) {
            Write-Verbose "$who already holds $RoleName at tenant scope."
            return [pscustomobject]@{ PrincipalId = "$PrincipalId"; RoleName = $RoleName; Assigned = $false; AlreadyAssigned = $true; WhatIf = [bool]$WhatIfPreference }
        }
    }
    $run = Invoke-M365Change -Caller $PSCmdlet -Service Graph -Action "Give $who the role '$RoleName' (whole tenant, permanent)" `
        -Command 'New-MgRoleManagementDirectoryRoleAssignment' -Parameters ([ordered]@{ PrincipalId = $PrincipalId; RoleDefinitionId = "$($role.Id)"; DirectoryScopeId = '/' })
    [pscustomobject]@{ PrincipalId = $(if ($planned) { "<$($PrincipalId.Name)>" } else { "$PrincipalId" }); RoleName = $RoleName; Assigned = $run.Ran; AlreadyAssigned = $false; WhatIf = -not $run.Ran }
}

function Add-M365ConditionalAccessExclusion {
    <#
    .SYNOPSIS
        Adds a user to the exclusion list of every Conditional Access policy (or the ones named), reporting each policy.
    .DESCRIPTION
        A break-glass account is only useful if no policy can block it. For each policy this
        reads the raw policy, appends the user to conditions.users.excludeUsers and PATCHes
        back the WHOLE users condition (every include/exclude list and the guest/external
        user settings), then reads it back to confirm nothing else changed.

        One result per policy: Updated, Planned (dry run), AlreadyExcluded, Skipped (no users
        condition, e.g. a workload-identity policy) or Failed. On a failure the function
        reports the failed policy, lists the ones not attempted, and throws before touching
        the next policy.

        Graph scopes: Policy.Read.All, Policy.ReadWrite.ConditionalAccess.
    .PARAMETER UserId
        Object id of the user to exclude, or New-M365Placeholder in a dry run where an earlier
        step would create the user.
    .PARAMETER UserLabel
        How to name the user in the plan, e.g. the UPN. Default: the id.
    .PARAMETER PolicyDisplayName
        Limit to policies with these exact display names. Each must match exactly one policy.
    .PARAMETER PolicyId
        Limit to policies with these ids (use when two policies share a name).
    .EXAMPLE
        Add-M365ConditionalAccessExclusion -UserId $breakGlass.Id -UserLabel breakglass@contoso.onmicrosoft.com -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [object]$UserId,

        [Parameter()]
        [string]$UserLabel,

        [Parameter()]
        [string[]]$PolicyDisplayName,

        [Parameter()]
        [string[]]$PolicyId
    )

    #region 1. Read every policy, pick the targets (exact matches only) ---------------
    $planned = Test-M365Placeholder $UserId
    if (-not $planned -and "$UserId" -notmatch $script:GuidPattern) { throw "UserId must be the user's object id (GUID), not '$UserId'. Nothing was changed." }
    $who = if ($UserLabel) { $UserLabel } elseif ($planned) { "<$($UserId.Name)>" } else { "$UserId" }
    $base = "$script:GraphBase/identity/conditionalAccess/policies"
    $all = [System.Collections.Generic.List[object]]::new()
    $uri = $base
    while ($uri) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
        foreach ($p in @($page['value'])) { if ($p) { $all.Add($p) } }
        $uri = $page['@odata.nextLink']
    }
    $describe = { param($p) "'$($p['displayName'])' (id $($p['id']), $($p['state']))" }
    $targets = [System.Collections.Generic.List[object]]::new()
    if ($PolicyId) {
        foreach ($id in $PolicyId) {
            $m = @($all | Where-Object { "$($_['id'])" -eq $id })
            if ($m.Count -ne 1) { throw "No Conditional Access policy has id '$id'. Nothing was changed." }
            $targets.Add($m[0])
        }
    } elseif ($PolicyDisplayName) {
        foreach ($name in $PolicyDisplayName) {
            $m = @($all | Where-Object { "$($_['displayName'])" -eq $name })
            if ($m.Count -eq 0) {
                throw "No Conditional Access policy is named '$name'. Policies in this tenant: $(($all | ForEach-Object { "'$($_['displayName'])'" }) -join ', '). Nothing was changed."
            }
            if ($m.Count -gt 1) {
                throw "$($m.Count) Conditional Access policies are named '$name': $(($m | ForEach-Object { & $describe $_ }) -join '; '). Pass -PolicyId to pick one. Nothing was changed."
            }
            $targets.Add($m[0])
        }
    } else {
        foreach ($p in $all) { $targets.Add($p) }
    }
    #endregion

    #region 2. One policy at a time; stop before the next one on any error -------------
    #   GOTCHA PATCH of conditions.users is sent with the full users object (all six lists AND
    #          include/excludeGuestsOrExternalUsers) so the result is right whether Graph merges
    #          or replaces it. The read-back confirms the user is excluded and nothing else in
    #          the users condition changed.
    $lists = 'includeUsers', 'excludeUsers', 'includeGroups', 'excludeGroups', 'includeRoles', 'excludeRoles'
    $guests = 'includeGuestsOrExternalUsers', 'excludeGuestsOrExternalUsers'
    $result = {
        param($p, [string]$Result, [string]$Reason, [bool]$Updated)
        [pscustomobject]@{ Policy = "$($p['displayName'])"; PolicyId = "$($p['id'])"; State = "$($p['state'])"; Result = $Result; Updated = $Updated; Reason = $Reason; WhatIf = [bool]$WhatIfPreference }
    }
    $doneNames = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $targets.Count; $i++) {
        $p = $targets[$i]
        $name = "$($p['displayName'])"
        try {
            $fresh = Invoke-MgGraphRequest -Method GET -Uri "$base/$($p['id'])" -ErrorAction Stop
            $conditions = $fresh['conditions']
            $users = if ($conditions) { $conditions['users'] } else { $null }
            if ($null -eq $users) {
                & $result $fresh 'Skipped' 'The policy has no users condition (it targets workload identities); a user exclusion does not apply.' $false
                continue
            }
            $exclude = @(@($users['excludeUsers']) | Where-Object { $_ })
            if (-not $planned -and $exclude -contains "$UserId") {
                Write-Verbose "'$name' already excludes $who."
                & $result $fresh 'AlreadyExcluded' $null $false
                continue
            }
            $newUsers = @{}
            foreach ($k in @($users.Keys)) { if ("$k" -notlike '@odata*') { $newUsers["$k"] = $users[$k] } }
            foreach ($k in $lists) { if (-not $newUsers.ContainsKey($k)) { $newUsers[$k] = @() } else { $newUsers[$k] = @(@($newUsers[$k]) | Where-Object { $_ }) } }
            foreach ($k in $guests) { if (-not $newUsers.ContainsKey($k)) { $newUsers[$k] = $null } }
            $newUsers['excludeUsers'] = @($exclude) + @($UserId)
            $run = Invoke-M365Change -Caller $PSCmdlet -Service Graph -Action "Exclude $who from Conditional Access policy '$name' ($($fresh['state'])); every other user, group, role and guest setting is sent back unchanged" `
                -Command 'Invoke-MgGraphRequest' -Parameters ([ordered]@{ Method = 'PATCH'; Uri = "$base/$($p['id'])"; Body = @{ conditions = @{ users = $newUsers } } })
            if (-not $run.Ran) { & $result $fresh 'Planned' $null $false; continue }

            #   Read back (a few tries: the new exclusion can take a moment to show).
            $after = $null
            for ($try = 1; $try -le 3; $try++) {
                $after = (Invoke-MgGraphRequest -Method GET -Uri "$base/$($p['id'])" -ErrorAction Stop)['conditions']['users']
                if (@($after['excludeUsers']) -contains "$UserId") { break }
                if ($try -lt 3) { Start-Sleep -Seconds 2 }
            }
            $problems = [System.Collections.Generic.List[string]]::new()
            if (@($after['excludeUsers']) -notcontains "$UserId") { $problems.Add('the user is not in excludeUsers') }
            foreach ($k in $lists | Where-Object { $_ -ne 'excludeUsers' }) {
                if (@(@($after[$k]) | Where-Object { $_ }).Count -ne @(@($users[$k]) | Where-Object { $_ }).Count) { $problems.Add("$k changed") }
            }
            foreach ($k in $guests) { if (($null -eq $users[$k]) -ne ($null -eq $after[$k])) { $problems.Add("$k changed") } }
            if ($problems.Count -gt 0) {
                throw "The PATCH ran, but reading the policy back shows: $($problems -join '; '). Open the policy in the Entra portal and check its users and guest settings."
            }
            $doneNames.Add($name)
            & $result $fresh 'Updated' $null $true
        } catch {
            $reason = $_.Exception.Message
            & $result $p 'Failed' $reason $false
            $rest = @(for ($j = $i + 1; $j -lt $targets.Count; $j++) { $targets[$j] })
            foreach ($r in $rest) { & $result $r 'NotAttempted' "Stopped after '$name' failed." $false }
            throw "Conditional Access exclusion stopped at policy '$name': $reason Updated before it: $(if ($doneNames.Count) { $doneNames -join ', ' } else { 'none' }). Not attempted: $(if ($rest.Count) { ($rest | ForEach-Object { $_['displayName'] }) -join ', ' } else { 'none' })."
        }
    }
    #endregion
}

function New-M365BreakGlassAccount {
    <#
    .SYNOPSIS
        Creates the emergency-access account: cloud-only, Global Administrator, excluded from every CA policy.
    .DESCRIPTION
        SOP #5 step 3. Composes New-M365CloudUser, Add-M365RoleAssignment and
        Add-M365ConditionalAccessExclusion. The UPN lives on the tenant's initial
        onmicrosoft.com domain: pass it with -Domain (the client config carries it) or let
        the function look it up. The password is returned once in the result; the calling
        script is responsible for putting it in Hudu (Add-HuduPassword) and the operator
        for never leaving it in a console log.

        An existing account with the same UPN is refused unless -AdoptExisting; with it, the
        role and exclusions are checked for that account and its password is NOT changed
        (the plan and the result say so). Under -WhatIf the role assignment and every CA
        exclusion are planned for the new account (shown as <id of the new account ...>).

        A failure after the account was created (role or CA) is returned in Errors with
        Completed = $false, never thrown, so the password in the result is never lost.

        Graph scopes: User.ReadWrite.All, RoleManagement.ReadWrite.Directory, Policy.Read.All,
        Policy.ReadWrite.ConditionalAccess, Domain.Read.All.
    .PARAMETER UpnPrefix
        Local part of the UPN. Default 'breakglass'.
    .PARAMETER DisplayName
        Default 'Emergency Access'.
    .PARAMETER PasswordLength
        Default 64. Long is fine; it lives in the vault, not in anyone's head.
    .PARAMETER Domain
        The tenant's <name>.onmicrosoft.com domain. Looked up (IsInitial) when omitted.
    .PARAMETER Password
        The password the operator chose (from Read-M365Password). Generated when omitted.
    .PARAMETER SkipConditionalAccessExclusion
        Do not touch CA policies (for tenants where a separate team owns CA).
    .PARAMETER AdoptExisting
        The account already exists and is this tenant's break-glass account: check its role
        and CA exclusions instead of refusing. Its password is not changed.
    .EXAMPLE
        New-M365BreakGlassAccount -Domain contoso.onmicrosoft.com -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'Typed by the operator or generated in memory; handed to Graph once.')]
    param(
        [Parameter()]
        [string]$UpnPrefix = 'breakglass',

        [Parameter()]
        [string]$DisplayName = 'Emergency Access',

        [Parameter()]
        [int]$PasswordLength = 64,

        [Parameter()]
        [string]$Domain,

        [Parameter()]
        [string]$Password,

        [Parameter()]
        [switch]$SkipConditionalAccessExclusion,

        [Parameter()]
        [switch]$AdoptExisting
    )

    #region 1. Pin the onmicrosoft.com domain ---------------------------------
    #   WHY    If the client's custom domain is ever removed, federated or
    #          mis-pointed, an account on .onmicrosoft.com still signs in. The
    #          caller normally passes it from the client config; the lookup is the
    #          fallback for ad-hoc use.
    if (-not $Domain) {
        $initial = @(Get-MgDomain -All -ErrorAction Stop | Where-Object { $_.IsInitial })
        if ($initial.Count -ne 1) { throw 'Could not find exactly one initial (.onmicrosoft.com) domain. Pass -Domain.' }
        $Domain = $initial[0].Id
    }
    if ($Domain -notmatch '^[a-z0-9-]+\.onmicrosoft\.com$') { throw "Break-glass accounts must live on the tenant's <name>.onmicrosoft.com domain, not '$Domain'." }
    $upn = "$UpnPrefix@$Domain"
    #endregion

    #region 2. Create (or adopt only when asked), then elevate and exclude -----------
    #   WHAT   New-M365CloudUser throws when the account exists and -AdoptExisting is not given.
    #   WHY    Re-granting Global Administrator and CA exclusions to an account that merely has
    #          the same name (a previous MSP's, de-admined on purpose) must be a decision.
    $userParams = @{ UserPrincipalName = $upn; DisplayName = $DisplayName; PasswordLength = $PasswordLength; AdoptExisting = $AdoptExisting }
    if ($Password) { $userParams.Password = $Password }
    $user = New-M365CloudUser @userParams -WhatIf:$WhatIfPreference
    if ($user.Adopted -and $Password) { Write-Warning "The password you gave was NOT applied: $upn already existed and its password is unchanged." }
    $note = if ($user.Adopted) { ' (existing account - password NOT changed)' } else { '' }
    $errors = [System.Collections.Generic.List[string]]::new()
    $role = $null
    $exclusions = [System.Collections.Generic.List[object]]::new()
    if (-not $user.Id -and -not $WhatIfPreference) {
        $errors.Add('The account was not created (declined), so no role or exclusion was attempted.')
    } else {
        $principal = if ($user.Id) { $user.Id } else { New-M365Placeholder "id of the new account $upn" }
        try {
            $role = Add-M365RoleAssignment -PrincipalId $principal -PrincipalLabel "$upn$note" -RoleName 'Global Administrator' -WhatIf:$WhatIfPreference
        } catch { $errors.Add("Global Administrator: $($_.Exception.Message)") }
        if (-not $SkipConditionalAccessExclusion -and $errors.Count -eq 0) {
            try {
                Add-M365ConditionalAccessExclusion -UserId $principal -UserLabel "$upn$note" -WhatIf:$WhatIfPreference | ForEach-Object { $exclusions.Add($_) }
            } catch { $errors.Add("Conditional Access: $($_.Exception.Message)") }
        }
    }
    foreach ($e in $errors) { Write-Warning "$upn - $e" }
    #endregion

    $roleState = if ($role) {
        if ($role.AlreadyAssigned) { 'AlreadyAssigned' } elseif ($role.Assigned) { 'Assigned' } elseif ($WhatIfPreference) { 'Planned' } else { 'Declined' }
    } elseif ($errors.Count) { 'Failed' } else { 'NotRun' }
    $byResult = { param([string[]]$Result) @($exclusions | Where-Object { $_.Result -in $Result } | ForEach-Object { $_.Policy }) }
    [pscustomobject]@{
        UserPrincipalName        = $upn
        Id                       = $user.Id
        Created                  = $user.Created
        Adopted                  = $user.Adopted
        PasswordChanged          = $user.PasswordChanged
        Password                 = $user.Password
        Note                     = $(if ($user.Adopted) { 'existing account - password NOT changed' } else { $null })
        GlobalAdmin              = $roleState
        GlobalAdminAssigned      = ($roleState -in 'Assigned', 'AlreadyAssigned')
        PoliciesUpdated          = @(& $byResult 'Updated')
        PoliciesPlanned          = @(& $byResult 'Planned')
        PoliciesAlreadyExcluding = @(& $byResult 'AlreadyExcluded')
        PoliciesSkipped          = @($exclusions | Where-Object { $_.Result -eq 'Skipped' } | ForEach-Object { "$($_.Policy): $($_.Reason)" })
        PoliciesFailed           = @(& $byResult 'Failed', 'NotAttempted')
        Errors                   = @($errors)
        Completed                = ($errors.Count -eq 0)
        WhatIf                   = [bool]$WhatIfPreference
    }
}

function New-M365AdminAccount {
    <#
    .SYNOPSIS
        Creates one of our named admin accounts in a client tenant and assigns its roles.
    .DESCRIPTION
        SOP #5 step 4. Like the break-glass account but with whatever roles our standard
        says (least privilege: Exchange Administrator + User Administrator for day-to-day,
        Global Administrator only where the contract needs it). Always lives on the client's
        <name>.onmicrosoft.com domain.

        Every role name is resolved before anything is created. An existing account with
        the same UPN is refused unless -AdoptExisting (its password is then NOT changed).
        A role failure after creation is returned in Errors with the password, never thrown.

        Graph scopes: User.ReadWrite.All, RoleManagement.ReadWrite.Directory, Domain.Read.All.
    .PARAMETER UpnPrefix
        Local part, e.g. 'msp-admin'.
    .PARAMETER DisplayName
        Display name.
    .PARAMETER Roles
        Entra role display names to assign. Each must match exactly one role.
    .PARAMETER Domain
        The tenant's <name>.onmicrosoft.com domain. Default: looked up (IsInitial).
    .PARAMETER PasswordLength
        Default 32.
    .PARAMETER Password
        The password the operator chose. Generated when omitted.
    .PARAMETER AdoptExisting
        The account already exists and is ours: assign missing roles instead of refusing.
        Its password is not changed.
    .EXAMPLE
        New-M365AdminAccount -UpnPrefix msp-admin -DisplayName 'MSP Admin' -Roles 'Exchange Administrator', 'User Administrator' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'Typed by the operator or generated in memory; handed to Graph once.')]
    param(
        [Parameter(Mandatory)]
        [string]$UpnPrefix,

        [Parameter(Mandatory)]
        [string]$DisplayName,

        [Parameter(Mandatory)]
        [string[]]$Roles,

        [Parameter()]
        [string]$Domain,

        [Parameter()]
        [int]$PasswordLength = 32,

        [Parameter()]
        [string]$Password,

        [Parameter()]
        [switch]$AdoptExisting
    )

    #region 1. Domain and roles, all checked before anything is created ----------------
    if (-not $Domain) {
        $initial = @(Get-MgDomain -All -ErrorAction Stop | Where-Object { $_.IsInitial })
        if ($initial.Count -ne 1) { throw 'Could not find exactly one initial (.onmicrosoft.com) domain. Pass -Domain.' }
        $Domain = $initial[0].Id
    }
    if ($Domain -notmatch '^[a-z0-9-]+\.onmicrosoft\.com$') { throw "Admin accounts must live on the tenant's <name>.onmicrosoft.com domain, not '$Domain'." }
    foreach ($roleName in $Roles) { $null = Get-M365RoleDefinitionExact -RoleName $roleName }
    $upn = "$UpnPrefix@$Domain"
    #endregion

    #region 2. Create (or adopt only when asked), then assign ----------------------------
    $userParams = @{ UserPrincipalName = $upn; DisplayName = $DisplayName; PasswordLength = $PasswordLength; AdoptExisting = $AdoptExisting }
    if ($Password) { $userParams.Password = $Password }
    $user = New-M365CloudUser @userParams -WhatIf:$WhatIfPreference
    if ($user.Adopted -and $Password) { Write-Warning "The password you gave was NOT applied: $upn already existed and its password is unchanged." }
    $note = if ($user.Adopted) { ' (existing account - password NOT changed)' } else { '' }
    $errors = [System.Collections.Generic.List[string]]::new()
    $assigned = [System.Collections.Generic.List[string]]::new()
    $already = [System.Collections.Generic.List[string]]::new()
    $plannedRoles = [System.Collections.Generic.List[string]]::new()
    if (-not $user.Id -and -not $WhatIfPreference) {
        $errors.Add('The account was not created (declined), so no role was attempted.')
    } else {
        $principal = if ($user.Id) { $user.Id } else { New-M365Placeholder "id of the new account $upn" }
        foreach ($roleName in $Roles) {
            try {
                $r = Add-M365RoleAssignment -PrincipalId $principal -PrincipalLabel "$upn$note" -RoleName $roleName -WhatIf:$WhatIfPreference
                if ($r.AlreadyAssigned) { $already.Add($roleName) } elseif ($r.Assigned) { $assigned.Add($roleName) } else { $plannedRoles.Add($roleName) }
            } catch { $errors.Add("${roleName}: $($_.Exception.Message)"); break }
        }
    }
    foreach ($e in $errors) { Write-Warning "$upn - $e" }
    #endregion

    [pscustomobject]@{
        UserPrincipalName = $upn
        Id                = $user.Id
        Created           = $user.Created
        Adopted           = $user.Adopted
        PasswordChanged   = $user.PasswordChanged
        Password          = $user.Password
        Note              = $(if ($user.Adopted) { 'existing account - password NOT changed' } else { $null })
        RolesRequested    = @($Roles)
        RolesAssigned     = @($assigned)
        RolesAlreadyHeld  = @($already)
        RolesPlanned      = @($plannedRoles)
        Errors            = @($errors)
        Completed         = ($errors.Count -eq 0)
        WhatIf            = [bool]$WhatIfPreference
    }
}
#endregion

#region Organization ---------------------------------------------------------
function Set-M365TechnicalContact {
    <#
    .SYNOPSIS
        Adds an address to the tenant's technical notification contacts (and optionally security/compliance).
    .DESCRIPTION
        SOP #5 step 9, the part that has an API. Microsoft sends service incident and
        tenant-level notices to technicalNotificationMails; adding our support address
        there means we hear about problems before the client does. Existing addresses
        are kept (an empty list is handled).

        The help desk card (Org settings > Organization profile > Help desk information)
        has no public Graph API; the calling script prints a reminder for that.

        Graph scopes: Organization.ReadWrite.All.
    .PARAMETER Email
        Address to add.
    .PARAMETER IncludeSecurityCompliance
        Also add to securityComplianceNotificationMails.
    .EXAMPLE
        Set-M365TechnicalContact -Email support@msp.example -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [string]$Email,

        [Parameter()]
        [switch]$IncludeSecurityCompliance
    )

    Assert-M365UpnShape -UserPrincipalName $Email -What 'Email'
    $orgs = @(Get-MgOrganization -ErrorAction Stop)
    if ($orgs.Count -ne 1) { throw "Expected one organization object, Graph returned $($orgs.Count). Nothing was changed." }
    $org = $orgs[0]
    $tech = @(@(Get-M365ObjectProperty $org 'TechnicalNotificationMails') | Where-Object { $_ })
    $sec = @(@(Get-M365ObjectProperty $org 'SecurityComplianceNotificationMails') | Where-Object { $_ })
    $params = [ordered]@{ OrganizationId = "$($org.Id)" }
    $lists = [System.Collections.Generic.List[string]]::new()
    if ($tech -notcontains $Email) { $params.TechnicalNotificationMails = @($tech + $Email); $lists.Add('technical') }
    if ($IncludeSecurityCompliance -and $sec -notcontains $Email) { $params.SecurityComplianceNotificationMails = @($sec + $Email); $lists.Add('security & compliance') }
    if ($lists.Count -eq 0) {
        Write-Verbose "$Email is already a notification contact."
        return [pscustomobject]@{ Tenant = $org.DisplayName; Email = $Email; Updated = $false; TechnicalContacts = $tech; WhatIf = [bool]$WhatIfPreference }
    }
    $run = Invoke-M365Change -Caller $PSCmdlet -Service Graph -Action "Add $Email to the $($lists -join ' and ') notification contacts of '$($org.DisplayName)' (existing contacts kept)" `
        -Command 'Update-MgOrganization' -Parameters $params
    [pscustomobject]@{
        Tenant            = $org.DisplayName
        Email             = $Email
        Updated           = $run.Ran
        TechnicalContacts = $(if ($run.Ran -and $params.Contains('TechnicalNotificationMails')) { $params.TechnicalNotificationMails } else { $tech })
        WhatIf            = -not $run.Ran
    }
}
#endregion

#region Partner ------------------------------------------------------------------
function Get-M365GdapRelationship {
    <#
    .SYNOPSIS
        Lists GDAP relationships from our partner tenant, optionally for one customer.
    .DESCRIPTION
        SOP #5 step 7 verification. Must run with a Graph session in OUR tenant (the
        partner), not the client's. Returns display name, customer, status, roles granted,
        end date and auto-extend, so you can confirm the Pax8-created relationship is
        active before relying on it.

        Graph scopes: DelegatedAdminRelationship.Read.All.
    .PARAMETER CustomerTenantId
        Filter to one customer tenant: its GUID or any verified domain (resolved to the GUID).
    .PARAMETER CustomerName
        Filter by customer display name: exact match, case-insensitive ("ABC" does not match
        "ABC Plumbing").
    .EXAMPLE
        Get-M365GdapRelationship -CustomerName 'Contoso Dental'
    .EXAMPLE
        Get-M365GdapRelationship -CustomerTenantId contoso.onmicrosoft.com
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$CustomerTenantId,

        [Parameter()]
        [string]$CustomerName
    )

    $relationships = @(Get-MgTenantRelationshipDelegatedAdminRelationship -All -ErrorAction Stop)
    if ($CustomerTenantId) {
        $tenantGuid = Resolve-M365TenantId -TenantId $CustomerTenantId
        $relationships = @($relationships | Where-Object { "$($_.Customer.TenantId)" -eq $tenantGuid })
    }
    if ($CustomerName) {
        $wanted = $CustomerName.Trim()
        $relationships = @($relationships | Where-Object { "$($_.Customer.DisplayName)".Trim() -ieq $wanted })
    }

    $roleNames = @{}
    foreach ($def in Get-MgRoleManagementDirectoryRoleDefinition -All -ErrorAction SilentlyContinue) { $roleNames[$def.Id] = $def.DisplayName }

    foreach ($rel in $relationships) {
        [pscustomobject]@{
            DisplayName      = $rel.DisplayName
            Customer         = $rel.Customer.DisplayName
            CustomerTenantId = $rel.Customer.TenantId
            Status           = $rel.Status
            Roles            = @($rel.AccessDetails.UnifiedRoles | ForEach-Object { if ($roleNames[$_.RoleDefinitionId]) { $roleNames[$_.RoleDefinitionId] } else { $_.RoleDefinitionId } })
            EndDateTime      = $rel.EndDateTime
            AutoExtend       = $rel.AutoExtendDuration
            Id               = $rel.Id
        }
    }
}
#endregion

#region Licensing and lifecycle --------------------------------------------------
function Get-M365LicenseSummary {
    <#
    .SYNOPSIS
        One row per subscribed SKU: purchased, assigned, available, warning/suspended units.
    .DESCRIPTION
        Graph scopes: Organization.Read.All (or Directory.Read.All).
    .EXAMPLE
        Get-M365LicenseSummary | Format-Table Sku, Total, Assigned, Available
    #>
    [CmdletBinding()]
    param()
    foreach ($sku in Get-MgSubscribedSku -All -ErrorAction Stop) {
        $total = [int]$sku.PrepaidUnits.Enabled
        [pscustomobject]@{
            Sku       = $sku.SkuPartNumber
            SkuId     = $sku.SkuId
            Total     = $total
            Assigned  = [int]$sku.ConsumedUnits
            Available = $total - [int]$sku.ConsumedUnits
            Warning   = [int]$sku.PrepaidUnits.Warning
            Suspended = [int]$sku.PrepaidUnits.Suspended
            Status    = "$($sku.CapabilityStatus)"
        }
    }
}

function Disable-M365UserSignIn {
    <#
    .SYNOPSIS
        Blocks a user's sign-in and (by default) revokes their refresh tokens so open sessions end.
    .DESCRIPTION
        Offboarding step 1. Idempotent: an already-disabled account is left alone, but
        sessions are still revoked unless -SkipRevoke. The account is never deleted.
        Graph scopes: User.ReadWrite.All (User.RevokeSessions.All for the revoke).
    .PARAMETER UserPrincipalName
        The user (exact UPN).
    .PARAMETER SkipRevoke
        Do not revoke sessions.
    .EXAMPLE
        Disable-M365UserSignIn -UserPrincipalName jane@contoso.com -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [string]$UserPrincipalName,

        [Parameter()]
        [switch]$SkipRevoke
    )
    $user = Get-M365EntraUserByUpn -UserPrincipalName $UserPrincipalName -Property accountEnabled
    if (-not $user) { throw "User $UserPrincipalName not found. Nothing was changed." }
    $wasEnabled = [bool](Get-M365ObjectProperty $user 'AccountEnabled')
    $disabled = $false; $revoked = $false
    if ($wasEnabled) {
        $run = Invoke-M365Change -Caller $PSCmdlet -Service Graph -Action "Block sign-in for $UserPrincipalName (the account is kept)" `
            -Command 'Update-MgUser' -Parameters ([ordered]@{ UserId = "$($user.Id)"; BodyParameter = @{ accountEnabled = $false } })
        $disabled = $run.Ran
    } else { Write-Verbose "$UserPrincipalName is already blocked." }
    if (-not $SkipRevoke) {
        $run = Invoke-M365Change -Caller $PSCmdlet -Service Graph -Action "Sign $UserPrincipalName out everywhere (revoke refresh tokens and session cookies)" `
            -Command 'Revoke-MgUserSignInSession' -Parameters ([ordered]@{ UserId = "$($user.Id)" })
        $revoked = $run.Ran
    }
    [pscustomobject]@{ UserPrincipalName = $UserPrincipalName; Id = "$($user.Id)"; WasEnabled = $wasEnabled; Disabled = $disabled; SessionsRevoked = $revoked; WhatIf = [bool]$WhatIfPreference }
}

function Remove-M365UserLicense {
    <#
    .SYNOPSIS
        Removes every directly assigned license from a user (group-based licenses are reported, not touched).
    .DESCRIPTION
        Offboarding step: run only after the mailbox is converted to shared so mail is kept
        (Invoke-M365UserOffboarding.ps1 checks that before calling this).
        Graph scopes: User.ReadWrite.All, Organization.Read.All.
    .PARAMETER UserPrincipalName
        The user (exact UPN).
    .EXAMPLE
        Remove-M365UserLicense -UserPrincipalName jane@contoso.com -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [string]$UserPrincipalName
    )
    $user = Get-M365EntraUserByUpn -UserPrincipalName $UserPrincipalName -Property assignedLicenses, licenseAssignmentStates
    if (-not $user) { throw "User $UserPrincipalName not found. Nothing was changed." }
    $skuNames = @{}
    try { foreach ($sku in Get-MgSubscribedSku -All -ErrorAction Stop) { $skuNames["$($sku.SkuId)"] = $sku.SkuPartNumber } }
    catch { Write-Warning "Could not read license names ($($_.Exception.Message)); showing SKU ids." }
    $nameOf = { param($id) if ($skuNames["$id"]) { $skuNames["$id"] } else { "$id" } }
    $states = @(Get-M365ObjectProperty $user 'LicenseAssignmentStates')
    $direct = @($states | Where-Object { $_ -and -not $_.AssignedByGroup } | ForEach-Object { "$($_.SkuId)" } | Sort-Object -Unique)
    $grouped = @($states | Where-Object { $_ -and $_.AssignedByGroup } | ForEach-Object { "$($_.SkuId)" } | Sort-Object -Unique)
    $groupNames = @($grouped | ForEach-Object { & $nameOf $_ })
    if ($grouped.Count -gt 0) { Write-Warning "$UserPrincipalName also has $($grouped.Count) group-based license(s) ($($groupNames -join ', ')); remove the user from the licensing group(s) to clear them." }
    if ($direct.Count -eq 0) {
        Write-Verbose "$UserPrincipalName has no directly assigned licenses."
        return [pscustomobject]@{ UserPrincipalName = $UserPrincipalName; Removed = @(); ToRemove = @(); GroupAssigned = $groupNames; WhatIf = [bool]$WhatIfPreference }
    }
    $names = @($direct | ForEach-Object { & $nameOf $_ })
    $run = Invoke-M365Change -Caller $PSCmdlet -Service Graph -Action "Remove license(s) $($names -join ', ') from $UserPrincipalName (directly assigned only)" `
        -Command 'Set-MgUserLicense' -Parameters ([ordered]@{ UserId = "$($user.Id)"; AddLicenses = @(); RemoveLicenses = @($direct) })
    [pscustomobject]@{ UserPrincipalName = $UserPrincipalName; Removed = $(if ($run.Ran) { $names } else { @() }); ToRemove = $names; GroupAssigned = $groupNames; WhatIf = -not $run.Ran }
}
#endregion

#region New-user onboarding ------------------------------------------------------
function New-M365User {
    <#
    .SYNOPSIS
        Creates a regular cloud user (person). Returns the user and its one-time password; reports, never takes over, an existing UPN.
    .DESCRIPTION
        For people, not service accounts: password must change at first sign-in, normal
        expiration policy. Sets usage location (required before licensing), job title,
        department and manager when given. Prefer New-M365TemporaryAccessPass over handing
        the password around; the password is still returned for tenants without TAP.

        When the UPN already exists nothing is created or changed: the result has
        Created = $false and AlreadyExisted = $true, and the caller decides (onboarding
        stops). The manager is looked up before the user is created; if setting it fails
        after creation, the created user and its password are still returned, with
        ManagerError saying why.
        Graph scopes: User.ReadWrite.All.
    .PARAMETER UserPrincipalName
        Full UPN on a verified domain.
    .PARAMETER DisplayName
        Display name.
    .PARAMETER GivenName
        First name.
    .PARAMETER Surname
        Last name.
    .PARAMETER UsageLocation
        Two-letter country code. Default US.
    .PARAMETER JobTitle
        Optional.
    .PARAMETER Department
        Optional.
    .PARAMETER ManagerUpn
        Optional manager (exact UPN). Must exist, or nothing is created.
    .PARAMETER Password
        Initial password. Generated when omitted.
    .EXAMPLE
        New-M365User -UserPrincipalName jane@contoso.com -DisplayName 'Jane Doe' -GivenName Jane -Surname Doe -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'Generated in memory; returned once to the operator.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Graph passwordProfile takes plain text; the value is generated, not typed.')]
    param(
        [Parameter(Mandatory)]
        [string]$UserPrincipalName,

        [Parameter(Mandatory)]
        [string]$DisplayName,

        [Parameter()]
        [string]$GivenName,

        [Parameter()]
        [string]$Surname,

        [Parameter()]
        [string]$UsageLocation = 'US',

        [Parameter()]
        [string]$JobTitle,

        [Parameter()]
        [string]$Department,

        [Parameter()]
        [string]$ManagerUpn,

        [Parameter()]
        [string]$Password
    )

    #region 1. Existing user? Report it, change nothing --------------------------------
    $result = [ordered]@{ UserPrincipalName = $UserPrincipalName; Id = $null; DisplayName = $DisplayName; Created = $false; AlreadyExisted = $false; Password = $null; ManagerSet = $false; ManagerError = $null; WhatIf = [bool]$WhatIfPreference }
    $existing = Get-M365EntraUserByUpn -UserPrincipalName $UserPrincipalName
    if ($existing) {
        $existingName = Get-M365ObjectProperty $existing 'DisplayName'
        Write-Warning "User $UserPrincipalName already exists ('$existingName', id $($existing.Id)). Nothing was created or changed."
        $result.Id = "$($existing.Id)"; $result.DisplayName = $existingName; $result.AlreadyExisted = $true
        return [pscustomobject]$result
    }
    #endregion

    #region 2. Manager first (a typo stops here, before anything exists) ----------------
    $manager = $null
    if ($ManagerUpn) {
        $manager = Get-M365EntraUserByUpn -UserPrincipalName $ManagerUpn
        if (-not $manager) { throw "Manager $ManagerUpn not found in this tenant. Nothing was created." }
    }
    #endregion

    #region 3. Create ---------------------------------------------------------------
    if (-not $Password) { $Password = New-StrongPassword -Length 20 }
    $body = @{
        accountEnabled    = $true
        displayName       = $DisplayName
        userPrincipalName = $UserPrincipalName
        mailNickname      = ($UserPrincipalName -split '@')[0]
        usageLocation     = $UsageLocation
        passwordProfile   = @{ password = $Password; forceChangePasswordNextSignIn = $true }
    }
    if ($GivenName) { $body.givenName = $GivenName }
    if ($Surname) { $body.surname = $Surname }
    if ($JobTitle) { $body.jobTitle = $JobTitle }
    if ($Department) { $body.department = $Department }
    $run = Invoke-M365Change -Caller $PSCmdlet -Service Graph -Action "Create user '$DisplayName' ($UserPrincipalName), must change the password at first sign-in" `
        -Command 'New-MgUser' -Parameters ([ordered]@{ BodyParameter = $body })
    if ($run.Ran) { $result.Id = "$($run.Output.Id)"; $result.Created = $true; $result.Password = $Password; $result.WhatIf = $false }
    #endregion

    #region 4. Manager (after creation: a failure must not lose the user or the password) --
    if ($manager -and ($run.Ran -or $WhatIfPreference)) {
        $newId = if ($run.Ran) { $result.Id } else { New-M365Placeholder "id of the new user $UserPrincipalName" }
        try {
            $mrun = Invoke-M365Change -Caller $PSCmdlet -Service Graph -Action "Set the manager of $UserPrincipalName to $ManagerUpn" `
                -Command 'Set-MgUserManagerByRef' -Parameters ([ordered]@{ UserId = $newId; BodyParameter = @{ '@odata.id' = "$script:GraphBase/users/$($manager.Id)" } })
            $result.ManagerSet = $mrun.Ran
        } catch {
            if (-not $run.Ran) { throw }
            $result.ManagerError = $_.Exception.Message
            Write-Warning "Created $UserPrincipalName, but setting the manager to $ManagerUpn failed: $($_.Exception.Message). Set it in the Entra portal."
        }
    }
    #endregion

    [pscustomobject]$result
}

function Add-M365UserLicense {
    <#
    .SYNOPSIS
        Assigns licenses to a user by SKU part number (SPB, SPE_E3, ...), skipping ones already held.
    .DESCRIPTION
        Checks the tenant has units available and warns when a SKU is at capacity. Needs the
        user's usageLocation set (New-M365User does that). When every SKU is already held it
        reports Status 'AlreadyLicensed' and changes nothing.
        Graph scopes: User.ReadWrite.All, Organization.Read.All.
    .PARAMETER UserPrincipalName
        The user (exact UPN).
    .PARAMETER Sku
        One or more SKU part numbers as shown by Get-M365LicenseSummary.
    .PARAMETER UserId
        The user's object id when an earlier step just created it, or New-M365Placeholder in a
        dry run of such a step (the user then has no licenses yet).
    .EXAMPLE
        Add-M365UserLicense -UserPrincipalName jane@contoso.com -Sku SPB -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [string]$UserPrincipalName,

        [Parameter(Mandatory)]
        [string[]]$Sku,

        [Parameter()]
        [object]$UserId
    )
    $target = Resolve-M365TargetUser -UserPrincipalName $UserPrincipalName -UserId $UserId -Property assignedLicenses, usageLocation
    $have = @()
    if (-not $target.Planned) {
        if (-not (Get-M365ObjectProperty $target.User 'UsageLocation')) { throw "$UserPrincipalName has no usageLocation; set it before assigning licenses." }
        $have = @(@(Get-M365ObjectProperty $target.User 'AssignedLicenses') | Where-Object { $_ } | ForEach-Object { "$($_.SkuId)" })
    }
    $skus = @(Get-MgSubscribedSku -All -ErrorAction Stop)
    $toAdd = [System.Collections.Generic.List[object]]::new()
    $already = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    $full = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $Sku) {
        $match = @($skus | Where-Object { $_.SkuPartNumber -ieq $name })
        if ($match.Count -eq 0) { $missing.Add($name); continue }
        if ($match.Count -gt 1) { throw "$($match.Count) subscribed SKUs are named '$name'. Nothing was changed." }
        $m = $match[0]
        if ($have -contains "$($m.SkuId)") { $already.Add($m.SkuPartNumber); continue }
        if (([int]$m.PrepaidUnits.Enabled - [int]$m.ConsumedUnits) -le 0) { $full.Add($m.SkuPartNumber) }
        $toAdd.Add($m)
    }
    if ($missing.Count -gt 0) { throw "SKU(s) not in this tenant: $($missing -join ', '). Available: $(($skus | ForEach-Object { $_.SkuPartNumber } | Sort-Object) -join ', ')" }
    if ($full.Count -gt 0) { Write-Warning "No free units for $($full -join ', '); the assignment will fail until a license is bought or freed." }
    if ($toAdd.Count -eq 0) {
        Write-Verbose "$UserPrincipalName already has $($already -join ', ')."
        return [pscustomobject]@{ UserPrincipalName = $UserPrincipalName; Assigned = @(); ToAssign = @(); AlreadyHad = @($already); Status = 'AlreadyLicensed'; WhatIf = [bool]$WhatIfPreference }
    }
    $addNames = @($toAdd | ForEach-Object { $_.SkuPartNumber })
    $run = Invoke-M365Change -Caller $PSCmdlet -Service Graph -Action "Assign license(s) $($addNames -join ', ') to $UserPrincipalName" `
        -Command 'Set-MgUserLicense' -Parameters ([ordered]@{ UserId = $target.Id; AddLicenses = @($toAdd | ForEach-Object { @{ skuId = "$($_.SkuId)" } }); RemoveLicenses = @() })
    [pscustomobject]@{
        UserPrincipalName = $UserPrincipalName
        Assigned          = $(if ($run.Ran) { $addNames } else { @() })
        ToAssign          = $addNames
        AlreadyHad        = @($already)
        Status            = $(if ($run.Ran) { 'Assigned' } else { 'Planned' })
        WhatIf            = -not $run.Ran
    }
}

function Add-M365GroupMember {
    <#
    .SYNOPSIS
        Adds a user to Entra groups (security or Microsoft 365) by exact display name or object id, skipping memberships that exist.
    .DESCRIPTION
        Every group is resolved before anything changes: a name must match exactly one group
        (two groups called "Sales" -> it stops and lists both ids; pass the id instead), and
        the group must take members through Graph. Distribution lists and mail-enabled
        security groups live in Exchange (use Add-M365DistributionListMember); dynamic and
        on-premises-synced groups cannot be added to directly. Any of those stops the call
        before the first change.
        Graph scopes: GroupMember.ReadWrite.All, User.Read.All.
    .PARAMETER UserPrincipalName
        The user (exact UPN).
    .PARAMETER GroupName
        Exact display names or object ids (GUIDs).
    .PARAMETER UserId
        The user's object id when an earlier step just created it, or New-M365Placeholder in a
        dry run of such a step (the user is then a member of nothing yet).
    .EXAMPLE
        Add-M365GroupMember -UserPrincipalName jane@contoso.com -GroupName 'All Staff', 'Sales' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [string]$UserPrincipalName,

        [Parameter(Mandatory)]
        [string[]]$GroupName,

        [Parameter()]
        [object]$UserId
    )
    $target = Resolve-M365TargetUser -UserPrincipalName $UserPrincipalName -UserId $UserId
    $props = 'id', 'displayName', 'groupTypes', 'mailEnabled', 'securityEnabled', 'onPremisesSyncEnabled'
    $kindOf = {
        param($g)
        $types = @(Get-M365ObjectProperty $g 'GroupTypes')
        if ($types -contains 'Unified') { 'Microsoft 365' }
        elseif (Get-M365ObjectProperty $g 'MailEnabled') { if (Get-M365ObjectProperty $g 'SecurityEnabled') { 'mail-enabled security' } else { 'distribution list' } }
        else { 'security' }
    }

    #region 1. Resolve and check every group before the first change ------------------
    $resolved = foreach ($name in $GroupName) {
        if ($name -match '[*?]') { throw "Group '$name' must be an exact name or id, not a wildcard. Nothing was changed." }
        if ($name -match $script:GuidPattern) {
            try { $g = Get-MgGroup -GroupId $name -Property $props -ErrorAction Stop }
            catch { throw "Group id '$name' could not be read: $($_.Exception.Message) Nothing was changed." }
        } else {
            $safe = $name.Replace("'", "''")
            $found = @(Get-MgGroup -Filter "displayName eq '$safe'" -All -Property $props -ErrorAction Stop | Where-Object { "$($_.DisplayName)" -eq $name })
            if ($found.Count -eq 0) { throw "No group is named '$name'. Nothing was changed." }
            if ($found.Count -gt 1) {
                throw "$($found.Count) groups are named '$name': $(($found | ForEach-Object { "$($_.Id) ($(& $kindOf $_))" }) -join '; '). Pass the id of the one you mean. Nothing was changed."
            }
            $g = $found[0]
        }
        $kind = & $kindOf $g
        $why = if ((Get-M365ObjectProperty $g 'MailEnabled') -and @(Get-M365ObjectProperty $g 'GroupTypes') -notcontains 'Unified') { "it is a $kind, which Exchange manages (use Add-M365DistributionListMember)" }
        elseif (@(Get-M365ObjectProperty $g 'GroupTypes') -contains 'DynamicMembership') { 'it has dynamic membership (its rule decides who is in it)' }
        elseif (Get-M365ObjectProperty $g 'OnPremisesSyncEnabled') { 'it is synced from on-premises AD (add the member there)' }
        else { $null }
        if ($why) { throw "Group '$name' ($($g.Id)) cannot take members here: $why. Nothing was changed." }
        [pscustomobject]@{ Name = $name; Group = $g; Kind = $kind }
    }
    #endregion

    #region 2. Add where not already a member ------------------------------------------
    foreach ($r in @($resolved)) {
        $g = $r.Group
        if (-not $target.Planned) {
            $isMember = [bool](Get-MgGroupMember -GroupId $g.Id -All -ErrorAction Stop | Where-Object { "$($_.Id)" -eq $target.Id })
            if ($isMember) { [pscustomobject]@{ Group = $r.Name; GroupId = "$($g.Id)"; Added = $false; Reason = 'already a member'; WhatIf = [bool]$WhatIfPreference }; continue }
        }
        $run = Invoke-M365Change -Caller $PSCmdlet -Service Graph -Action "Add $UserPrincipalName to $($r.Kind) group '$($g.DisplayName)'" `
            -Command 'New-MgGroupMember' -Parameters ([ordered]@{ GroupId = "$($g.Id)"; DirectoryObjectId = $target.Id })
        [pscustomobject]@{ Group = $r.Name; GroupId = "$($g.Id)"; Added = $run.Ran; Reason = $(if ($run.Ran) { $null } else { 'WhatIf' }); WhatIf = -not $run.Ran }
    }
    #endregion
}

function New-M365TemporaryAccessPass {
    <#
    .SYNOPSIS
        Issues a Temporary Access Pass so a user can sign in once and register MFA, without a shared password.
    .DESCRIPTION
        Requires the Temporary Access Pass authentication method to be enabled in the tenant
        (Entra > Authentication methods); the error from Graph says so if it is not. Returns
        the pass once. One-time use by default.
        Graph scopes: UserAuthenticationMethod.ReadWrite.All.
    .PARAMETER UserPrincipalName
        The user (exact UPN).
    .PARAMETER LifetimeHours
        Validity. Default 8, max 8 days per Microsoft.
    .PARAMETER Reusable
        Allow repeated use within the lifetime.
    .PARAMETER UserId
        The user's object id when an earlier step just created it, or New-M365Placeholder in a
        dry run of such a step.
    .EXAMPLE
        New-M365TemporaryAccessPass -UserPrincipalName jane@contoso.com -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [string]$UserPrincipalName,

        [Parameter()]
        [ValidateRange(1, 192)]
        [int]$LifetimeHours = 8,

        [Parameter()]
        [switch]$Reusable,

        [Parameter()]
        [object]$UserId
    )
    $target = Resolve-M365TargetUser -UserPrincipalName $UserPrincipalName -UserId $UserId
    $usableOnce = -not $Reusable.IsPresent
    $run = Invoke-M365Change -Caller $PSCmdlet -Service Graph -Action "Issue a $(if ($usableOnce) { 'one-time' } else { 'reusable' }) Temporary Access Pass for $UserPrincipalName, valid $LifetimeHours h" `
        -Command 'New-MgUserAuthenticationTemporaryAccessPassMethod' -Parameters ([ordered]@{ UserId = $target.Id; BodyParameter = @{ lifetimeInMinutes = $LifetimeHours * 60; isUsableOnce = $usableOnce } })
    if (-not $run.Ran) {
        return [pscustomobject]@{ UserPrincipalName = $UserPrincipalName; Pass = $null; ExpiresAt = $null; UsableOnce = $usableOnce; Issued = $false; WhatIf = $true }
    }
    #   GOTCHA Computing the expiry must never lose the pass that was just issued.
    $tap = $run.Output
    $minutes = Get-M365ObjectProperty $tap 'LifetimeInMinutes'
    if (-not $minutes) { $minutes = $LifetimeHours * 60 }
    $expires = try { ([datetime](Get-M365ObjectProperty $tap 'StartDateTime')).AddMinutes([int]$minutes) } catch { (Get-Date).AddMinutes([int]$minutes) }
    if ($expires.Year -lt 2000) { $expires = (Get-Date).AddMinutes([int]$minutes) }
    $once = Get-M365ObjectProperty $tap 'IsUsableOnce'
    [pscustomobject]@{ UserPrincipalName = $UserPrincipalName; Pass = (Get-M365ObjectProperty $tap 'TemporaryAccessPass'); ExpiresAt = $expires; UsableOnce = $(if ($null -ne $once) { [bool]$once } else { $usableOnce }); Issued = $true; WhatIf = $false }
}
#endregion

Export-ModuleMember -Function Get-M365UserReview, New-M365CloudUser, Add-M365RoleAssignment, Add-M365ConditionalAccessExclusion,
    New-M365BreakGlassAccount, New-M365AdminAccount, Set-M365TechnicalContact, Get-M365GdapRelationship,
    Get-M365LicenseSummary, Disable-M365UserSignIn, Remove-M365UserLicense,
    New-M365User, Add-M365UserLicense, Add-M365GroupMember, New-M365TemporaryAccessPass
