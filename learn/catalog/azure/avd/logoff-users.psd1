@{
    Id      = 'azure.avd.logoff-users'
    Title   = 'Log off every user on a session host'
    Summary = 'Forcibly ends every session on one host. Unsaved work is lost. Drain and message first.'
    Learn   = @(
        'This is the last step before a reimage. Order: drain, message, wait, log off, then rebuild.'
        'Active and disconnected sessions are both removed. FSLogix profiles unmount cleanly on log-off; they do not on a hard power-off.'
    )
    Requires = @{ Auth = 'Azure'; Modules = @('Az.DesktopVirtualization'); Roles = @('Desktop Virtualization Session Host Operator') }
    Prerequisites = @('azure.avd.drain-host', 'azure.avd.message-users')
    Fields = @(
        @{ Name = 'ResourceGroupName'; Label = 'Resource group'; Help = 'The resource group the resource lives in. A lifecycle, RBAC, and cost boundary; delete the group and everything inside goes.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzResourceGroup'; Display = 'ResourceGroupName'; Value = 'ResourceGroupName'; Auth = 'Azure' } }
        @{ Name = 'HostPoolName'; Label = 'Host pool'; Help = 'The AVD host pool: the control-plane object that session hosts register with and that holds the load-balancing, session limit, and RDP settings. Users never see it directly; they see workspaces and app groups attached to it.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzWvdHostPool'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
        @{ Name = 'SessionHostName'; Label = 'Session host'; Help = 'The host as the AVD control plane names it: <hostpool>/<computername>, where the computer name may include the AD domain suffix (avd-01.contoso.com) or be bare for Entra-joined hosts. It is not the Azure VM resource name. The list shows the right value; the command takes the part after the slash.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-AzWvdSessionHost'; Parameters = @{ ResourceGroupName = '{{ResourceGroupName}}'; HostPoolName = '{{HostPoolName}}' }; Display = 'Name'; Value = 'Name'; Auth = 'Azure' } }
    )
    Steps = @(
        @{
            Title = 'Remove every user session on the host'
            What  = 'Lists sessions and removes each with -Force.'
            Why   = 'Destructive. Make sure drain is on so nobody lands on the host while you do this.'
            Fixed = @('Force')
            Raw   = @('Get-AzWvdUserSession -ResourceGroupName {{ResourceGroupName}} -HostPoolName {{HostPoolName}} -SessionHostName ({{SessionHostName}} -split ''/'')[-1] | ForEach-Object { Remove-AzWvdUserSession -ResourceGroupName {{ResourceGroupName}} -HostPoolName {{HostPoolName}} -SessionHostName ({{SessionHostName}} -split ''/'')[-1] -Id ($_.Name -split ''/'')[-1] -Force }')
        }
    )
    Verify = @('Get-AzWvdUserSession -ResourceGroupName {{ResourceGroupName}} -HostPoolName {{HostPoolName}} -SessionHostName ({{SessionHostName}} -split ''/'')[-1] | Measure-Object | Select-Object Count')
    Docs   = @('https://learn.microsoft.com/powershell/module/az.desktopvirtualization/remove-azwvdusersession')
    Status = 'Untested'
}
