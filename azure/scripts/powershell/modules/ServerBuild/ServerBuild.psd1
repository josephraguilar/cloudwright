@{
    RootModule        = 'ServerBuild.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '7c1f3a52-9d0e-4b1a-a8c3-2f6e0d4b9a11'
    Author            = 'Cloudwright contributors'
    Description       = 'Plain Windows servers on Azure: inventory, power, VM build, and role setup (IIS, AD DS forest, SQL Server) through in-guest scripts.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Get-ServerVmInfo'
        'Start-ServerVm'
        'Stop-ServerVm'
        'Restart-ServerVm'
        'Get-ServerImageCatalog'
        'Resolve-ServerImage'
        'New-ServerNic'
        'New-ServerVm'
        'Invoke-ServerScript'
        'Initialize-ServerDataDisk'
        'Install-ServerWebRole'
        'Install-ServerAdForest'
        'Set-ServerSqlConfig'
        'Register-ServerSqlVm'
        'Set-ServerVNetDnsServer'
        'Get-ServerCallerIp'
        'Get-ServerRdpAccess'
        'Grant-ServerRdpAccess'
        'Revoke-ServerRdpAccess'
        'New-ServerRdpFile'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('Azure', 'WindowsServer', 'IIS', 'ActiveDirectory', 'SQLServer')
        }
    }
}
