function Assert-MsGraphContext {
    <#
    .SYNOPSIS
        Ensure a Microsoft Graph session with READ-ONLY scopes for pick-list lookups.
    .DESCRIPTION
        Reuses only a verified process-scoped delegated read context. Otherwise connects with the read-only scope
        set below. Generated scripts ask for their own (write) scopes in their own window;
        this session never holds a write scope. Returns the context or $null with a warning.
    .PARAMETER TenantId
        Optional tenant GUID for a fresh sign-in.
    #>
    [CmdletBinding()]
    param([Parameter()] [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')] [string]$TenantId)

    # Read-only. Add to this list only with a *.Read.* scope and a note in docs/architecture.md.
    $readOnlyScopes = @('User.Read.All', 'Group.Read.All', 'Directory.Read.All', 'Organization.Read.All')

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Warning 'Microsoft.Graph.Authentication is not installed, so Microsoft 365 pick lists are off. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser to enable them.'
        return $null
    }
    $context = Get-MgContext -ErrorAction SilentlyContinue
    if ($context -and (-not (Test-MsReadOnlyGraphContext $context) -or
        ($TenantId -and $context.TenantId -ne $TenantId))) {
        $null = Disconnect-MgGraph -ErrorAction Stop
        $context = $null
    }
    if (-not $context) {
        $connectParams = @{ Scopes = $readOnlyScopes; NoWelcome = $true; ContextScope = 'Process'; ErrorAction = 'Stop' }
        if ($TenantId) { $connectParams.TenantId = $TenantId }
        $null = Connect-MgGraph @connectParams
        $context = Get-MgContext
    }
    if (-not (Test-MsReadOnlyGraphContext $context) -or ($TenantId -and $context.TenantId -ne $TenantId)) {
        $null = Disconnect-MgGraph -ErrorAction Stop
        throw 'Learn refused a Graph session with unexpected permissions or tenant. Use offline mode or a reader account.'
    }
    return $context
}

function Test-MsReadOnlyGraphContext {
    param([AllowNull()]$Context)
    if (-not $Context) { return $false }
    foreach ($name in 'Scopes', 'AuthType', 'ContextScope', 'TenantId') {
        if (-not $Context.PSObject.Properties[$name] -or -not $Context.$name) { return $false }
    }
    $allowed = @('User.Read.All', 'Group.Read.All', 'Directory.Read.All', 'Organization.Read.All', 'openid', 'profile', 'email', 'offline_access')
    return "$($Context.AuthType)" -eq 'Delegated' -and "$($Context.ContextScope)" -eq 'Process' -and
        @($Context.Scopes | Where-Object { $_ -notin $allowed }).Count -eq 0
}
