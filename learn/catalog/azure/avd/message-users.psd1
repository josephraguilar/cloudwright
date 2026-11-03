@{
    Id      = 'azure.avd.message-users'
    Title   = 'Send a message to every user on a session host'
    Summary = 'Pops a dialog in each active session on one host. Use it before a reimage or forced log-off.'
    Learn   = @(
        'Messages go per session, so this lists the sessions and sends one message each. Disconnected sessions do not see it until they reconnect.'
        'The session ID in the pipeline is the last segment of the user session resource name.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.DesktopVirtualization'); Roles = @('Desktop Virtualization Session Host Operator') }
    Prerequisites = @('azure.avd.new-session-host')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'HostPoolName'; Label = 'Host pool'; Help = 'The AVD host pool: the control-plane object that session hosts register with and that holds the load-balancing, session limit, and RDP settings. Users never see it directly; they see workspaces and app groups attached to it.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzWvdHostPool'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'SessionHostName'; Label = 'Session host'; Help = 'The host as the AVD control plane names it: <hostpool>/<computername>, where the computer name may include the AD domain suffix (avd-01.contoso.com) or be bare for Entra-joined hosts. It is not the Azure VM resource name. The list shows the right value; the command takes the part after the slash.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzWvdSessionHost'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}'; HostPoolName = '{{HostPoolName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'Title'; Label = 'Message title'; Help = 'The title of the dialog users see.'; Type = 'String'; Required = $true; Default = 'Maintenance' }
        @{ Name = 'Body'; Label = 'Message'; Help = 'The message body shown to users.'; Type = 'String'; Required = $true; Default = 'Please save your work and sign out within 30 minutes. This desktop will be restarted.' }
    )
    Steps = @(
        @{
            Title = 'Message each session on the host'
            What  = 'Lists user sessions on the host and sends the message to each one.'
            Why   = 'There is no host-wide broadcast; it is per session.'
            Raw   = @('Get-AzWvdUserSession -ResourceGroupName {{ResourceGroupName}} -HostPoolName {{HostPoolName}} -SessionHostName ({{SessionHostName}} -split ''/'')[-1] | ForEach-Object { Send-AzWvdUserSessionMessage -ResourceGroupName {{ResourceGroupName}} -HostPoolName {{HostPoolName}} -SessionHostName ({{SessionHostName}} -split ''/'')[-1] -UserSessionId ($_.Name -split ''/'')[-1] -MessageTitle {{Title}} -MessageBody {{Body}} }')
        }
    )
    Docs   = @('https://learn.microsoft.com/powershell/module/az.desktopvirtualization/send-azwvdusersessionmessage')
    Status = 'Untested'
}
