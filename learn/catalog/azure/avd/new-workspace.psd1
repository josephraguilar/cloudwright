@{
    Id      = 'azure.avd.new-workspace'
    Title   = 'Create a workspace and register the app group'
    Summary = 'A workspace is what shows up in the Windows App / Remote Desktop client. It lists the app groups registered to it.'
    Learn   = @(
        'An app group belongs to at most one workspace. Registering it to a second one moves it.'
        'Workspace and host pool should be in the same region; the workspace is metadata only, no compute.'
        'The friendly name is what users see. Set it to something they recognise.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.DesktopVirtualization'); Roles = @('Desktop Virtualization Contributor on the resource group') }
    Prerequisites = @('azure.avd.new-application-group')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'Location'; Label = 'Region'; Help = 'Azure region short name, e.g. eastus2. Resources that talk to each other should share a region.'; Type = 'Choice'; Required = $true; Default = 'eastus2'
           Source = @{ Cmdlet = 'Get-AzLocation'; Display = 'DisplayName'; Value = 'Location'; Auth = 'Azure' } }
        @{ Name = 'WorkspaceName'; Label = 'Workspace name'; Help = 'An AVD workspace is the container that appears in the Windows App / Remote Desktop client. It lists the app groups registered to it; an app group belongs to at most one workspace. Metadata only, no compute, no cost.'; Type = 'String'; Required = $true; Example = 'ws-lab' }
        @{ Name = 'FriendlyName'; Label = 'Friendly name shown to users'; Help = 'What users see as the name of the workspace in the Windows App, instead of the resource name. Use something they recognise, like the company or environment name.'; Type = 'String'; Required = $false; Example = 'Contoso Lab Desktop' }
        @{ Name = 'AppGroupName'; Label = 'Application group to register'; Help = 'The AVD application group: the object users are granted access to (Desktop Virtualization User role on it). A host pool has one Desktop app group and optionally several RemoteApp groups. The portal default name is <hostpool>-DAG for the desktop group.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzWvdApplicationGroup'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
    )
    Steps = @(
        @{
            Title = 'Create the workspace with the app group registered'
            What  = 'Creates the workspace and passes the app group ID as its reference list.'
            Why   = 'One call does both; Register-AzWvdApplicationGroup is the separate cmdlet for adding more later.'
            Raw   = @('New-AzWvdWorkspace -Name {{WorkspaceName}} -ResourceGroupName {{ResourceGroupName}} -Location {{Location}} -FriendlyName {{FriendlyName}} -ApplicationGroupReference (Get-AzWvdApplicationGroup -Name {{AppGroupName}} -ResourceGroupName {{ResourceGroupName}}).Id')
        }
    )
    Verify   = @('Get-AzWvdWorkspace -Name {{WorkspaceName}} -ResourceGroupName {{ResourceGroupName}} | Select-Object Name, FriendlyName, ApplicationGroupReference')
    Rollback = @('Remove-AzWvdWorkspace -Name {{WorkspaceName}} -ResourceGroupName {{ResourceGroupName}}')
    Docs     = @('https://learn.microsoft.com/powershell/module/az.desktopvirtualization/new-azwvdworkspace')
    Status   = 'Untested'
}
