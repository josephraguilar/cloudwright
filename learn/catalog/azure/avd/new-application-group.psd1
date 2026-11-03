@{
    Id      = 'azure.avd.new-application-group'
    Title   = 'Create an application group (desktop or RemoteApp)'
    Summary = 'The object users are actually granted access to. A Desktop app group publishes the full desktop of a host pool; RemoteApp groups publish individual apps.'
    Learn   = @(
        'One host pool can have one Desktop app group and many RemoteApp groups.'
        'The app group references the host pool by ARM resource ID, which is why the pool is looked up inline.'
        'Nobody can see it until it is registered to a workspace (next task) and a group has the Desktop Virtualization User role on it.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.DesktopVirtualization'); Roles = @('Desktop Virtualization Contributor on the resource group') }
    Prerequisites = @('azure.avd.new-host-pool')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'Location'; Label = 'Region (same as the host pool)'; Help = 'Azure region short name, e.g. eastus2. Resources that talk to each other should share a region.'; Type = 'Choice'; Required = $true; Default = 'eastus2'
           Source = @{ Cmdlet = 'Get-AzLocation'; Display = 'DisplayName'; Value = 'Location'; Auth = 'Azure' } }
        @{ Name = 'HostPoolName'; Label = 'Host pool'; Help = 'The AVD host pool: the control-plane object that session hosts register with and that holds the load-balancing, session limit, and RDP settings. Users never see it directly; they see workspaces and app groups attached to it.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzWvdHostPool'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'AppGroupName'; Label = 'Application group name'; Help = 'The AVD application group: the object users are granted access to (Desktop Virtualization User role on it). A host pool has one Desktop app group and optionally several RemoteApp groups. The portal default name is <hostpool>-DAG for the desktop group.'; Type = 'String'; Required = $true; Example = 'hp-lab-DAG' }
        @{ Name = 'AppGroupType'; Label = 'Type'; Help = 'Desktop app groups publish the whole Windows desktop (one per host pool). RemoteApp app groups publish individual applications that run on the host but appear as separate windows on the user''s own desktop; a pool can have several. Users are granted access per app group.'; Type = 'Choice'; Required = $true; Default = 'Desktop'; Options = @(@{ Display = 'Desktop (full desktop)'; Value = 'Desktop' }, @{ Display = 'RemoteApp (individual apps)'; Value = 'RemoteApp' }) }
    )
    Steps = @(
        @{
            Title = 'Create the desktop app group'
            What  = 'Creates a Desktop-type application group bound to the host pool.'
            Why   = 'Access is granted on app groups, not on pools.'
            Raw   = @('New-AzWvdApplicationGroup -Name {{AppGroupName}} -ResourceGroupName {{ResourceGroupName}} -Location {{Location}} -ApplicationGroupType {{AppGroupType}} -HostPoolArmPath (Get-AzWvdHostPool -Name {{HostPoolName}} -ResourceGroupName {{ResourceGroupName}}).Id')
        }
    )
    Verify   = @('Get-AzWvdApplicationGroup -Name {{AppGroupName}} -ResourceGroupName {{ResourceGroupName}} | Select-Object Name, ApplicationGroupType, HostPoolArmPath, WorkspaceArmPath')
    Rollback = @('Remove-AzWvdApplicationGroup -Name {{AppGroupName}} -ResourceGroupName {{ResourceGroupName}}')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.desktopvirtualization/new-azwvdapplicationgroup')
    Status   = 'Untested'
}
