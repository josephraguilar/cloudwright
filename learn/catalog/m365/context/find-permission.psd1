@{
    Id      = 'm365.context.find-permission'
    Title   = 'Find the Graph permission a cmdlet needs'
    Summary = 'Searches the Graph permission catalogue so you request the right scope instead of guessing or over-asking.'
    Learn   = @(
        'Find-MgGraphCommand -Command <cmdlet> lists the permissions that cmdlet accepts, least privileged first. Find-MgGraphPermission searches by keyword.'
        'Delegated = acting as a signed-in user. Application = a daemon with its own identity. This tool only ever uses delegated.'
    )
    Requires = @{ Auth = 'None'; Modules = @('Microsoft.Graph.Authentication') }
    Fields = @(
        @{ Name = 'Cmdlet'; Label = 'Cmdlet name (blank to search by keyword instead)'; Help = 'A Graph PowerShell cmdlet name to look up the permissions for.'; Type = 'String'; Required = $false; Example = 'New-MgUser' }
        @{ Name = 'Keyword'; Label = 'Keyword'; Help = 'Text to search in permission names and descriptions.'; Type = 'String'; Required = $false; Example = 'Group' }
        @{ Name = 'PermissionType'; Label = 'Permission type for the keyword search'; Help = 'Graph has two permission models. Delegated permissions act on behalf of a signed-in user (what this tool and interactive scripts use); the user needs the scope AND a role that allows the action. Application permissions let a daemon or app registration act with its own identity, no user present, and are much more powerful; grant them only to automation.'; Type = 'Choice'; Required = $true; Default = 'Delegated'; Options = @('Delegated', 'Application') }
    )
    Steps = @(
        @{
            Title = 'Permissions for a cmdlet'
            When  = 'Cmdlet'
            What  = 'Lists the permission names the cmdlet accepts, per API version.'
            Why   = 'Pick the first delegated one that is not ReadWrite unless you are writing.'
            Raw   = @('Find-MgGraphCommand -Command {{Cmdlet}} | Select-Object -First 1 -ExpandProperty Permissions | Format-Table Name, IsAdmin, Description -AutoSize')
        }
        @{
            Title = 'Search by keyword'
            When  = 'Keyword'
            What  = 'Keyword search over delegated permissions.'
            Why   = 'For when you know the noun but not the cmdlet.'
            Raw   = @('Find-MgGraphPermission -SearchString {{Keyword}} -PermissionType {{PermissionType}} | Format-Table Name, Consent, Description -AutoSize')
        }
    )
    Docs   = @('https://learn.microsoft.com/powershell/microsoftgraph/find-mg-graph-command')
    Status = 'Untested'
}
