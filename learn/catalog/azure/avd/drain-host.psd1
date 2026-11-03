@{
    Id      = 'azure.avd.drain-host'
    Title   = 'Drain a session host (block new sessions)'
    Summary = 'Drain mode blocks new sessions on a host so you can patch or reimage it once existing users leave. Un-drain puts it back in rotation.'
    Learn   = @(
        'Draining does not disconnect anyone. Existing sessions stay until users log off or you remove them (next tasks).'
        'The session host name is the FQDN-style name AVD knows (vmname.domain or vmname for Entra joined), not the Azure VM name. The list shows the right one.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.DesktopVirtualization'); Roles = @('Desktop Virtualization Session Host Operator') }
    Prerequisites = @('azure.avd.new-session-host')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'HostPoolName'; Label = 'Host pool'; Help = 'The AVD host pool: the control-plane object that session hosts register with and that holds the load-balancing, session limit, and RDP settings. Users never see it directly; they see workspaces and app groups attached to it.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzWvdHostPool'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'SessionHostName'; Label = 'Session host'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzWvdSessionHost'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}'; HostPoolName = '{{HostPoolName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' }
           Help = 'The host as the AVD control plane names it: <hostpool>/<computername>, where the computer name may include the AD domain suffix (avd-01.contoso.com) or be bare for Entra-joined hosts. It is not the Azure VM resource name. The list shows the right value; the command takes the part after the slash.' }
    )
    Steps = @(
        @{
            Title = 'Set AllowNewSession on the host'
            What  = 'Updates the session host object. Takes effect immediately for new connections.'
            Why   = 'The one switch behind "drain mode" in the portal.'
            Fixed = @('AllowNewSession')
            Raw   = @('Update-AzWvdSessionHost -ResourceGroupName {{ResourceGroupName}} -HostPoolName {{HostPoolName}} -Name ({{SessionHostName}} -split ''/'')[-1] -AllowNewSession:$false')
        }
    )
    Verify = @('Get-AzWvdSessionHost -ResourceGroupName {{ResourceGroupName}} -HostPoolName {{HostPoolName}} | Select-Object Name, Status, AllowNewSession, Session')
    Rollback = @('Update-AzWvdSessionHost -ResourceGroupName {{ResourceGroupName}} -HostPoolName {{HostPoolName}} -Name ({{SessionHostName}} -split ''/'')[-1] -AllowNewSession:$true')
    Docs   = @('https://learn.microsoft.com/powershell/module/az.desktopvirtualization/update-azwvdsessionhost')
    Status = 'Untested'
}
