#region Module setup ----------------------------------------------------------
#   WHAT   Strict mode, M365Helpers by path, and the fixed role table.
#   WHY    Everything here runs in OUR partner tenant with Graph. Role template IDs
#          are the same in every Entra tenant, so one fixed table resolves every role
#          name, offline or signed in. The GUI count, the dry run and the real run
#          therefore always mean the same roles ("allAdmin" never grows because a
#          Graph session happens to exist).
#   GOTCHA Microsoft Graph v1.0 only: /tenantRelationships/delegatedAdminRelationships.
#          Every change goes through Invoke-M365Change (M365Helpers): it shows the exact
#          Graph call first, records it in the plan and runs exactly that.
Set-StrictMode -Version Latest
if (-not (Get-Module -Name M365Helpers)) {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Helpers' 'M365Helpers.psd1') -ErrorAction Stop
}

#   WHAT   Entra built-in role template ids (Microsoft Learn: "Microsoft Entra built-in roles",
#          permissions-reference). Add a role here only after checking its id there; a role
#          not in this table must be given to the template as its GUID.
$script:WellKnownRoles = @{
    'Global Administrator'                    = '62e90394-69f5-4237-9190-012177145e10'
    'Global Reader'                           = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
    'Helpdesk Administrator'                  = '729827e3-9c14-49f7-bb1b-9608f156bbb8'
    'Service Support Administrator'           = 'f023fd81-a637-4b56-95fd-791ac0226033'
    'User Administrator'                      = 'fe930be7-5e62-47db-91af-98c3a49a38b1'
    'License Administrator'                   = '4d6ac14f-3453-41d0-bef9-a3e0c569773a'
    'Groups Administrator'                    = 'fdd7a751-b60b-444a-984c-02652fe8fa1c'
    'Exchange Administrator'                  = '29232cdf-9323-42fd-ade2-1d097af3e4de'
    'SharePoint Administrator'                = 'f28a1f50-f6e7-4571-818b-6a12f2af6b6c'
    'Teams Administrator'                     = '69091246-20e8-4a56-aa4d-066075b2a7a8'
    'Intune Administrator'                    = '3a2c62db-5318-420d-8d74-23affee5d9d5'
    'Security Administrator'                  = '194ae4cb-b126-40b2-bd5b-6091b380977d'
    'Security Reader'                         = '5d6b6bb7-de71-4623-b4af-96380a352509'
    'Conditional Access Administrator'        = 'b1be1c3e-b65d-4f19-8427-f6fa0d97feb9'
    'Authentication Administrator'            = 'c4e39bd9-1100-46d3-8c65-fb160da0071f'
    'Privileged Authentication Administrator' = '7be44c8a-adaf-4e2a-84d6-ab2649e08a13'
    'Privileged Role Administrator'           = 'e8611ab8-c189-46e8-94e1-60213ab1f814'
    'Cloud Application Administrator'         = '158c047a-c907-4556-b7ef-446551a6b5f7'
    'Application Administrator'               = '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3'
    'Domain Name Administrator'               = '8329153b-31d0-4727-b945-745eb3bc5f31'
    'Directory Readers'                       = '88d8e3e3-8f55-4a1e-953a-9b9898b8876b'
    'Reports Reader'                          = '4a5d8f65-41da-4de4-8968-e035b65339cf'
    'Billing Administrator'                   = 'b0f54661-2d74-4c50-afa3-1ec803f12efe'
    'Compliance Administrator'                = '17315797-102d-40b4-93e0-432062caca18'
    'Password Administrator'                  = '966707d0-3269-4727-9be2-8c3a10f19b9d'
    'Windows 365 Administrator'               = '11451d60-acb2-45eb-a7d6-43d0f0125c13'
    'Teams Communications Administrator'      = 'baf37b3a-610e-45da-9e62-d9d1e5e8914b'
}
$script:GlobalAdminRoleId = $script:WellKnownRoles['Global Administrator']
#   WHAT   Roles that can take over the whole customer tenant; always listed first and flagged.
$script:PrivilegedRoleIds = @(
    $script:WellKnownRoles['Global Administrator']
    $script:WellKnownRoles['Privileged Role Administrator']
    $script:WellKnownRoles['Privileged Authentication Administrator']
)
$script:GuidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
$script:GraphBase = 'https://graph.microsoft.com/v1.0'
#endregion

#region Roles and template ----------------------------------------------------
function Get-GdapRoleCatalog {
    <#
    .SYNOPSIS
        Internal: name -> id map. Always the fixed table above, never the live Graph list.
    #>
    [CmdletBinding()]
    param()
    return (@{} + $script:WellKnownRoles)
}

function Get-GdapRoleId {
    <#
    .SYNOPSIS
        Resolves an Entra role display name (or GUID) to its role definition id.
    .PARAMETER Role
        Display name, e.g. 'Exchange Administrator', or a GUID (returned as-is, lower-cased).
    .EXAMPLE
        Get-GdapRoleId 'Global Reader'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string[]]$Role
    )
    process {
        $catalog = Get-GdapRoleCatalog
        foreach ($r in $Role) {
            if ($r -match $script:GuidPattern) { $r.ToLowerInvariant(); continue }
            $key = $catalog.Keys | Where-Object { $_ -ieq $r } | Select-Object -First 1
            if (-not $key) { throw "Unknown Entra role '$r'. The toolkit resolves only the roles in its verified table ($(@($catalog.Keys | Sort-Object) -join ', ')). For any other role, put its role definition GUID in the template." }
            $catalog[$key].ToLowerInvariant()
        }
    }
}

function Get-GdapRoleName {
    <#
    .SYNOPSIS
        Resolves a role definition id to its display name (falls back to the id).
    .EXAMPLE
        Get-GdapRoleName '62e90394-69f5-4237-9190-012177145e10'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string[]]$RoleId
    )
    process {
        $catalog = Get-GdapRoleCatalog
        foreach ($id in $RoleId) {
            $hit = $catalog.GetEnumerator() | Where-Object { $_.Value -ieq $id } | Select-Object -First 1
            if ($hit) { $hit.Key } else { $id }
        }
    }
}

function Get-GdapAdminRoleName {
    <#
    .SYNOPSIS
        The "allAdmin" role set: every role in the toolkit's fixed table (all ending in Administrator, plus the four reader roles).
    .DESCRIPTION
        Always the same list, signed in or not, so the GUI's role count, the dry run and the
        real run agree. Includes Global Administrator (owner's decision for Admin Agents).
    .EXAMPLE
        Get-GdapAdminRoleName
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $catalog = Get-GdapRoleCatalog
    $readers = @('Global Reader', 'Security Reader', 'Reports Reader', 'Directory Readers')
    return @($catalog.Keys | Where-Object { $_ -match '(?i)administrator$' -or $readers -contains $_ } | Sort-Object -Unique)
}

function Get-GdapRoleList {
    <#
    .SYNOPSIS
        Role ids as readable rows (Name, Id, Privileged), the highly privileged roles first.
    .DESCRIPTION
        Global Administrator, Privileged Role Administrator and Privileged Authentication
        Administrator come first (in that order) with Privileged = $true; the rest follow by
        name. Use it wherever roles are shown to the operator.
    .PARAMETER RoleIds
        Role definition ids (e.g. $template.RoleIds or $assessment.MissingRoleIds).
    .EXAMPLE
        Get-GdapRoleList -RoleIds $template.RoleIds | ForEach-Object { $_.Name }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$RoleIds
    )
    $ids = @($RoleIds | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    $rows = foreach ($id in $ids) {
        $rank = [array]::IndexOf($script:PrivilegedRoleIds, $id)
        [pscustomobject]@{ Name = (Get-GdapRoleName -RoleId $id); Id = $id; Privileged = ($rank -ge 0); Rank = $(if ($rank -ge 0) { $rank } else { 99 }) }
    }
    @($rows | Sort-Object Rank, Name | Select-Object Name, Id, Privileged)
}

function Format-GdapRoleList {
    <#
    .SYNOPSIS
        One readable line naming every role, highly privileged ones first and flagged.
    .EXAMPLE
        Format-GdapRoleList -RoleIds $template.RoleIds
        # 27 roles - HIGHLY PRIVILEGED: Global Administrator, Privileged Role Administrator, Privileged Authentication Administrator; also: Application Administrator, ...
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$RoleIds
    )
    $rows = @(Get-GdapRoleList -RoleIds $RoleIds)
    $count = "$($rows.Count) role$(if ($rows.Count -ne 1) { 's' })"
    $priv = @($rows | Where-Object { $_.Privileged } | ForEach-Object { $_.Name })
    $rest = @($rows | Where-Object { -not $_.Privileged } | ForEach-Object { $_.Name })
    if ($priv.Count -eq 0) { return "${count}: $($rest -join ', ')" }
    $text = "$count - HIGHLY PRIVILEGED: $($priv -join ', ')"
    if ($rest.Count -gt 0) { $text += "; also: $($rest -join ', ')" }
    return $text
}

function Test-GdapDuration {
    <#
    .SYNOPSIS
        Validates an ISO 8601 day duration for GDAP (P1D to P730D) or an auto-extend value (PT0S or P180D).
    .PARAMETER Duration
        The value to check.
    .PARAMETER AutoExtend
        Validate as an autoExtendDuration instead of a relationship duration.
    .EXAMPLE
        Test-GdapDuration -Duration P730D
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Duration,

        [Parameter()]
        [switch]$AutoExtend
    )
    if ($AutoExtend) { return ($Duration -in 'PT0S', 'P180D') }
    if ($Duration -notmatch '^P(\d{1,3})D$') { return $false }
    $days = [int]$Matches[1]
    return ($days -ge 1 -and $days -le 730)
}

function Get-GdapTemplate {
    <#
    .SYNOPSIS
        Loads and validates the MSP GDAP role template (roles, duration, auto-extend, security groups).
    .DESCRIPTION
        Reads config/<partner.gdapTemplate> (default gdap-roles.local.json) or -Path. Resolves
        every role name to its id from the fixed role table, checks durations, rejects
        <placeholder> group ids, and enforces the Microsoft rule that a template containing
        Global Administrator cannot auto-extend. Returns the template with RoleIds added to
        the root and each group.
    .PARAMETER Path
        Explicit template file.
    .PARAMETER Settings
        MSP settings; loaded if omitted.
    .EXAMPLE
        $template = Get-GdapTemplate
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Path,

        [Parameter()]
        [object]$Settings
    )

    if (-not $Path) {
        if (-not $Settings) { $Settings = Get-M365Settings }
        $file = if ($Settings.PSObject.Properties.Name -contains 'partner' -and $Settings.partner.gdapTemplate) { $Settings.partner.gdapTemplate } else { 'gdap-roles.local.json' }
        $Path = Join-Path $PSScriptRoot '..' '..' '..' '..' 'config' $file
    }
    if (-not (Test-Path $Path)) { throw "GDAP template not found: $Path. Copy config/gdap-roles.example.json to config/gdap-roles.local.json and fill in the group ids." }
    $t = Get-Content -Path $Path -Raw | ConvertFrom-Json

    foreach ($key in 'name', 'duration', 'autoExtendDuration', 'roles') {
        if (-not ($t.PSObject.Properties.Name -contains $key) -or -not $t.$key) { throw "GDAP template is missing '$key' ($Path)." }
    }
    if (-not ($t.roles -is [string]) -and @($t.roles).Count -eq 0) { throw "GDAP template has an empty roles list ($Path)." }
    if (-not (Test-GdapDuration -Duration $t.duration)) { throw "GDAP template duration '$($t.duration)' must be P1D..P730D." }
    if (-not (Test-GdapDuration -Duration $t.autoExtendDuration -AutoExtend)) { throw "GDAP template autoExtendDuration '$($t.autoExtendDuration)' must be PT0S or P180D." }
    if (-not ($t.PSObject.Properties.Name -contains 'displayNamePattern') -or -not $t.displayNamePattern) {
        $t | Add-Member -NotePropertyName displayNamePattern -NotePropertyValue 'GDAP - {customer}' -Force
    }
    if ($t.displayNamePattern -notmatch '\{customer\}') { throw "displayNamePattern must contain {customer}." }

    #   WHAT   roles: a list of names, or "allAdmin" (the fixed table, resolved now so the request body is explicit).
    $roleNames = @(if ($t.roles -is [string] -and $t.roles -ieq 'allAdmin') { Get-GdapAdminRoleName } else { @($t.roles) })
    $t | Add-Member -NotePropertyName RoleNames -NotePropertyValue @($roleNames) -Force
    $roleIds = @($roleNames | Get-GdapRoleId | Sort-Object -Unique)
    if ($roleIds -contains $script:GlobalAdminRoleId -and $t.autoExtendDuration -ne 'PT0S') {
        throw 'A GDAP relationship that includes Global Administrator cannot auto-extend. Set autoExtendDuration to PT0S or remove Global Administrator.'
    }
    $t | Add-Member -NotePropertyName RoleIds -NotePropertyValue $roleIds -Force

    $groups = @()
    if ($t.PSObject.Properties.Name -contains 'groups' -and $t.groups) {
        foreach ($g in $t.groups) {
            if (-not $g.id -or "$($g.id)" -match '^<.*>$') { throw "Group '$($g.name)' in the GDAP template has no object id (still a placeholder). Fill it in from Entra." }
            if ($g.id -notmatch $script:GuidPattern) { throw "Group '$($g.name)' id '$($g.id)' is not a GUID." }
            $gRoleNames = @(if ($g.roles -is [string] -and $g.roles -ieq 'all') { @($roleNames) } else { @($g.roles) })
            $gRoleIds = @($gRoleNames | Get-GdapRoleId | Sort-Object -Unique)
            $outside = @($gRoleIds | Where-Object { $roleIds -notcontains $_ })
            if ($outside.Count -gt 0) { throw "Group '$($g.name)' asks for roles not in the template: $(($outside | Get-GdapRoleName) -join ', ')." }
            $groups += [pscustomobject]@{ Name = $g.name; Id = $g.id.ToLowerInvariant(); Roles = @($gRoleNames); RoleIds = $gRoleIds }
        }
    }
    $t | Add-Member -NotePropertyName Groups -NotePropertyValue $groups -Force
    $t | Add-Member -NotePropertyName Path -NotePropertyValue $Path -Force
    return $t
}

function Get-GdapApprovalUrl {
    <#
    .SYNOPSIS
        Builds the customer approval link for a GDAP relationship id.
    .DESCRIPTION
        The link is deterministic; Partner Center shows the same one. The customer's Global
        Administrator opens it, signs in on Microsoft's page, reviews the roles and approves.
        It only works once the relationship is locked for approval (status approvalPending).
    .EXAMPLE
        Get-GdapApprovalUrl -RelationshipId $rel.Id
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RelationshipId
    )
    return "https://admin.microsoft.com/AdminPortal/Home#/partners/invitation/granularAdminRelationships/$RelationshipId"
}

function Get-GdapDisplayName {
    # Internal. "<pattern with customer> yyyy-MM-dd", at most 50 characters (Graph limit), only
    # characters Partner Center accepts. The customer part is shortened, never the date: the
    # date keeps a replacement or supplementary request from reusing an existing name.
    param([string]$Pattern, [string]$CustomerName, [datetime]$Date)
    $suffix = ' ' + $Date.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
    $cleanPattern = ($Pattern -replace '[^A-Za-z0-9 ._{}-]', '' -replace '\s+', ' ')
    $customer = ($CustomerName -replace '[^A-Za-z0-9 ._-]', '' -replace '\s+', ' ').Trim()
    if (-not $customer) { throw "Customer name '$CustomerName' has no letters or digits to build a relationship name from. Pass -CustomerName." }
    $budget = 50 - $suffix.Length - $cleanPattern.Replace('{customer}', '').Length
    if ($budget -lt 3) { throw "displayNamePattern '$Pattern' leaves no room for the customer name within 50 characters." }
    if ($customer.Length -gt $budget) { $customer = $customer.Substring(0, $budget).TrimEnd() }
    return (($cleanPattern.Replace('{customer}', $customer) + $suffix) -replace '\s+', ' ').Trim()
}

function Get-GdapPropertyValue {
    # Internal. A property's value, or $null when the object or property is missing (StrictMode-safe).
    param([object]$InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Format-GdapCustomerLabel {
    # Internal. "customer 'Contoso Ltd' (contoso.onmicrosoft.com, tenant <guid>)"; names both when ours differs.
    param([string]$CustomerName, [object]$TenantInfo, [string]$TenantId)
    $tenantName = Get-GdapPropertyValue $TenantInfo 'DisplayName'
    $domainName = Get-GdapPropertyValue $TenantInfo 'DefaultDomainName'
    $domain = if ($domainName) { "$domainName, " } else { '' }
    $where = "($domain" + "tenant $TenantId)"
    if (-not $tenantName) { return "customer '$CustomerName' $where" }
    if (-not $CustomerName -or $CustomerName -ieq $tenantName) { return "customer '$tenantName' $where" }
    return "customer '$CustomerName' = tenant '$tenantName' $where"
}

function Get-GdapRequestSummary {
    <#
    .SYNOPSIS
        Everything a GDAP request will contain, in plain words: customer, tenant domain, name, duration, auto-extend and every role.
    .DESCRIPTION
        Pure. New-GdapRequest uses .Text as the plan line for the create, the partner scripts
        use it in their confirmation, and the GUI can show it before a request. Role names are
        listed in full, Global Administrator / Privileged Role Administrator / Privileged
        Authentication Administrator first. DisplayName gets today's date (unique per day).
    .PARAMETER CustomerTenantId
        Customer tenant GUID.
    .PARAMETER CustomerName
        Our name for the customer (used in the relationship name).
    .PARAMETER Template
        From Get-GdapTemplate.
    .PARAMETER TenantInfo
        From Get-GdapTenantInfo for the same tenant.
    .PARAMETER RoleIds
        Roles to request. Default: every template role.
    .PARAMETER DisplayName
        Exact relationship name instead of the template pattern (max 50, letters, digits, space . _ -).
    .PARAMETER Date
        Date for the name suffix. Default today.
    .EXAMPLE
        (Get-GdapRequestSummary -CustomerTenantId $tid -CustomerName 'Contoso' -Template $template -TenantInfo (Get-GdapTenantInfo -TenantId $tid)).Text
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CustomerTenantId,

        [Parameter(Mandatory)]
        [string]$CustomerName,

        [Parameter(Mandatory)]
        [object]$Template,

        [Parameter(Mandatory)]
        [object]$TenantInfo,

        [Parameter()]
        [string[]]$RoleIds,

        [Parameter()]
        [string]$DisplayName,

        [Parameter()]
        [datetime]$Date = (Get-Date)
    )
    if ($CustomerTenantId -notmatch $script:GuidPattern) { throw "CustomerTenantId must be a GUID. Resolve a domain first with Resolve-M365TenantId." }
    $tid = $CustomerTenantId.ToLowerInvariant()
    $infoTenant = Get-GdapPropertyValue $TenantInfo 'TenantId'
    if ($infoTenant -and "$infoTenant" -ine $tid) { throw "Tenant information is for $infoTenant, not $tid. Stopped." }
    if (-not $RoleIds) { $RoleIds = @($Template.RoleIds) }
    $RoleIds = @($RoleIds | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    if ($RoleIds.Count -eq 0) { throw 'No roles to request.' }
    if (-not (Test-GdapDuration -Duration $Template.duration)) { throw "Invalid duration '$($Template.duration)'." }
    $autoExtend = "$($Template.autoExtendDuration)"
    if (-not (Test-GdapDuration -Duration $autoExtend -AutoExtend)) { throw "Invalid autoExtendDuration '$autoExtend'." }
    if ($RoleIds -contains $script:GlobalAdminRoleId -and $autoExtend -ne 'PT0S') { throw 'Relationships that include Global Administrator cannot auto-extend. Set autoExtendDuration to PT0S.' }

    if ($DisplayName) {
        if ($DisplayName.Length -gt 50 -or $DisplayName -notmatch '^[A-Za-z0-9 ._-]+$') { throw "DisplayName '$DisplayName' must be at most 50 characters of letters, digits, space, '.', '_' or '-'." }
        $name = $DisplayName
    } else {
        $name = Get-GdapDisplayName -Pattern $Template.displayNamePattern -CustomerName $CustomerName -Date $Date
    }
    $days = [int]($Template.duration -replace '\D', '')
    $durationText = "$days days ($($Template.duration))"
    $autoText = if ($autoExtend -eq 'PT0S') { 'no auto-extend' } else { "auto-extends by $(($autoExtend -replace '\D', '')) days ($autoExtend)" }
    $roles = @(Get-GdapRoleList -RoleIds $RoleIds)
    $customerLabel = Format-GdapCustomerLabel -CustomerName $CustomerName -TenantInfo $TenantInfo -TenantId $tid
    [pscustomobject]@{
        DisplayName         = $name
        CustomerTenantId    = $tid
        CustomerName        = $CustomerName
        TenantDisplayName   = Get-GdapPropertyValue $TenantInfo 'DisplayName'
        TenantDomain        = Get-GdapPropertyValue $TenantInfo 'DefaultDomainName'
        Duration            = $Template.duration
        AutoExtendDuration  = $autoExtend
        RoleIds             = $RoleIds
        RoleNames           = @($roles | ForEach-Object { $_.Name })
        PrivilegedRoleNames = @($roles | Where-Object { $_.Privileged } | ForEach-Object { $_.Name })
        CustomerLabel       = $customerLabel
        Text                = "Request GDAP admin access to $customerLabel as relationship '$name': $durationText, $autoText, $(Format-GdapRoleList -RoleIds $RoleIds)"
    }
}
#endregion

function Open-GdapApprovalPage {
    <#
    .SYNOPSIS
        Opens the customer approval page on this machine in a private browser window.
    .DESCRIPTION
        The technician is normally the approver, signing in with their own admin account in
        the customer tenant. A private window (Edge InPrivate, else Chrome Incognito, else the
        default browser) keeps the partner sign-in out of the way so the wrong account is never
        auto-selected. The request itself carries customer.tenantId, so Microsoft only accepts
        approval from a Global Administrator of that tenant; nothing here can approve anything.
        A local side effect only; nothing opens under -WhatIf.
    .PARAMETER Url
        From Get-GdapApprovalUrl.
    .PARAMETER NoPrivate
        Use the default browser without a private-window argument.
    .EXAMPLE
        Open-GdapApprovalPage -Url $rel.ApprovalUrl
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter()]
        [switch]$NoPrivate
    )
    if (Test-M365ReadOnly) { throw 'Safe mode: opening a customer access approval page is disabled.' }
    $uri = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.Host -ne 'admin.microsoft.com' -or
        $uri.UserInfo -or -not $uri.IsDefaultPort) {
        throw 'GDAP approval URLs must use https://admin.microsoft.com.'
    }
    $Url = $uri.AbsoluteUri
    $pf = [Environment]::GetEnvironmentVariable('ProgramFiles')
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $local = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    $candidates = @(
        @{ Browser = 'Edge'; Arg = '--inprivate'; Paths = @("$pf86\Microsoft\Edge\Application\msedge.exe", "$pf\Microsoft\Edge\Application\msedge.exe") }
        @{ Browser = 'Chrome'; Arg = '--incognito'; Paths = @("$pf\Google\Chrome\Application\chrome.exe", "$pf86\Google\Chrome\Application\chrome.exe", "$local\Google\Chrome\Application\chrome.exe") }
    )
    $choice = $null
    if (-not $NoPrivate) {
        foreach ($c in $candidates) {
            $exe = $c.Paths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
            if ($exe) { $choice = [pscustomobject]@{ Browser = $c.Browser; Private = $true; Exe = $exe; Arguments = @($c.Arg, $Url) }; break }
        }
    }
    if (-not $choice) { $choice = [pscustomobject]@{ Browser = 'Default'; Private = $false; Exe = $null; Arguments = @($Url) } }
    $launched = $false
    if ($PSCmdlet.ShouldProcess($Url, "Open in $($choice.Browser)$(if ($choice.Private) { ' (private window)' })")) {
        if ($choice.Exe) { Start-Process -FilePath $choice.Exe -ArgumentList $choice.Arguments } else { Start-Process $Url }
        $launched = $true
    }
    [pscustomobject]@{ Browser = $choice.Browser; Private = $choice.Private; Url = $Url; Launched = $launched }
}

#region Discovery (read-only) -------------------------------------------------
function Get-GdapTenantInfo {
    <#
    .SYNOPSIS
        Who is this tenant? Display name and default domain of any Entra tenant, from its id.
    .DESCRIPTION
        Graph: GET /v1.0/tenantRelationships/findTenantInformationByTenantId(tenantId='<guid>').
        Run before any GDAP request so the operator sees whose tenant a typed domain or id
        really is (a typo like contoso.co is somebody else's tenant). Throws when the lookup
        fails or answers for a different tenant; it never guesses.
        Graph scopes: CrossTenantInformation.ReadBasic.All.
    .PARAMETER TenantId
        Tenant GUID, or any verified domain (resolved to the GUID first).
    .EXAMPLE
        Get-GdapTenantInfo -TenantId 'contoso.onmicrosoft.com'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantId
    )
    $guid = if ($TenantId -match $script:GuidPattern) { $TenantId.ToLowerInvariant() } else { Resolve-M365TenantId -TenantId $TenantId }
    $uri = "$script:GraphBase/tenantRelationships/findTenantInformationByTenantId(tenantId='$guid')"
    try {
        $info = Invoke-M365WithRetry -Operation 'Look up customer tenant' { Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -ErrorAction Stop }
    } catch {
        throw "Could not look up tenant $guid ($($_.Exception.Message)). The sign-in needs the Graph scope CrossTenantInformation.ReadBasic.All. Nothing was requested."
    }
    $read = { param($n) if ($null -ne $info -and $info.PSObject.Properties[$n]) { "$($info.PSObject.Properties[$n].Value)" } else { $null } }
    $returned = & $read 'tenantId'
    if (-not $returned -or $returned -ine $guid) { throw "The tenant lookup for $guid answered for tenant '$returned'. Stopped." }
    $name = & $read 'displayName'
    $domain = & $read 'defaultDomainName'
    if (-not $name -and -not $domain) { throw "Graph returned no display name or domain for tenant $guid. Check the tenant id before requesting anything." }
    [pscustomobject]@{ TenantId = $guid; DisplayName = $name; DefaultDomainName = $domain; FederationBrandName = (& $read 'federationBrandName') }
}

function Get-GdapCustomer {
    <#
    .SYNOPSIS
        Lists customers that have at least one GDAP relationship with us.
    .DESCRIPTION
        Graph: /tenantRelationships/delegatedAdminCustomers. A customer with no relationship
        yet is not listed; enter their tenant id or domain and validate it with
        Resolve-M365TenantId instead. Graph scopes: DelegatedAdminRelationship.Read.All.
    .PARAMETER TenantId
        Filter to one tenant GUID.
    .PARAMETER Name
        Filter by display name (contains). For browsing only; pick by tenant id.
    .EXAMPLE
        Get-GdapCustomer -Name contoso
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$TenantId,

        [Parameter()]
        [string]$Name
    )
    $customers = Invoke-M365WithRetry -Operation 'List GDAP customers' { Get-MgTenantRelationshipDelegatedAdminCustomer -All -ErrorAction Stop }
    if ($TenantId) { $customers = $customers | Where-Object { $_.TenantId -ieq $TenantId } }
    if ($Name) { $customers = $customers | Where-Object { $_.DisplayName -like "*$Name*" } }
    foreach ($c in $customers) {
        [pscustomobject]@{ DisplayName = $c.DisplayName; TenantId = $c.TenantId; Id = $c.Id }
    }
}

function Get-GdapAccessAssignment {
    <#
    .SYNOPSIS
        Lists the security-group access assignments on one relationship.
    .EXAMPLE
        Get-GdapAccessAssignment -RelationshipId $rel.Id
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RelationshipId
    )
    $assignments = Invoke-M365WithRetry -Operation 'List GDAP access assignments' {
        Get-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment -DelegatedAdminRelationshipId $RelationshipId -All -ErrorAction Stop
    }
    foreach ($a in $assignments) {
        $roleIds = @($a.AccessDetails.UnifiedRoles | ForEach-Object { $_.RoleDefinitionId.ToLowerInvariant() } | Sort-Object -Unique)
        [pscustomobject]@{
            Id             = $a.Id
            RelationshipId = $RelationshipId
            GroupId        = $a.AccessContainer.AccessContainerId.ToLowerInvariant()
            ContainerType  = $a.AccessContainer.AccessContainerType
            Status         = "$($a.Status)"
            RoleIds        = $roleIds
            Roles          = @($roleIds | Get-GdapRoleName)
            Created        = $a.CreatedDateTime
        }
    }
}

function ConvertTo-GdapRelationshipRecord {
    <#
    .SYNOPSIS
        Internal: normalize one Graph relationship object (plus optional assignments).
    #>
    [CmdletBinding()]
    param([object]$Relationship, [object[]]$Assignments = @())
    $roleIds = @($Relationship.AccessDetails.UnifiedRoles | ForEach-Object { $_.RoleDefinitionId.ToLowerInvariant() } | Sort-Object -Unique)
    $status = "$($Relationship.Status)"
    $end = $Relationship.EndDateTime
    [pscustomobject]@{
        Id               = $Relationship.Id
        DisplayName      = $Relationship.DisplayName
        Customer         = $Relationship.Customer.DisplayName
        CustomerTenantId = if ($Relationship.Customer.TenantId) { $Relationship.Customer.TenantId.ToLowerInvariant() } else { $null }
        Status           = $status
        RoleIds          = $roleIds
        Roles            = @($roleIds | Get-GdapRoleName)
        Duration         = $Relationship.Duration
        AutoExtend       = "$($Relationship.AutoExtendDuration)"
        Created          = $Relationship.CreatedDateTime
        Activated        = $Relationship.ActivatedDateTime
        EndDateTime      = $end
        DaysToExpiry     = if ($end) { [int][math]::Floor(($end - (Get-Date)).TotalDays) } else { $null }
        #   GOTCHA Only a locked request (approvalPending) can be approved. A 'created' one has
        #          no working link; Start-M365GdapOnboarding.ps1 retries its lock.
        ApprovalUrl      = if ($status -eq 'approvalPending') { Get-GdapApprovalUrl -RelationshipId $Relationship.Id } else { $null }
        Assignments      = @($Assignments)
    }
}

function Get-GdapRelationship {
    <#
    .SYNOPSIS
        Lists GDAP relationships from our partner tenant, with access assignments when asked.
    .DESCRIPTION
        Builds on the same Graph call as EntraHelpers' Get-M365GdapRelationship and adds the
        fields the onboarding workflow needs: lower-cased role ids, days to expiry, the
        approval URL for requests awaiting approval, and (with -IncludeAssignments) the
        security-group assignments. Graph scopes: DelegatedAdminRelationship.Read.All.
    .PARAMETER CustomerTenantId
        Filter to one customer tenant GUID.
    .PARAMETER RelationshipId
        Fetch exactly one relationship by id.
    .PARAMETER IncludeAssignments
        Also fetch access assignments (one extra call per relationship).
    .EXAMPLE
        Get-GdapRelationship -CustomerTenantId $tid -IncludeAssignments
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$CustomerTenantId,

        [Parameter()]
        [string]$RelationshipId,

        [Parameter()]
        [switch]$IncludeAssignments
    )
    $relationships = if ($RelationshipId) {
        @(Invoke-M365WithRetry -Operation 'Get GDAP relationship' { Get-MgTenantRelationshipDelegatedAdminRelationship -DelegatedAdminRelationshipId $RelationshipId -ErrorAction Stop })
    } else {
        @(Invoke-M365WithRetry -Operation 'List GDAP relationships' { Get-MgTenantRelationshipDelegatedAdminRelationship -All -ErrorAction Stop })
    }
    if ($CustomerTenantId) { $relationships = @($relationships | Where-Object { $_.Customer -and $_.Customer.TenantId -ieq $CustomerTenantId }) }
    foreach ($rel in $relationships) {
        $assignments = @()
        if ($IncludeAssignments -and "$($rel.Status)" -in 'active', 'expiring', 'approved', 'activating') {
            $assignments = @(Get-GdapAccessAssignment -RelationshipId $rel.Id)
        }
        ConvertTo-GdapRelationshipRecord -Relationship $rel -Assignments $assignments
    }
}
#endregion

#region Compliance (pure) -----------------------------------------------------
function Compare-GdapRelationship {
    <#
    .SYNOPSIS
        Compares a customer's relationships against the MSP template and says what, if anything, to do.
    .DESCRIPTION
        Pure function: takes relationship records (from Get-GdapRelationship -IncludeAssignments)
        and a template (from Get-GdapTemplate), returns one assessment. States:

          NoRelationship      nothing usable exists; create a request
          PendingApproval     a request is waiting (created/approvalPending/approved/activating).
                              Reuse it; never request again while one is in flight, even when
                              roles are still missing (they are listed in MissingRoles and
                              requested by a re-run after this one is approved or expires)
          Compliant           active relationship(s) cover every template role and every
                              template group has an active assignment with its roles
          MissingAssignments  roles are covered but one or more group assignments are missing
                              or incomplete; create/extend only those
          MissingRoles        active relationship(s) do not cover every template role and no
                              request is pending; a supplementary relationship is needed (roles
                              cannot be added to an existing relationship)
          Expired             only expired/terminated relationships exist; replacement needed

        Several active relationships are evaluated together (their roles union). Overlapping
        active relationships produce a warning, never a termination. Group assignments target
        only relationships in status 'active' (an 'expiring' one still covers roles but is not
        assigned to; Set-GdapAccessAssignment would refuse it).
    .PARAMETER Relationships
        Records for one customer.
    .PARAMETER Template
        From Get-GdapTemplate.
    .EXAMPLE
        Compare-GdapRelationship -Relationships $rels -Template $template
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [object[]]$Relationships = @(),

        [Parameter(Mandatory)]
        [object]$Template
    )

    #region 1. Bucket by status ----------------------------------------------
    $active = @($Relationships | Where-Object { $_.Status -in 'active', 'expiring' })
    $assignable = @($active | Where-Object { $_.Status -eq 'active' })
    #   WHAT   Requests in flight, the one most worth waiting for first: approvalPending, then
    #          approved/activating, then created (not locked; nothing to approve yet).
    $pendingRank = @{ approvalPending = 0; approved = 1; activating = 1; created = 2 }
    $pending = @($Relationships | Where-Object { $_.Status -in 'created', 'approvalPending', 'approved', 'activating' } |
            Sort-Object @{ Expression = { $pendingRank["$($_.Status)"] } }, @{ Expression = { "$($_.Id)" } })
    $dead = @($Relationships | Where-Object { $_.Status -in 'expired', 'terminated', 'terminating', 'terminationRequested' })
    $warnings = [System.Collections.Generic.List[string]]::new()
    $actions = [System.Collections.Generic.List[object]]::new()
    #   WHAT   Role names for people: highly privileged first, then by name.
    $names = { param($ids) @(Get-GdapRoleList -RoleIds @($ids) | ForEach-Object { $_.Name }) }
    #endregion

    #region 2. Roles -----------------------------------------------------------------
    $coveredRoles = @($active | ForEach-Object { $_.RoleIds } | Sort-Object -Unique)
    $pendingRoles = @($pending | ForEach-Object { $_.RoleIds } | Sort-Object -Unique)
    $notActive = @($Template.RoleIds | Where-Object { $coveredRoles -notcontains $_ })
    #   WHAT   Roles a NEW request would need: in neither an active nor a pending relationship.
    $missingRoles = @($notActive | Where-Object { $pendingRoles -notcontains $_ })
    $awaitingRoles = @($notActive | Where-Object { $pendingRoles -contains $_ })
    if ($active.Count -gt 1) {
        $overlap = @($active | ForEach-Object { $_.RoleIds } | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        if ($overlap.Count -gt 0) { $warnings.Add("$($active.Count) active relationships overlap on $($overlap.Count) role(s). Not changing them; consider consolidating in Partner Center.") }
    }
    foreach ($a in $active | Where-Object { $null -ne $_.DaysToExpiry -and $_.DaysToExpiry -le 60 -and $_.AutoExtend -in '', 'PT0S' }) {
        $warnings.Add("Relationship '$($a.DisplayName)' expires in $($a.DaysToExpiry) day(s) and does not auto-extend.")
    }
    #endregion

    #region 3. Assignments -------------------------------------------------------------
    #   WHAT   For each template group, the roles it should hold that an active relationship
    #          grants but no assignment of the group carries yet. Each is assigned on the
    #          'active' relationship that grants the most of what is still needed, then the
    #          next, so a group whose roles are split across two relationships gets both.
    #   WHY    Assignments live per relationship. Sorting by id as a tie-break keeps the dry
    #          run and the real run choosing the same relationship.
    $missingAssignments = @()
    foreach ($group in $Template.Groups) {
        $haveRoles = @()
        foreach ($rel in $active) {
            foreach ($asg in $rel.Assignments | Where-Object { $_.GroupId -ieq $group.Id -and $_.Status -in 'active', 'pending' }) {
                $haveRoles += $asg.RoleIds
            }
        }
        $haveRoles = @($haveRoles | Sort-Object -Unique)
        $remaining = @($group.RoleIds | Where-Object { $haveRoles -notcontains $_ -and $coveredRoles -contains $_ })
        while ($remaining.Count -gt 0) {
            $need = $remaining
            $target = $assignable | Sort-Object @{ Expression = { @($_.RoleIds | Where-Object { $need -contains $_ }).Count }; Descending = $true }, @{ Expression = { "$($_.Id)" } } | Select-Object -First 1
            $grantable = @(if ($target) { $need | Where-Object { $target.RoleIds -contains $_ } })
            if ($grantable.Count -eq 0) { break }
            $missingAssignments += [pscustomobject]@{ GroupName = $group.Name; GroupId = $group.Id; RelationshipId = $target.Id; RelationshipName = $target.DisplayName; RoleIds = $grantable; Roles = @(& $names $grantable) }
            $remaining = @($remaining | Where-Object { $grantable -notcontains $_ })
        }
        if ($remaining.Count -gt 0) {
            $warnings.Add("Group '$($group.Name)' lacks $($remaining.Count) role(s) that only an expiring relationship grants ($((& $names $remaining) -join ', ')). Not assigning on an expiring relationship; renew it.")
        }
    }
    #endregion

    #region 4. State -----------------------------------------------------------------------
    $state = if ($pending.Count -gt 0 -and ($active.Count -eq 0 -or $notActive.Count -gt 0)) { 'PendingApproval' }
    elseif ($active.Count -eq 0 -and $dead.Count -gt 0) { 'Expired' }
    elseif ($active.Count -eq 0) { 'NoRelationship' }
    elseif ($missingRoles.Count -gt 0) { 'MissingRoles' }
    elseif ($missingAssignments.Count -gt 0) { 'MissingAssignments' }
    else { 'Compliant' }

    $privNote = { param($ids) $p = @(Get-GdapRoleList -RoleIds $ids | Where-Object { $_.Privileged } | ForEach-Object { $_.Name }); if ($p.Count) { " incl. HIGHLY PRIVILEGED $($p -join ', ')" } else { '' } }
    switch ($state) {
        'NoRelationship' { $actions.Add([pscustomobject]@{ Action = 'CreateRequest'; Detail = "Create '$($Template.name)' relationship ($($Template.RoleIds.Count) roles$(& $privNote $Template.RoleIds), $($Template.duration), auto-extend $($Template.autoExtendDuration)) and send the approval link." }) }
        'Expired' { $actions.Add([pscustomobject]@{ Action = 'CreateReplacement'; Detail = "Only expired/terminated relationships exist ($($dead.Count)). Create a replacement request ($($Template.RoleIds.Count) roles$(& $privNote $Template.RoleIds))." }) }
        'PendingApproval' {
            $p = $pending[0]
            $detail = if ($p.Status -eq 'created') {
                "Request '$($p.DisplayName)' was created but never locked for approval, so the customer cannot approve it. Start-M365GdapOnboarding.ps1 retries the lock when this toolkit created it."
            } elseif ($p.ApprovalUrl) { "Request '$($p.DisplayName)' is $($p.Status). Reuse its approval link: $($p.ApprovalUrl)" } else { "Request '$($p.DisplayName)' is $($p.Status). Wait for it to become active." }
            if ($missingRoles.Count -gt 0 -and $active.Count -gt 0) { $detail += " After it is approved, $($missingRoles.Count) template role(s) will still be missing ($((& $names $missingRoles) -join ', ')); re-run then to request them." }
            $actions.Add([pscustomobject]@{ Action = 'AwaitApproval'; Detail = $detail })
        }
        'MissingRoles' { $actions.Add([pscustomobject]@{ Action = 'CreateSupplementary'; Detail = "Active relationship(s) lack $($missingRoles.Count) template role(s): $((& $names $missingRoles) -join ', '). Roles cannot be added to an existing relationship; a supplementary request is needed." }) }
    }
    foreach ($m in $missingAssignments) {
        $actions.Add([pscustomobject]@{ Action = 'CreateAssignment'; Detail = "Assign '$($m.GroupName)' on '$($m.RelationshipName)' for: $($m.Roles -join ', ')"; Target = $m })
    }
    if ($pending.Count -gt 0 -and $active.Count -gt 0) { $warnings.Add("A request '$($pending[0].DisplayName)' is still $($pending[0].Status) alongside active relationship(s).") }
    if ($pending.Count -gt 1) { $warnings.Add("$($pending.Count) requests are in flight at once: $(($pending | ForEach-Object { "'$($_.DisplayName)' [$($_.Status)]" }) -join ', ').") }
    #endregion

    [pscustomobject]@{
        State              = $state
        Compliant          = ($state -eq 'Compliant')
        ActiveCount        = $active.Count
        PendingCount       = $pending.Count
        ExpiredCount       = $dead.Count
        Active             = $active
        Pending            = $pending
        CoveredRoles       = @(& $names $coveredRoles)
        CoveredRoleIds     = $coveredRoles
        PendingRoles       = @(& $names $awaitingRoles)
        PendingRoleIds     = $awaitingRoles
        MissingRoles       = @(& $names $missingRoles)
        MissingRoleIds     = $missingRoles
        MissingAssignments = $missingAssignments
        Warnings           = @($warnings)
        ProposedActions    = @($actions)
    }
}

function Test-GdapCompliance {
    <#
    .SYNOPSIS
        Live check: fetches a customer's relationships and compares them to the template.
    .PARAMETER CustomerTenantId
        Customer tenant GUID.
    .PARAMETER Template
        From Get-GdapTemplate; loaded if omitted.
    .EXAMPLE
        Test-GdapCompliance -CustomerTenantId $tid | Format-List State, MissingRoles, ProposedActions
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CustomerTenantId,

        [Parameter()]
        [object]$Template
    )
    if (-not $Template) { $Template = Get-GdapTemplate }
    $rels = @(Get-GdapRelationship -CustomerTenantId $CustomerTenantId -IncludeAssignments)
    $result = Compare-GdapRelationship -Relationships $rels -Template $Template
    $result | Add-Member -NotePropertyName CustomerTenantId -NotePropertyValue $CustomerTenantId.ToLowerInvariant() -Force
    $result | Add-Member -NotePropertyName TemplateName -NotePropertyValue $Template.name -Force
    return $result
}
#endregion

#region Changes ------------------------------------------------------------------
function Invoke-GdapLockChange {
    # Internal. The one lockForApproval call, through Invoke-M365Change. RelationshipId may be a
    # New-M365Placeholder (dry run of a create).
    param([System.Management.Automation.PSCmdlet]$Caller, [object]$RelationshipId, [string]$DisplayName, [string]$CustomerLabel)
    Invoke-M365Change -Caller $Caller -Service Graph -Retry `
        -Action "Send relationship '$DisplayName' to $CustomerLabel for approval (lockForApproval: its roles can no longer be changed; the customer's Global Administrator approves it)" `
        -Command 'New-MgTenantRelationshipDelegatedAdminRelationshipRequest' `
        -Parameters ([ordered]@{ DelegatedAdminRelationshipId = $RelationshipId; BodyParameter = [ordered]@{ action = 'lockForApproval' } })
}

function Test-GdapCreatedByToolkit {
    # Internal. True when the customer's saved state names this relationship as one we created.
    param([string]$CustomerTenantId, [string]$RelationshipId, [string]$StatePath)
    if (-not $CustomerTenantId -or -not $RelationshipId) { return $false }
    $state = Get-GdapState -CustomerTenantId $CustomerTenantId -StatePath $StatePath
    if (-not $state) { return $false }
    $ids = @()
    if ($state.PSObject.Properties.Name -contains 'createdRelationshipIds') { $ids += @($state.createdRelationshipIds) }
    if ($state.PSObject.Properties.Name -contains 'relationshipId') { $ids += $state.relationshipId }
    return [bool](@($ids | Where-Object { $_ -and "$_" -ieq $RelationshipId }).Count)
}

function New-GdapRequest {
    <#
    .SYNOPSIS
        Creates a GDAP relationship from the template and locks it for customer approval.
    .DESCRIPTION
        Two Graph changes, both through Invoke-M365Change so the plan shows them first:
          1. POST the relationship (status 'created'). The plan line names the customer
             (tenant display name and default domain), the duration, auto-extend and every
             role, Global Administrator / Privileged Role / Privileged Authentication
             Administrator first.
          2. POST a lockForApproval request (status 'approvalPending'). Under -WhatIf the new
             relationship's id is a placeholder.
        Saves resumable state (runs/gdap/<tenant>.json) right after the create, so a re-run of
        Start-M365GdapOnboarding.ps1 can retry a failed lock on a relationship we created.
        Does NOT check for existing relationships; callers run Compare-GdapRelationship first
        (Start-M365GdapOnboarding.ps1 and New-M365GdapRequest.ps1 do).
        Graph scopes: DelegatedAdminRelationship.ReadWrite.All, CrossTenantInformation.ReadBasic.All.
    .PARAMETER CustomerTenantId
        Customer tenant GUID. Validated as a GUID; resolve domains first with Resolve-M365TenantId.
    .PARAMETER CustomerName
        Used in the display name.
    .PARAMETER Template
        From Get-GdapTemplate.
    .PARAMETER DisplayName
        Exact relationship name instead of the template pattern plus date. Max 50 characters.
    .PARAMETER RoleIds
        Override the template roles (used for supplementary requests carrying only the missing roles).
    .PARAMETER TenantInfo
        From Get-GdapTenantInfo; looked up when omitted.
    .PARAMETER CorrelationId
        For logs and state.
    .PARAMETER StatePath
        Folder for the state file (tests).
    .EXAMPLE
        New-GdapRequest -CustomerTenantId $tid -CustomerName Contoso -Template $template -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [string]$CustomerTenantId,

        [Parameter(Mandatory)]
        [string]$CustomerName,

        [Parameter(Mandatory)]
        [object]$Template,

        [Parameter()]
        [string]$DisplayName,

        [Parameter()]
        [string[]]$RoleIds,

        [Parameter()]
        [object]$TenantInfo,

        [Parameter()]
        [string]$CorrelationId,

        [Parameter()]
        [string]$StatePath
    )

    #region 1. Validate inputs and describe the request --------------------------------
    if ($CustomerTenantId -notmatch $script:GuidPattern) { throw "CustomerTenantId must be a GUID. Resolve a domain first with Resolve-M365TenantId." }
    $tid = $CustomerTenantId.ToLowerInvariant()
    if (-not $TenantInfo) { $TenantInfo = Get-GdapTenantInfo -TenantId $tid }
    $summaryParams = @{ CustomerTenantId = $tid; CustomerName = $CustomerName; Template = $Template; TenantInfo = $TenantInfo }
    if ($RoleIds) { $summaryParams.RoleIds = $RoleIds }
    if ($DisplayName) { $summaryParams.DisplayName = $DisplayName }
    $summary = Get-GdapRequestSummary @summaryParams
    if (-not $CorrelationId) { $CorrelationId = New-M365CorrelationId }
    $result = [ordered]@{
        Id = $null; DisplayName = $summary.DisplayName; Customer = $CustomerName; CustomerTenantId = $tid
        TenantDisplayName = $summary.TenantDisplayName; TenantDomain = $summary.TenantDomain
        Status = $null; RoleIds = $summary.RoleIds; Roles = $summary.RoleNames; Duration = $summary.Duration; AutoExtend = $summary.AutoExtendDuration
        Locked = $false; LockError = $null; ApprovalUrl = $null; WhatIf = $false; Declined = $false; Summary = $summary.Text
    }
    #endregion

    #region 2. Create ------------------------------------------------------------------
    #   GOTCHA -Retry retries only 429/503 (rejected, not processed). A timeout is never
    #          retried: the relationship may exist, and a second create would duplicate it.
    $body = [ordered]@{
        displayName        = $summary.DisplayName
        duration           = $summary.Duration
        autoExtendDuration = $summary.AutoExtendDuration
        customer           = [ordered]@{ tenantId = $tid }
        accessDetails      = [ordered]@{ unifiedRoles = @($summary.RoleIds | ForEach-Object { [ordered]@{ roleDefinitionId = $_ } }) }
    }
    $run = Invoke-M365Change -Caller $PSCmdlet -Service Graph -Retry -Action $summary.Text `
        -Command 'New-MgTenantRelationshipDelegatedAdminRelationship' -Parameters ([ordered]@{ BodyParameter = $body })
    if (-not $run.Ran) {
        if (-not $WhatIfPreference) {
            $result.Status = 'Declined'; $result.Declined = $true
            return [pscustomobject]$result
        }
        $null = Invoke-GdapLockChange -Caller $PSCmdlet -RelationshipId (New-M365Placeholder 'id of the relationship created above') -DisplayName $summary.DisplayName -CustomerLabel $summary.CustomerLabel
        $result.Status = 'WhatIf'; $result.WhatIf = $true
        return [pscustomobject]$result
    }
    $newId = "$($run.Output.Id)"
    if (-not $newId) { throw "Graph did not return an id for the new relationship '$($summary.DisplayName)'. Check Partner Center before re-running; it may exist." }
    $result.Id = $newId; $result.Status = "$($run.Output.Status)"
    $stateFile = @{ CustomerTenantId = $tid; StatePath = $StatePath }
    $saveState = {
        param([hashtable]$Fields)
        try {
            $prev = Get-GdapState @stateFile
            $ids = @(if ($prev -and $prev.PSObject.Properties.Name -contains 'createdRelationshipIds') { @($prev.createdRelationshipIds) }) + $newId
            $Fields.createdRelationshipIds = @($ids | Where-Object { $_ } | Select-Object -Unique)
            $null = Save-GdapState @stateFile -State $Fields -Confirm:$false
        } catch { Write-Warning "Could not save GDAP state for $tid ($($_.Exception.Message)). Relationship $newId exists; note its id." }
    }
    & $saveState @{ customerName = $CustomerName; relationshipId = $newId; displayName = $summary.DisplayName; status = $result.Status; templateName = $Template.name; correlationId = $CorrelationId; lockError = 'not attempted yet' }
    #endregion

    #region 3. Lock for approval ---------------------------------------------------------
    try {
        $lock = Invoke-GdapLockChange -Caller $PSCmdlet -RelationshipId $newId -DisplayName $summary.DisplayName -CustomerLabel $summary.CustomerLabel
        if ($lock.Ran) { $result.Locked = $true } else { $result.LockError = 'Lock not confirmed by the operator.' }
    } catch {
        $result.LockError = $_.Exception.Message
        $null = Write-M365Log -Level Error -Operation 'New-GdapRequest' -TenantId $tid -CorrelationId $CorrelationId -Message "lockForApproval failed: $($result.LockError)" -Data @{ relationshipId = $newId }
    }
    try {
        $record = Get-GdapRelationship -RelationshipId $newId | Select-Object -First 1
        if ($record) { $result.Status = $record.Status }
    } catch { Write-Warning "Created relationship $newId but could not re-read it: $($_.Exception.Message)" }
    if ($result.Locked) {
        if ($result.Status -eq 'created') { $result.Status = 'approvalPending' }
        $result.ApprovalUrl = Get-GdapApprovalUrl -RelationshipId $newId
    }
    & $saveState @{ status = $result.Status; approvalUrl = $result.ApprovalUrl; lockError = $result.LockError }
    if ($result.LockError) { Write-Warning "Relationship '$($summary.DisplayName)' ($newId) was created but not locked for approval: $($result.LockError). The customer cannot approve it yet; re-run Start-M365GdapOnboarding.ps1 to retry the lock." }
    #endregion

    return [pscustomobject]$result
}

function Lock-GdapRelationship {
    <#
    .SYNOPSIS
        Retries lockForApproval on a relationship this toolkit created whose lock failed (status 'created').
    .DESCRIPTION
        Recovery for a create that succeeded while the lock did not: the request stays in
        'created' and the customer has nothing to approve. Refuses unless the relationship is
        in status 'created' AND the customer's saved state (runs/gdap/<tenant>.json) names it
        as created by this toolkit. Never locks someone else's draft. The lock goes through
        Invoke-M365Change. Graph scopes: DelegatedAdminRelationship.ReadWrite.All.
    .PARAMETER RelationshipId
        The relationship to lock.
    .PARAMETER TenantInfo
        From Get-GdapTenantInfo; used only to name the customer in the plan.
    .PARAMETER CorrelationId
        For logs.
    .PARAMETER StatePath
        Folder for the state file (tests).
    .EXAMPLE
        Lock-GdapRelationship -RelationshipId $rel.Id -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [string]$RelationshipId,

        [Parameter()]
        [object]$TenantInfo,

        [Parameter()]
        [string]$CorrelationId,

        [Parameter()]
        [string]$StatePath
    )
    $rel = Get-GdapRelationship -RelationshipId $RelationshipId | Select-Object -First 1
    if (-not $rel) { throw "Relationship $RelationshipId not found." }
    if ($rel.Status -ne 'created') { throw "Relationship '$($rel.DisplayName)' is $($rel.Status); only a relationship in status 'created' needs locking for approval." }
    if (-not (Test-GdapCreatedByToolkit -CustomerTenantId $rel.CustomerTenantId -RelationshipId $rel.Id -StatePath $StatePath)) {
        throw "Relationship '$($rel.DisplayName)' ($($rel.Id)) is 'created' but this toolkit's saved state does not name it as one we created. Not locking it; whoever drafted it should finish it in Partner Center."
    }
    $label = Format-GdapCustomerLabel -CustomerName $rel.Customer -TenantInfo $TenantInfo -TenantId $rel.CustomerTenantId
    $result = [ordered]@{
        Id = $rel.Id; DisplayName = $rel.DisplayName; Customer = $rel.Customer; CustomerTenantId = $rel.CustomerTenantId; RoleIds = $rel.RoleIds; Roles = $rel.Roles
        Status = $rel.Status; Locked = $false; ApprovalUrl = $null; WhatIf = $false; Declined = $false
    }
    $run = Invoke-GdapLockChange -Caller $PSCmdlet -RelationshipId $rel.Id -DisplayName $rel.DisplayName -CustomerLabel $label
    if (-not $run.Ran) {
        if ($WhatIfPreference) { $result.WhatIf = $true } else { $result.Declined = $true }
        return [pscustomobject]$result
    }
    $result.Locked = $true
    $result.Status = 'approvalPending'
    $result.ApprovalUrl = Get-GdapApprovalUrl -RelationshipId $rel.Id
    try {
        $null = Save-GdapState -CustomerTenantId $rel.CustomerTenantId -State @{ status = 'approvalPending'; approvalUrl = $result.ApprovalUrl; lockError = $null; correlationId = $CorrelationId } -StatePath $StatePath -Confirm:$false
    } catch { Write-Warning "Locked $($rel.Id) but could not save GDAP state: $($_.Exception.Message)" }
    return [pscustomobject]$result
}

function Wait-GdapApproval {
    <#
    .SYNOPSIS
        Polls a relationship until it is active (or rejected/expired) or the timeout passes.
    .DESCRIPTION
        Read-only towards Graph. Prints progress with Write-Progress; Ctrl+C stops waiting
        without touching the request, and a later run resumes from the saved state. Returns
        the final record with a Result of Active, Timeout, or Failed. Updates the saved status
        only when the saved state is about this same relationship.
    .PARAMETER RelationshipId
        The relationship to watch.
    .PARAMETER TimeoutMinutes
        Default 30.
    .PARAMETER PollSeconds
        Default 20.
    .EXAMPLE
        Wait-GdapApproval -RelationshipId $rel.Id -TimeoutMinutes 10
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RelationshipId,

        [Parameter()]
        [ValidateRange(1, 1440)]
        [int]$TimeoutMinutes = 30,

        [Parameter()]
        [ValidateRange(5, 600)]
        [int]$PollSeconds = 20
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $record = $null
    do {
        $record = Get-GdapRelationship -RelationshipId $RelationshipId | Select-Object -First 1
        $status = $record.Status
        $label = switch ($status) {
            'created' { 'Created, not yet locked for approval' }
            'approvalPending' { 'Awaiting customer approval' }
            'approved' { 'Approved, activating' }
            'activating' { 'Approved, activating' }
            'active' { 'Active' }
            default { "Status: $status" }
        }
        Write-Progress -Activity "GDAP approval for '$($record.DisplayName)'" -Status $label -SecondsRemaining ([int]($deadline - (Get-Date)).TotalSeconds)
        if ($status -eq 'active') { break }
        if ($status -in 'expired', 'terminated', 'terminating', 'terminationRequested') { break }
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)
    Write-Progress -Activity 'GDAP approval' -Completed
    $result = if ($record.Status -eq 'active') { 'Active' } elseif ($record.Status -in 'expired', 'terminated', 'terminating', 'terminationRequested') { 'Failed' } else { 'Timeout' }
    $record | Add-Member -NotePropertyName Result -NotePropertyValue $result -Force
    if ($record.CustomerTenantId) {
        try {
            $saved = Get-GdapState -CustomerTenantId $record.CustomerTenantId
            if ($saved -and $saved.PSObject.Properties.Name -contains 'relationshipId' -and "$($saved.relationshipId)" -ieq $record.Id) {
                $null = Save-GdapState -CustomerTenantId $record.CustomerTenantId -State @{ status = $record.Status; approvalUrl = $record.ApprovalUrl } -Confirm:$false
            }
        } catch { Write-Warning "Could not update GDAP state: $($_.Exception.Message)" }
    }
    return $record
}

function Set-GdapAccessAssignment {
    <#
    .SYNOPSIS
        Ensures a security group holds the given roles on an active relationship (creates or extends its one assignment).
    .DESCRIPTION
        Idempotent. Verifies the relationship is active, every role is in it, and the group is
        a security group in our tenant. Then, through Invoke-M365Change:
          - no assignment for the group: POST one with the roles;
          - an active assignment lacking roles: PATCH that same assignment with the UNION of
            its roles and the missing ones (If-Match etag, read fresh). Never a second POST,
            which Graph rejects for a group that already has an assignment;
          - the group already holds every role: nothing.
        Refuses a pending/errored assignment (finish it first) and an etag it cannot read.
        -PlannedRelationship plans the POST for a relationship that is not active yet (the
        request a dry run would create, or one awaiting approval); dry run only.
        Graph scopes: DelegatedAdminRelationship.ReadWrite.All, Group.Read.All.
    .PARAMETER RelationshipId
        Active relationship.
    .PARAMETER PlannedRelationship
        Dry run only: the record from New-GdapRequest -WhatIf (no id yet) or a pending
        relationship record; plans what the real run assigns once it is approved.
    .PARAMETER GroupId
        MSP security group object id.
    .PARAMETER RoleIds
        Role definition ids the group must hold.
    .PARAMETER TenantInfo
        From Get-GdapTenantInfo; only used to name the customer's domain in the plan.
    .PARAMETER CorrelationId
        For logs.
    .EXAMPLE
        Set-GdapAccessAssignment -RelationshipId $rel.Id -GroupId $group.Id -RoleIds $group.RoleIds -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Relationship')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Relationship')]
        [string]$RelationshipId,

        [Parameter(Mandatory, ParameterSetName = 'Planned')]
        [object]$PlannedRelationship,

        [Parameter(Mandatory)]
        [string]$GroupId,

        [Parameter(Mandatory)]
        [string[]]$RoleIds,

        [Parameter()]
        [object]$TenantInfo,

        [Parameter()]
        [string]$CorrelationId
    )

    #region 1. Relationship -----------------------------------------------------------
    $RoleIds = @($RoleIds | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    if ($RoleIds.Count -eq 0) { throw 'No roles to assign.' }
    if ($GroupId -notmatch $script:GuidPattern) { throw "GroupId '$GroupId' is not a GUID." }
    $GroupId = $GroupId.ToLowerInvariant()
    if ($PSCmdlet.ParameterSetName -eq 'Planned') {
        if (-not $WhatIfPreference) { throw '-PlannedRelationship is for a dry run (-WhatIf) only: that relationship is not active yet.' }
        $rel = $PlannedRelationship
        $relRef = if ($rel.Id) { "$($rel.Id)" } else { New-M365Placeholder 'id of the relationship created above, once the customer approves it' }
        $relIdOut = if ($rel.Id) { "$($rel.Id)" } else { $null }
        $existing = @()
    } else {
        $rel = Get-GdapRelationship -RelationshipId $RelationshipId -IncludeAssignments | Select-Object -First 1
        if (-not $rel) { throw "Relationship $RelationshipId not found." }
        if ($rel.Status -ne 'active') { throw "Relationship '$($rel.DisplayName)' is $($rel.Status); assignments need it to be active." }
        $relRef = "$($rel.Id)"
        $relIdOut = $relRef
        $existing = @($rel.Assignments | Where-Object { $_.GroupId -ieq $GroupId -and $_.Status -notin 'deleted', 'deleting' })
    }
    $outside = @($RoleIds | Where-Object { @($rel.RoleIds) -notcontains $_ })
    if ($outside.Count -gt 0) { throw "Role(s) not in relationship '$($rel.DisplayName)': $(($outside | Get-GdapRoleName) -join ', '). A new relationship is needed for them." }
    $customer = if (Get-GdapPropertyValue $rel 'TenantDisplayName') { $rel.TenantDisplayName } else { Get-GdapPropertyValue $rel 'Customer' }
    if (-not $TenantInfo -and (Get-GdapPropertyValue $rel 'TenantDomain')) { $TenantInfo = [pscustomobject]@{ DisplayName = $customer; DefaultDomainName = $rel.TenantDomain } }
    $infoTenant = Get-GdapPropertyValue $TenantInfo 'TenantId'
    if ($infoTenant -and "$infoTenant" -ine "$($rel.CustomerTenantId)") { throw "Tenant information is for $infoTenant, but relationship '$($rel.DisplayName)' is with $($rel.CustomerTenantId). Stopped." }
    $customerLabel = Format-GdapCustomerLabel -CustomerName $customer -TenantInfo $TenantInfo -TenantId $rel.CustomerTenantId
    #endregion

    #region 2. Group (our tenant) ---------------------------------------------------------
    $group = Invoke-M365WithRetry -Operation 'Get group' { Get-MgGroup -GroupId $GroupId -ErrorAction Stop }
    if (-not $group) { throw "Security group $GroupId not found in our tenant." }
    if ($group.PSObject.Properties.Name -contains 'SecurityEnabled' -and $group.SecurityEnabled -eq $false) { throw "Group '$($group.DisplayName)' ($GroupId) is not a security group; GDAP roles can only go to security groups." }
    $out = [ordered]@{
        RelationshipId = $relIdOut; RelationshipName = $rel.DisplayName; Customer = $customer; GroupId = $GroupId; GroupName = $group.DisplayName
        RoleIds = $RoleIds; Roles = @(Get-GdapRoleList -RoleIds $RoleIds | ForEach-Object { $_.Name }); AddedRoleIds = @(); AddedRoles = @()
        Change = 'None'; Created = $false; Updated = $false; AssignmentId = $null; Status = $null; WhatIf = $false; Declined = $false
    }
    #endregion

    #region 3. Create, extend, or nothing ------------------------------------------------------
    if ($existing.Count -gt 1) { throw "Group '$($group.DisplayName)' has $($existing.Count) access assignments on '$($rel.DisplayName)' ($(($existing | ForEach-Object { "$($_.Id) [$($_.Status)]" }) -join ', ')). Expected at most one; clean up in Partner Center first." }
    $current = $existing | Select-Object -First 1
    if ($current) {
        $missing = @($RoleIds | Where-Object { @($current.RoleIds) -notcontains $_ })
        $out.AssignmentId = $current.Id; $out.Status = $current.Status
        if ($missing.Count -eq 0) {
            Write-Verbose "Group '$($group.DisplayName)' already holds all requested roles on '$($rel.DisplayName)'."
            $out.RoleIds = @($current.RoleIds); $out.Roles = @(Get-GdapRoleList -RoleIds @($current.RoleIds) | ForEach-Object { $_.Name })
            return [pscustomobject]$out
        }
        if ($current.Status -ne 'active') { throw "Group '$($group.DisplayName)' has an access assignment on '$($rel.DisplayName)' in status '$($current.Status)'. Graph can only extend an active assignment; re-run once it is active (or fix it in Partner Center)." }
        #   GOTCHA Graph requires If-Match with the assignment's current etag. Read it fresh (with
        #          the roles it holds right now); without it, refuse rather than guess.
        $uri = "$script:GraphBase/tenantRelationships/delegatedAdminRelationships/$($rel.Id)/accessAssignments/$($current.Id)"
        try {
            $fresh = Invoke-M365WithRetry -Operation 'Read GDAP access assignment' { Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -ErrorAction Stop }
        } catch { throw "Could not read access assignment $($current.Id) to extend it ($($_.Exception.Message)). Nothing was changed." }
        $etag = if ($null -ne $fresh -and $fresh.PSObject.Properties['@odata.etag']) { "$($fresh.PSObject.Properties['@odata.etag'].Value)" } else { $null }
        if (-not $etag) { throw "Graph returned no etag for access assignment $($current.Id) of group '$($group.DisplayName)', so it cannot be extended safely. Nothing was changed. Add these roles in Partner Center instead: $(($missing | Get-GdapRoleName) -join ', ')." }
        $freshStatus = if ($fresh.PSObject.Properties['status']) { "$($fresh.PSObject.Properties['status'].Value)" } else { 'active' }
        if ($freshStatus -ne 'active') { throw "Access assignment $($current.Id) is now '$freshStatus'. Nothing was changed; re-run once it is active." }
        #   GOTCHA The PATCH replaces the role list, so the roles it holds now must be read; if they
        #          cannot be, refuse (sending only the new roles would drop the existing ones).
        $freshRoles = @()
        $details = $fresh.PSObject.Properties['accessDetails']
        if ($details -and $details.Value -and $details.Value.PSObject.Properties['unifiedRoles']) {
            $freshRoles = @($details.Value.PSObject.Properties['unifiedRoles'].Value | ForEach-Object { if ($_ -and $_.PSObject.Properties['roleDefinitionId']) { "$($_.PSObject.Properties['roleDefinitionId'].Value)".ToLowerInvariant() } } | Where-Object { $_ })
        }
        if ($freshRoles.Count -eq 0) { throw "Could not read the roles access assignment $($current.Id) holds now. Nothing was changed (extending it without them would remove them)." }
        $union = @(@($freshRoles) + @($RoleIds) | Sort-Object -Unique)
        $added = @($RoleIds | Where-Object { $freshRoles -notcontains $_ })
        $out.RoleIds = $union; $out.Roles = @(Get-GdapRoleList -RoleIds $union | ForEach-Object { $_.Name })
        $out.AddedRoleIds = $added; $out.AddedRoles = @(Get-GdapRoleList -RoleIds $added | ForEach-Object { $_.Name })
        $out.Change = 'Update'
        $run = Invoke-M365Change -Caller $PSCmdlet -Service Graph -Retry `
            -Action "Extend our group '$($group.DisplayName)' in $customerLabel through relationship '$($rel.DisplayName)' (its assignment will hold $($union.Count) roles). Adding $(Format-GdapRoleList -RoleIds $added)" `
            -Command 'Invoke-MgGraphRequest' -Parameters ([ordered]@{
                Method  = 'PATCH'
                Uri     = $uri
                Headers = [ordered]@{ 'If-Match' = $etag }
                Body    = [ordered]@{ accessDetails = [ordered]@{ unifiedRoles = @($union | ForEach-Object { [ordered]@{ roleDefinitionId = $_ } }) } }
            })
        $out.Updated = [bool]$run.Ran
    } else {
        $out.AddedRoleIds = $RoleIds; $out.AddedRoles = $out.Roles
        $out.Change = 'Create'
        $run = Invoke-M365Change -Caller $PSCmdlet -Service Graph -Retry `
            -Action "Give our group '$($group.DisplayName)' admin roles in $customerLabel through relationship '$($rel.DisplayName)': $(Format-GdapRoleList -RoleIds $RoleIds)" `
            -Command 'New-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment' -Parameters ([ordered]@{
                DelegatedAdminRelationshipId = $relRef
                BodyParameter                = [ordered]@{
                    accessContainer = [ordered]@{ accessContainerId = $GroupId; accessContainerType = 'securityGroup' }
                    accessDetails   = [ordered]@{ unifiedRoles = @($RoleIds | ForEach-Object { [ordered]@{ roleDefinitionId = $_ } }) }
                }
            })
        $out.Created = [bool]$run.Ran
        if ($run.Ran) { $out.AssignmentId = $run.Output.Id; $out.Status = "$($run.Output.Status)" }
    }
    if (-not $run.Ran) {
        if ($WhatIfPreference) { $out.WhatIf = $true; $out.Status = 'WhatIf' } else { $out.Declined = $true; $out.Status = 'Declined' }
    } elseif ($out.Change -eq 'Update') { $out.Status = 'active' }
    if ($run.Ran) {
        $null = Write-M365Log -Operation 'Set-GdapAccessAssignment' -TenantId $rel.CustomerTenantId -CorrelationId $CorrelationId -Message "$($out.Change) access assignment" -Data @{ relationshipId = $relIdOut; groupId = $GroupId; roles = $out.RoleIds.Count }
    }
    #endregion

    return [pscustomobject]$out
}
#endregion

#region State --------------------------------------------------------------------
function Get-GdapStatePath {
    [CmdletBinding()]
    param([string]$CustomerTenantId, [string]$StatePath)
    if (-not $StatePath) { $StatePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..' '..' 'runs' 'gdap')) }
    return (Join-Path $StatePath "$($CustomerTenantId.ToLowerInvariant()).json")
}

function Get-GdapState {
    <#
    .SYNOPSIS
        Reads the saved GDAP onboarding state for a customer (runs/gdap/<tenantId>.json), or $null.
    .DESCRIPTION
        The state is a pointer (relationship ids this toolkit created, approval URL, last
        status). Graph is the truth: callers re-query the relationship by id and treat a
        missing one as missing.
    .EXAMPLE
        Get-GdapState -CustomerTenantId $tid
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CustomerTenantId,

        [Parameter()]
        [string]$StatePath
    )
    $file = Get-GdapStatePath -CustomerTenantId $CustomerTenantId -StatePath $StatePath
    if (-not (Test-Path $file)) { return $null }
    return (Get-Content $file -Raw | ConvertFrom-Json)
}

function Save-GdapState {
    <#
    .SYNOPSIS
        Merges fields into the customer's GDAP state file. Never stores secrets. Returns nothing unless -PassThru.
    .PARAMETER CustomerTenantId
        Customer tenant GUID (the file name).
    .PARAMETER State
        Fields to set.
    .PARAMETER StatePath
        Folder override (tests).
    .PARAMETER PassThru
        Return the file path. Without it nothing is returned, so a call can never leak a path
        into a caller's output.
    .EXAMPLE
        Save-GdapState -CustomerTenantId $tid -State @{ relationshipId = $id; status = 'approvalPending' }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$CustomerTenantId,

        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter()]
        [string]$StatePath,

        [Parameter()]
        [switch]$PassThru
    )
    $file = Get-GdapStatePath -CustomerTenantId $CustomerTenantId -StatePath $StatePath
    $current = [ordered]@{}
    if (Test-Path $file) {
        $existing = Get-Content $file -Raw | ConvertFrom-Json
        foreach ($p in $existing.PSObject.Properties) { $current[$p.Name] = $p.Value }
    }
    $current['customerTenantId'] = $CustomerTenantId.ToLowerInvariant()
    foreach ($k in $State.Keys) { $current[$k] = $State[$k] }
    $current['updatedAt'] = (Get-Date).ToUniversalTime().ToString('o')
    if ($PSCmdlet.ShouldProcess($file, 'Write GDAP state')) {
        $dir = Split-Path $file -Parent
        if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $current | ConvertTo-Json -Depth 5 | Set-Content -Path $file -Encoding utf8
    }
    if ($PassThru) { return $file }
}
#endregion

Export-ModuleMember -Function Get-GdapRoleId, Get-GdapRoleName, Get-GdapAdminRoleName, Get-GdapRoleList, Format-GdapRoleList, Get-GdapTemplate, Get-GdapApprovalUrl,
    Get-GdapRequestSummary, Open-GdapApprovalPage, Test-GdapDuration, Get-GdapTenantInfo,
    Get-GdapCustomer, Get-GdapAccessAssignment, Get-GdapRelationship, Compare-GdapRelationship, Test-GdapCompliance,
    New-GdapRequest, Lock-GdapRelationship, Wait-GdapApproval, Set-GdapAccessAssignment, Get-GdapState, Save-GdapState
