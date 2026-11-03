@{
    RootModule        = 'AppDeploy.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '5b9e2d7c-1a46-4f83-9c0b-e3a7d85f2c14'
    Author            = 'Cloudwright contributors'
    Description       = 'Apps and scripts on VMs through managed Run Commands: targets, a parallel runner, a script library, winget, shell apps, certificates, MSIX app attach, and a local store for groups and deployments. No deletes.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Resolve-GuestTarget'
        'Invoke-GuestRunCommand'
        'Get-GuestRunCommandInfo'
        'Get-GuestScriptLibrary'
        'Get-ToolboxStore'
        'Set-ToolboxStoreItem'
        'Find-WingetPackage'
        'Install-WingetPackage'
        'New-ShellAppScript'
        'Install-ShellApp'
        'Get-KvCertificateInfo'
        'Import-KvCertificate'
        'Install-GuestCertificate'
        'Get-AppAttachPackageInfo'
        'New-AppAttachPackageResource'
        'Set-AppAttachPackageState'
        'Add-AppAttachPackageHostPool'
        'Grant-AppAttachPackageAccess'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('Azure', 'RunCommand', 'winget', 'AppAttach', 'Certificates') } }
}
