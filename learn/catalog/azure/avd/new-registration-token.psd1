@{
    Id      = 'azure.avd.new-registration-token'
    Title   = 'Generate a host pool registration token'
    Summary = 'A short-lived token a new session host presents to join the pool. Generate one, build your hosts, let it expire.'
    Learn   = @(
        'One token per pool at a time. Generating a new one invalidates the previous. Build all hosts in a batch with the same token.'
        'Expiry must be between 1 hour and 27 days from now. Shorter is safer; it is a bearer credential.'
        'Get-AzWvdHostPoolRegistrationToken reads the current one back if it has not expired.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.DesktopVirtualization'); Roles = @('Desktop Virtualization Contributor on the host pool') }
    Prerequisites = @('azure.avd.new-host-pool')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'HostPoolName'; Label = 'Host pool'; Help = 'The AVD host pool: the control-plane object that session hosts register with and that holds the load-balancing, session limit, and RDP settings. Users never see it directly; they see workspaces and app groups attached to it.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzWvdHostPool'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'Hours'; Label = 'Valid for (hours, 1-648)'; Help = 'How long the registration token stays valid, from 1 hour to 27 days (648 hours). A token is a bearer secret: anyone who has it can register a machine into your pool, so keep it short (24 hours covers a build) and let it expire.'; Type = 'Int'; Required = $true; Default = '24' }
    )
    Steps = @(
        @{
            Title = 'Generate the token and show it'
            What  = 'Creates registration info with the expiry and prints the token string.'
            Why   = 'You paste the token into the session host task (it is a Secret there, prompted at run time).'
            Raw   = @('(New-AzWvdRegistrationInfo -ResourceGroupName {{ResourceGroupName}} -HostPoolName {{HostPoolName}} -ExpirationTime (Get-Date).AddHours({{Hours}})).Token')
        }
    )
    Verify = @('Get-AzWvdHostPoolRegistrationToken -ResourceGroupName {{ResourceGroupName}} -HostPoolName {{HostPoolName}} | Select-Object ExpirationTime')
    Docs   = @('https://learn.microsoft.com/powershell/module/az.desktopvirtualization/new-azwvdregistrationinfo')
    Status = 'Untested'
}
