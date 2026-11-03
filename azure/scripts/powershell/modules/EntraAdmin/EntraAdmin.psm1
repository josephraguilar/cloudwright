#region Module setup ----------------------------------------------------------
#   WHAT   Entra ID users and groups: list and search, create, add to a group,
#          block or allow sign-in, reset a password, revoke sessions, assign a
#          licence. Everything goes through Microsoft Graph with the token of the
#          Az sign-in (Invoke-AzRestMethod), so no second module or sign-in.
#   WHY    These are the day-to-day helpdesk actions. Every one of them is
#          reversible: a blocked user can be allowed again, a new password can be
#          replaced, a licence can be removed in the admin center. Nothing here
#          deletes a user or a group, or removes a member or a licence; that
#          stays in the Entra admin center, done by a person who can see it.
#   GOTCHA Users and groups synced from Active Directory are owned by AD: a change
#          made in the cloud is overwritten at the next sync, or refused. Those are
#          refused here with a sentence instead. Dynamic groups cannot take members
#          by hand. Graph needs the right directory role on the signed-in account
#          (User Administrator for users, Groups Administrator for groups, License
#          Administrator for licences); a 403 says which call was refused.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:GraphRoot = 'https://graph.microsoft.com/v1.0'
#endregion

#region Graph plumbing --------------------------------------------------------
function Get-EntraProperty {
    # StrictMode throws on a missing property; Graph leaves some out entirely.
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $Default
}

function Invoke-EntraGraph {
    <#
    .SYNOPSIS
        One Graph call with the Az token. -All follows @odata.nextLink and returns
        every item of .value; otherwise the parsed body is returned.
    .PARAMETER Path
        Relative to /v1.0 (users?$select=id) or a full https URL.
    .PARAMETER Max
        With -All, stop after this many items.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [ValidateSet('GET', 'POST', 'PATCH')] [string]$Method = 'GET',
        [Parameter(Mandatory)] [string]$Path,
        [Parameter()] [object]$Body,
        [Parameter()] [switch]$All,
        [Parameter()] [int]$Max = 5000
    )
    $uri = if ($Path -match '^https://') { $Path } else { "$script:GraphRoot/$($Path.TrimStart('/'))" }
    $items = [System.Collections.Generic.List[object]]::new()
    while ($uri) {
        $p = @{ Method = $Method; Uri = $uri; ErrorAction = 'Stop' }
        if ($null -ne $Body) { $p.Payload = ($Body | ConvertTo-Json -Depth 10 -Compress) }
        $resp = Invoke-AzRestMethod @p
        if ($resp.StatusCode -ge 300) {
            $msg = $resp.Content
            try { $msg = (($resp.Content | ConvertFrom-Json).error.message) } catch { Write-Verbose 'Graph error body was not JSON.' }
            throw "Graph $Method $($uri -replace '\?.*$', '') returned $($resp.StatusCode): $msg"
        }
        if (-not $resp.Content) { return }
        $data = $resp.Content | ConvertFrom-Json
        if (-not $All) { return $data }
        foreach ($v in @(Get-EntraProperty $data 'value' @())) { $items.Add($v); if ($items.Count -ge $Max) { break } }
        $uri = if ($items.Count -lt $Max) { Get-EntraProperty $data '@odata.nextLink' } else { $null }
    }
    return $items.ToArray()   # unrolled on purpose: callers wrap in @() (a comma-return would nest inside @())
}

function ConvertTo-EntraFilterText {
    # A value inside a $filter string: single quotes doubled, then URL-escaped.
    param([string]$Text)
    return [uri]::EscapeDataString($Text.Replace("'", "''"))
}

function ConvertFrom-EntraSecureString {
    param([securestring]$Value)
    return [System.Net.NetworkCredential]::new('', $Value).Password
}

function New-EntraPassword {
    <#
    .SYNOPSIS
        A random password that meets Entra complexity: upper, lower, digit and
        symbol, no look-alike characters. Returned as a SecureString.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a string in memory; changes nothing.')]
    [CmdletBinding()]
    [OutputType([securestring])]
    param([Parameter()] [ValidateRange(12, 64)] [int]$Length = 16)
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#$%*-_=+?')
    $all = -join $sets
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($s in $sets) { $chars.Add($s[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($s.Length)]) }
    while ($chars.Count -lt $Length) { $chars.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)]) }
    # Shuffle so the first four characters are not always upper, lower, digit, symbol.
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($i + 1)
        $t = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $t
    }
    $ss = [securestring]::new()
    foreach ($c in $chars) { $ss.AppendChar($c) }
    $ss.MakeReadOnly()
    return $ss
}
#endregion

#region Lookups ---------------------------------------------------------------
function Get-EntraDomainInfo {
    <#
    .SYNOPSIS
        Verified domains of the tenant, default first: the choices for a new UPN.
    #>
    [CmdletBinding()]
    param()
    $d = Invoke-EntraGraph -Path 'domains?$select=id,isVerified,isDefault' -All
    $d | Where-Object { $_.isVerified } | Sort-Object @{ e = { -not $_.isDefault } }, id |
        ForEach-Object { [pscustomobject]@{ Name = $_.id; IsDefault = [bool]$_.isDefault } }
}

function Get-EntraLicenseInfo {
    <#
    .SYNOPSIS
        Licences the tenant owns: SKU, how many are in use and how many are free.
    #>
    [CmdletBinding()]
    param()
    $skus = Invoke-EntraGraph -Path 'subscribedSkus?$select=skuId,skuPartNumber,consumedUnits,prepaidUnits,capabilityStatus' -All
    foreach ($s in $skus | Sort-Object skuPartNumber) {
        $enabled = [int](Get-EntraProperty (Get-EntraProperty $s 'prepaidUnits') 'enabled' 0)
        [pscustomobject]@{
            Sku = $s.skuPartNumber; SkuId = $s.skuId; Status = $s.capabilityStatus
            Total = $enabled; Used = [int]$s.consumedUnits; Free = $enabled - [int]$s.consumedUnits
        }
    }
}

function ConvertTo-EntraUserRow {
    param($User, [hashtable]$SkuNames)
    $lic = @(Get-EntraProperty $User 'assignedLicenses' @() | ForEach-Object { if ($SkuNames.ContainsKey("$($_.skuId)")) { $SkuNames["$($_.skuId)"] } else { "$($_.skuId)" } })
    [pscustomobject]@{
        DisplayName       = $User.displayName
        UserPrincipalName = $User.userPrincipalName
        SignIn            = $(if ($User.accountEnabled) { 'Allowed' } else { 'Blocked' })
        Type              = Get-EntraProperty $User 'userType' ''
        Source            = $(if (Get-EntraProperty $User 'onPremisesSyncEnabled') { 'Synced from AD' } else { 'Cloud' })
        JobTitle          = Get-EntraProperty $User 'jobTitle' ''
        Department        = Get-EntraProperty $User 'department' ''
        UsageLocation     = Get-EntraProperty $User 'usageLocation' ''
        Licenses          = ($lic -join ', ')
        Created           = Get-EntraProperty $User 'createdDateTime' ''
        Id                = $User.id
    }
}

function Get-EntraUserInfo {
    <#
    .SYNOPSIS
        Users as flat rows. -Search matches the start of the display name, UPN or mail.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [string]$Search,
        [Parameter()] [int]$Max = 500
    )
    $select = 'id,displayName,userPrincipalName,accountEnabled,userType,onPremisesSyncEnabled,jobTitle,department,usageLocation,assignedLicenses,createdDateTime'
    $path = "users?`$select=$select&`$top=999"
    if ($Search) {
        $q = ConvertTo-EntraFilterText $Search
        $path += "&`$filter=startswith(displayName,'$q')%20or%20startswith(userPrincipalName,'$q')%20or%20startswith(mail,'$q')"
    }
    $skuNames = @{}
    try { foreach ($s in Get-EntraLicenseInfo) { $skuNames["$($s.SkuId)"] = $s.Sku } } catch { Write-Verbose "Licence names unavailable: $($_.Exception.Message)" }
    foreach ($u in (Invoke-EntraGraph -Path $path -All -Max $Max) | Sort-Object displayName) { ConvertTo-EntraUserRow -User $u -SkuNames $skuNames }
}

function Resolve-EntraUser {
    <#
    .SYNOPSIS
        One user by UPN or object ID, with the fields the actions need. Throws
        with a sentence when the user does not exist.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$User)
    $select = 'id,displayName,userPrincipalName,accountEnabled,onPremisesSyncEnabled,usageLocation,assignedLicenses'
    try { return Invoke-EntraGraph -Path "users/$([uri]::EscapeDataString($User))?`$select=$select" }
    catch { if ($_.Exception.Message -match ' 404:') { throw "No user '$User' in this tenant." } else { throw } }
}

function Assert-EntraCloudUser {
    param($User, [string]$Action)
    if (Get-EntraProperty $User 'onPremisesSyncEnabled') {
        throw "$($User.userPrincipalName) is synced from Active Directory. $Action it in AD; a cloud change would be overwritten at the next sync."
    }
}

function Get-EntraUserGroupInfo {
    <#
    .SYNOPSIS
        Groups a user is a direct member of.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$User)
    $u = Resolve-EntraUser $User
    $groups = Invoke-EntraGraph -Path "users/$($u.id)/memberOf/microsoft.graph.group?`$select=id,displayName,securityEnabled,groupTypes" -All
    foreach ($g in $groups | Sort-Object displayName) {
        [pscustomobject]@{ DisplayName = $g.displayName; Type = (Get-EntraGroupKind $g); Id = $g.id }
    }
}

function Get-EntraGroupKind {
    param($Group)
    $types = @(Get-EntraProperty $Group 'groupTypes' @())
    $kind = if ($types -contains 'Unified') { 'Microsoft 365' }
            elseif ((Get-EntraProperty $Group 'mailEnabled') -and (Get-EntraProperty $Group 'securityEnabled')) { 'Mail-enabled security' }
            elseif (Get-EntraProperty $Group 'securityEnabled') { 'Security' }
            else { 'Distribution' }
    if ($types -contains 'DynamicMembership') { $kind += ' (dynamic)' }
    return $kind
}

function Get-EntraGroupInfo {
    <#
    .SYNOPSIS
        Groups as flat rows. -Search matches the start of the display name.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [string]$Search,
        [Parameter()] [int]$Max = 500
    )
    $path = "groups?`$select=id,displayName,description,securityEnabled,mailEnabled,groupTypes,membershipRule,onPremisesSyncEnabled,createdDateTime&`$top=999"
    if ($Search) { $path += "&`$filter=startswith(displayName,'$(ConvertTo-EntraFilterText $Search)')" }
    foreach ($g in (Invoke-EntraGraph -Path $path -All -Max $Max) | Sort-Object displayName) {
        [pscustomobject]@{
            DisplayName = $g.displayName
            Type        = Get-EntraGroupKind $g
            Source      = $(if (Get-EntraProperty $g 'onPremisesSyncEnabled') { 'Synced from AD' } else { 'Cloud' })
            Description = Get-EntraProperty $g 'description' ''
            Rule        = Get-EntraProperty $g 'membershipRule' ''
            Created     = Get-EntraProperty $g 'createdDateTime' ''
            Id          = $g.id
        }
    }
}

function Get-EntraGroupMemberInfo {
    <#
    .SYNOPSIS
        Direct members of a group: users, devices, groups and service principals.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$GroupId)
    $m = Invoke-EntraGraph -Path "groups/$GroupId/members?`$select=id,displayName,userPrincipalName,accountEnabled" -All
    foreach ($x in $m | Sort-Object displayName) {
        [pscustomobject]@{
            DisplayName       = $x.displayName
            Kind              = ("$(Get-EntraProperty $x '@odata.type' '')" -replace '^#microsoft\.graph\.', '')
            UserPrincipalName = Get-EntraProperty $x 'userPrincipalName' ''
            Id                = $x.id
        }
    }
}
#endregion

#region Create ----------------------------------------------------------------
function New-EntraUser {
    <#
    .SYNOPSIS
        A cloud user. Without -Password a random one is generated. Returns the user
        row plus TemporaryPassword as a SecureString (never written to a stream).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter(Mandatory)] [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')] [string]$UserPrincipalName,
        [Parameter()] [securestring]$Password,
        [Parameter()] [bool]$ForceChangePassword = $true,
        [Parameter()] [string]$GivenName,
        [Parameter()] [string]$Surname,
        [Parameter()] [string]$JobTitle,
        [Parameter()] [string]$Department,
        [Parameter()] [ValidatePattern('^$|^[A-Z]{2}$')] [string]$UsageLocation
    )
    $existing = $null
    try { $existing = Resolve-EntraUser $UserPrincipalName } catch { if ($_.Exception.Message -notmatch '^No user') { throw } }
    if ($existing) { throw "$UserPrincipalName already exists ($($existing.id))." }
    if (-not $Password) { $Password = New-EntraPassword }
    $body = [ordered]@{
        accountEnabled    = $true
        displayName       = $DisplayName
        userPrincipalName = $UserPrincipalName
        mailNickname      = (($UserPrincipalName -split '@')[0] -replace '[^A-Za-z0-9._-]', '')
        passwordProfile   = @{ forceChangePasswordNextSignIn = $ForceChangePassword; password = (ConvertFrom-EntraSecureString $Password) }
    }
    foreach ($k in 'GivenName', 'Surname', 'JobTitle', 'Department', 'UsageLocation') {
        if ($PSBoundParameters.ContainsKey($k) -and $PSBoundParameters[$k]) { $body[$k.Substring(0, 1).ToLower() + $k.Substring(1)] = $PSBoundParameters[$k] }
    }
    if (-not $PSCmdlet.ShouldProcess($UserPrincipalName, 'Create Entra user')) { return }
    $u = Invoke-EntraGraph -Method POST -Path 'users' -Body $body
    $body.passwordProfile.password = $null
    Write-Verbose "Created $UserPrincipalName ($($u.id))."
    [pscustomobject]@{ DisplayName = $DisplayName; UserPrincipalName = $UserPrincipalName; Id = $u.id; TemporaryPassword = $Password; MustChange = $ForceChangePassword }
}

function New-EntraGroup {
    <#
    .SYNOPSIS
        A cloud security group. If one with the same name exists it is returned
        instead, with a warning, so a second click never makes a duplicate.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter()] [string]$Description,
        [Parameter()] [string]$MailNickname
    )
    $same = @(Invoke-EntraGraph -Path "groups?`$select=id,displayName&`$filter=displayName%20eq%20'$(ConvertTo-EntraFilterText $DisplayName)'" -All)
    if ($same.Count -gt 0) {
        Write-Warning "A group named '$DisplayName' already exists ($($same[0].id)); using it."
        return [pscustomobject]@{ DisplayName = $same[0].displayName; Id = $same[0].id; Created = $false }
    }
    if (-not $MailNickname) { $MailNickname = ($DisplayName -replace '[^A-Za-z0-9]', '') }
    if (-not $MailNickname) { $MailNickname = 'group' + (Get-Random -Maximum 99999) }
    $body = @{ displayName = $DisplayName; mailEnabled = $false; mailNickname = $MailNickname; securityEnabled = $true }
    if ($Description) { $body.description = $Description }
    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Create Entra security group')) { return }
    $g = Invoke-EntraGraph -Method POST -Path 'groups' -Body $body
    Write-Verbose "Created group $DisplayName ($($g.id))."
    [pscustomobject]@{ DisplayName = $DisplayName; Id = $g.id; Created = $true }
}
#endregion

#region Change ----------------------------------------------------------------
function Add-EntraGroupMember {
    <#
    .SYNOPSIS
        Add a user (UPN or ID) to a group. Already a member is not an error.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$GroupId,
        [Parameter(Mandatory)] [string]$User
    )
    $g = Invoke-EntraGraph -Path "groups/$GroupId`?`$select=id,displayName,groupTypes,onPremisesSyncEnabled"
    if (@(Get-EntraProperty $g 'groupTypes' @()) -contains 'DynamicMembership') { throw "$($g.displayName) is a dynamic group; its rule decides the members." }
    if (Get-EntraProperty $g 'onPremisesSyncEnabled') { throw "$($g.displayName) is synced from Active Directory. Add the member in AD." }
    $u = Resolve-EntraUser $User
    if (-not $PSCmdlet.ShouldProcess("$($u.userPrincipalName) -> $($g.displayName)", 'Add group member')) { return }
    try {
        $null = Invoke-EntraGraph -Method POST -Path "groups/$($g.id)/members/`$ref" -Body @{ '@odata.id' = "$script:GraphRoot/directoryObjects/$($u.id)" }
        Write-Verbose "Added $($u.userPrincipalName) to $($g.displayName)."
        $state = 'Added'
    } catch {
        if ($_.Exception.Message -match 'already exist') { Write-Verbose "$($u.userPrincipalName) is already in $($g.displayName)."; $state = 'Already a member' } else { throw }
    }
    [pscustomobject]@{ User = $u.userPrincipalName; Group = $g.displayName; Result = $state }
}

function Set-EntraUserSignIn {
    <#
    .SYNOPSIS
        Block or allow sign-in. Blocking also revokes the user's refresh tokens so
        open sessions end within the hour.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$User,
        [Parameter(Mandatory)] [bool]$Enabled
    )
    $u = Resolve-EntraUser $User
    Assert-EntraCloudUser $u $(if ($Enabled) { 'Enable' } else { 'Disable' })
    $verb = if ($Enabled) { 'Allow sign-in' } else { 'Block sign-in' }
    if (-not $PSCmdlet.ShouldProcess($u.userPrincipalName, $verb)) { return }
    $null = Invoke-EntraGraph -Method PATCH -Path "users/$($u.id)" -Body @{ accountEnabled = $Enabled }
    if (-not $Enabled) { $null = Invoke-EntraGraph -Method POST -Path "users/$($u.id)/revokeSignInSessions" }
    Write-Verbose "$verb for $($u.userPrincipalName)."
    [pscustomobject]@{ User = $u.userPrincipalName; Result = $verb }
}

function Reset-EntraUserPassword {
    <#
    .SYNOPSIS
        Set a new password (random unless given). Returns it as a SecureString in
        TemporaryPassword; nothing is written to the verbose or output text.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$User,
        [Parameter()] [securestring]$Password,
        [Parameter()] [bool]$ForceChangePassword = $true
    )
    $u = Resolve-EntraUser $User
    Assert-EntraCloudUser $u 'Reset the password'
    if (-not $Password) { $Password = New-EntraPassword }
    if (-not $PSCmdlet.ShouldProcess($u.userPrincipalName, 'Reset password')) { return }
    $null = Invoke-EntraGraph -Method PATCH -Path "users/$($u.id)" -Body @{ passwordProfile = @{ forceChangePasswordNextSignIn = $ForceChangePassword; password = (ConvertFrom-EntraSecureString $Password) } }
    Write-Verbose "Password reset for $($u.userPrincipalName)$(if ($ForceChangePassword) { '; they must change it at next sign-in' })."
    [pscustomobject]@{ User = $u.userPrincipalName; Result = 'Password reset'; TemporaryPassword = $Password; MustChange = $ForceChangePassword }
}

function Revoke-EntraUserSession {
    <#
    .SYNOPSIS
        Invalidate refresh tokens and session cookies: apps ask the user to sign
        in again within the hour. Use after a password reset or a lost device.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string]$User)
    $u = Resolve-EntraUser $User
    if (-not $PSCmdlet.ShouldProcess($u.userPrincipalName, 'Revoke sign-in sessions')) { return }
    $null = Invoke-EntraGraph -Method POST -Path "users/$($u.id)/revokeSignInSessions"
    Write-Verbose "Sessions revoked for $($u.userPrincipalName)."
    [pscustomobject]@{ User = $u.userPrincipalName; Result = 'Sessions revoked' }
}

function Add-EntraUserLicense {
    <#
    .SYNOPSIS
        Assign one licence SKU. The user needs a usage location first; pass
        -UsageLocation to set it on the way.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$User,
        [Parameter(Mandatory)] [guid]$SkuId,
        [Parameter()] [ValidatePattern('^$|^[A-Z]{2}$')] [string]$UsageLocation
    )
    $u = Resolve-EntraUser $User
    $has = @(Get-EntraProperty $u 'assignedLicenses' @() | Where-Object { "$($_.skuId)" -eq "$SkuId" })
    if ($has.Count -gt 0) { Write-Verbose "$($u.userPrincipalName) already has that licence."; return [pscustomobject]@{ User = $u.userPrincipalName; Result = 'Already licensed' } }
    $sku = Get-EntraLicenseInfo | Where-Object { "$($_.SkuId)" -eq "$SkuId" } | Select-Object -First 1
    if (-not $sku) { throw "The tenant has no licence with SKU ID $SkuId." }
    if ($sku.Free -le 0) { throw "No free $($sku.Sku) licences ($($sku.Used) of $($sku.Total) in use)." }
    $loc = Get-EntraProperty $u 'usageLocation'
    if (-not $loc -and -not $UsageLocation) { throw "$($u.userPrincipalName) has no usage location. Pass -UsageLocation (two letters, for example US)." }
    if (-not $PSCmdlet.ShouldProcess($u.userPrincipalName, "Assign $($sku.Sku)")) { return }
    if ($UsageLocation -and $UsageLocation -ne $loc) { $null = Invoke-EntraGraph -Method PATCH -Path "users/$($u.id)" -Body @{ usageLocation = $UsageLocation } }
    $null = Invoke-EntraGraph -Method POST -Path "users/$($u.id)/assignLicense" -Body @{ addLicenses = @(@{ skuId = "$SkuId"; disabledPlans = @() }); removeLicenses = @() }
    Write-Verbose "Assigned $($sku.Sku) to $($u.userPrincipalName)."
    [pscustomobject]@{ User = $u.userPrincipalName; Result = "Assigned $($sku.Sku)" }
}
#endregion
