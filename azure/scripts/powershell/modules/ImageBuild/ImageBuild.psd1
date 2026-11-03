@{
    RootModule        = 'ImageBuild.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '0c8e4b7d-3f21-4a96-b5e8-71d2c9a04f6e'
    Author            = 'Cloudwright contributors'
    Description       = 'Desktop images: Compute Gallery galleries, definitions and versions, an image builder VM, sysprep and capture, managed images, and Windows 365 custom images. No deletes.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Get-GalleryInfo'
        'Get-GalleryImageInfo'
        'Get-GalleryImageVersionInfo'
        'Get-GalleryMarketplaceCatalog'
        'New-GalleryVersionNumber'
        'New-GalleryResource'
        'New-GalleryImageDefinitionResource'
        'New-GalleryBuilderVm'
        'Invoke-GalleryVmSysprep'
        'New-GalleryImageVersionFromVm'
        'New-GalleryManagedImage'
        'Get-ManagedImageInfo'
        'Connect-W365Graph'
        'Get-W365DeviceImageInfo'
        'Get-W365ProvisioningPolicyInfo'
        'New-W365DeviceImage'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('Azure', 'Gallery', 'Image', 'AVD', 'Windows365') } }
}
