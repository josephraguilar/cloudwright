@{
    Id      = 'azure.avd.new-host-pool'
    Title   = 'Create an AVD host pool'
    Summary = 'The control-plane object that session hosts register with and that holds the RDP properties, load balancing, and session limits.'
    Learn   = @(
        'Pooled = shared hosts, users land on any host, profiles need FSLogix. Personal = one VM per user, assigned on first connect or by an admin.'
        'BreadthFirst spreads users across hosts (better experience). DepthFirst fills one host before the next (cheaper with autoscale).'
        'Entra-joined hosts need targetisaadjoined:i:1 in the RDP properties so clients that are not Entra joined can connect; enablerdsaadauth:i:1 enables single sign-on. The azure repo''s New-AvdHostPoolResource sets the same.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.DesktopVirtualization'); Roles = @('Desktop Virtualization Contributor on the resource group') }
    Prerequisites = @('azure.create.resource-group', 'azure.context.register-providers')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'Location'; Label = 'Region (AVD metadata region, e.g. eastus2, westus3, centralus)'; Help = 'Azure region short name, e.g. eastus2. Resources that talk to each other should share a region.'; Type = 'Choice'; Required = $true; Default = 'eastus2'
           Source = @{ Cmdlet = 'Get-AzLocation'; Display = 'DisplayName'; Value = 'Location'; Auth = 'Azure' } }
        @{ Name = 'HostPoolName'; Label = 'Host pool name'; Help = 'The AVD host pool: the control-plane object that session hosts register with and that holds the load-balancing, session limit, and RDP settings. Users never see it directly; they see workspaces and app groups attached to it.'; Type = 'String'; Required = $true; Example = 'hp-lab'; Pattern = '^[A-Za-z0-9][A-Za-z0-9_.-]{1,62}$' }
        @{ Name = 'HostPoolType'; Label = 'Pool type'; Help = 'Pooled: users share a set of identical hosts; a load balancer picks one per session and FSLogix brings the user''s profile along. Cheaper, standard for task workers. Personal: each user is assigned their own VM that persists between sessions, like a physical PC in the cloud. Needed for users who install software or need local admin.'; Type = 'Choice'; Required = $true; Default = 'Pooled'; Options = @('Pooled', 'Personal') }
        @{ Name = 'LoadBalancerType'; Label = 'Load balancing (Pooled)'; Type = 'Choice'; Required = $true; Default = 'BreadthFirst'; Options = @('BreadthFirst', 'DepthFirst', 'Persistent'); Help = 'How a pooled host pool places new sessions. BreadthFirst spreads users across all available hosts (best performance, all hosts stay on). DepthFirst fills one host to its max session limit before starting on the next (lets autoscale shut idle hosts down, cheaper). Persistent is the personal-pool mode: each user always returns to their own host.' }
        @{ Name = 'MaxSessionLimit'; Label = 'Max sessions per host (Pooled)'; Help = 'Most concurrent user sessions one pooled host accepts; beyond it the load balancer sends users to another host, and if none has room they cannot sign in. Size it from the VM: a common rule is one or two light users per vCPU, so 8 to 10 on a D4s_v5. DepthFirst pools fill to this number before opening the next host.'; Type = 'Int'; Required = $true; Default = '10' }
        @{ Name = 'PreferredAppGroupType'; Label = 'Preferred app group type'; Help = 'Which kind of app group this pool is meant to publish. Desktop = users get a full Windows desktop. RailApplications (RemoteApp) = users get individual apps that appear in their own windows on the local PC, with no visible remote desktop. A pool can have both kinds of app group; this just sets the default.'; Type = 'Choice'; Required = $true; Default = 'Desktop'; Options = @(@{ Display = 'Desktop'; Value = 'Desktop' }, @{ Display = 'RailApplications (RemoteApp)'; Value = 'RailApplications' }) }
        @{ Name = 'RdpProperties'; Label = 'Identity of the session hosts'; Help = 'Settings written into the RDP file users receive. targetisaadjoined:i:1 tells the client the host is Entra ID joined, required when the user''s own device is not Entra joined (otherwise the connection fails with a credential error). enablerdsaadauth:i:1 turns on Entra single sign-on so users are not prompted a second time. Leave empty for Active Directory joined hosts.'; Type = 'Choice'; Required = $false; Default = 'targetisaadjoined:i:1;enablerdsaadauth:i:1;'
           Options = @(@{ Display = 'Entra ID joined (sets targetisaadjoined + SSO)'; Value = 'targetisaadjoined:i:1;enablerdsaadauth:i:1;' }, @{ Display = 'Active Directory joined (no extra RDP properties)'; Value = '' }) }
        @{ Name = 'StartVMOnConnect'; Label = 'Start VM on connect (powers deallocated hosts when a user connects)'; Help = 'Lets the AVD service power on a deallocated host when a user tries to connect, so you can shut hosts down out of hours without autoscale. The user waits a minute or two. Needs the Azure Virtual Desktop service principal to hold the Desktop Virtualization Power On Contributor role on the VMs'' resource group.'; Type = 'Bool'; Required = $false; Default = $false }
    )
    Steps = @(
        @{
            Title      = 'Create the host pool'
            What       = 'Creates the pool with desktop as the preferred app group type and your RDP properties.'
            Why        = 'Everything else in AVD hangs off this object.'
            Cmdlet     = 'New-AzWvdHostPool'
            Parameters = @{ Name = '{{HostPoolName}}'; ResourceGroupName = '{{ResourceGroupName}}'; Location = '{{Location}}'; HostPoolType = '{{HostPoolType}}'; LoadBalancerType = '{{LoadBalancerType}}'; MaxSessionLimit = '{{MaxSessionLimit}}'; PreferredAppGroupType = '{{PreferredAppGroupType}}'; CustomRdpProperty = '{{RdpProperties}}'; StartVMOnConnect = '{{StartVMOnConnect}}' }
            ParameterOrder = @('Name', 'ResourceGroupName', 'Location', 'HostPoolType', 'LoadBalancerType', 'MaxSessionLimit', 'PreferredAppGroupType', 'CustomRdpProperty', 'StartVMOnConnect')
        }
    )
    Verify   = @('Get-AzWvdHostPool -Name {{HostPoolName}} -ResourceGroupName {{ResourceGroupName}} | Select-Object Name, HostPoolType, LoadBalancerType, MaxSessionLimit, CustomRdpProperty, StartVMOnConnect')
    Rollback = @('Remove-AzWvdHostPool -Name {{HostPoolName}} -ResourceGroupName {{ResourceGroupName}} -Force    # Fails while session hosts or app groups still reference it.')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.desktopvirtualization/new-azwvdhostpool')
    Status   = 'Untested'
}
