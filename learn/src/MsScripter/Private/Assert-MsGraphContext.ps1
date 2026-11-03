function Assert-MsGraphContext {
    <#
    .SYNOPSIS
        Ensure a Microsoft Graph session with READ-ONLY scopes for pick-list lookups.
    .DESCRIPTION
        Reuses Get-MgContext if present. Otherwise Connect-MgGraph with the read-only scope
        set below. Generated scripts ask for their own (write) scopes in their own window;
        this session never holds a write scope. Returns the context or $null with a warning.
    .PARAMETER TenantId
        Optional tenant for a fresh sign-in.
    #>
    [CmdletBinding()]
    param([Parameter()] [string]$TenantId)

    # Read-only. Add to this list only with a *.Read.* scope and a note in docs/architecture.md.
    $readOnlyScopes = @('User.Read.All', 'Group.Read.All', 'Directory.Read.All', 'Organization.Read.All')

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Warning 'Microsoft.Graph.Authentication is not installed, so Microsoft 365 pick lists are off. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser to enable them.'
        return $null
    }
    $context = Get-MgContext -ErrorAction SilentlyContinue
    if (-not $context) {
        $connectParams = @{ Scopes = $readOnlyScopes; NoWelcome = $true }
        if ($TenantId) { $connectParams.TenantId = $TenantId }
        $null = Connect-MgGraph @connectParams
        $context = Get-MgContext
    }
    return $context
}
