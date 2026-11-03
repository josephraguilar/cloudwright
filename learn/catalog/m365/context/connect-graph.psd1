@{
    Id      = 'm365.context.connect-graph'
    Title   = 'Connect to Microsoft Graph'
    Summary = 'Signs in to Graph PowerShell with the scopes your next commands need. Delegated: you act as yourself, limited to the scopes you consented to and the roles you hold.'
    Learn   = @(
        'Scopes are requested per session and remembered as consent. Ask for the least you need; a session with Directory.ReadWrite.All is a loaded weapon.'
        'Admin consent is required for most *.All scopes the first time in a tenant. A Global Admin runs Connect-MgGraph once with them, consents, and everyone can use them after.'
        'Get-MgContext shows who you are and what scopes the token holds. Disconnect-MgGraph ends it.'
    )
    Requires = @{ Auth = 'None'; Modules = @('Microsoft.Graph.Authentication'); Roles = @('Any user; admin roles decide what the scopes actually let you do') }
    Fields = @(
        @{ Name = 'Scopes'; Label = 'Scopes to request'; Help = 'Microsoft Graph permissions to request for this session, named Resource.Access.Scope: User.Read.All = read every user; Group.ReadWrite.All = create and change groups; the .All suffix means tenant-wide rather than just your own objects. Delegated scopes act as you, limited by both the scope and your admin role. Most .All scopes need a Global Administrator to grant admin consent the first time. Ask for the least you need.'; Type = 'MultiChoice'; Required = $true
           Options = @(
               @{ Display = 'User.Read.All (read users)';                     Value = 'User.Read.All' }
               @{ Display = 'User.ReadWrite.All (create/update users)';       Value = 'User.ReadWrite.All' }
               @{ Display = 'Group.Read.All (read groups)';                   Value = 'Group.Read.All' }
               @{ Display = 'Group.ReadWrite.All (create/update groups)';     Value = 'Group.ReadWrite.All' }
               @{ Display = 'GroupMember.ReadWrite.All (membership only)';    Value = 'GroupMember.ReadWrite.All' }
               @{ Display = 'Directory.Read.All (read everything)';           Value = 'Directory.Read.All' }
               @{ Display = 'Organization.Read.All (licences / SKUs)';        Value = 'Organization.Read.All' }
               @{ Display = 'RoleManagement.ReadWrite.Directory (admin roles)'; Value = 'RoleManagement.ReadWrite.Directory' }
               @{ Display = 'Policy.ReadWrite.ConditionalAccess';             Value = 'Policy.ReadWrite.ConditionalAccess' }
               @{ Display = 'Application.ReadWrite.All (app registrations)';  Value = 'Application.ReadWrite.All' }
           ) }
        @{ Name = 'TenantId'; Label = 'Tenant ID or domain (blank for the account default)'; Help = 'The Entra tenant (directory) GUID, or a verified domain like contoso.onmicrosoft.com. One account can be a member or guest in many tenants; specifying this makes sure you land in the right one. Leave blank to use the account''s home tenant.'; Type = 'String'; Required = $false; Example = 'contoso.onmicrosoft.com' }
    )
    Steps = @(
        @{
            Title      = 'Connect'
            What       = 'Interactive sign-in requesting the scopes. A consent prompt appears for any you have not granted before.'
            Why        = 'Every Graph cmdlet after this uses this token.'
            Cmdlet     = 'Connect-MgGraph'
            Parameters = @{ Scopes = '{{Scopes}}'; TenantId = '{{TenantId}}'; NoWelcome = '$true' }
            ParameterOrder = @('Scopes', 'TenantId', 'NoWelcome')
            Fixed          = @('NoWelcome')
            WhatIf     = $false
        }
    )
    Verify = @('Get-MgContext | Select-Object Account, TenantId, AuthType, Scopes')
    Docs   = @('https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands', 'https://learn.microsoft.com/graph/permissions-reference')
    Status = 'Untested'
}
