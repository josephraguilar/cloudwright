#region Module setup ----------------------------------------------------------
#   WHAT   Strict mode for the whole module.
#   WHY    Every script imports this. A typo here breaks everything, so catch it
#          at import time rather than three scripts later.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:SettingsCache = $null
$script:SettingsCachePath = $null
$script:TenantIdCache = @{}
. (Join-Path $PSScriptRoot 'Safety.ps1')
#   GOTCHA The verified sign-in targets, the change recorder and the approved plan live in
#          global variables, not module scope: every task script re-imports this module
#          with -Force, which would reset module state between the dry run and the run.
#            $global:M365ToolkitTargets       Service -> verified tenant (Assert-M365Graph/Exchange)
#            $global:M365ToolkitChangeLog     changes planned/run since Start-M365ChangeRecording
#            $global:M365ToolkitApprovedPlan  when set, the only changes allowed to run
function Get-M365SessionTarget {
    # Internal. The shared Service -> verified target table (created once per PowerShell session).
    $table = Get-Variable -Name M365ToolkitTargets -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $table) { $table = @{}; Set-Variable -Name M365ToolkitTargets -Scope Global -Value $table }
    return $table
}
#endregion

function Get-M365Settings {
    <#
    .SYNOPSIS
        Loads the MSP-wide settings file (our tenant, shared mailboxes, naming conventions).
    .DESCRIPTION
        Reads config/msp.settings.local.json by default. That file is gitignored and holds
        the real values; config/msp.settings.example.json documents every key. The result
        is cached for the session so repeated calls are free.

        Anything that is the same for every client lives here: our home tenant, the
        clients@ shared mailbox, the support address, break-glass and admin account naming,
        the names of the IT@ and alerts@ distribution lists, Hudu base URL.
    .PARAMETER Path
        Override the settings file location. Tests use this.
    .PARAMETER Force
        Re-read the file even if a cached copy exists.
    .EXAMPLE
        $settings = Get-M365Settings
        $settings.msp.sharedClientsMailbox
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'It returns the whole settings document; "Setting" would be misleading.')]
    param(
        [Parameter()]
        [string]$Path,

        [Parameter()]
        [switch]$Force
    )

    #region 1. Locate the file ----------------------------------------------
    #   WHAT   Default to <repo>/config/msp.settings.local.json.
    #   WHY    The module lives three levels below the repo root. Resolving from
    #          $PSScriptRoot means the scripts work from any current directory.
    if (-not $Path) {
        $Path = Join-Path $PSScriptRoot '..' '..' '..' '..' 'config' 'msp.settings.local.json'
    }
    if (-not $Force -and $script:SettingsCache -and $script:SettingsCachePath -eq $Path) {
        return $script:SettingsCache
    }
    if (-not (Test-Path $Path)) {
        throw "Settings file not found: $Path. Copy config/msp.settings.example.json to config/msp.settings.local.json and fill it in."
    }
    #endregion

    #region 2. Load and validate ----------------------------------------------
    #   WHAT   Parse JSON and fail on placeholders that were never filled in.
    #   WHY    A '<fill-me>' value that slips through becomes a mail contact named
    #          '<fill-me>' in a client tenant. Catch it before any connection.
    $settings = Get-Content -Path $Path -Raw | ConvertFrom-Json
    $required = @(
        'msp.homeTenantId', 'msp.adminUpn', 'msp.sharedClientsMailbox', 'msp.supportEmail', 'msp.clientNotificationsDl'
    )
    foreach ($key in $required) {
        $value = $settings
        foreach ($part in $key.Split('.')) { $value = $value.$part }
        if (-not $value -or "$value" -match '^<.*>$') {
            throw "Setting '$key' is missing or still a placeholder in $Path."
        }
    }
    #endregion

    $script:SettingsCache = $settings
    $script:SettingsCachePath = $Path
    return $settings
}

function Get-M365ClientConfig {
    <#
    .SYNOPSIS
        Loads one client's onboarding config file and fills in derived values.
    .DESCRIPTION
        Reads config/clients/<Name>.local.json (gitignored) or an explicit -Path. Validates
        the keys the onboarding steps need and derives anything that follows from the rest:
        the onmicrosoft.com domain from tenantId when tenantId is a domain, the internal
        alias local part from shortName, and so on. See config/clients/example.client.json
        for every key and what it is used for.
    .PARAMETER Name
        Client short name. Resolves to config/clients/<Name>.local.json.
    .PARAMETER Path
        Explicit path to a client config file. Overrides -Name.
    .PARAMETER Settings
        MSP settings object from Get-M365Settings. Loaded if omitted.
    .EXAMPLE
        $client = Get-M365ClientConfig -Name contoso
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Name,

        [Parameter()]
        [string]$Path,

        [Parameter()]
        [object]$Settings
    )

    #region 1. Locate and parse ---------------------------------------------
    if (-not $Path) {
        if (-not $Name) { throw 'Pass -Name <client> or -Path <file>.' }
        $Path = Join-Path $PSScriptRoot '..' '..' '..' '..' 'config' 'clients' "$Name.local.json"
    }
    if (-not (Test-Path $Path)) {
        throw "Client config not found: $Path. Copy config/clients/example.client.json and fill it in."
    }
    $client = Get-Content -Path $Path -Raw | ConvertFrom-Json
    if (-not $Settings) { $Settings = Get-M365Settings }
    #endregion

    #region 2. Validate -----------------------------------------------------
    #   WHAT   The values every tenant-side step depends on.
    #   WHY    tenantId picks the tenant we sign in to. primaryDomain is where the
    #          IT@ / alerts@ lists and the 911@ mailbox get their addresses.
    #          onmicrosoftDomain is where break-glass and admin accounts live; it is
    #          fixed when the tenant is created (often not by us), so it is typed in,
    #          not discovered. If tenantId is itself the onmicrosoft domain it is
    #          reused; otherwise the field is required.
    foreach ($key in 'name', 'shortName', 'tenantId', 'primaryDomain') {
        $value = $client.$key
        if (-not $value -or "$value" -match '^<.*>$') {
            throw "Client config '$key' is missing or still a placeholder in $Path."
        }
    }
    if ($client.shortName -notmatch '^[a-z0-9][a-z0-9-]{1,30}$') {
        throw "shortName '$($client.shortName)' must be lowercase letters, digits and hyphens. It becomes a mail alias."
    }
    $hasOnmicrosoft = ($client.PSObject.Properties.Name -contains 'onmicrosoftDomain') -and $client.onmicrosoftDomain -and "$($client.onmicrosoftDomain)" -notmatch '^<.*>$'
    if (-not $hasOnmicrosoft) {
        if ($client.tenantId -match '\.onmicrosoft\.com$') {
            $client | Add-Member -NotePropertyName onmicrosoftDomain -NotePropertyValue $client.tenantId -Force
        } else {
            throw "Client config 'onmicrosoftDomain' is required (the tenant's initial <something>.onmicrosoft.com domain) when tenantId is a GUID or a custom domain, in $Path."
        }
    }
    if ($client.onmicrosoftDomain -notmatch '^[a-z0-9-]+\.onmicrosoft\.com$') {
        throw "onmicrosoftDomain '$($client.onmicrosoftDomain)' must look like <name>.onmicrosoft.com (lowercase)."
    }
    #endregion

    #region 3. Derive ---------------------------------------------------------
    #   WHAT   Fill in values that follow from what the tech typed.
    #   WHY    Fewer fields to fill means fewer to get wrong. Each derived value
    #          can still be set explicitly in the file to override.
    #   GOTCHA The alias convention is <name>.clients@<our domain>, a secondary
    #          address on the single clients@ shared mailbox. msp.clientAliasPattern
    #          holds the pattern; {shortName} is the only token. The console wizard
    #          asks the tech to confirm the result, and the client file can override.
    $homeDomain = ($Settings.msp.sharedClientsMailbox -split '@')[1]
    $pattern = if ($Settings.msp.PSObject.Properties.Name -contains 'clientAliasPattern' -and $Settings.msp.clientAliasPattern) {
        $Settings.msp.clientAliasPattern
    } else { "{shortName}.clients@$homeDomain" }
    $derived = [ordered]@{
        internalAlias     = $pattern.Replace('{shortName}', $client.shortName)
        domains           = @($client.primaryDomain)
        support24x7       = $false
        ironScales        = $false
        americanHelpDesk  = $false
        huduCompanyId     = 0
        poc               = @()
        newUserDefaults   = [pscustomobject]@{ usageLocation = 'US'; licenses = @(); groups = @(); distributionLists = @(); timeZone = 'Pacific Standard Time'; language = 'en-US'; issueTemporaryAccessPass = $true; temporaryAccessPassHours = 8 }
    }
    foreach ($key in $derived.Keys) {
        if (-not ($client.PSObject.Properties.Name -contains $key) -or $null -eq $client.$key) {
            $client | Add-Member -NotePropertyName $key -NotePropertyValue $derived[$key] -Force
        }
    }
    if ($client.domains -notcontains $client.primaryDomain) {
        $client.domains = @($client.primaryDomain) + @($client.domains)
    }
    $client | Add-Member -NotePropertyName configPath -NotePropertyValue (Resolve-Path $Path).Path -Force
    #endregion

    return $client
}

function Resolve-M365TenantId {
    <#
    .SYNOPSIS
        Turns a tenant domain (contoso.onmicrosoft.com, contoso.com) into the tenant GUID.
    .DESCRIPTION
        Uses the public, unauthenticated OpenID configuration endpoint, so it works for any
        tenant before you sign in. A GUID passes through unchanged. Assert-M365Graph uses
        this so a session in the wrong tenant is always detected, even when the caller
        passed a domain name.
    .PARAMETER TenantId
        GUID or any verified domain of the tenant.
    .EXAMPLE
        Resolve-M365TenantId -TenantId contoso.onmicrosoft.com
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$TenantId
    )
    if ($TenantId -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { return $TenantId.ToLowerInvariant() }
    $key = $TenantId.Trim().ToLowerInvariant()
    if ($key -notmatch '^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$') {
        throw 'Tenant must be a GUID or a verified DNS domain; URLs, paths, and query strings are not accepted.'
    }
    if ($script:TenantIdCache.ContainsKey($key)) { return $script:TenantIdCache[$key] }
    $uri = "https://login.microsoftonline.com/$key/v2.0/.well-known/openid-configuration"
    try {
        $config = Invoke-RestMethod -Uri $uri -ErrorAction Stop
    } catch {
        throw "Could not resolve tenant '$TenantId': $($_.Exception.Message). Check the spelling; the domain must be verified in some Entra tenant."
    }
    if ($config.issuer -match '^https://login\.microsoftonline\.com/([0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})/v2\.0/?$') {
        $script:TenantIdCache[$key] = $Matches[1].ToLowerInvariant()
        return $script:TenantIdCache[$key]
    }
    throw "Unexpected issuer '$($config.issuer)' while resolving tenant '$TenantId'."
}

function Assert-M365SameTenant {
    <#
    .SYNOPSIS
        Throws unless every given tenant identifier (GUID or verified domain) belongs to the same tenant.
    .DESCRIPTION
        A client config, or a script that signs in to Graph and Exchange separately, names the
        tenant more than once (tenantId, onmicrosoftDomain, primaryDomain, -TenantId and
        -Organization). One typo there sends half the run to another client. This resolves
        every value to its tenant GUID and refuses to continue when they differ.
    .PARAMETER Identifier
        Tenant GUIDs or domains, labelled: @{ tenantId = 'x'; onmicrosoftDomain = 'y' }.
    .PARAMETER AllowUnresolved
        Labels whose value may not resolve yet (a custom domain not verified anywhere); a
        warning instead of a stop. A value that resolves to a different tenant always stops.
    .EXAMPLE
        Assert-M365SameTenant -Identifier ([ordered]@{ TenantId = $TenantId; Organization = $Organization })
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Identifier,

        [Parameter()]
        [string[]]$AllowUnresolved = @()
    )
    $resolved = [ordered]@{}
    foreach ($label in $Identifier.Keys) {
        $value = "$($Identifier[$label])"
        if (-not $value) { continue }
        try { $resolved[$label] = Resolve-M365TenantId -TenantId $value }
        catch {
            if ($AllowUnresolved -contains $label) { Write-Warning "$label '$value' does not resolve to a tenant yet; not checked."; continue }
            throw
        }
    }
    $distinct = @($resolved.Values | Sort-Object -Unique)
    if ($distinct.Count -gt 1) {
        $detail = ($resolved.Keys | ForEach-Object { "$_ '$($Identifier[$_])' = tenant $($resolved[$_])" }) -join '; '
        throw "These do not belong to the same tenant, so nothing was done: $detail. Fix the value that names the wrong client."
    }
    if ($distinct.Count -eq 1) { return $distinct[0] }
}

function Assert-M365Graph {
    <#
    .SYNOPSIS
        Ensures a Microsoft Graph session exists for the given tenant with the given scopes.
    .DESCRIPTION
        The 365 equivalent of Assert-AzContext in the azure repo. Checks Get-MgContext. If
        there is no session, or it is for a different tenant, or it lacks a requested scope,
        connects (interactively) with Connect-MgGraph -TenantId <tenant>.

        For a client tenant this is a GDAP sign-in: you authenticate with your own partner
        account and Entra resolves the delegated roles into the client tenant. Nothing is
        stored in the client tenant. For our own tenant pass our tenant ID.
    .PARAMETER TenantId
        Tenant to target: a GUID or any verified domain (contoso.onmicrosoft.com).
    .PARAMETER Scopes
        Delegated Graph scopes the caller needs. Missing scopes trigger a reconnect so
        consent is requested once, up front.
    .EXAMPLE
        Assert-M365Graph -TenantId contoso.onmicrosoft.com -Scopes 'User.Read.All', 'Domain.Read.All'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter()]
        [string[]]$Scopes = @('User.Read.All')
    )

    #region 1. Preflight ------------------------------------------------------
    #   WHAT   Make sure Microsoft.Graph.Authentication is installed.
    #   WHY    'Connect-MgGraph is not recognized' is a confusing first error.
    #   GOTCHA Checked at call time, not import time, so tests can load this
    #          module on a machine without the Graph SDK.
    $readOnly = Test-M365ReadOnly
    if ($readOnly) { Assert-M365ReadOnlyScope -Scopes $Scopes }
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw 'Microsoft.Graph is not installed. Run: Install-Module Microsoft.Graph -Scope CurrentUser'
    }
    #endregion

    #region 2. Reuse or connect ---------------------------------------------
    #   WHAT   Reuse the session when tenant and scopes already match.
    #   WHY    Interactive sign-in opens a browser. Once per tenant per terminal
    #          is the goal, not once per script.
    #   GOTCHA Get-MgContext.TenantId is always a GUID even if you signed in with
    #          a domain name, so the requested tenant is resolved to its GUID first.
    #          Without this, an onboarding run could reuse our home-tenant session
    #          and create the break-glass account in the wrong tenant.
    $tenantGuid = Resolve-M365TenantId -TenantId $TenantId
    $context = Get-MgContext -ErrorAction SilentlyContinue
    if ($readOnly -and $context -and -not (Test-M365ReadOnlyGraphContext -Context $context)) {
        $null = Disconnect-MgGraph -ErrorAction Stop
        $context = $null
    }
    $needConnect = $true
    if ($context) {
        $sameTenant = ($context.TenantId -eq $tenantGuid)
        $missing = @($Scopes | Where-Object { $context.Scopes -notcontains $_ })
        $needConnect = -not $sameTenant -or $missing.Count -gt 0
        if ($needConnect) {
            Write-Verbose "Existing Graph session does not match (tenant ok: $sameTenant, missing scopes: $($missing -join ', ')). Reconnecting."
        }
    }
    if ($needConnect) {
        Write-Verbose "Connecting to Microsoft Graph in tenant $TenantId."
        if ($context) { $null = Disconnect-MgGraph -ErrorAction Stop }
        $null = Connect-MgGraph -TenantId $tenantGuid -Scopes $Scopes -ContextScope Process -NoWelcome -ErrorAction Stop
        $context = Get-MgContext
    }
    if ($readOnly -and -not (Test-M365ReadOnlyGraphContext -Context $context -RequiredScopes $Scopes)) {
        $null = Disconnect-MgGraph -ErrorAction Stop
        throw 'Safe mode refused the Graph session: a delegated, process-scoped session with only approved read permissions is required.'
    }
    if (-not $context) { throw 'Graph sign-in did not return a context.' }
    if ("$($context.TenantId)".ToLowerInvariant() -ne $tenantGuid) {
        $null = Disconnect-MgGraph -ErrorAction Stop
        throw "Signed in to Graph, but the session is in tenant $($context.TenantId), not $TenantId ($tenantGuid). Stopped before any change."
    }
    #endregion

    #region 3. Record the verified target ---------------------------------------
    #   WHAT   Invoke-M365Change labels every Graph change with this tenant and checks the
    #          live context still matches it right before running.
    #   WHY    Plans read better with a domain than a GUID. When a GUID was passed, ask the
    #          tenant for its initial domain (best effort; the GUID is the fallback).
    $label = if ($TenantId -match '^[0-9a-fA-F]{8}-') { $tenantGuid } else { $TenantId.ToLowerInvariant() }
    if ($label -eq $tenantGuid -and (Get-Command -Name Get-MgOrganization -ErrorAction SilentlyContinue)) {
        try {
            $initial = @((Get-MgOrganization -ErrorAction Stop | Select-Object -First 1).VerifiedDomains | Where-Object { $_.IsInitial }) | Select-Object -First 1
            if ($initial -and $initial.Name) { $label = "$($initial.Name)".ToLowerInvariant() }
        } catch { Write-Verbose "Initial domain not readable ($($_.Exception.Message)); plans show the tenant GUID." }
    }
    (Get-M365SessionTarget)['Graph'] = [pscustomobject]@{ Label = $label; TenantId = $tenantGuid; ModuleName = $null; Verified = 'live' }
    #endregion

    Write-Verbose "Graph session: $($context.Account) in tenant $($context.TenantId)."
    return $context
}

function Get-M365ExchangeTenant {
    <#
    .SYNOPSIS
        Asks the open Exchange Online session which tenant it is actually talking to. $null when there is no usable session.
    .DESCRIPTION
        Reads the tenant's initial (<name>.onmicrosoft.com) accepted domain through the active
        Get-AcceptedDomain cmdlet and resolves it to the tenant GUID. This is the tenant every
        un-prefixed Exchange cmdlet will hit, whatever Get-ConnectionInformation says.
    .EXAMPLE
        (Get-M365ExchangeTenant).InitialDomain
    #>
    [CmdletBinding()]
    param()
    $cmd = Get-Command -Name Get-AcceptedDomain -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    try {
        $initial = @(Get-AcceptedDomain -ErrorAction Stop | Where-Object { $_.InitialDomain }) | Select-Object -First 1
    } catch {
        Write-Verbose "Exchange session not usable: $($_.Exception.Message)"
        return $null
    }
    if (-not $initial) { return $null }
    $domain = "$($initial.DomainName)".ToLowerInvariant()
    [pscustomobject]@{ TenantId = (Resolve-M365TenantId -TenantId $domain); InitialDomain = $domain; ModuleName = $cmd.ModuleName }
}

function Assert-M365Exchange {
    <#
    .SYNOPSIS
        Ensures the Exchange Online session talks to exactly the given organization, verified live.
    .DESCRIPTION
        Exchange Online tasks (mail contacts, distribution lists, shared mailboxes, DKIM,
        inbox rules) have no Graph equivalent, so they go through ExchangeOnlineManagement.
        For a client tenant this connects with -DelegatedOrganization (the GDAP path for
        Exchange) using your partner account. When -Organization is our own tenant (it
        resolves to msp.homeTenantId) it connects without delegation.

        Safety rules, in order:
          1. -Organization is required. There is no "blank means our tenant" default.
          2. With -ExpectedTenantId (the Graph tenant of the same script), both must be the
             same tenant or nothing happens.
          3. The open session is asked which tenant it is actually in (Get-M365ExchangeTenant).
             If it is not the requested one, every Exchange connection is closed and a single
             new one is opened. Exchange cmdlets always follow the most recent connection, so
             "reusing" an older connection to another client would send changes there.
          4. After connecting, the tenant is checked again; a mismatch stops the script.
    .PARAMETER Organization
        The tenant's onmicrosoft.com domain or any verified domain. Our own tenant is allowed
        and named explicitly like any other.
    .PARAMETER UserPrincipalName
        Partner account to sign in as. Skips the account picker.
    .PARAMETER ExpectedTenantId
        Tenant the script also signed in to with Graph (GUID or domain). Must be the same tenant.
    .EXAMPLE
        Assert-M365Exchange -Organization contoso.onmicrosoft.com -UserPrincipalName tech@msp.example
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Alias('DelegatedOrganization')]
        [ValidateNotNullOrEmpty()]
        [string]$Organization,

        [Parameter()]
        [string]$UserPrincipalName,

        [Parameter()]
        [string]$ExpectedTenantId
    )

    #region 1. Preflight ------------------------------------------------------
    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        throw 'ExchangeOnlineManagement is not installed. Run: Install-Module ExchangeOnlineManagement -Scope CurrentUser'
    }
    if ($Organization -match '^[0-9a-fA-F]{8}-') { throw "-Organization must be a domain (e.g. contoso.onmicrosoft.com), not a GUID: '$Organization'." }
    $wantGuid = if ($ExpectedTenantId) {
        Assert-M365SameTenant -Identifier ([ordered]@{ Organization = $Organization; TenantId = $ExpectedTenantId })
    } else { Resolve-M365TenantId -TenantId $Organization }
    $settings = Get-M365Settings
    $isHome = ($wantGuid -eq (Resolve-M365TenantId -TenantId $settings.msp.homeTenantId))
    #endregion

    #region 2. Reuse only a session verified to be in that tenant ------------------
    $readOnly = Test-M365ReadOnly
    $current = Get-M365ExchangeTenant
    $known = (Get-M365SessionTarget)['Exchange']
    $limited = $known -and $known.PSObject.Properties['ReadOnly'] -and $known.ReadOnly -and
        $current -and $known.ModuleName -eq $current.ModuleName -and $known.TenantId -eq $wantGuid
    if ($current -and $current.TenantId -eq $wantGuid -and (-not $readOnly -or $limited)) {
        Write-Verbose "Reusing the Exchange Online session in $($current.InitialDomain) (verified live)."
    } else {
        if ($current) { Write-Verbose "Open Exchange session is in $($current.InitialDomain), not $Organization. Closing it." }
        if (@(Get-ConnectionInformation -ErrorAction SilentlyContinue).Count -gt 0) { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction Stop }
        $connectParams = @{ ShowBanner = $false; ErrorAction = 'Stop' }
        if ($readOnly) { $connectParams.CommandName = @(Get-M365ReadOnlyExchangeCommand) }
        if (-not $isHome) { $connectParams.DelegatedOrganization = $Organization }
        if ($UserPrincipalName) { $connectParams.UserPrincipalName = $UserPrincipalName }
        Write-Verbose "Connecting to Exchange Online $(if ($isHome) { '(our tenant)' } else { "for $Organization" })."
        Connect-ExchangeOnline @connectParams
        $current = Get-M365ExchangeTenant
        if (-not $current) { throw "Connected to Exchange Online but could not read the session's tenant. Stopped before any change." }
        if ($current.TenantId -ne $wantGuid) {
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction Stop
            throw "The Exchange session is in $($current.InitialDomain) ($($current.TenantId)), not $Organization ($wantGuid). Stopped before any change."
        }
    }
    #endregion

    #region 3. Record the verified target ---------------------------------------
    #   WHAT   Invoke-M365Change labels every Exchange change with this domain and checks
    #          the cmdlet it runs still comes from this same connection.
    (Get-M365SessionTarget)['Exchange'] = [pscustomobject]@{ Label = $current.InitialDomain; TenantId = $current.TenantId; ModuleName = $current.ModuleName; Verified = 'live'; ReadOnly = $readOnly }
    #endregion

    return $current
}

function Disconnect-M365Tenant {
    <#
    .SYNOPSIS
        Closes the Graph and Exchange Online sessions.
    .DESCRIPTION
        Call this when switching from a client tenant back to ours, or at the end of a run.
        Leaving a delegated Exchange session open and then running a cmdlet meant for our
        tenant is the easiest way to create an object in the wrong place.
    .EXAMPLE
        Disconnect-M365Tenant
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if ($PSCmdlet.ShouldProcess('Graph and Exchange Online sessions', 'Disconnect')) {
        if (Get-Command Disconnect-MgGraph -ErrorAction SilentlyContinue) {
            $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
        }
        if (Get-Command Disconnect-ExchangeOnline -ErrorAction SilentlyContinue) {
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
        }
        (Get-M365SessionTarget).Remove('Graph')
        (Get-M365SessionTarget).Remove('Exchange')
    }
}

function Resolve-DnsRecord {
    <#
    .SYNOPSIS
        Looks up DNS records (TXT, CNAME, MX, A) in a way that works on Windows, macOS and Linux.
    .DESCRIPTION
        Resolve-DnsName only exists on Windows. This uses DNS over HTTPS (Cloudflare by
        default) so the SPF and DKIM checks behave the same everywhere, including CI.
        Returns the record data as plain strings: TXT records are unquoted and their
        string segments joined, CNAME targets lose their trailing dot.
    .PARAMETER Name
        The DNS name to resolve.
    .PARAMETER Type
        Record type. TXT, CNAME, MX or A.
    .PARAMETER Resolver
        DoH endpoint. Any server that speaks application/dns-json works.
    .EXAMPLE
        Resolve-DnsRecord -Name contoso.com -Type TXT
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [ValidateSet('TXT', 'CNAME', 'MX', 'A')]
        [string]$Type = 'TXT',

        [Parameter()]
        [string]$Resolver = 'https://cloudflare-dns.com/dns-query'
    )

    #region 1. Query ----------------------------------------------------------
    #   WHAT   One GET per lookup. NXDOMAIN or no answer returns an empty array.
    #   WHY    Callers (SPF lookup counting, DKIM CNAME checks) treat "no record"
    #          as a finding, not an exception.
    $uri = "{0}?name={1}&type={2}" -f $Resolver, [uri]::EscapeDataString($Name), $Type
    try {
        $response = Invoke-RestMethod -Uri $uri -Headers @{ accept = 'application/dns-json' } -ErrorAction Stop
    } catch {
        throw "DNS lookup for $Name ($Type) failed: $($_.Exception.Message)"
    }
    if (-not ($response.PSObject.Properties.Name -contains 'Answer') -or -not $response.Answer) { return @() }
    #endregion

    #region 2. Normalize ------------------------------------------------------
    #   WHAT   Strip DoH quoting so callers see the record as DNS admins write it.
    #   WHY    A long TXT record comes back as "part one" "part two". SPF treats
    #          that as one string, so join the segments before parsing.
    #   GOTCHA Only answers of the requested type are returned. A CNAME chain on a
    #          TXT query returns the CNAME rows too; skip them.
    $typeCodes = @{ A = 1; CNAME = 5; MX = 15; TXT = 16 }
    $records = foreach ($answer in $response.Answer) {
        if ($answer.type -ne $typeCodes[$Type]) { continue }
        $data = [string]$answer.data
        switch ($Type) {
            'TXT' { ($data -replace '"\s+"', '') -replace '^"|"$', '' }
            'CNAME' { $data.TrimEnd('.') }
            'MX' { ($data -split '\s+')[-1].TrimEnd('.') }
            default { $data }
        }
    }
    #endregion

    return @($records)
}

function New-StrongPassword {
    <#
    .SYNOPSIS
        Generates a random password using the OS cryptographic RNG.
    .DESCRIPTION
        Used for break-glass and admin accounts. Default 32 characters from letters,
        digits and a conservative symbol set that survives copy and paste into every
        portal we use. Guarantees at least one of each class so Entra's complexity rule
        never rejects it.
    .PARAMETER Length
        Password length. 16 to 128.
    .PARAMETER AsSecureString
        Return a SecureString instead of plain text.
    .EXAMPLE
        $plain = New-StrongPassword -Length 64
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The plain text is generated here, in memory, never read from input.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Generates a string; changes no system state.')]
    [OutputType([string], [securestring])]
    param(
        [Parameter()]
        [ValidateRange(16, 128)]
        [int]$Length = 32,

        [Parameter()]
        [switch]$AsSecureString
    )

    #region 1. Build ----------------------------------------------------------
    #   WHAT   One character from each class first, then fill, then shuffle.
    #   WHY    Pure random draws can miss a class; Entra requires three of four.
    #          Shuffling hides which positions were the guaranteed ones.
    $classes = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnopqrstuvwxyz',
        '23456789',
        '!@#$%^&*-_=+?'
    )
    $all = -join $classes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $pick = {
        param([string]$set)
        $bytes = [byte[]]::new(4)
        $rng.GetBytes($bytes)
        $set[[System.BitConverter]::ToUInt32($bytes, 0) % $set.Length]
    }
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($class in $classes) { $chars.Add((& $pick $class)) }
    while ($chars.Count -lt $Length) { $chars.Add((& $pick $all)) }

    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $bytes = [byte[]]::new(4)
        $rng.GetBytes($bytes)
        $j = [System.BitConverter]::ToUInt32($bytes, 0) % ($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }
    $rng.Dispose()
    $plain = -join $chars
    #endregion

    if ($AsSecureString) { return (ConvertTo-SecureString -String $plain -AsPlainText -Force) }
    return $plain
}

function Test-M365PasswordComplexity {
    <#
    .SYNOPSIS
        Checks a password against Entra's rules (8+ chars, 3 of 4 classes) and our minimum length. Pure.
    .PARAMETER Password
        The candidate.
    .PARAMETER MinimumLength
        Our floor. Default 16.
    .EXAMPLE
        (Test-M365PasswordComplexity -Password $p -MinimumLength 16).Ok
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'Validation of a value the operator just typed; nothing is stored.')]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Password,

        [Parameter()]
        [int]$MinimumLength = 16
    )
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($Password.Length -lt $MinimumLength) { $problems.Add("at least $MinimumLength characters (has $($Password.Length))") }
    $classes = @(($Password -cmatch '[A-Z]'), ($Password -cmatch '[a-z]'), ($Password -match '[0-9]'), ($Password -match '[^A-Za-z0-9]')) | Where-Object { $_ }
    if (@($classes).Count -lt 3) { $problems.Add('three of: uppercase, lowercase, digit, symbol') }
    if ($Password -match '\s') { $problems.Add('no spaces') }
    [pscustomobject]@{ Ok = ($problems.Count -eq 0); Problems = @($problems) }
}

function Read-M365Password {
    <#
    .SYNOPSIS
        Prompts for a password twice (hidden), verifies the entries match and meet complexity, returns it as plain text for Graph.
    .DESCRIPTION
        The operator types the password and saves it in Hudu themselves; the toolkit never
        stores it. Three attempts, then it throws. In a non-interactive host (the GUI's
        background runspace) it throws a clear message: run the script from a terminal.
    .PARAMETER Prompt
        What the password is for, e.g. 'Break-glass password for Contoso'.
    .PARAMETER MinimumLength
        Our floor. Default 16.
    .EXAMPLE
        $plain = Read-M365Password -Prompt 'Break-glass password'
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Round-trip of a SecureString the operator typed; Graph needs the plain text.')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter()]
        [int]$MinimumLength = 16
    )
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $first = Read-Host -Prompt "$Prompt (typed hidden, min $MinimumLength chars)" -AsSecureString
            $second = Read-Host -Prompt 'Type it again to verify' -AsSecureString
        } catch {
            throw "This step asks for a password at the keyboard and this host cannot prompt. Run the script from a PowerShell 7 terminal (use Copy in the GUI), or pass -GeneratePassword. ($($_.Exception.Message))"
        }
        $a = [System.Net.NetworkCredential]::new('', $first).Password
        $b = [System.Net.NetworkCredential]::new('', $second).Password
        if ($a -cne $b) { Write-Warning 'The two entries do not match.'; continue }
        $check = Test-M365PasswordComplexity -Password $a -MinimumLength $MinimumLength
        if (-not $check.Ok) { Write-Warning "Password needs: $($check.Problems -join '; ')."; continue }
        return $a
    }
    throw 'No valid password entered after 3 attempts.'
}

function Add-HuduPassword {
    <#
    .SYNOPSIS
        Stores a credential in a client's Hudu Passwords section via the Hudu REST API.
    .DESCRIPTION
        The break-glass and admin account steps call this so the password never has to be
        copied by hand. Uses POST /api/v1/asset_passwords with the x-api-key header. The
        API key comes from the environment variable named in settings (hudu.apiKeyEnvVar,
        default HUDU_API_KEY), never from a file in this repo.

        Hudu MCP tooling cannot write passwords, so this is the one Hudu write that must
        go through the REST API directly.
    .PARAMETER CompanyId
        Hudu company_id of the client. Numeric. Found in the client's AI Context article.
    .PARAMETER Name
        Password entry name, e.g. 'Break Glass - Entra ID'.
    .PARAMETER Username
        The UPN or username.
    .PARAMETER Password
        The secret.
    .PARAMETER Description
        Free text. Say what the account is for and that it is excluded from CA.
    .PARAMETER Settings
        MSP settings. Loaded if omitted.
    .EXAMPLE
        Add-HuduPassword -CompanyId 42 -Name 'Break Glass - Entra ID' -Username breakglass@contoso.onmicrosoft.com -Password $plain
    .NOTES
        Status: Untested against a live Hudu. The endpoint and payload follow the Hudu
        API v1 docs; verify the first write by opening the entry in Hudu.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'Hudu REST API takes the plain text; it is generated in memory by the caller.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Mirrors the Hudu asset_password payload, which is a username and a password.')]
    param(
        [Parameter(Mandatory)]
        [int]$CompanyId,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Username,

        [Parameter(Mandatory)]
        [string]$Password,

        [Parameter()]
        [string]$Description,

        [Parameter()]
        [object]$Settings
    )

    #region 1. Check the API key is there before planning anything ----------------
    if (-not $Settings) { $Settings = Get-M365Settings }
    $envVar = if ($Settings.hudu.apiKeyEnvVar) { $Settings.hudu.apiKeyEnvVar } else { 'HUDU_API_KEY' }
    if (-not [Environment]::GetEnvironmentVariable($envVar)) { throw "Hudu API key not found in environment variable $envVar." }
    #endregion

    #region 2. Write ----------------------------------------------------------
    #   WHAT   One POST through Invoke-M365Change. Returns the created record so the caller can log its ID.
    #   WHY    The plan shows the call with the password hidden; the API key never appears in it.
    $body = [ordered]@{
        asset_password = [ordered]@{
            company_id  = $CompanyId
            name        = $Name
            username    = $Username
            password    = $Password
            description = $Description
        }
    }
    $run = Invoke-M365Change -Caller $PSCmdlet -Service Hudu -Action "Save password '$Name' for $Username in Hudu company $CompanyId" `
        -Command 'Invoke-M365HuduRequest' -Parameters ([ordered]@{ Method = 'Post'; Path = '/api/v1/asset_passwords'; Body = $body })
    if ($run.Ran) { return $run.Output.asset_password }
    #endregion
}

function Invoke-M365HuduRequest {
    # Internal. One Hudu REST call: JSON body, x-api-key from the environment variable in settings.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Get', 'Post', 'Put')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [System.Collections.IDictionary]$Body
    )
    if ($Method -ne 'Get') { Assert-M365WriteAllowed }
    $settings = Get-M365Settings
    $envVar = if ($settings.hudu.apiKeyEnvVar) { $settings.hudu.apiKeyEnvVar } else { 'HUDU_API_KEY' }
    $apiKey = [Environment]::GetEnvironmentVariable($envVar)
    if (-not $apiKey) { throw "Hudu API key not found in environment variable $envVar." }
    $request = @{ Method = $Method; Uri = "$($settings.hudu.baseUrl.TrimEnd('/'))$Path"; Headers = @{ 'x-api-key' = $apiKey; 'Content-Type' = 'application/json' }; ErrorAction = 'Stop' }
    if ($Body) { $request.Body = ($Body | ConvertTo-Json -Depth 6) }
    Invoke-RestMethod @request
}

function Invoke-M365WithRetry {
    <#
    .SYNOPSIS
        Runs a scriptblock, retrying transient Graph/Exchange failures with exponential backoff.
    .DESCRIPTION
        Retries on throttling (429), 503/504, gateway and timeout errors, honoring a
        Retry-After header when the exception carries one. Everything else is rethrown at
        once. The Graph SDK already retries 429 internally; this covers the rest and gives
        every caller the same behavior. A failed status query is still a failure: callers
        must never treat an exception here as "the thing does not exist".
    .PARAMETER ScriptBlock
        The call to make.
    .PARAMETER MaxAttempts
        Total attempts. Default 5.
    .PARAMETER BaseDelaySeconds
        First delay; doubles each attempt with up to one second of jitter. Default 2.
    .PARAMETER Operation
        Name for log lines.
    .PARAMETER Write
        The call changes something. Retry only on replies that mean the request was not
        processed (429, 503); a timeout is rethrown because the change may have happened.
    .EXAMPLE
        $rels = Invoke-M365WithRetry -Operation 'List GDAP' { Get-MgTenantRelationshipDelegatedAdminRelationship -All }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [scriptblock]$ScriptBlock,

        [Parameter()]
        [ValidateRange(1, 10)]
        [int]$MaxAttempts = 5,

        [Parameter()]
        [ValidateRange(1, 60)]
        [int]$BaseDelaySeconds = 2,

        [Parameter()]
        [string]$Operation = 'call',

        [Parameter()]
        [switch]$Write
    )

    #   GOTCHA A write that times out (or gets 502/504) may still have been carried out by the
    #          service; retrying it can create a second relationship, mailbox or contact. With
    #          -Write only the replies that mean "rejected, not processed" (429, 503) are retried.
    $transient = if ($Write) {
        'TooManyRequests|\b429\b|ServiceUnavailable|\b503\b'
    } else {
        'TooManyRequests|\b429\b|ServiceUnavailable|\b503\b|GatewayTimeout|\b504\b|BadGateway|\b502\b|timed out|timeout|temporarily unavailable|connection was (reset|closed)'
    }
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $ScriptBlock
        } catch {
            $message = $_.Exception.Message
            $isTransient = $message -match $transient
            if (-not $isTransient -or $attempt -eq $MaxAttempts) { throw }
            $delay = $BaseDelaySeconds * [math]::Pow(2, $attempt - 1) + (Get-Random -Minimum 0 -Maximum 1000) / 1000
            $retryAfter = $null
            try { $retryAfter = $_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds } catch { $retryAfter = $null }
            if ($retryAfter -and $retryAfter -gt 0) { $delay = [math]::Max($delay, $retryAfter) }
            Write-Warning "$Operation failed (attempt $attempt of $MaxAttempts): $message. Retrying in $([int]$delay)s."
            Start-Sleep -Seconds $delay
        }
    }
}

function New-M365CorrelationId {
    <#
    .SYNOPSIS
        Returns a short correlation id for one run, used in logs and state files.
    .EXAMPLE
        $cid = New-M365CorrelationId
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Generates a string; changes no system state.')]
    [OutputType([string])]
    param()
    return ([guid]::NewGuid().ToString('N').Substring(0, 12))
}

function Write-M365Log {
    <#
    .SYNOPSIS
        Appends one structured log line (JSON) to runs/logs/<date>.jsonl.
    .DESCRIPTION
        Fields: ts, level, correlationId, operation, tenantId, message, data. The message and
        data are sanitized: anything that looks like a bearer/JWT token is redacted. Never
        pass credentials in -Data; this function cannot recognize every secret shape.
        runs/ is gitignored.
    .PARAMETER Message
        What happened, in one line.
    .PARAMETER Level
        Info, Warning or Error.
    .PARAMETER Operation
        Function or step name.
    .PARAMETER TenantId
        Customer tenant the operation targeted, if any.
    .PARAMETER CorrelationId
        From New-M365CorrelationId; ties one run's lines together.
    .PARAMETER Data
        Small hashtable of non-sensitive details (ids, statuses, counts).
    .PARAMETER LogPath
        Override the log folder (tests).
    .PARAMETER PassThru
        Return the log file path. Without it nothing is returned, so a call can never leak
        a path into a caller's output.
    .EXAMPLE
        Write-M365Log -Operation 'New-GdapRequest' -TenantId $tid -CorrelationId $cid -Message 'Relationship created' -Data @{ relationshipId = $rel.Id }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info',

        [Parameter()]
        [string]$Operation,

        [Parameter()]
        [string]$TenantId,

        [Parameter()]
        [string]$CorrelationId,

        [Parameter()]
        [hashtable]$Data,

        [Parameter()]
        [string]$LogPath,

        [Parameter()]
        [switch]$PassThru
    )

    if (-not $LogPath) { $LogPath = if ($env:M365_TOOLKIT_LOG_PATH) { $env:M365_TOOLKIT_LOG_PATH } else { [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..' '..' 'runs' 'logs')) } }
    if (-not (Test-Path $LogPath)) { $null = New-Item -ItemType Directory -Path $LogPath -Force }
    $redact = { param([string]$text) if ($null -eq $text) { return $null }; $text -replace 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}', '[REDACTED-TOKEN]' -replace '(?i)(bearer\s+)[A-Za-z0-9._-]+', '$1[REDACTED]' }
    $safeData = @{}
    if ($Data) { foreach ($k in $Data.Keys) { $safeData[$k] = & $redact ([string]$Data[$k]) } }
    $line = [ordered]@{
        ts            = (Get-Date).ToUniversalTime().ToString('o')
        level         = $Level
        correlationId = $CorrelationId
        operation     = $Operation
        tenantId      = $TenantId
        message       = (& $redact $Message)
        data          = $safeData
    } | ConvertTo-Json -Compress -Depth 4
    $file = Join-Path $LogPath ("{0}.jsonl" -f (Get-Date -Format 'yyyy-MM-dd'))
    Add-Content -Path $file -Value $line -Encoding utf8
    if ($PassThru) { return $file }
}

#region Plan and run every change ---------------------------------------------------------
#   WHAT   Invoke-M365Change is the one door every tenant change goes through. It shows the
#          exact Exchange/Graph command (secrets hidden) before anything runs, runs exactly
#          that parameter data, records it, and logs it. Format-M365Command renders a command;
#          New-M365Placeholder stands in for a value that only exists after an earlier step
#          (the id of something a dry run did not create).
#   WHY    The operator reviews the real commands, not a wrapper script, and a run started
#          from a reviewed plan (Start-M365ChangeRecording -ApprovedPlan) refuses to make any
#          change the plan did not show.
#   GOTCHA Secrets are hidden by key name (password, secret, token, ...). Pass them under a
#          name like that, never inside a free-text string.
$script:SecretKeyPattern = '(?i)^(?!passwordpolicies$).*(password|passwd|secret|apikey|api-key|token|temporaryaccesspass)'

function New-M365Placeholder {
    <#
    .SYNOPSIS
        A stand-in value for a dry run: something that only exists once an earlier step has run (e.g. a new object's id).
    .DESCRIPTION
        Rendered as <Name> in the plan. A reviewed plan accepts any real value in its place
        during the run; a placeholder can never reach a real command.
    .PARAMETER Name
        What the value will be, in words: 'id of the relationship created above'.
    .EXAMPLE
        $id = if ($run.Ran) { $run.Output.Id } else { New-M365Placeholder 'id of the relationship created above' }
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns an object; changes nothing.')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name
    )
    [pscustomobject]@{ PSTypeName = 'M365.Placeholder'; Name = $Name }
}

function Add-M365LiteralToken {
    # Internal. Appends the tokens that render one value: literal text, or a placeholder hole.
    param([System.Collections.Generic.List[object]]$Tokens, $Value, [string]$Key)
    $lit = { param($t) $Tokens.Add([pscustomobject]@{ Text = $t; Hole = $false }) }
    if ($null -eq $Value) { & $lit '$null'; return }
    if ($Value.PSObject.TypeNames -contains 'M365.Placeholder') { $Tokens.Add([pscustomobject]@{ Text = "<$($Value.Name)>"; Hole = $true }); return }
    if ($Key -and $Key -match $script:SecretKeyPattern -and -not ($Value -is [bool]) -and -not ($Value -is [System.Collections.IDictionary])) { & $lit '<hidden>'; return }
    if ($Value -is [switch]) { & $lit $(if ($Value.IsPresent) { '$true' } else { '$false' }); return }
    if ($Value -is [bool]) { & $lit $(if ($Value) { '$true' } else { '$false' }); return }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { & $lit ([string]::Format([cultureinfo]::InvariantCulture, '{0}', $Value)); return }
    if ($Value -is [datetime] -or $Value -is [datetimeoffset]) { & $lit "'$($Value.ToString('o'))'"; return }
    if ($Value -is [System.Collections.IDictionary]) {
        $keys = if ($Value -is [System.Collections.Specialized.OrderedDictionary]) { @($Value.Keys) } else { @($Value.Keys | Sort-Object) }
        & $lit '@{ '
        $first = $true
        foreach ($k in $keys) {
            if (-not $first) { & $lit '; ' }
            $first = $false
            $name = if ("$k" -match '^[A-Za-z_][A-Za-z0-9_]*$') { "$k" } else { "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent("$k") + "'" }
            & $lit "$name = "
            Add-M365LiteralToken -Tokens $Tokens -Value $Value[$k] -Key "$k"
        }
        & $lit ' }'
        return
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        & $lit '@('
        $first = $true
        foreach ($item in $Value) {
            if (-not $first) { & $lit ', ' }
            $first = $false
            Add-M365LiteralToken -Tokens $Tokens -Value $item -Key $Key
        }
        & $lit ')'
        return
    }
    & $lit ("'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent("$Value") + "'")
}

function Get-M365CommandRendering {
    # Internal. Returns @{ Text; Pattern; HasHole } for a command and its parameters.
    param([string]$Command, [System.Collections.IDictionary]$Parameters)
    $tokens = [System.Collections.Generic.List[object]]::new()
    $tokens.Add([pscustomobject]@{ Text = $Command; Hole = $false })
    $keys = if ($Parameters -is [System.Collections.Specialized.OrderedDictionary]) { @($Parameters.Keys) } else { @($Parameters.Keys | Sort-Object) }
    foreach ($k in $keys) {
        $v = $Parameters[$k]
        if ($v -is [switch]) {
            $tokens.Add([pscustomobject]@{ Text = $(if ($v.IsPresent) { " -$k" } else { " -${k}:`$false" }); Hole = $false })
            continue
        }
        if ($v -is [bool]) {
            $tokens.Add([pscustomobject]@{ Text = " -${k}:$(if ($v) { '$true' } else { '$false' })"; Hole = $false })
            continue
        }
        $tokens.Add([pscustomobject]@{ Text = " -$k "; Hole = $false })
        Add-M365LiteralToken -Tokens $tokens -Value $v -Key "$k"
    }
    [pscustomobject]@{
        Text    = -join ($tokens | ForEach-Object { $_.Text })
        Pattern = -join ($tokens | ForEach-Object { if ($_.Hole) { '.+?' } else { [regex]::Escape($_.Text) } })
        HasHole = [bool]($tokens | Where-Object { $_.Hole })
    }
}

function Format-M365Command {
    <#
    .SYNOPSIS
        Renders a command and its parameters as one line of PowerShell, secrets hidden. Pure.
    .DESCRIPTION
        Strings are single-quoted with every PowerShell quote character escaped (including the
        typographic ones Outlook and Word insert). Booleans render as -Name:$true, switches as
        -Name, hashtables as @{ key = value }, arrays as @(a, b), placeholders as <what>.
        Ordered dictionaries keep their order; plain hashtables are sorted by key.
    .PARAMETER Command
        Cmdlet or function name.
    .PARAMETER Parameters
        Parameter name -> value.
    .EXAMPLE
        Format-M365Command -Command New-MailContact -Parameters ([ordered]@{ Name = 'Vendor'; ExternalEmailAddress = 'v@vendor.example' })
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter()]
        [System.Collections.IDictionary]$Parameters = [ordered]@{}
    )
    (Get-M365CommandRendering -Command $Command -Parameters $Parameters).Text
}

function Set-M365ChangeTarget {
    <#
    .SYNOPSIS
        Records a sign-in target without a live check. For tests and offline harnesses only.
    .DESCRIPTION
        Assert-M365Graph and Assert-M365Exchange record live-verified targets. This records a
        'manual' one so module functions can be exercised against stubs; Invoke-M365Change
        skips the live session checks for manual targets.
    .PARAMETER Service
        Graph or Exchange.
    .PARAMETER Label
        What to show in plans, e.g. test.onmicrosoft.com.
    .PARAMETER TenantId
        Tenant GUID to record.
    .EXAMPLE
        Set-M365ChangeTarget -Service Exchange -Label test.onmicrosoft.com
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Sets an in-memory label for tests; changes no tenant.')]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Graph', 'Exchange')]
        [string]$Service,

        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter()]
        [string]$TenantId = '00000000-0000-0000-0000-000000000000'
    )
    (Get-M365SessionTarget)[$Service] = [pscustomobject]@{ Label = $Label; TenantId = $TenantId; ModuleName = $null; Verified = 'manual' }
}

function Start-M365ChangeRecording {
    <#
    .SYNOPSIS
        Starts collecting the changes Invoke-M365Change plans or runs; with -ApprovedPlan, also allows only those changes.
    .DESCRIPTION
        The GUI and console call this around a dry run (to collect the plan) and around the
        real run (passing the dry run's planned records as -ApprovedPlan). During an approved
        run, a change that does not match an unused planned entry is refused before it runs.
        Placeholders in the plan accept any real value. An empty approved plan allows nothing.
    .PARAMETER ApprovedPlan
        Records with Status 'Planned' from Stop-M365ChangeRecording after the dry run.
    .EXAMPLE
        Start-M365ChangeRecording; & $script -WhatIf; $plan = Stop-M365ChangeRecording
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'In-memory recorder; changes no tenant.')]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$ApprovedPlan
    )
    Set-Variable -Name M365ToolkitChangeLog -Scope Global -Value ([System.Collections.Generic.List[object]]::new())
    $approved = $null
    if ($PSBoundParameters.ContainsKey('ApprovedPlan')) {
        $approved = [System.Collections.Generic.List[object]]::new()
        foreach ($p in @($ApprovedPlan | Where-Object { $_ -and $_.Status -eq 'Planned' })) {
            $approved.Add([pscustomobject]@{ Text = $p.Text; Pattern = $p.Pattern; Used = $false })
        }
    }
    Set-Variable -Name M365ToolkitApprovedPlan -Scope Global -Value $approved
}

function Stop-M365ChangeRecording {
    <#
    .SYNOPSIS
        Stops collecting and returns the change records (Planned, Declined, Refused, Done, Failed), oldest first.
    .EXAMPLE
        $records = Stop-M365ChangeRecording
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'In-memory recorder; changes no tenant.')]
    param()
    $log = Get-Variable -Name M365ToolkitChangeLog -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    #   GOTCHA No if-expression here: it would unroll an empty array to $null.
    $records = @(if ($null -ne $log) { $log.ToArray() })
    Set-Variable -Name M365ToolkitChangeLog -Scope Global -Value $null
    Set-Variable -Name M365ToolkitApprovedPlan -Scope Global -Value $null
    return , $records
}

function Add-M365ChangeRecord {
    # Internal. Adds one record to the recorder when one is running.
    param($Record)
    $log = Get-Variable -Name M365ToolkitChangeLog -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $log) { $log.Add($Record) }
}

function Invoke-M365Change {
    <#
    .SYNOPSIS
        The one way the toolkit changes a tenant: shows the exact command, checks it is allowed and aimed at the verified tenant, runs exactly that.
    .DESCRIPTION
        Every module function that changes something calls this instead of calling the cmdlet
        directly. In order:
          1. Renders "[tenant] Action" and the exact command (secrets hidden). The tenant is
             the one Assert-M365Graph / Assert-M365Exchange verified live.
          2. Asks the caller's ShouldProcess with that text. Under -WhatIf the terminal prints
             it as "What if: ..." and the change is recorded as Planned; nothing runs.
          3. On a real run: refuses if a placeholder is left, if an approved plan is active and
             this change is not in it, if the session no longer points at the verified tenant,
             or if the command is not available.
          4. Runs the command with exactly the rendered parameters (plus -ErrorAction Stop and,
             where the command has it, -Confirm:$false: the confirmation already happened),
             prints "Run: ...", records Done or Failed and writes the audit log.
        Returns @{ Ran; Output; Text }. Ran is $false under -WhatIf or when declined.
    .PARAMETER Caller
        $PSCmdlet of the calling function, so its -WhatIf / -Confirm apply.
    .PARAMETER Service
        Exchange, Graph or Hudu.
    .PARAMETER Action
        Plain English, e.g. "Create mail contact 'Vendor' (v@vendor.example)".
    .PARAMETER Command
        The cmdlet or function to run.
    .PARAMETER Parameters
        Parameter name -> value; use [ordered] so the plan reads in a sensible order. Pass
        plain strings and ids, not objects, so the plan shows exactly what is sent.
    .PARAMETER Retry
        Retry when the service answers 429/503 (never on timeouts; see Invoke-M365WithRetry -Write).
    .EXAMPLE
        $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Create mail contact '$Name'" -Command New-MailContact -Parameters ([ordered]@{ Name = $Name; ExternalEmailAddress = $Address })
        if ($run.Ran) { $contact = $run.Output }
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Calls the CALLER''s ShouldProcess ($Caller), so the caller''s -WhatIf/-Confirm apply.')]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCmdlet]$Caller,

        [Parameter(Mandatory)]
        [ValidateSet('Exchange', 'Graph', 'Hudu')]
        [string]$Service,

        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter()]
        [System.Collections.IDictionary]$Parameters = [ordered]@{},

        [Parameter()]
        [switch]$Retry
    )

    # The release is read-only, including direct module calls and approved plans.
    # No CLI flag, environment variable, or confirmation can unlock tenant writes.
    Assert-M365WriteAllowed

    #region 1. Render ------------------------------------------------------------
    $target = (Get-M365SessionTarget)[$Service]
    $tenant = switch ($Service) {
        'Hudu' { try { 'Hudu ' + ([uri](Get-M365Settings).hudu.baseUrl).Host } catch { 'Hudu' } }
        default { if ($target) { $target.Label } else { "not signed in to $Service" } }
    }
    $render = Get-M365CommandRendering -Command $Command -Parameters $Parameters
    $headline = "[$tenant] $Action"
    $detail = "$headline`n    $($render.Text)"
    $record = [pscustomobject]@{
        Time    = (Get-Date).ToUniversalTime().ToString('o')
        Service = $Service
        Tenant  = $tenant
        Action  = $Action
        Command = $render.Text
        Text    = "[$tenant] $($render.Text)"
        Pattern = '^' + [regex]::Escape("[$tenant] ") + $render.Pattern + '$'
        Status  = $null
        Error   = $null
    }
    #endregion

    #region 2. Ask -------------------------------------------------------------------
    $reason = [System.Management.Automation.ShouldProcessReason]::None
    if (-not $Caller.ShouldProcess($detail, "$detail`nMake this change?", 'Confirm change', [ref]$reason)) {
        $record.Status = if ($reason -eq [System.Management.Automation.ShouldProcessReason]::WhatIf) { 'Planned' } else { 'Declined' }
        Add-M365ChangeRecord $record
        return [pscustomobject]@{ Ran = $false; Output = $null; Text = $detail }
    }
    #endregion

    #region 3. Refuse anything that is not exactly what was shown and reviewed -------------
    $refuse = {
        param([string]$Why)
        $record.Status = 'Refused'; $record.Error = $Why
        Add-M365ChangeRecord $record
        throw "$Why Nothing was run for: $headline"
    }
    if ($render.HasHole) { & $refuse "Internal error: the command still contains a placeholder ($($render.Text))." }
    $plan = Get-Variable -Name M365ToolkitApprovedPlan -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $plan) {
        $entry = $plan | Where-Object { -not $_.Used -and $record.Text -match $_.Pattern } | Select-Object -First 1
        if (-not $entry) { & $refuse "This change was not in the reviewed plan: $($record.Text). Do a new dry run and review it." }
        $entry.Used = $true
    }
    if ($Service -in 'Graph', 'Exchange' -and -not $target) { & $refuse "Not signed in to $Service (Assert-M365$Service was not called)." }
    #   GOTCHA Resolve and run the command inside the CALLER's module, exactly as if the
    #          module function had called it directly ($Caller.SessionState would be this
    #          module's, the one currently running).
    $callerModule = $Caller.MyInvocation.MyCommand.Module
    $inCaller = { param($Block) if ($callerModule) { $callerModule.NewBoundScriptBlock($Block) } else { $Block } }
    $resolve = { param($Name) Get-Command -Name $Name -CommandType Function, Cmdlet, Alias -ErrorAction SilentlyContinue | Select-Object -First 1 }
    $cmdInfo = & (& $inCaller $resolve) $Command
    if (-not $cmdInfo) { & $refuse "The command '$Command' is not available in this session." }
    if ($cmdInfo -is [System.Management.Automation.AliasInfo] -and $cmdInfo.ResolvedCommand) { $cmdInfo = $cmdInfo.ResolvedCommand }
    if ($target -and $target.Verified -eq 'live') {
        if ($Service -eq 'Exchange' -and $cmdInfo.ModuleName -ne $target.ModuleName) {
            & $refuse "'$Command' now comes from a different Exchange connection than the one verified for $($target.Label)."
        }
        if ($Service -eq 'Graph') {
            $ctx = Get-MgContext
            if (-not $ctx -or "$($ctx.TenantId)".ToLowerInvariant() -ne $target.TenantId) { & $refuse "The Graph session is no longer in $($target.Label)." }
        }
    }
    #endregion

    #region 4. Run exactly the rendered parameters ---------------------------------
    $splat = @{}
    foreach ($k in $Parameters.Keys) { $splat[$k] = $Parameters[$k] }
    if ($cmdInfo.Parameters -and $cmdInfo.Parameters.ContainsKey('ErrorAction')) { $splat['ErrorAction'] = 'Stop' }
    if ($cmdInfo.Parameters -and $cmdInfo.Parameters.ContainsKey('Confirm')) { $splat['Confirm'] = $false }
    Write-Information -MessageData "Run: $detail" -Tags 'M365Change' -InformationAction Continue
    $runner = & $inCaller { param($Name, $Splat) & $Name @Splat }
    try {
        $output = if ($Retry) {
            Invoke-M365WithRetry -Write -Operation $Action -ScriptBlock { & $runner $Command $splat }.GetNewClosure()
        } else { & $runner $Command $splat }
    } catch {
        $record.Status = 'Failed'; $record.Error = $_.Exception.Message
        Add-M365ChangeRecord $record
        Write-M365Log -Level Error -Operation $Command -TenantId $tenant -Message "FAILED $($record.Text)" -Data @{ error = $_.Exception.Message }
        throw
    }
    $record.Status = 'Done'
    Add-M365ChangeRecord $record
    Write-M365Log -Operation $Command -TenantId $tenant -Message "DONE $($record.Text)"
    #endregion

    return [pscustomobject]@{ Ran = $true; Output = $output; Text = $detail }
}
#endregion

function Get-M365ConfigPlaceholder {
    <#
    .SYNOPSIS
        Lists the keys in a JSON config file whose value is still a <placeholder>.
    .DESCRIPTION
        Walks the document and returns dotted key paths (msp.supportEmail, groups[0].id) whose
        string value matches <...>. Keys starting with an underscore (comments) are skipped.
        Install-Toolkit.ps1 uses this to ask only for what is missing.
    .PARAMETER Path
        JSON file.
    .EXAMPLE
        Get-M365ConfigPlaceholder -Path config/msp.settings.local.json
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $doc = Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    $found = [System.Collections.Generic.List[string]]::new()
    $walk = {
        param($node, [string]$prefix)
        if ($null -eq $node) { return }
        if ($node -is [string]) { if ($node -match '^<.*>$') { $found.Add($prefix) }; return }
        if ($node -is [System.Collections.IEnumerable] -and -not ($node -is [string])) {
            $i = 0
            foreach ($item in $node) { & $walk $item "$prefix[$i]"; $i++ }
            return
        }
        if ($node -is [pscustomobject]) {
            foreach ($prop in $node.PSObject.Properties) {
                if ($prop.Name.StartsWith('_')) { continue }
                & $walk $prop.Value $(if ($prefix) { "$prefix.$($prop.Name)" } else { $prop.Name })
            }
        }
    }
    & $walk $doc ''
    return @($found)
}

function Get-M365ConfigValue {
    <#
    .SYNOPSIS
        Reads one value from a JSON config file by dotted key path (msp.supportEmail, groups[0].id). $null when absent.
    .EXAMPLE
        Get-M365ConfigValue -Path config/msp.settings.example.json -Key msp.supportEmail
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Key
    )
    #   GOTCHA Never assign through an if-expression here: PowerShell unrolls a one-element
    #          array into its single object, and the next [0] then indexes a non-array.
    $node = Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    foreach ($m in [regex]::Matches($Key, '([^.\[\]]+)|\[(\d+)\]')) {
        if ($null -eq $node) { return $null }
        $next = $null
        if ($m.Groups[2].Success) {
            $i = [int]$m.Groups[2].Value
            if ($node -is [array] -and $i -lt $node.Count) { $next = $node[$i] }
        } else {
            $name = $m.Groups[1].Value
            if ($node.PSObject.Properties[$name]) { $next = $node.$name }
        }
        $node = $next
    }
    return $node
}

function Set-M365ConfigValue {
    <#
    .SYNOPSIS
        Sets one value in a JSON config file by dotted key path and writes the file back.
    .DESCRIPTION
        Key paths look like msp.supportEmail or groups[1].id. Only the one value changes;
        the rest of the document is rewritten by ConvertTo-Json, so comments (keys starting
        with an underscore) survive as data.
    .PARAMETER Path
        JSON file.
    .PARAMETER Key
        Dotted path with optional [index] segments.
    .PARAMETER Value
        New value (string).
    .EXAMPLE
        Set-M365ConfigValue -Path config/msp.settings.local.json -Key msp.supportEmail -Value support@msp.example
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )
    $doc = Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    $segments = [regex]::Matches($Key, '([^.\[\]]+)|\[(\d+)\]') | ForEach-Object { if ($_.Groups[2].Success) { [int]$_.Groups[2].Value } else { $_.Groups[1].Value } }
    $node = $doc
    for ($i = 0; $i -lt $segments.Count - 1; $i++) {
        $seg = $segments[$i]
        $next = $null
        if ($seg -is [int]) { if ($node -is [array] -and $seg -lt $node.Count) { $next = $node[$seg] } }
        elseif ($node.PSObject.Properties[$seg]) { $next = $node.$seg }
        $node = $next
        if ($null -eq $node) { throw "Key path '$Key' does not exist in $Path." }
    }
    $last = $segments[-1]
    if ($PSCmdlet.ShouldProcess($Path, "Set $Key")) {
        if ($last -is [int]) { $node[$last] = $Value } else { $node.$last = $Value }
        $doc | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding utf8
    }
}

function Export-M365Csv {
    <#
    .SYNOPSIS
        Writes report rows to CSV, resolving relative paths from the repo root and creating folders.
    .DESCRIPTION
        Shared by every report script so -CsvPath behaves the same everywhere. Array-valued
        properties are joined with semicolons so the CSV stays one row per object.
    .PARAMETER Rows
        Objects to write.
    .PARAMETER Path
        Target file. Relative paths resolve from the repo root (runs/ is the usual place).
    .EXAMPLE
        Export-M365Csv -Rows $rows -Path runs/contoso-licenses.csv
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [string]$Path
    )
    if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $PSScriptRoot '..' '..' '..' '..' $Path }
    $Path = [IO.Path]::GetFullPath($Path)
    $dir = Split-Path $Path -Parent
    if ($PSCmdlet.ShouldProcess($Path, "Write $($Rows.Count) row(s)")) {
        if ($dir -and -not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $flat = foreach ($row in $Rows) {
            $o = [ordered]@{}
            foreach ($prop in $row.PSObject.Properties) { $o[$prop.Name] = if ($prop.Value -is [array]) { $prop.Value -join ';' } else { $prop.Value } }
            [pscustomobject]$o
        }
        @($flat) | Export-Csv -Path $Path -NoTypeInformation -Encoding utf8
    }
    return $Path
}

function Write-M365Step {
    <#
    .SYNOPSIS
        Prints one onboarding checklist line with a status tag.
    .DESCRIPTION
        The orchestrator and the console both print the same shape of line so a run reads
        like the Autotask checklist it mirrors:

            [DONE]   5.3  Create break-glass account
            [MANUAL] 5.2  Get admin rights release form signed
    .PARAMETER Id
        Checklist step id, e.g. '5.3'.
    .PARAMETER Name
        Step name as written in the SOP.
    .PARAMETER Status
        Done, Skipped, Manual, WhatIf, Failed, Info.
    .PARAMETER Detail
        Optional second line with the result or the reason.
    .EXAMPLE
        Write-M365Step -Id 5.3 -Name 'Create break-glass account' -Status Done -Detail 'breakglass@contoso.onmicrosoft.com'
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Checklist output is for the operator. Data is returned separately by the caller.')]
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('Done', 'Skipped', 'Manual', 'WhatIf', 'Failed', 'Info')]
        [string]$Status,

        [Parameter()]
        [string]$Detail
    )

    $color = switch ($Status) {
        'Done' { 'Green' }
        'Skipped' { 'DarkGray' }
        'Manual' { 'Yellow' }
        'WhatIf' { 'Cyan' }
        'Failed' { 'Red' }
        default { 'Gray' }
    }
    $tag = "[{0}]" -f $Status.ToUpperInvariant()
    Write-Host ("{0,-9} {1,-5} {2}" -f $tag, $Id, $Name) -ForegroundColor $color
    if ($Detail) { Write-Host ("{0,-16}{1}" -f '', $Detail) -ForegroundColor DarkGray }
}

Export-ModuleMember -Function Test-M365ReadOnly, Get-M365Settings, Get-M365ClientConfig, Resolve-M365TenantId, Assert-M365SameTenant, Assert-M365Graph, Assert-M365Exchange,
    Get-M365ExchangeTenant, Disconnect-M365Tenant, Resolve-DnsRecord, New-StrongPassword, Add-HuduPassword, Write-M365Step,
    Invoke-M365WithRetry, New-M365CorrelationId, Write-M365Log, Get-M365ConfigPlaceholder, Get-M365ConfigValue, Set-M365ConfigValue, Export-M365Csv,
    Test-M365PasswordComplexity, Read-M365Password,
    New-M365Placeholder, Format-M365Command, Set-M365ChangeTarget, Start-M365ChangeRecording, Stop-M365ChangeRecording, Invoke-M365Change
