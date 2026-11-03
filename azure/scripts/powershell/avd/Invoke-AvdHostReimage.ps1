<#
.SYNOPSIS
    Replaces a session host with a fresh build from a gallery image version.
.DESCRIPTION
    The AVD equivalent of "reimage" in Nerdio:

      1. Read the existing VM (size, NIC, subnet, tags, security type) so the rebuild matches
      2. Drain the host
      3. Message active users, wait for the host to empty (log off stragglers with -Force)
      4. Remove the session host from the pool
      5. Delete the VM and its OS disk. The NIC is kept so the IP survives.
      6. Call New-AvdSessionHost.ps1 with the same name and the new image

    Everything before step 4 is reversible with Set-AvdHostDrain.ps1 -Action DrainOff.
    From step 5 on, the only way back is this script finishing.
.PARAMETER SubscriptionId
    Subscription containing the host pool and VM.
.PARAMETER ResourceGroupName
    Resource group of the host pool.
.PARAMETER HostPoolName
    Host pool name.
.PARAMETER SessionHostName
    VM name, FQDN, or 'pool/fqdn' of the host to replace.
.PARAMETER ImageSource
    Gallery (default) or Marketplace. See New-AvdSessionHost.ps1.
.PARAMETER GalleryResourceGroupName
    Resource group of the Compute Gallery. Required for Gallery.
.PARAMETER GalleryName
    Compute Gallery name. Required for Gallery.
.PARAMETER GalleryImageDefinitionName
    Image definition inside the gallery. Required for Gallery.
.PARAMETER GalleryImageVersion
    Specific version or 'latest'. Default latest.
.PARAMETER ImagePublisher
    Marketplace publisher. Default MicrosoftWindowsDesktop.
.PARAMETER ImageOffer
    Marketplace offer. Default office-365.
.PARAMETER ImageSku
    Marketplace SKU. Default win11-25h2-avd-m365.
.PARAMETER ImageVersion
    Marketplace version or 'latest'. Default latest.
.PARAMETER UserGroupObjectId
    Entra group to grant Virtual Machine User Login on the rebuilt VM (EntraId only).
.PARAMETER LocalAdminCredential
    Local administrator for the new VM.
.PARAMETER JoinType
    ActiveDirectory or EntraId. Must match how the pool is set up.
.PARAMETER DomainName
    AD domain FQDN. Required for ActiveDirectory.
.PARAMETER DomainJoinCredential
    Domain join account. Required for ActiveDirectory.
.PARAMETER OUPath
    OU for the computer object. Optional.
.PARAMETER FsLogixProfileShare
    UNC path of the profile share, if FSLogix should be configured on the new host.
.PARAMETER DrainTimeoutMinutes
    How long to wait for users to leave after the message. Default 30.
.PARAMETER MessageBody
    What users see. Default tells them the host restarts in DrainTimeoutMinutes.
.PARAMETER Force
    Log off anyone still connected when the drain timeout expires. Without it the
    script stops, leaving the host drained but intact.
.PARAMETER TimeoutMinutes
    How long to wait for the new host to show Available. Default 20.
.EXAMPLE
    ./Invoke-AvdHostReimage.ps1 -SubscriptionId <sub> -ResourceGroupName rg-avd-lab -HostPoolName hp-lab `
        -SessionHostName avd-lab-01 -GalleryResourceGroupName rg-images -GalleryName gal_lab `
        -GalleryImageDefinitionName win11-avd -LocalAdminCredential (Get-Credential) `
        -JoinType ActiveDirectory -DomainName corp.example -DomainJoinCredential (Get-Credential) -Force -Verbose
.NOTES
    Requires: Az.Accounts, Az.Compute, Az.Network, Az.Resources, Az.DesktopVirtualization
    Status:   Untested
    Roles:    Contributor on the host pool and VM resource groups. Reader on the gallery.
#>

#region 1. Parameters ---------------------------------------------------------
#   WHAT   Which host to replace, which image to use, and the credentials the rebuild
#          needs. VM size, subnet, tags, and security type are read from the existing
#          VM, not passed in.
#   WHY    A reimage should produce the same host with a new OS. Reading the
#          existing settings makes drift impossible.
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$HostPoolName,

    [Parameter(Mandatory)]
    [string]$SessionHostName,

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

    [Parameter()]
    [string]$UserGroupObjectId,

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
    [string]$FsLogixProfileShare,

    [Parameter()]
    [int]$DrainTimeoutMinutes = 30,

    [Parameter()]
    [string]$MessageBody,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [int]$TimeoutMinutes = 20
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Strict mode, fail fast, modules, context, resolve the host and its VM.
#   WHY    ConfirmImpact High means PowerShell prompts before the destructive steps
#          unless you pass -Confirm:$false. -Force here only means "log off users";
#          it does not skip that prompt, on purpose.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($JoinType -eq 'EntraId') {
    throw 'Entra-joined reimage is disabled until device ownership can be verified before destruction. No host has been drained, deleted, or rebuilt.'
}

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AvdHelpers' 'AvdHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AvdBuild' 'AvdBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId

if ($JoinType -eq 'ActiveDirectory' -and (-not $DomainName -or -not $DomainJoinCredential)) {
    throw 'JoinType ActiveDirectory requires -DomainName and -DomainJoinCredential.'
}
if ($ImageSource -eq 'Gallery' -and (-not $GalleryResourceGroupName -or -not $GalleryName -or -not $GalleryImageDefinitionName)) {
    throw 'ImageSource Gallery requires -GalleryResourceGroupName, -GalleryName and -GalleryImageDefinitionName. Or use -ImageSource Marketplace.'
}
if (-not $MessageBody) {
    $MessageBody = "This desktop will be restarted for maintenance in $DrainTimeoutMinutes minutes. Please save your work and sign out."
}

$sessionHost = Get-AvdSessionHostInfo -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -Name $SessionHostName
if (-not $sessionHost) {
    throw "Session host '$SessionHostName' not found in host pool $HostPoolName."
}
if (-not $sessionHost.VmResourceId) {
    throw "Session host $($sessionHost.Name) has no VM resource ID. Cannot locate the VM to replace."
}
#endregion

#region 3. Capture the existing VM -------------------------------------------
#   WHAT   Everything New-AvdSessionHost.ps1 needs that we are not asking the caller for.
#   WHY    The session host object only knows the VM's ARM ID. Get-AzVM gives size,
#          tags, security profile, and the NIC. The NIC gives the subnet. All of this
#          is captured before anything is deleted.
#   GOTCHA A VM created outside this repo may not have a NIC named <vm>-nic. The
#          rebuild uses the existing NIC's subnet but New-AvdSessionHost.ps1 looks for
#          <vm>-nic by name, so a differently named NIC is left orphaned and a new one
#          is created. Clean it up by hand if that happens.
$vmResource = Get-AzResource -ResourceId $sessionHost.VmResourceId
$vm = Get-AzVM -ResourceGroupName $vmResource.ResourceGroupName -Name $vmResource.Name
$vmRg = $vm.ResourceGroupName
$vmName = $vm.Name

$nic = Get-AzResource -ResourceId $vm.NetworkProfile.NetworkInterfaces[0].Id |
    ForEach-Object { Get-AzNetworkInterface -ResourceGroupName $_.ResourceGroupName -Name $_.Name }
$subnetId = $nic.IpConfigurations[0].Subnet.Id

$osDisk = Get-AzResource -ResourceId $vm.StorageProfile.OsDisk.ManagedDisk.Id

$securityType = if ($vm.SecurityProfile -and $vm.SecurityProfile.SecurityType) { $vm.SecurityProfile.SecurityType } else { 'Standard' }
$tags = if ($vm.Tags) { $vm.Tags } else { @{} }

Write-Verbose "Replacing $vmName ($($vm.HardwareProfile.VmSize), $securityType) in $vmRg. OS disk $($osDisk.Name)."
#endregion

#region 4. Drain and empty ----------------------------------------------------
#   WHAT   Block new sessions, warn the people already on, wait, then log off whoever
#          is left if -Force.
#   WHY    Deleting a VM with active sessions loses unsaved work. Drain plus a timed
#          warning is the polite path. The timeout is the hard deadline.
#   GOTCHA Without -Force, a user who ignores the warning stops the whole reimage.
#          The host stays drained. Re-run with -Force, or DrainOff to give it back.
Set-AvdSessionHostDrain -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -SessionHostName $sessionHost.Name -Enabled $true

$active = @(Send-AvdUserMessage -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -SessionHostName $sessionHost.Name `
    -Title 'Maintenance' -Body $MessageBody)
if ($active.Count -gt 0 -and -not $WhatIfPreference) {
    Write-Verbose "Messaged $($active.Count) user(s). Waiting up to $DrainTimeoutMinutes minutes for the host to empty."
    $empty = Wait-AvdSessionHostEmpty -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName `
        -SessionHostName $sessionHost.Name -TimeoutMinutes $DrainTimeoutMinutes -Verbose:($VerbosePreference -eq 'Continue')
    if (-not $empty) {
        if (-not $Force) {
            throw "Host $($sessionHost.Name) still has sessions after $DrainTimeoutMinutes minutes. Re-run with -Force to log them off, or -Action DrainOff to cancel."
        }
        $null = Remove-AvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -SessionHostName $sessionHost.Name -Force
    }
}
#endregion

#region 5. Remove from pool and delete ----------------------------------------
#   WHAT   Unregister the session host, delete the VM, delete the OS disk.
#   WHY    Order matters. Removing the session host object first stops the broker
#          from routing to a VM that is about to vanish. The OS disk is a separate
#          resource that Remove-AzVM does not delete. The NIC is kept on purpose.
#   GOTCHA This is the point of no return. Everything above here can be undone.
if ($PSCmdlet.ShouldProcess($vmName, "Remove from pool $HostPoolName, delete VM and OS disk $($osDisk.Name)")) {
    Write-Verbose "Removing session host $($sessionHost.Name) from $HostPoolName."
    $null = Remove-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -Name $sessionHost.Name -Force

    Write-Verbose "Deleting VM $vmName."
    $null = Remove-AzVM -ResourceGroupName $vmRg -Name $vmName -Force

    Write-Verbose "Deleting OS disk $($osDisk.Name)."
    $null = Remove-AzDisk -ResourceGroupName $osDisk.ResourceGroupName -DiskName $osDisk.Name -Force
}
#endregion

#region 6. Rebuild ------------------------------------------------------------
#   WHAT   Call New-AvdSessionHost.ps1 with the captured settings and the new image.
#   WHY    One build path. If the build script changes, reimage gets the change for
#          free. The registration token is fetched fresh so an expired one never
#          sneaks in.
#   GOTCHA Under -WhatIf the old VM still exists, so the build script would refuse
#          to run. The call is skipped and the parameters are shown instead.
$token = Get-AvdRegistrationToken -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName

$buildParams = @{
    SubscriptionId             = $SubscriptionId
    ResourceGroupName          = $vmRg
    HostPoolName               = $HostPoolName
    HostPoolResourceGroupName  = $ResourceGroupName
    RegistrationToken          = $token.Token
    VMName                     = $vmName
    VMSize                     = $vm.HardwareProfile.VmSize
    Location                   = $vm.Location
    SubnetId                   = $subnetId
    ImageSource                = $ImageSource
    GalleryImageVersion        = $GalleryImageVersion
    ImagePublisher             = $ImagePublisher
    ImageOffer                 = $ImageOffer
    ImageSku                   = $ImageSku
    ImageVersion               = $ImageVersion
    LocalAdminCredential       = $LocalAdminCredential
    JoinType                   = $JoinType
    SecurityType               = $securityType
    Tags                       = $tags
    TimeoutMinutes             = $TimeoutMinutes
    Verbose                    = ($VerbosePreference -eq 'Continue')
}
if ($GalleryResourceGroupName)   { $buildParams.GalleryResourceGroupName = $GalleryResourceGroupName }
if ($GalleryName)                { $buildParams.GalleryName = $GalleryName }
if ($GalleryImageDefinitionName) { $buildParams.GalleryImageDefinitionName = $GalleryImageDefinitionName }
if ($UserGroupObjectId)          { $buildParams.UserGroupObjectId = $UserGroupObjectId }
if ($DomainName)           { $buildParams.DomainName = $DomainName }
if ($DomainJoinCredential) { $buildParams.DomainJoinCredential = $DomainJoinCredential }
if ($OUPath)               { $buildParams.OUPath = $OUPath }
if ($FsLogixProfileShare)  { $buildParams.FsLogixProfileShare = $FsLogixProfileShare }

if ($WhatIfPreference) {
    Write-Verbose "WhatIf: would rebuild $vmName with New-AvdSessionHost.ps1 ($ImageSource image)."
    return
}

& (Join-Path $PSScriptRoot 'New-AvdSessionHost.ps1') @buildParams
#endregion
