@{
    RootModule        = 'AvdHelpers.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '10d96227-4c15-49c9-96e5-87f6f2e6bc77'
    Author            = 'Cloudwright contributors'
    Description       = 'Reusable Azure Virtual Desktop operations: session hosts, sessions, drain, tokens.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Resolve-AvdSessionHostName'
        'Find-AvdSessionHost'
        'Get-AvdSessionHostInfo'
        'Set-AvdSessionHostDrain'
        'Get-AvdUserSession'
        'Send-AvdUserMessage'
        'Remove-AvdUserSession'
        'Wait-AvdSessionHostStatus'
        'Wait-AvdSessionHostEmpty'
        'Get-AvdRegistrationToken'
        'Start-AvdSessionHostVm'
        'Stop-AvdSessionHostVm'
        'Restart-AvdSessionHostVm'
        'Get-AvdVmRetailPrice'
        'Get-AvdHostPoolOverview'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('Azure', 'AVD', 'AzureVirtualDesktop')
        }
    }
}
