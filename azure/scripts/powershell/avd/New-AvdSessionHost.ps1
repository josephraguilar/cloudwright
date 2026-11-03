<#
.SYNOPSIS
    Creates one AVD session host from a gallery or marketplace image and joins it to a host pool.
.DESCRIPTION
    The full build of a single session host, in the order the pieces depend on each other:

      1. Resolve the image (Compute Gallery version, or marketplace)
      2. NIC (reused if one with the right name exists, so a reimage keeps its IP)
      3. VM from the image, LicenseType Windows_Client
      4. Domain join (Active Directory or Entra ID)
      5. Virtual Machine User Login role for the user group (Entra ID only)
      6. AVD agent + boot loader via the DSC extension, using the registration token
      7. FSLogix registry via Run Command (optional)
      8. Wait for the host to show Available in the pool

    Thin wrapper: each step is one function in the AvdBuild module. See
    docs/avd/provisioning-order.md for why this order and not another.
    Not idempotent for the VM: if a VM with this name exists the script stops.
    Use Invoke-AvdHostReimage.ps1 to replace one.
.PARAMETER SubscriptionId
    Subscription to deploy into.
.PARAMETER ResourceGroupName
    Resource group for the VM, NIC, and disk.
.PARAMETER HostPoolName
    Host pool to join.
.PARAMETER HostPoolResourceGroupName
    Resource group of the host pool. Defaults to -ResourceGroupName.
.PARAMETER RegistrationToken
    A valid registration token for the pool. From New-AvdHostPool.ps1 output or
    Get-AvdRegistrationToken.
.PARAMETER VMName
    VM and computer name. 15 characters max (NetBIOS limit).
.PARAMETER VMSize
    VM size. Default Standard_D4s_v5.
.PARAMETER Location
    Region for the VM. Defaults to the resource group's location.
.PARAMETER SubnetId
    Full ARM ID of the subnet the NIC attaches to.
.PARAMETER ImageSource
    Gallery (default) or Marketplace. Marketplace needs no gallery at all.
.PARAMETER GalleryResourceGroupName
    Resource group of the Compute Gallery. Required for Gallery.
.PARAMETER GalleryName
    Compute Gallery name. Required for Gallery.
.PARAMETER GalleryImageDefinitionName
    Image definition inside the gallery. Required for Gallery.
.PARAMETER GalleryImageVersion
    Specific version (e.g. 1.0.3) or 'latest'. Default latest.
.PARAMETER ImagePublisher
    Marketplace publisher. Default MicrosoftWindowsDesktop.
.PARAMETER ImageOffer
    Marketplace offer. Default office-365 (Windows multi-session with M365 Apps).
.PARAMETER ImageSku
    Marketplace SKU. Default win11-25h2-avd-m365. List with
    Get-AzVMImageSku -Location <region> -PublisherName MicrosoftWindowsDesktop -Offer office-365
.PARAMETER ImageVersion
    Marketplace version or 'latest'. Default latest.
.PARAMETER LocalAdminCredential
    Local administrator account for the VM.
.PARAMETER JoinType
    ActiveDirectory or EntraId.
.PARAMETER DomainName
    AD domain FQDN. Required for ActiveDirectory.
.PARAMETER DomainJoinCredential
    Account with rights to join computers to the domain/OU. Required for ActiveDirectory.
.PARAMETER OUPath
    Distinguished name of the OU for the computer object. Optional.
.PARAMETER UserGroupObjectId
    Entra group to grant Virtual Machine User Login on this VM. Entra-joined hosts
    require it in addition to the app group role. Ignored for ActiveDirectory.
.PARAMETER FsLogixProfileShare
    UNC path of the FSLogix profile share. If set, FSLogix registry is configured.
.PARAMETER SecurityType
    TrustedLaunch (default) or Standard. Must match what the image supports.
.PARAMETER OSDiskType
    Managed disk SKU for the OS disk. Default Premium_LRS.
.PARAMETER Tags
    Hashtable of tags for the VM and NIC.
.PARAMETER RemoveStaleEntraDevice
    Let the Entra join delete a leftover device record with this VM's name. Off by
    default: the build stops and names the record for you to delete in the Entra
    admin center.
.PARAMETER DscArtifactsUrl
    URL of Microsoft's AVD DSC package. Default is the one in the Azure/RDS-Templates
    repo, which is what the portal's own templates use.
.PARAMETER TimeoutMinutes
    How long to wait for the host to show Available. Default 20.
.EXAMPLE
    # Entra-only lab host from the marketplace image, no gallery, no domain
    ./New-AvdSessionHost.ps1 -SubscriptionId <sub> -ResourceGroupName rg-avd-lab -HostPoolName hp-lab `
        -RegistrationToken $pool.RegistrationToken -VMName avd-lab-01 -SubnetId <subnet-id> `
        -ImageSource Marketplace -JoinType EntraId -UserGroupObjectId <entra-group-object-id> `
        -FsLogixProfileShare '\\stavdlab.file.core.windows.net\profiles' `
        -LocalAdminCredential (Get-Credential -Message 'Local admin') -Verbose
.NOTES
    Requires: Az.Accounts, Az.Compute, Az.Network, Az.Resources, Az.DesktopVirtualization
    Status:   Tested 2026-10-17 (marketplace image, Entra join; join verification and device cleanup added after the test run)
    Roles:    Contributor on the VM resource group and the host pool resource group.
              Reader on the gallery resource group. Network Contributor (or join
              permission) on the subnet. User Access Administrator on the VM resource
              group if -UserGroupObjectId is used.
#>

#region 1. Parameters ---------------------------------------------------------
#   WHAT   Everything the build needs. Credentials come in as PSCredential so they
#          are never on the command line in plain text.
#   GOTCHA VMName is also the computer name. Windows caps it at 15 characters.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$HostPoolName,

    [Parameter()]
    [string]$HostPoolResourceGroupName = $ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$RegistrationToken,

    [Parameter(Mandatory)]
    [ValidateLength(1, 15)]
    [string]$VMName,

    [Parameter()]
    [string]$VMSize = 'Standard_D4s_v5',

    [Parameter()]
    [string]$Location,

    [Parameter(Mandatory)]
    [string]$SubnetId,

    [Parameter()]
    [ValidateSet('Gallery', 'Marketplace')]
    [string]$ImageSource = 'Gallery',

    [Parameter()]
    [string]$GalleryResourceGroupName,

    [Parameter()]
    [string]$GalleryName,

    [Parameter()]
    [string]$GalleryImageDefinitionName,

    [Parameter()]
    [string]$GalleryImageVersion = 'latest',

    [Parameter()]
    [string]$ImagePublisher = 'MicrosoftWindowsDesktop',

    [Parameter()]
    [string]$ImageOffer = 'office-365',

    [Parameter()]
    [string]$ImageSku = 'win11-25h2-avd-m365',

    [Parameter()]
    [string]$ImageVersion = 'latest',

    [Parameter(Mandatory)]
    [pscredential]$LocalAdminCredential,

    [Parameter(Mandatory)]
    [ValidateSet('ActiveDirectory', 'EntraId')]
    [string]$JoinType,

    [Parameter()]
    [string]$DomainName,

    [Parameter()]
    [pscredential]$DomainJoinCredential,

    [Parameter()]
    [string]$OUPath,

    [Parameter()]
    [string]$UserGroupObjectId,

    [Parameter()]
    [string]$FsLogixProfileShare,

    [Parameter()]
    [ValidateSet('TrustedLaunch', 'Standard')]
    [string]$SecurityType = 'TrustedLaunch',

    [Parameter()]
    [ValidateSet('Premium_LRS', 'StandardSSD_LRS', 'Standard_LRS')]
    [string]$OSDiskType = 'Premium_LRS',

    [Parameter()]
    [hashtable]$Tags = @{},

    [Parameter()]
    [string]$DscArtifactsUrl = 'https://raw.githubusercontent.com/Azure/RDS-Templates/master/ARM-wvd-templates/DSC/Configuration.zip',

    [Parameter()]
    [switch]$RemoveStaleEntraDevice,

    [Parameter()]
    [int]$TimeoutMinutes = 20
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Strict mode, fail fast, modules, Azure context, cross-parameter checks.
#   WHY    ActiveDirectory needs a domain and credential; Gallery needs gallery
#          names. PowerShell cannot express "mandatory if" in the param block.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AvdHelpers' 'AvdHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AvdBuild' 'AvdBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
$verbose = ($VerbosePreference -eq 'Continue')

if ($JoinType -eq 'ActiveDirectory' -and (-not $DomainName -or -not $DomainJoinCredential)) {
    throw 'JoinType ActiveDirectory requires -DomainName and -DomainJoinCredential.'
}
if (-not $Location) { $Location = (Get-AzResourceGroup -Name $ResourceGroupName).Location }
if (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction SilentlyContinue) {
    throw "VM $VMName already exists in $ResourceGroupName. Use Invoke-AvdHostReimage.ps1 to replace it."
}
$entra = ($JoinType -eq 'EntraId')
#endregion

#region 3. Image and NIC ------------------------------------------------------
#   WHAT   Resolve the exact image, then get-or-create the NIC.
#   WHY    Image first so a missing image fails before anything is created.
$image = Resolve-AvdImage -Location $Location -ImageSource $ImageSource `
    -GalleryResourceGroupName $GalleryResourceGroupName -GalleryName $GalleryName `
    -GalleryImageDefinitionName $GalleryImageDefinitionName -GalleryImageVersion $GalleryImageVersion `
    -ImagePublisher $ImagePublisher -ImageOffer $ImageOffer -ImageSku $ImageSku -ImageVersion $ImageVersion
Write-Verbose "Using image $($image.Label)."

$nic = New-AvdSessionHostNic -ResourceGroupName $ResourceGroupName -VMName $VMName -Location $Location -SubnetId $SubnetId -Tags $Tags -Verbose:$verbose
#endregion

#region 4. VM -----------------------------------------------------------------
#   WHAT   Create the VM. Entra join needs a system-assigned identity on it.
#   GOTCHA Under -WhatIf $nic is $null, so the call is skipped with a message.
if ($nic) {
    $null = New-AvdSessionHostVm -ResourceGroupName $ResourceGroupName -VMName $VMName -Location $Location -VMSize $VMSize `
        -Image $image -NicId $nic.Id -LocalAdminCredential $LocalAdminCredential -SecurityType $SecurityType `
        -OSDiskType $OSDiskType -SystemAssignedIdentity:$entra -Tags $Tags -Verbose:$verbose
} elseif ($PSCmdlet.ShouldProcess($VMName, "Create $VMSize VM from $($image.Label)")) { $null }
#endregion

#region 5. Join, login role, agent, FSLogix ----------------------------------
#   WHAT   The in-guest steps in dependency order.
#   WHY    Join before agent: the agent registers under the domain identity.
#          Login role right after join so it is in place before first sign-in.
#          Agent before FSLogix: a failed agent install should not waste time on
#          config that is thrown away with the VM.
Join-AvdSessionHost -ResourceGroupName $ResourceGroupName -VMName $VMName -Location $Location -JoinType $JoinType `
    -DomainName $DomainName -DomainJoinCredential $DomainJoinCredential -OUPath $OUPath -RemoveStaleEntraDevice:$RemoveStaleEntraDevice -Verbose:$verbose

if ($entra -and $UserGroupObjectId) {
    Grant-AvdVmLogin -ResourceGroupName $ResourceGroupName -VMName $VMName -ObjectId $UserGroupObjectId -Verbose:$verbose
}

Install-AvdAgent -ResourceGroupName $ResourceGroupName -VMName $VMName -Location $Location -HostPoolName $HostPoolName `
    -RegistrationToken $RegistrationToken -EntraJoined:$entra -DscArtifactsUrl $DscArtifactsUrl -Verbose:$verbose

if ($FsLogixProfileShare) {
    $null = Set-AvdSessionHostFsLogix -ResourceGroupName $ResourceGroupName -VMName $VMName -ProfileShare $FsLogixProfileShare -EntraKerberos:$entra -Verbose:$verbose
}
#endregion

#region 6. Verify and output --------------------------------------------------
#   WHAT   Poll the pool until this host shows Available, then return what was built.
#   WHY    The DSC extension succeeding means the agent installed, not that it
#          finished registering. Available is the only status that means a user
#          could connect right now. If the host registers but sits in Unavailable
#          for 5 minutes, the wait restarts the VM once: a fresh agent that ran its
#          first health checks before the join settled is cured by a reboot.
if ($WhatIfPreference) {
    Write-Verbose 'WhatIf run. Nothing created, nothing to verify.'
    return
}
$sessionHost = Wait-AvdSessionHostStatus -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName `
    -Name $VMName -Status 'Available' -TimeoutMinutes $TimeoutMinutes -RestartVmAfterMinutes 5 -Verbose:$verbose

[pscustomobject]@{
    VMName       = $VMName
    SessionHost  = $sessionHost.Name
    Status       = $sessionHost.Status
    HostPool     = $HostPoolName
    ImageSource  = $image.Source
    Image        = $image.Label
    ImageVersion = $image.Version
    ImageId      = $image.Id
    PrivateIp    = $nic.IpConfigurations[0].PrivateIpAddress
    JoinType     = $JoinType
}
#endregion
