#region Module setup ----------------------------------------------------------
#   WHAT   Read-only Azure and AVD inspection: sign-in, context checks, one
#          allowlisted command gateway, and flat report rows.
#   WHY    The legacy modules mix reads with deployment and administration, and
#          they stay blocked. This is a separate, small surface that can be
#          reviewed on its own: nothing here starts, stops, changes or deletes.
#   GOTCHA Never import a legacy module from here and never call an Az cmdlet
#          directly. Every Azure call names an allowlisted command as a literal
#          string and goes through Invoke-AzReadCommand. The tests parse this file
#          to enforce that.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'   # module functions do not inherit the caller's value
$script:Session = $null
$script:ProviderState = @{}   # registration state per namespace, cleared at the start of every report
$script:GuidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
$script:RequiredModules = @('Az.Accounts', 'Az.Resources', 'Az.Compute', 'Az.Network', 'Az.DesktopVirtualization')
#endregion

#region 1. Command allowlist ---------------------------------------------------
#   WHAT   The exact Az commands this module may run, the module that must supply
#          each one, the parameters it may receive, and values the gateway pins.
#   WHY    "Get-" in a name is not enough. Get-AzStorageAccountKey and
#          Get-AzKeyVaultSecret return secrets, Get-AzVM -UserData returns data
#          that often holds them, and host pools carry a registration token. An
#          explicit list keeps every reachable call reviewable.
#   GOTCHA The session commands change only this PowerShell process's sign-in
#          state. Scope is pinned to Process so nothing is saved for later sessions.
#          Invoke-AzRestMethod is pinned to GET on a few exact paths: the caller's
#          own permissions and three providers' registration state.
#          Provider: Az.Accounts registers a resource provider and retries when ARM
#          answers "not registered to use namespace", and a Get is enough to
#          trigger it under an Owner or Contributor account. That is an Azure
#          write, so the gateway reads the namespace's registration state first
#          and refuses the call unless it is Registered. The other commands reach
#          providers that are always registered or tenant-level endpoints.
$script:ShouldProcessOff = @{ WhatIf = $false; Confirm = $false }
$script:Commands = @{
    'Get-AzContext'              = @{ Module = 'Az.Accounts'; Parameters = @() }
    'Disable-AzContextAutosave'  = @{ Module = 'Az.Accounts'; Parameters = @(); Pinned = @{ Scope = 'Process' } + $script:ShouldProcessOff }
    'Connect-AzAccount'          = @{ Module = 'Az.Accounts'; Parameters = @('Tenant', 'Subscription', 'UseDeviceAuthentication'); Pinned = @{ Scope = 'Process' } + $script:ShouldProcessOff }
    'Set-AzContext'              = @{ Module = 'Az.Accounts'; Parameters = @('Tenant', 'Subscription'); Pinned = @{ Scope = 'Process' } + $script:ShouldProcessOff }
    'Get-AzSubscription'         = @{ Module = 'Az.Accounts'; Parameters = @('TenantId') }
    'Invoke-AzRestMethod'        = @{ Module = 'Az.Accounts'; Parameters = @('Path'); Pinned = @{ Method = 'GET' } + $script:ShouldProcessOff
                                     Paths = @(
                                         '/subscriptions/{subscription}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01'
                                         '/subscriptions/{subscription}/providers/Microsoft.Compute?api-version=2021-04-01'
                                         '/subscriptions/{subscription}/providers/Microsoft.Network?api-version=2021-04-01'
                                         '/subscriptions/{subscription}/providers/Microsoft.DesktopVirtualization?api-version=2021-04-01'
                                     ) }
    'Get-AzResourceGroup'        = @{ Module = 'Az.Resources'; Parameters = @() }
    'Get-AzVM'                   = @{ Module = 'Az.Compute'; Parameters = @('ResourceGroupName', 'Status'); Provider = 'Microsoft.Compute' }
    'Get-AzVirtualNetwork'       = @{ Module = 'Az.Network'; Parameters = @(); Provider = 'Microsoft.Network' }
    'Get-AzNetworkSecurityGroup' = @{ Module = 'Az.Network'; Parameters = @(); Provider = 'Microsoft.Network' }
    'Get-AzWvdHostPool'          = @{ Module = 'Az.DesktopVirtualization'; Parameters = @('SubscriptionId'); Provider = 'Microsoft.DesktopVirtualization' }
    'Get-AzWvdSessionHost'       = @{ Module = 'Az.DesktopVirtualization'; Parameters = @('SubscriptionId', 'ResourceGroupName', 'HostPoolName'); Provider = 'Microsoft.DesktopVirtualization' }
    'Get-AzWvdUserSession'       = @{ Module = 'Az.DesktopVirtualization'; Parameters = @('SubscriptionId', 'ResourceGroupName', 'HostPoolName'); Provider = 'Microsoft.DesktopVirtualization' }
    'Get-AzWvdApplicationGroup'  = @{ Module = 'Az.DesktopVirtualization'; Parameters = @('SubscriptionId'); Provider = 'Microsoft.DesktopVirtualization' }
    'Get-AzWvdWorkspace'         = @{ Module = 'Az.DesktopVirtualization'; Parameters = @('SubscriptionId'); Provider = 'Microsoft.DesktopVirtualization' }
    'Get-AzWvdScalingPlan'       = @{ Module = 'Az.DesktopVirtualization'; Parameters = @('SubscriptionId'); Provider = 'Microsoft.DesktopVirtualization' }
}

function Get-AzReadCommandPolicy {
    <#
    .SYNOPSIS
        A copy of the allowlist, for display and tests. Changing the copy changes nothing.
    #>
    [CmdletBinding()]
    param()
    foreach ($name in $script:Commands.Keys | Sort-Object) {
        $spec = $script:Commands[$name]
        [pscustomobject]@{
            Name       = $name
            Module     = $spec.Module
            Parameters = @($spec.Parameters)
            Pinned     = $(if ($spec.ContainsKey('Pinned')) { @{} + $spec.Pinned } else { @{} })
            Paths      = $(if ($spec.ContainsKey('Paths')) { @($spec.Paths) } else { @() })
            Provider   = $(if ($spec.ContainsKey('Provider')) { $spec.Provider } else { $null })
        }
    }
}
#endregion

#region 2. The gateway ---------------------------------------------------------
#   WHAT   Runs one allowlisted command from its expected module with checked
#          parameters. Everything else is refused before any command is resolved.
#   WHY    One choke point is easy to review and to test. Pinned values are added
#          here, so a caller cannot widen Scope or Method.
#   GOTCHA The refusals set their own error preference first, and every refusal is
#          followed by return. -ErrorAction or a caller's preference must not turn
#          a refusal into a warning that lets the next line run. Names compare
#          ordinally and exactly: PowerShell would otherwise accept an abbreviation
#          or alias for a listed parameter, and culture-aware comparison ignores
#          some invisible characters. Built-ins are module-qualified so a
#          same-named function in the session cannot stand in for them.
function Invoke-AzReadCommand {
    <#
    .SYNOPSIS
        Runs one allowlisted Az read command. Everything else is refused.
    .PARAMETER Name
        Exact command name from the allowlist.
    .PARAMETER Parameters
        Parameter names and values. Only the command's listed names are accepted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string]$Name,
        [Parameter(Position = 1)] [hashtable]$Parameters = @{}
    )
    $ErrorActionPreference = 'Stop'
    $listed = @($script:Commands.Keys | Microsoft.PowerShell.Core\Where-Object { [string]::Equals($_, $Name, [StringComparison]::OrdinalIgnoreCase) })
    if ($listed.Count -ne 1) {
        throw "Azure read-only mode refuses '$Name': it is not an allowlisted read command."; return
    }
    $canonical = $listed[0]
    $spec = $script:Commands[$canonical]
    foreach ($key in @($Parameters.Keys)) {
        if (@($spec.Parameters | Microsoft.PowerShell.Core\Where-Object { [string]::Equals($_, "$key", [StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) {
            throw "Azure read-only mode refuses parameter -$key for $canonical."; return
        }
    }
    if ($spec.ContainsKey('Paths')) {
        $subscription = if ($script:Session) { "$($script:Session.SubscriptionId)" } else { '' }
        $path = "$($Parameters['Path'])"
        $allowed = @(if ($subscription) { $spec.Paths | Microsoft.PowerShell.Core\Where-Object { [string]::Equals($_.Replace('{subscription}', $subscription), $path, [StringComparison]::Ordinal) } })
        if ($allowed.Count -ne 1) {
            throw "Azure read-only mode refuses this $canonical request: only the selected subscription's permission and provider checks are allowed."; return
        }
    }
    if ($spec.ContainsKey('Provider') -and -not (Test-AzReadOnlyProviderRegistered -Namespace $spec.Provider)) {
        throw "$($spec.Provider) is not registered in this subscription, so it has nothing to read. Cloudwright does not register it."; return
    }
    $command = @(Microsoft.PowerShell.Core\Get-Command -Name $canonical -Module $spec.Module -CommandType Cmdlet, Function -ErrorAction SilentlyContinue) |
        Microsoft.PowerShell.Utility\Select-Object -First 1
    if (-not $command) {
        if (Microsoft.PowerShell.Core\Get-Module -ListAvailable -Name $spec.Module) {
            throw "$($spec.Module) is installed but $canonical could not be loaded. Run Import-Module $($spec.Module) in a new PowerShell window to see why."; return
        }
        throw "$($spec.Module) is not installed. Run: Install-Module $($spec.Module) -Scope CurrentUser"; return
    }
    if (-not [string]::Equals($command.Name, $canonical, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($command.ModuleName, $spec.Module, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Azure read-only mode refuses '$canonical': it resolved to $($command.ModuleName)\$($command.Name)."; return
    }
    $arguments = @{} + $Parameters
    if ($spec.ContainsKey('Pinned')) { foreach ($key in $spec.Pinned.Keys) { $arguments[$key] = $spec.Pinned[$key] } }
    $arguments.ErrorAction = 'Stop'
    & $command @arguments
}

function Test-AzReadOnlyProviderRegistered {
    # One GET per namespace per report: Assert-AzReadOnlyContext clears the cache.
    # Anything but Registered (NotRegistered, Registering, an error) means no read.
    param([string]$Namespace)
    $ErrorActionPreference = 'Stop'
    if (-not $script:ProviderState.ContainsKey($Namespace)) {
        if (-not $script:Session -or -not $script:Session.SubscriptionId) { return $false }
        $response = Invoke-AzReadCommand 'Invoke-AzRestMethod' @{ Path = "/subscriptions/$($script:Session.SubscriptionId)/providers/${Namespace}?api-version=2021-04-01" }
        $status = [int](Get-AzReadOnlyValue $response 'StatusCode' 0)
        if ($status -ne 200) { throw "Could not check whether $Namespace is registered (HTTP $status), so it was not read."; return }
        $script:ProviderState[$Namespace] = "$(Get-AzReadOnlyValue (Get-AzReadOnlyValue $response 'Content' '{}' | Microsoft.PowerShell.Utility\ConvertFrom-Json) 'registrationState')"
    }
    return [string]::Equals($script:ProviderState[$Namespace], 'Registered', [StringComparison]::Ordinal)
}
#endregion

#region 3. Helpers -------------------------------------------------------------
#   WHAT   Safe property reads and ARM resource ID parsing.
#   WHY    Older Az versions name some properties differently, and StrictMode
#          throws on a missing one. Reports pick the fields they show; raw objects
#          never leave this module, so secrets such as a host pool's registration
#          token cannot reach the screen.
function Get-AzReadOnlyValue {
    param($Object, [string[]]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    foreach ($n in $Name) {
        $p = $Object.PSObject.Properties[$n]
        if ($p -and $null -ne $p.Value) { return $p.Value }
    }
    return $Default
}

function Split-AzReadOnlyResourceId {
    # /subscriptions/<sub>/resourceGroups/<rg>/providers/<namespace>/<type>/<name>
    param([string]$ResourceId)
    $parts = "$ResourceId" -split '/'
    if ($parts.Count -ge 9 -and $parts[1] -eq 'subscriptions' -and $parts[3] -eq 'resourceGroups' -and $parts[5] -eq 'providers') {
        return [pscustomobject]@{ SubscriptionId = $parts[2]; ResourceGroupName = $parts[4]; Type = "$($parts[6])/$($parts[7])"; Name = $parts[8] }
    }
    return [pscustomobject]@{ SubscriptionId = $null; ResourceGroupName = $null; Type = $null; Name = $null }
}

function Test-AzReadOnlySame {
    # Ordinal and case-insensitive, for GUIDs, names and account IDs. Never culture-aware.
    param([string]$Left, [string]$Right)
    return [string]::Equals($Left, $Right, [StringComparison]::OrdinalIgnoreCase)
}

function Get-AzReadOnlyMissingModule {
    <#
    .SYNOPSIS
        The Az modules this area needs that are not installed. Checks only; installs nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    foreach ($m in $script:RequiredModules) {
        if (-not (Get-Module -ListAvailable -Name $m)) { $m }
    }
}
#endregion

#region 4. Sign-in and context -------------------------------------------------
#   WHAT   Sign in to one tenant for this process only, verify where that landed,
#          and re-verify it before every report.
#   WHY    Reading the wrong subscription is the read-only version of the classic
#          Azure mistake. Process scope keeps Az's context and token cache out of
#          the saved profile, so a later PowerShell session cannot reuse them by
#          accident. On Windows the sign-in broker (WAM) still remembers the account.
#   GOTCHA Az.Accounts loads saved contexts when it is imported. A fresh sign-in
#          replaces the default context, and the checks below compare the context
#          that Connect-AzAccount returned with the one Azure commands will use.
function Connect-AzReadOnly {
    <#
    .SYNOPSIS
        Signs in to one tenant for this PowerShell process only and verifies the result.
    .PARAMETER TenantId
        Directory (tenant) ID. A GUID, so the result can be compared exactly.
    .PARAMETER SubscriptionId
        Subscription to open. Omit to accept the sign-in's default and choose later.
    .PARAMETER UseDeviceAuthentication
        Sign in with a device code instead of a browser window.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')] [string]$TenantId,
        [Parameter()] [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')] [string]$SubscriptionId,
        [Parameter()] [switch]$UseDeviceAuthentication
    )
    $ErrorActionPreference = 'Stop'
    $script:Session = $null
    $script:ProviderState = @{}

    #region 4a. Keep the sign-in in memory -----------------------------------
    $autosave = Invoke-AzReadCommand 'Disable-AzContextAutosave'
    if ("$(Get-AzReadOnlyValue $autosave 'Mode')" -ne 'Process') {
        throw 'Azure read-only mode could not keep the sign-in in this process only. Nothing was signed in.'
    }
    #endregion

    #region 4b. Sign in and compare ------------------------------------------
    $connect = @{ Tenant = $TenantId }
    if ($SubscriptionId) { $connect.Subscription = $SubscriptionId }
    if ($UseDeviceAuthentication) { $connect.UseDeviceAuthentication = $true }
    $result = Invoke-AzReadCommand 'Connect-AzAccount' $connect
    $signedIn = Get-AzReadOnlyValue $result 'Context'
    $context = Invoke-AzReadCommand 'Get-AzContext'
    $account = Get-AzReadOnlyValue $signedIn 'Account'
    $accountId = "$(Get-AzReadOnlyValue $account 'Id')"
    if (-not $signedIn -or -not $context -or -not $accountId -or
        -not (Test-AzReadOnlySame "$(Get-AzReadOnlyValue (Get-AzReadOnlyValue $context 'Tenant') 'Id')" $TenantId) -or
        -not (Test-AzReadOnlySame "$(Get-AzReadOnlyValue (Get-AzReadOnlyValue $signedIn 'Tenant') 'Id')" $TenantId) -or
        -not (Test-AzReadOnlySame "$(Get-AzReadOnlyValue (Get-AzReadOnlyValue $context 'Account') 'Id')" $accountId)) {
        throw "Azure read-only mode refuses this sign-in: the active context is not the account that just signed in to tenant $TenantId."
    }
    if ("$(Get-AzReadOnlyValue $account 'Type')" -ne 'User') {
        throw 'Azure read-only mode supports interactive user sign-in only.'
    }
    $script:Session = [pscustomobject]@{
        TenantId = $TenantId; AccountId = $accountId; SubscriptionId = $null; SubscriptionName = $null; SubscriptionHomeTenantId = $null
    }
    #endregion

    #region 4c. Adopt the subscription ---------------------------------------
    #   WHY    A requested subscription must be exactly what Azure selected. Without
    #          one, the sign-in's default is kept only if it is listed under this
    #          tenant. A Lighthouse-delegated subscription is; its home tenant differs.
    #   GOTCHA PowerShell variable names ignore case: a local named like a
    #          parameter replaces it. The tests reject that pattern.
    $subscription = Get-AzReadOnlyValue $context 'Subscription'
    $selected = "$(Get-AzReadOnlyValue $subscription 'Id')"
    $accessTenant = "$(Get-AzReadOnlyValue $subscription 'TenantId' $TenantId)"
    if ($SubscriptionId -and -not (Test-AzReadOnlySame $selected $SubscriptionId)) {
        $script:Session = $null
        throw "Azure read-only mode refuses this sign-in: Azure selected subscription '$selected', not $SubscriptionId."
    }
    if ($selected -match $script:GuidPattern -and (Test-AzReadOnlySame $accessTenant $TenantId)) {
        $script:Session.SubscriptionId = $selected
        $script:Session.SubscriptionName = "$(Get-AzReadOnlyValue $subscription 'Name')"
        $script:Session.SubscriptionHomeTenantId = "$(Get-AzReadOnlyValue $subscription 'HomeTenantId' $TenantId)"
    }
    #endregion
    return Get-AzReadOnlySession
}

function Get-AzReadOnlySession {
    <#
    .SYNOPSIS
        The verified tenant, account and subscription, or nothing before sign-in.
    #>
    [CmdletBinding()]
    param()
    if (-not $script:Session) { return }
    [pscustomobject]@{
        TenantId = $script:Session.TenantId; AccountId = $script:Session.AccountId
        SubscriptionId = $script:Session.SubscriptionId; SubscriptionName = $script:Session.SubscriptionName
        SubscriptionHomeTenantId = $script:Session.SubscriptionHomeTenantId
    }
}

function Assert-AzReadOnlyContext {
    <#
    .SYNOPSIS
        Refuses unless Azure's active context is still the verified tenant, account and subscription.
    #>
    [CmdletBinding()]
    param([Parameter()] [switch]$TenantOnly)
    $ErrorActionPreference = 'Stop'
    $script:ProviderState = @{}
    if (-not $script:Session) { throw 'Azure read-only mode: sign in first.' }
    if (-not $TenantOnly -and -not $script:Session.SubscriptionId) { throw 'Azure read-only mode: choose a subscription first.' }
    $context = Invoke-AzReadCommand 'Get-AzContext'
    $same = $context -and
        (Test-AzReadOnlySame "$(Get-AzReadOnlyValue (Get-AzReadOnlyValue $context 'Tenant') 'Id')" $script:Session.TenantId) -and
        (Test-AzReadOnlySame "$(Get-AzReadOnlyValue (Get-AzReadOnlyValue $context 'Account') 'Id')" $script:Session.AccountId)
    if ($same -and -not $TenantOnly) {
        $same = Test-AzReadOnlySame "$(Get-AzReadOnlyValue (Get-AzReadOnlyValue $context 'Subscription') 'Id')" $script:Session.SubscriptionId
    }
    if (-not $same) {
        throw 'Azure read-only mode refuses to continue: the Azure context changed after sign-in. Restart cloudwright azure.'
    }
}

function Get-AzReadOnlySubscription {
    <#
    .SYNOPSIS
        Subscriptions the signed-in account can read in the verified tenant.
    #>
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Stop'
    Assert-AzReadOnlyContext -TenantOnly
    $tenant = $script:Session.TenantId
    foreach ($s in @(Invoke-AzReadCommand 'Get-AzSubscription' @{ TenantId = $tenant }) | Sort-Object Name) {
        # Lighthouse-delegated subscriptions are listed under the signed-in tenant;
        # HomeTenantId shows which directory actually owns them.
        if (-not (Test-AzReadOnlySame "$(Get-AzReadOnlyValue $s 'TenantId' $tenant)" $tenant)) { continue }
        $id = "$(Get-AzReadOnlyValue $s 'Id', 'SubscriptionId')"
        [pscustomobject]@{
            Name         = "$(Get-AzReadOnlyValue $s 'Name')"
            Id           = $id
            State        = "$(Get-AzReadOnlyValue $s 'State')"
            HomeTenantId = "$(Get-AzReadOnlyValue $s 'HomeTenantId' $tenant)"
            Selected     = Test-AzReadOnlySame $id $script:Session.SubscriptionId
        }
    }
}

function Select-AzReadOnlySubscription {
    <#
    .SYNOPSIS
        Points this process at another subscription in the verified tenant, then verifies it.
    .DESCRIPTION
        Changes only which subscription this PowerShell process reads. Nothing in
        Azure changes, and nothing is saved for later sessions.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')] [string]$SubscriptionId)
    $ErrorActionPreference = 'Stop'
    $available = @(Get-AzReadOnlySubscription | Where-Object { Test-AzReadOnlySame $_.Id $SubscriptionId })
    if ($available.Count -ne 1) { throw "Subscription $SubscriptionId is not readable by this account in tenant $($script:Session.TenantId)." }
    $previous = [pscustomobject]@{ Id = $script:Session.SubscriptionId; Name = $script:Session.SubscriptionName; Home = $script:Session.SubscriptionHomeTenantId }
    $null = Invoke-AzReadCommand 'Set-AzContext' @{ Tenant = $script:Session.TenantId; Subscription = $available[0].Id }
    $script:Session.SubscriptionId = $available[0].Id
    $script:Session.SubscriptionName = $available[0].Name
    $script:Session.SubscriptionHomeTenantId = $available[0].HomeTenantId
    try { Assert-AzReadOnlyContext } catch {
        $script:Session.SubscriptionId = $previous.Id
        $script:Session.SubscriptionName = $previous.Name
        $script:Session.SubscriptionHomeTenantId = $previous.Home
        throw
    }
    return Get-AzReadOnlySession
}

function Get-AzReadOnlyAccess {
    <#
    .SYNOPSIS
        Whether the signed-in account has any permission beyond reading at subscription scope.
    .DESCRIPTION
        Reads the account's own effective permissions at subscription scope (the
        portal's "Check access"). Any action that does not end in /read, and any
        data action that does not, counts as a change permission unless the same
        permission set's exclusions cover it. Cloudwright still only reads; this
        tells you how much more the account could do. Resource-group, resource and
        deny assignments are not included.
    .OUTPUTS
        Checked (the response was understood), Complete (every page was read),
        CanChange ($true, $false, or $null when an unread page could hold more),
        Examples (permission patterns that can change something), Note.
    #>
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Stop'
    Assert-AzReadOnlyContext
    $path = "/subscriptions/$($script:Session.SubscriptionId)/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
    $scope = 'Subscription scope only: resource-group, resource and deny assignments are not included.'
    $response = Invoke-AzReadCommand 'Invoke-AzRestMethod' @{ Path = $path }
    $status = [int](Get-AzReadOnlyValue $response 'StatusCode' 0)
    $body = $null
    if ($status -eq 200) {
        try { $body = Get-AzReadOnlyValue $response 'Content' '' | ConvertFrom-Json } catch { $body = $null }
    }
    if (-not $body -or -not $body.PSObject.Properties['value']) {
        $note = if ($status -ne 200) { "The permission check returned HTTP $status." } else { 'The permission check returned an unexpected response.' }
        return [pscustomobject]@{ Checked = $false; Complete = $false; CanChange = $null; Examples = @(); Note = $note }
    }
    $changes = @(@(foreach ($p in @($body.value)) {
        foreach ($pattern in @(Get-AzReadOnlyValue $p 'actions' @())) {
            if (Test-AzReadOnlyChangePattern -Pattern $pattern -Excluded @(Get-AzReadOnlyValue $p 'notActions' @())) { "$pattern" }
        }
        foreach ($pattern in @(Get-AzReadOnlyValue $p 'dataActions' @())) {
            if (Test-AzReadOnlyChangePattern -Pattern $pattern -Excluded @(Get-AzReadOnlyValue $p 'notDataActions' @())) { "data: $pattern" }
        }
    }) | Sort-Object -Unique)
    $complete = -not (Get-AzReadOnlyValue $body 'nextLink')
    [pscustomobject]@{
        Checked   = $true
        Complete  = $complete
        CanChange = $(if ($changes.Count) { $true } elseif ($complete) { $false } else { $null })
        Examples  = @($changes)
        Note      = $(if ($complete) { $scope } else { "More permissions were listed than one page; they were not read. $scope" })
    }
}

function Test-AzReadOnlyChangePattern {
    # A pattern that only reads ends in /read. Anything else ('*', 'Microsoft.Storage/*',
    # '.../action') can change something, unless one of the same permission set's
    # exclusions covers the whole pattern. Azure's wildcards mean what -like means.
    param([string]$Pattern, [string[]]$Excluded)
    if ($Pattern -like '*/read') { return $false }
    return @($Excluded | Where-Object { $Pattern -like $_ }).Count -eq 0
}
#endregion

#region 5. Resources -----------------------------------------------------------
#   WHAT   Resource groups and virtual machines with their power state.
function Get-AzReadOnlyResourceGroup {
    <#
    .SYNOPSIS
        Resource groups in the selected subscription.
    #>
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Stop'
    Assert-AzReadOnlyContext
    foreach ($g in @(Invoke-AzReadCommand 'Get-AzResourceGroup') | Sort-Object ResourceGroupName) {
        [pscustomobject]@{
            Name              = "$(Get-AzReadOnlyValue $g 'ResourceGroupName')"
            Location          = "$(Get-AzReadOnlyValue $g 'Location')"
            ProvisioningState = "$(Get-AzReadOnlyValue $g 'ProvisioningState')"
        }
    }
}

function Get-AzReadOnlyVm {
    <#
    .SYNOPSIS
        Virtual machines with power state, size and OS, for the subscription or one resource group.
    #>
    [CmdletBinding()]
    param([Parameter()] [string]$ResourceGroupName)
    $ErrorActionPreference = 'Stop'
    Assert-AzReadOnlyContext
    $query = @{ Status = $true }
    if ($ResourceGroupName) { $query.ResourceGroupName = $ResourceGroupName }
    @(Invoke-AzReadCommand 'Get-AzVM' $query) | ForEach-Object { ConvertTo-AzReadOnlyVmRow $_ } | Sort-Object ResourceGroupName, Name
}

function ConvertTo-AzReadOnlyVmRow {
    param($Vm)
    $power = "$(Get-AzReadOnlyValue $Vm 'PowerState')" -replace '^VM ', ''
    [pscustomobject]@{
        Name              = "$(Get-AzReadOnlyValue $Vm 'Name')"
        ResourceGroupName = "$(Get-AzReadOnlyValue $Vm 'ResourceGroupName')"
        Location          = "$(Get-AzReadOnlyValue $Vm 'Location')"
        PowerState        = $(if ($power) { $power } else { 'unknown' })
        Size              = "$(Get-AzReadOnlyValue (Get-AzReadOnlyValue $Vm 'HardwareProfile') 'VmSize')"
        OsType            = "$(Get-AzReadOnlyValue (Get-AzReadOnlyValue (Get-AzReadOnlyValue $Vm 'StorageProfile') 'OsDisk') 'OsType')"
    }
}
#endregion

#region 6. Azure Virtual Desktop -----------------------------------------------
#   WHAT   Host pools with their app groups, workspaces and scaling plans; one
#          pool's session hosts with VM power and health checks; user sessions;
#          and a health report across every pool.
#   WHY    These answer "what is deployed, is it healthy, who is on it" without
#          opening five portal blades.
#   GOTCHA "Drain mode" in the portal is AllowNewSession = $false in the API. AVD
#          calls pass the verified subscription explicitly, as a second check.
function Get-AzReadOnlyAvdInventory {
    # One call per AVD resource type for the whole subscription.
    $sub = $script:Session.SubscriptionId
    [pscustomobject]@{
        HostPools    = @(Invoke-AzReadCommand 'Get-AzWvdHostPool' @{ SubscriptionId = $sub })
        AppGroups    = @(Invoke-AzReadCommand 'Get-AzWvdApplicationGroup' @{ SubscriptionId = $sub })
        Workspaces   = @(Invoke-AzReadCommand 'Get-AzWvdWorkspace' @{ SubscriptionId = $sub })
        ScalingPlans = @(Invoke-AzReadCommand 'Get-AzWvdScalingPlan' @{ SubscriptionId = $sub })
    }
}

function Get-AzReadOnlyPoolLink {
    # App groups, their workspaces, and scaling plans that point at one host pool.
    param($Pool, $Inventory)
    $poolId = "$(Get-AzReadOnlyValue $Pool 'Id')"
    $groups = @($Inventory.AppGroups | Where-Object { "$(Get-AzReadOnlyValue $_ 'HostPoolArmPath')" -eq $poolId })
    $groupRows = foreach ($g in $groups) {
        $groupId = "$(Get-AzReadOnlyValue $g 'Id')"
        $spaces = @($Inventory.Workspaces | Where-Object { @(Get-AzReadOnlyValue $_ 'ApplicationGroupReference' @()) -contains $groupId })
        [pscustomobject]@{
            Name       = "$(Get-AzReadOnlyValue $g 'Name')"
            Type       = "$(Get-AzReadOnlyValue $g 'ApplicationGroupType')"
            Workspaces = @($spaces | ForEach-Object { "$(Get-AzReadOnlyValue $_ 'Name')" })
        }
    }
    $plans = foreach ($plan in $Inventory.ScalingPlans) {
        $ref = @(Get-AzReadOnlyValue $plan 'HostPoolReference' @() | Where-Object { "$(Get-AzReadOnlyValue $_ 'HostPoolArmPath')" -eq $poolId })
        if ($ref.Count -eq 0) { continue }
        $schedules = @(Get-AzReadOnlyValue $plan 'Schedule' @() | ForEach-Object {
            '{0} ({1}): up {2:d2}:{3:d2}, peak {4:d2}:{5:d2}, down {6:d2}:{7:d2}, off {8:d2}:{9:d2}' -f "$(Get-AzReadOnlyValue $_ 'Name')",
                (@(Get-AzReadOnlyValue $_ 'DaysOfWeek' @() | ForEach-Object { "$_".Substring(0, [math]::Min(3, "$_".Length)) }) -join ' '),
                [int](Get-AzReadOnlyValue $_ 'RampUpStartTimeHour' 0), [int](Get-AzReadOnlyValue $_ 'RampUpStartTimeMinute' 0),
                [int](Get-AzReadOnlyValue $_ 'PeakStartTimeHour' 0), [int](Get-AzReadOnlyValue $_ 'PeakStartTimeMinute' 0),
                [int](Get-AzReadOnlyValue $_ 'RampDownStartTimeHour' 0), [int](Get-AzReadOnlyValue $_ 'RampDownStartTimeMinute' 0),
                [int](Get-AzReadOnlyValue $_ 'OffPeakStartTimeHour' 0), [int](Get-AzReadOnlyValue $_ 'OffPeakStartTimeMinute' 0)
        })
        [pscustomobject]@{
            Name      = "$(Get-AzReadOnlyValue $plan 'Name')"
            Enabled   = [bool](Get-AzReadOnlyValue $ref[0] 'ScalingPlanEnabled' $false)
            TimeZone  = "$(Get-AzReadOnlyValue $plan 'TimeZone')"
            Schedules = $schedules -join '; '
        }
    }
    [pscustomobject]@{ AppGroups = @($groupRows); ScalingPlans = @($plans) }
}

function Get-AzReadOnlyAvdEnvironment {
    <#
    .SYNOPSIS
        One row per host pool: settings, app groups, the workspaces that publish them, and scaling plans.
    #>
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Stop'
    Assert-AzReadOnlyContext
    $inventory = Get-AzReadOnlyAvdInventory
    foreach ($pool in $inventory.HostPools | Sort-Object Name) {
        $links = Get-AzReadOnlyPoolLink -Pool $pool -Inventory $inventory
        [pscustomobject]@{
            HostPool          = "$(Get-AzReadOnlyValue $pool 'Name')"
            ResourceGroupName = (Split-AzReadOnlyResourceId (Get-AzReadOnlyValue $pool 'Id')).ResourceGroupName
            Location          = "$(Get-AzReadOnlyValue $pool 'Location')"
            Type              = "$(Get-AzReadOnlyValue $pool 'HostPoolType')"
            LoadBalancer      = "$(Get-AzReadOnlyValue $pool 'LoadBalancerType')"
            MaxSessions       = Get-AzReadOnlyValue $pool 'MaxSessionLimit'
            StartVMOnConnect  = [bool](Get-AzReadOnlyValue $pool 'StartVMOnConnect' $false)
            AppGroups         = (@($links.AppGroups | ForEach-Object { "$($_.Name) ($($_.Type))" }) -join ', ')
            Workspaces        = (@($links.AppGroups | ForEach-Object { $_.Workspaces } | Sort-Object -Unique) -join ', ')
            ScalingPlans      = (@($links.ScalingPlans | ForEach-Object { "$($_.Name)$(if (-not $_.Enabled) { ' (disabled)' })" }) -join ', ')
        }
    }
}

function Get-AzReadOnlyPoolDetail {
    # Session hosts of one pool joined to their VMs. One Get-AzVM -Status call per
    # resource group that holds hosts, so this stays cheap for big pools.
    # GOTCHA Only Azure VMs in the selected subscription are joined. A host whose VM
    #        is in another subscription, or an Azure Local/Arc machine, says so
    #        instead: a same-named VM here is not its VM, and it is not orphaned.
    param($Pool, $Inventory)
    $rg = (Split-AzReadOnlyResourceId (Get-AzReadOnlyValue $Pool 'Id')).ResourceGroupName
    $name = "$(Get-AzReadOnlyValue $Pool 'Name')"
    $hosts = @(Invoke-AzReadCommand 'Get-AzWvdSessionHost' @{ SubscriptionId = $script:Session.SubscriptionId; ResourceGroupName = $rg; HostPoolName = $name })
    $vmByKey = @{}
    $unread = @{}
    $refs = @($hosts | ForEach-Object { Split-AzReadOnlyResourceId (Get-AzReadOnlyValue $_ 'ResourceId') })
    $groups = @($refs | Where-Object { $_.ResourceGroupName -and (Test-AzReadOnlySame $_.SubscriptionId $script:Session.SubscriptionId) -and (Test-AzReadOnlySame $_.Type 'Microsoft.Compute/virtualMachines') } |
        ForEach-Object ResourceGroupName | Sort-Object -Unique)
    foreach ($g in $groups) {
        try {
            foreach ($vm in @(Invoke-AzReadCommand 'Get-AzVM' @{ ResourceGroupName = $g; Status = $true })) {
                $vmByKey["$g/$(Get-AzReadOnlyValue $vm 'Name')".ToLowerInvariant()] = $vm
            }
        } catch { $unread[$g.ToLowerInvariant()] = $_.Exception.Message }
    }
    $rows = @(foreach ($h in $hosts) {
        $ref = Split-AzReadOnlyResourceId (Get-AzReadOnlyValue $h 'ResourceId')
        $local = $ref.ResourceGroupName -and (Test-AzReadOnlySame $ref.SubscriptionId $script:Session.SubscriptionId) -and
            (Test-AzReadOnlySame $ref.Type 'Microsoft.Compute/virtualMachines')
        $vm = if ($local) { $vmByKey["$($ref.ResourceGroupName)/$($ref.Name)".ToLowerInvariant()] }
        $power = if ($vm) { "$(Get-AzReadOnlyValue $vm 'PowerState')" -replace '^VM ', '' }
            elseif (-not $ref.ResourceGroupName) { 'unknown' }
            elseif (-not (Test-AzReadOnlySame $ref.SubscriptionId $script:Session.SubscriptionId)) { 'other subscription' }
            elseif (-not $local) { 'not an Azure VM' }
            elseif ($unread.ContainsKey($ref.ResourceGroupName.ToLowerInvariant())) { 'unknown' }
            else { 'not found' }
        $checks = @(Get-AzReadOnlyValue $h 'HealthCheckResult', 'SessionHostHealthCheckResult' @())
        $failed = @($checks | Where-Object { "$(Get-AzReadOnlyValue $_ 'HealthCheckResult')" -eq 'HealthCheckFailed' } |
            ForEach-Object { "$(Get-AzReadOnlyValue $_ 'HealthCheckName')" })
        [pscustomobject]@{
            Name          = ("$(Get-AzReadOnlyValue $h 'Name')" -split '/')[-1]
            Status        = "$(Get-AzReadOnlyValue $h 'Status')"
            Drain         = $false -eq (Get-AzReadOnlyValue $h 'AllowNewSession')
            Sessions      = [int](Get-AzReadOnlyValue $h 'Session' 0)
            PowerState    = $(if ($power) { $power } else { 'unknown' })
            VMSize        = "$(Get-AzReadOnlyValue (Get-AzReadOnlyValue $vm 'HardwareProfile') 'VmSize')"
            AgentVersion  = "$(Get-AzReadOnlyValue $h 'AgentVersion')"
            LastHeartBeat = Get-AzReadOnlyValue $h 'LastHeartBeat'
            UpdateState   = "$(Get-AzReadOnlyValue $h 'UpdateState')"
            FailedChecks  = $failed -join ', '
            VMResourceGroup = "$($ref.ResourceGroupName)"
        }
    })
    $links = Get-AzReadOnlyPoolLink -Pool $Pool -Inventory $Inventory
    [pscustomobject]@{
        Pool = [pscustomobject]@{
            Name = $name; ResourceGroupName = $rg; Location = "$(Get-AzReadOnlyValue $Pool 'Location')"
            Type = "$(Get-AzReadOnlyValue $Pool 'HostPoolType')"; LoadBalancer = "$(Get-AzReadOnlyValue $Pool 'LoadBalancerType')"
            MaxSessionLimit = Get-AzReadOnlyValue $Pool 'MaxSessionLimit'
            StartVMOnConnect = [bool](Get-AzReadOnlyValue $Pool 'StartVMOnConnect' $false)
            ValidationEnvironment = [bool](Get-AzReadOnlyValue $Pool 'ValidationEnvironment' $false)
            PreferredAppGroupType = "$(Get-AzReadOnlyValue $Pool 'PreferredAppGroupType')"
        }
        Counts = [pscustomobject]@{
            Total       = @($rows).Count
            Available   = @($rows | Where-Object Status -eq 'Available').Count
            Unavailable = @($rows | Where-Object Status -eq 'Unavailable').Count
            Other       = @($rows | Where-Object { $_.Status -notin 'Available', 'Unavailable' }).Count
            Drained     = @($rows | Where-Object Drain).Count
            Sessions    = [int](@($rows | ForEach-Object Sessions) | Measure-Object -Sum).Sum
            Running     = @($rows | Where-Object PowerState -eq 'running').Count
        }
        AppGroups    = $links.AppGroups
        ScalingPlans = $links.ScalingPlans
        Hosts        = @($rows | Sort-Object Name)
        UnreadVmGroups = @($unread.Keys | Sort-Object)
    }
}

function Find-AzReadOnlyHostPool {
    param([string]$ResourceGroupName, [string]$HostPoolName, $Inventory)
    $pool = @($Inventory.HostPools | Where-Object {
        "$(Get-AzReadOnlyValue $_ 'Name')" -eq $HostPoolName -and
        (Split-AzReadOnlyResourceId (Get-AzReadOnlyValue $_ 'Id')).ResourceGroupName -eq $ResourceGroupName
    }) | Select-Object -First 1
    if (-not $pool) { throw "Host pool $HostPoolName was not found in resource group $ResourceGroupName of the selected subscription." }
    return $pool
}

function Get-AzReadOnlyHostPool {
    <#
    .SYNOPSIS
        One host pool: settings, host counts, session hosts with VM power and failed health checks, app groups and scaling plans.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$HostPoolName
    )
    $ErrorActionPreference = 'Stop'
    Assert-AzReadOnlyContext
    $inventory = Get-AzReadOnlyAvdInventory
    $pool = Find-AzReadOnlyHostPool -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -Inventory $inventory
    Get-AzReadOnlyPoolDetail -Pool $pool -Inventory $inventory
}

function Get-AzReadOnlyUserSession {
    <#
    .SYNOPSIS
        Who is signed in to a host pool, on which host, and whether the session is active or disconnected.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$HostPoolName
    )
    $ErrorActionPreference = 'Stop'
    Assert-AzReadOnlyContext
    $query = @{ SubscriptionId = $script:Session.SubscriptionId; ResourceGroupName = $ResourceGroupName; HostPoolName = $HostPoolName }
    $rows = foreach ($s in @(Invoke-AzReadCommand 'Get-AzWvdUserSession' $query)) {
        # Name is 'hostpool/sessionhost/sessionId'.
        $parts = "$(Get-AzReadOnlyValue $s 'Name')" -split '/'
        [pscustomobject]@{
            SessionHost = $(if ($parts.Count -ge 2) { $parts[1] } else { '' })
            SessionId   = $parts[-1]
            User        = "$(Get-AzReadOnlyValue $s 'UserPrincipalName')"
            State       = "$(Get-AzReadOnlyValue $s 'SessionState')"
            Application = "$(Get-AzReadOnlyValue $s 'ApplicationType')"
            Started     = Get-AzReadOnlyValue $s 'CreateTime'
        }
    }
    @($rows) | Sort-Object SessionHost, User
}

function Get-AzReadOnlyAvdHealth {
    <#
    .SYNOPSIS
        Problems and warnings across every host pool in the subscription.
    .DESCRIPTION
        Problem: hosts users cannot reach (status other than Available, Shutdown or
        Upgrading), failed health checks or agent updates, session hosts whose VM is
        missing, and pools nobody can connect to. Warning: drain mode left on, app
        groups no workspace publishes, VMs that could not be read.
    #>
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Stop'
    Assert-AzReadOnlyContext
    $inventory = Get-AzReadOnlyAvdInventory
    foreach ($pool in $inventory.HostPools | Sort-Object Name) {
        $poolName = "$(Get-AzReadOnlyValue $pool 'Name')"
        try { $detail = Get-AzReadOnlyPoolDetail -Pool $pool -Inventory $inventory } catch {
            [pscustomobject]@{ Severity = 'Warning'; HostPool = $poolName; SessionHost = ''; Finding = "Could not read session hosts: $($_.Exception.Message)" }
            continue
        }
        Get-AzReadOnlyPoolFinding -Detail $detail
    }
}

function Get-AzReadOnlyPoolFinding {
    param($Detail)
    $pool = $Detail.Pool.Name
    if ($Detail.Counts.Total -eq 0) { New-AzReadOnlyFinding 'Warning' $pool '' 'No session hosts.' }
    if (@($Detail.AppGroups).Count -eq 0) { New-AzReadOnlyFinding 'Problem' $pool '' 'No application group: users have nothing to open.' }
    foreach ($g in $Detail.AppGroups | Where-Object { @($_.Workspaces).Count -eq 0 }) {
        New-AzReadOnlyFinding 'Warning' $pool '' "Application group $($g.Name) is not in any workspace, so users do not see it."
    }
    # Only when every host's power state is known: unknown or unjoined hosts may be running.
    $known = @($Detail.Hosts | Where-Object { $_.PowerState -notin 'unknown', 'other subscription', 'not an Azure VM' }).Count -eq $Detail.Counts.Total
    if ($Detail.Counts.Total -gt 0 -and $Detail.Counts.Running -eq 0 -and -not $Detail.Pool.StartVMOnConnect -and $known) {
        New-AzReadOnlyFinding 'Problem' $pool '' 'No host is running and Start VM On Connect is off: users cannot connect until a host starts.'
    }
    foreach ($g in $Detail.UnreadVmGroups) { New-AzReadOnlyFinding 'Warning' $pool '' "Could not read VMs in resource group $g; power states are unknown." }
    foreach ($h in $Detail.Hosts) {
        if ($h.Status -notin 'Available', 'Shutdown', 'Upgrading') { New-AzReadOnlyFinding 'Problem' $pool $h.Name "Status is $(if ($h.Status) { $h.Status } else { 'unknown' })." }
        if ($h.PowerState -eq 'not found') { New-AzReadOnlyFinding 'Problem' $pool $h.Name 'Its VM was not found; the session host may be orphaned.' }
        if ($h.FailedChecks) { New-AzReadOnlyFinding 'Problem' $pool $h.Name "Failed health checks: $($h.FailedChecks)." }
        if ($h.UpdateState -eq 'Failed') { New-AzReadOnlyFinding 'Problem' $pool $h.Name 'The last agent update failed.' }
        if ($h.Drain) { New-AzReadOnlyFinding 'Warning' $pool $h.Name 'Drain mode is on: no new sessions.' }
    }
}

function New-AzReadOnlyFinding {
    # A report row. Builds an object in memory; changes nothing.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates a report row in memory only.')]
    param([string]$Severity, [string]$HostPool, [string]$SessionHost, [string]$Finding)
    [pscustomobject]@{ Severity = $Severity; HostPool = $HostPool; SessionHost = $SessionHost; Finding = $Finding }
}
#endregion

#region 7. Networking ----------------------------------------------------------
#   WHAT   Virtual networks, subnets with their NSGs, and NSGs with inbound Allow
#          rules from any internet source.
#   GOTCHA OpenToInternet is a pointer, not an evaluation: it does not apply rule
#          priority or Deny rules, and misses a source split into several ranges.
#   WHY    "Which subnet are the hosts in, and is RDP open to the world" are the
#          two network questions behind most AVD and server tickets.
function Get-AzReadOnlyNetwork {
    <#
    .SYNOPSIS
        VNets, subnets and NSGs in the selected subscription, including inbound rules that allow any internet source.
    #>
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Stop'
    Assert-AzReadOnlyContext
    $vnets = @(Invoke-AzReadCommand 'Get-AzVirtualNetwork')
    $nsgs = @(Invoke-AzReadCommand 'Get-AzNetworkSecurityGroup')
    $networks = foreach ($v in $vnets) {
        $dns = @(Get-AzReadOnlyValue (Get-AzReadOnlyValue $v 'DhcpOptions') 'DnsServers' @())
        [pscustomobject]@{
            Name              = "$(Get-AzReadOnlyValue $v 'Name')"
            ResourceGroupName = "$(Get-AzReadOnlyValue $v 'ResourceGroupName')"
            Location          = "$(Get-AzReadOnlyValue $v 'Location')"
            AddressSpace      = (@(Get-AzReadOnlyValue (Get-AzReadOnlyValue $v 'AddressSpace') 'AddressPrefixes' @()) -join ', ')
            DnsServers        = $(if ($dns.Count) { $dns -join ', ' } else { 'Azure default' })
            Subnets           = @(Get-AzReadOnlyValue $v 'Subnets' @()).Count
            Peerings          = @(Get-AzReadOnlyValue $v 'VirtualNetworkPeerings' @()).Count
        }
    }
    $subnets = foreach ($v in $vnets) {
        foreach ($s in @(Get-AzReadOnlyValue $v 'Subnets' @())) {
            $nsg = Get-AzReadOnlyValue (Get-AzReadOnlyValue $s 'NetworkSecurityGroup') 'Id'
            [pscustomobject]@{
                VirtualNetwork = "$(Get-AzReadOnlyValue $v 'Name')"
                Name           = "$(Get-AzReadOnlyValue $s 'Name')"
                AddressPrefix  = (@(Get-AzReadOnlyValue $s 'AddressPrefix' @()) -join ', ')
                Nsg            = $(if ($nsg) { (Split-AzReadOnlyResourceId $nsg).Name } else { '' })
                NatGateway     = $(if (Get-AzReadOnlyValue (Get-AzReadOnlyValue $s 'NatGateway') 'Id') { 'yes' } else { '' })
            }
        }
    }
    $groups = foreach ($n in $nsgs) {
        $rules = @(Get-AzReadOnlyValue $n 'SecurityRules' @())
        $open = @($rules | Where-Object {
            "$(Get-AzReadOnlyValue $_ 'Direction')" -eq 'Inbound' -and "$(Get-AzReadOnlyValue $_ 'Access')" -eq 'Allow' -and
            @(@(Get-AzReadOnlyValue $_ 'SourceAddressPrefix' @()) | Where-Object { "$_" -in '*', 'Internet', 'Any', '0.0.0.0/0', '::/0' }).Count -gt 0
        } | ForEach-Object { "$(Get-AzReadOnlyValue $_ 'Name') ($(Get-AzReadOnlyValue $_ 'Protocol') $(@(Get-AzReadOnlyValue $_ 'DestinationPortRange' @()) -join ','))" })
        [pscustomobject]@{
            Name              = "$(Get-AzReadOnlyValue $n 'Name')"
            ResourceGroupName = "$(Get-AzReadOnlyValue $n 'ResourceGroupName')"
            Rules             = $rules.Count
            Subnets           = @(Get-AzReadOnlyValue $n 'Subnets' @()).Count
            Nics              = @(Get-AzReadOnlyValue $n 'NetworkInterfaces' @()).Count
            OpenToInternet    = $open -join '; '
        }
    }
    [pscustomobject]@{
        VirtualNetworks = @($networks | Sort-Object ResourceGroupName, Name)
        Subnets         = @($subnets | Sort-Object VirtualNetwork, Name)
        SecurityGroups  = @($groups | Sort-Object ResourceGroupName, Name)
    }
}
#endregion

Export-ModuleMember -Function @(
    'Get-AzReadCommandPolicy'
    'Get-AzReadOnlyMissingModule'
    'Connect-AzReadOnly'
    'Get-AzReadOnlySession'
    'Get-AzReadOnlySubscription'
    'Select-AzReadOnlySubscription'
    'Get-AzReadOnlyAccess'
    'Get-AzReadOnlyResourceGroup'
    'Get-AzReadOnlyVm'
    'Get-AzReadOnlyAvdEnvironment'
    'Get-AzReadOnlyHostPool'
    'Get-AzReadOnlyUserSession'
    'Get-AzReadOnlyAvdHealth'
    'Get-AzReadOnlyNetwork'
)
