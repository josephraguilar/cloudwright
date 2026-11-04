# Read-only policy for this release. This is an application guard, not a sandbox.
# There is intentionally no public write-mode switch. Legacy mutation tests mock
# Test-M365ReadOnly against fake APIs; production never loads those test fixtures.
function Test-M365ReadOnly {
    <# .SYNOPSIS
        Reports the mandatory Microsoft 365 read-only mode for this release.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return $true
}

function Assert-M365WriteAllowed {
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Stop'
    if (Test-M365ReadOnly) {
        throw 'Microsoft 365 safe mode: tenant and Hudu changes are disabled in this release. Only read-only tasks are available.'
    }
}

function Get-M365ReadOnlyScope {
    # Exact allowlist: a scope containing the word "Read" is not sufficient.
    @('User.Read.All', 'Group.Read.All', 'Directory.Read.All', 'Organization.Read.All',
        'Domain.Read.All', 'AuditLog.Read.All', 'UserAuthenticationMethod.Read.All',
        'RoleManagement.Read.Directory', 'Policy.Read.All',
        'DelegatedAdminRelationship.Read.All', 'CrossTenantInformation.ReadBasic.All',
        'Mail.Read.Shared')
}

function Assert-M365ReadOnlyScope {
    param([AllowEmptyCollection()][string[]]$Scopes)
    $ErrorActionPreference = 'Stop'
    $allowed = @(Get-M365ReadOnlyScope)
    if (-not $Scopes -or @($Scopes | Where-Object { $_ -notin $allowed }).Count) {
        throw 'Microsoft 365 safe mode refuses write permissions or unknown Graph scopes.'
    }
}

function Test-M365ReadOnlyGraphContext {
    param([AllowNull()]$Context, [string[]]$RequiredScopes = @())
    if (-not $Context) { return $false }
    foreach ($key in 'AuthType', 'ContextScope', 'Scopes', 'TenantId') {
        if (-not $Context.PSObject.Properties[$key] -or -not $Context.$key) { return $false }
    }
    if ("$($Context.AuthType)" -ne 'Delegated' -or "$($Context.ContextScope)" -ne 'Process') { return $false }
    $allowed = @(Get-M365ReadOnlyScope) + @('openid', 'profile', 'email', 'offline_access')
    if (@($Context.Scopes | Where-Object { $_ -notin $allowed }).Count) { return $false }
    if (@($RequiredScopes | Where-Object { $_ -notin $Context.Scopes }).Count) { return $false }
    return $true
}

function Get-M365ReadOnlyExchangeCommand {
    # CommandName limits imported cmdlets. It does NOT reduce the account's EXO
    # permissions: use a separately provisioned reader identity for a server boundary.
    @('Get-AcceptedDomain', 'Get-Recipient', 'Get-MailContact', 'Get-DistributionGroup', 'Get-DistributionGroupMember',
        'Get-DkimSigningConfig', 'Get-InboxRule', 'Get-Mailbox', 'Get-MailboxPermission',
        'Get-MailboxRegionalConfiguration', 'Get-MailboxStatistics', 'Get-RecipientPermission',
        'Get-AdminAuditLogConfig', 'Get-AntiPhishPolicy', 'Get-ExternalInOutlook',
        'Get-HostedOutboundSpamFilterPolicy', 'Get-HostedOutboundSpamFilterRule',
        'Get-OrganizationConfig', 'Get-TransportConfig')
}
