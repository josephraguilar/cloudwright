@{
    RootModule        = 'AvdBuild.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '16980936-f64a-4747-8e8b-da232f59c510'
    Author            = 'Cloudwright contributors'
    Description       = 'Build steps for Azure Virtual Desktop: host pool objects, session host VMs, join, agent, FSLogix, roles. One function per step.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Resolve-AvdImage'
        'New-AvdSessionHostNic'
        'New-AvdSessionHostVm'
        'Join-AvdSessionHost'
        'Install-AvdAgent'
        'Set-AvdSessionHostFsLogix'
        'Set-AvdProfileShareAcl'
        'Grant-AvdVmLogin'
        'Find-AvdEntraDevice'
        'Remove-AvdEntraDevice'
        'Test-AvdEntraJoin'
        'Get-AvdEntraJoinLogTail'
        'Test-AvdBuildPermission'
        'Grant-AvdStorageKerberosConsent'
        'Remove-AvdStorageKerberosApp'
        'Get-AvdVmQuota'
        'Test-AvdVmSizeQuota'
        'Get-AvdVmSizeCatalog'
        'Get-AvdMarketplaceImageSku'
        'Test-AvdVmCredentialPolicy'
        'New-AvdHostPoolResource'
        'New-AvdApplicationGroupResource'
        'New-AvdWorkspaceResource'
        'Register-AvdApplicationGroupToWorkspace'
        'Grant-AvdDesktopAccess'
        'Test-AvdAutoscaleRole'
        'Grant-AvdAutoscaleRole'
        'Get-AvdScalingPlan'
        'New-AvdScalingPlanResource'
        'Set-AvdScalingPlanEnabled'
        'Get-AvdScalingPlanSchedule'
        'Set-AvdScalingPlanResource'
        'Set-AvdHostPoolAgentUpdate'
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
