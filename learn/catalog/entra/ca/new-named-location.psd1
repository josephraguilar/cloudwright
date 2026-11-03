@{
    Id      = 'entra.ca.new-named-location'
    Title   = 'Create a trusted IP named location'
    Summary = 'Defines office or VPN egress ranges so Conditional Access can treat them as trusted (skip MFA, or block everything else).'
    Learn   = @(
        'Trusted locations also feed Identity Protection: sign-ins from them are not flagged as risky. Only add ranges you control.'
        'CIDR ranges are required (203.0.113.10/32 for a single address).'
        'Named locations are referenced by Id in policies; renaming is safe, deleting breaks policies that use them.'
    )
    Requires = @{ Auth = 'Graph'; Modules = @('Microsoft.Graph.Identity.SignIns'); Scopes = @('Policy.ReadWrite.ConditionalAccess'); Roles = @('Conditional Access Administrator') }
    Prerequisites = @('m365.context.connect-graph')
    Fields = @(
        @{ Name = 'Name'; Label = 'Location name'; Help = 'The resource name. Pick something that says what it is and which environment it belongs to.'; Type = 'String'; Required = $true; Example = 'HQ and VPN egress' }
        @{ Name = 'IpRanges'; Label = 'IPv4 CIDR ranges'; Type = 'MultiChoice'; Required = $true; Options = @('203.0.113.0/24'); Help = 'Public IPv4 address blocks in CIDR notation. /32 is one address; /24 is 256. These are the addresses the internet sees for your office or VPN egress (check with a what-is-my-ip site from inside), not internal 10.x ranges. Conditional Access only ever sees the public source address.' }
        @{ Name = 'Trusted'; Label = 'Mark as trusted'; Help = 'Trusted named locations do two things: policies can use "trusted location" as a condition (for example, skip MFA from the office), and Entra ID Protection stops flagging sign-ins from them as unfamiliar or risky. Mark only ranges you control, because anyone on them becomes less scrutinised.'; Type = 'TrueFalse'; Required = $false; Default = $true }
    )
    Steps = @(
        @{
            Title = 'Create the named location'
            What  = 'POST an ipNamedLocation with the ranges wrapped as iPv4CidrRange objects.'
            Why   = 'The CA policy task references this by name.'
            Raw   = @('New-MgIdentityConditionalAccessNamedLocation -BodyParameter @{ ''@odata.type'' = ''#microsoft.graph.ipNamedLocation''; displayName = {{Name}}; isTrusted = {{Trusted}}; ipRanges = @({{IpRanges}} | ForEach-Object { @{ ''@odata.type'' = ''#microsoft.graph.iPv4CidrRange''; cidrAddress = $_ } }) }')
        }
    )
    Verify   = @('Get-MgIdentityConditionalAccessNamedLocation -Filter {{Name:filter:displayName}} | Select-Object Id, DisplayName, @{ n = ''Trusted''; e = { $_.AdditionalProperties.isTrusted } }, @{ n = ''Ranges''; e = { $_.AdditionalProperties.ipRanges.cidrAddress } }')
    Rollback = @('Remove-MgIdentityConditionalAccessNamedLocation -NamedLocationId (Get-MgIdentityConditionalAccessNamedLocation -Filter {{Name:filter:displayName}}).Id')
    Docs     = @('https://learn.microsoft.com/graph/api/conditionalaccessroot-post-namedlocations')
    Status   = 'Untested'
}
