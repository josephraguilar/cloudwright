#region Module setup ----------------------------------------------------------
#   WHAT   The image cycle for AVD and Windows 365: a builder VM from a marketplace
#          image, you install apps on it, sysprep generalizes it, a version is
#          captured into a Compute Gallery definition (AVD) and, if wanted, a
#          managed image is made from it (Windows 365 takes only those).
#   WHY    Session hosts built from a gallery version start with the apps in,
#          which beats installing on every host. The gallery keeps versions, so
#          the previous one is there if the new one is bad.
#   GOTCHA Sysprep is one-way: the builder VM cannot boot again afterwards, and
#          Azure marks it Generalized. Use a VM made for the purpose, never a
#          server or a session host. Nothing here deletes the builder VM, a
#          version or a definition; clean-up happens in the portal.
#          A definition's security type and generation must match the VM:
#          Trusted Launch VMs (the default here) need a TrustedLaunch, V2 definition.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
#endregion

#region Lookups ---------------------------------------------------------------
function Split-ImgResourceId {
    param([Parameter(Mandatory)] [string]$Id)
    $p = $Id -split '/'
    # .../resourceGroups/<rg>/providers/Microsoft.Compute/galleries/<g>/images/<d>/versions/<v>
    [pscustomobject]@{
        ResourceGroupName = $p[4]
        GalleryName       = $(if ($p.Count -ge 9) { $p[8] } else { $null })
        DefinitionName    = $(if ($p.Count -ge 11) { $p[10] } else { $null })
        VersionName       = $(if ($p.Count -ge 13) { $p[12] } else { $null })
        Name              = $p[-1]
    }
}

function Get-GalleryInfo {
    <#
    .SYNOPSIS
        Compute Galleries as flat rows.
    #>
    [CmdletBinding()]
    param([Parameter()] [string]$ResourceGroupName)
    $g = if ($ResourceGroupName) { @(Get-AzGallery -ResourceGroupName $ResourceGroupName) } else { @(Get-AzGallery) }
    foreach ($x in $g | Sort-Object ResourceGroupName, Name) {
        $defs = @(Get-AzGalleryImageDefinition -ResourceGroupName $x.ResourceGroupName -GalleryName $x.Name -ErrorAction SilentlyContinue)
        [pscustomobject]@{ Name = $x.Name; ResourceGroupName = $x.ResourceGroupName; Location = $x.Location; Definitions = $defs.Count; Id = $x.Id }
    }
}

function Get-GalleryImageInfo {
    <#
    .SYNOPSIS
        Image definitions of one gallery (or every gallery) with their latest version.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [string]$ResourceGroupName,
        [Parameter()] [string]$GalleryName
    )
    $galleries = if ($GalleryName) { @(Get-AzGallery -ResourceGroupName $ResourceGroupName -Name $GalleryName) } else { @(Get-AzGallery) }
    foreach ($g in $galleries) {
        foreach ($d in @(Get-AzGalleryImageDefinition -ResourceGroupName $g.ResourceGroupName -GalleryName $g.Name) | Sort-Object Name) {
            $versions = @(Get-AzGalleryImageVersion -ResourceGroupName $g.ResourceGroupName -GalleryName $g.Name -GalleryImageDefinitionName $d.Name -ErrorAction SilentlyContinue)
            $latest = $versions | Where-Object { "$($_.ProvisioningState)" -eq 'Succeeded' } | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
            $sec = @($d.Features | Where-Object { $_.Name -eq 'SecurityType' } | ForEach-Object { $_.Value }) | Select-Object -First 1
            [pscustomobject]@{
                Name              = $d.Name
                Gallery           = $g.Name
                ResourceGroupName = $g.ResourceGroupName
                OsState           = "$($d.OsState)"
                Generation        = "$($d.HyperVGeneration)"
                SecurityType      = $(if ($sec) { $sec } else { 'Standard' })
                Source            = "$($d.Identifier.Publisher)/$($d.Identifier.Offer)/$($d.Identifier.Sku)"
                Versions          = $versions.Count
                Latest            = $(if ($latest) { $latest.Name } else { '' })
                Location          = $d.Location
                Id                = $d.Id
            }
        }
    }
}

function Get-GalleryImageVersionInfo {
    <#
    .SYNOPSIS
        Versions of one image definition, newest first, with state and regions.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$DefinitionId)
    $r = Split-ImgResourceId $DefinitionId
    foreach ($v in @(Get-AzGalleryImageVersion -ResourceGroupName $r.ResourceGroupName -GalleryName $r.GalleryName -GalleryImageDefinitionName $r.DefinitionName) | Sort-Object { [version]$_.Name } -Descending) {
        $pp = $v.PublishingProfile
        [pscustomobject]@{
            Version           = $v.Name
            State             = "$($v.ProvisioningState)"
            Published         = $(if ($pp -and $pp.PublishedDate) { $pp.PublishedDate.ToString('yyyy-MM-dd HH:mm') } else { '' })
            ExcludeFromLatest = $(if ($pp) { [bool]$pp.ExcludeFromLatest } else { $false })
            Regions           = $(if ($pp -and $pp.TargetRegions) { (@($pp.TargetRegions | ForEach-Object { "$($_.Name) x$($_.RegionalReplicaCount)" }) -join ', ') } else { '' })
            SourceVm          = $(if ($v.StorageProfile -and $v.StorageProfile.Source -and $v.StorageProfile.Source.Id) { ($v.StorageProfile.Source.Id -split '/')[-1] } else { '' })
            Id                = $v.Id
        }
    }
}

function Get-ManagedImageInfo {
    <#
    .SYNOPSIS
        Managed images (Microsoft.Compute/images): what Windows 365 uploads from.
    #>
    [CmdletBinding()]
    param()
    foreach ($i in @(Get-AzImage) | Sort-Object ResourceGroupName, Name) {
        [pscustomobject]@{ Name = $i.Name; ResourceGroupName = $i.ResourceGroupName; Location = $i.Location; Generation = "$($i.HyperVGeneration)"; Source = $(if ($i.SourceVirtualMachine) { ($i.SourceVirtualMachine.Id -split '/')[-1] } else { '' }); Id = $i.Id }
    }
}

function Get-GalleryMarketplaceCatalog {
    <#
    .SYNOPSIS
        Marketplace starting points for a builder VM: Windows 11 multi-session with
        and without Microsoft 365 apps (AVD), Windows 11 Enterprise (Windows 365),
        and Windows Server. Value is publisher:offer:sku.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Location)
    $rows = [System.Collections.Generic.List[object]]::new()
    $sources = @(
        @{ Pub = 'MicrosoftWindowsDesktop'; Offer = 'office-365'; Pattern = '^win11-\d\dh\d-avd-m365$'; Label = 'Windows 11 multi-session + Microsoft 365 apps {0}  (AVD)' }
        @{ Pub = 'MicrosoftWindowsDesktop'; Offer = 'windows-11'; Pattern = '^win11-\d\dh\d-avd$'; Label = 'Windows 11 multi-session {0}  (AVD)' }
        @{ Pub = 'MicrosoftWindowsDesktop'; Offer = 'windows-11'; Pattern = '^win11-\d\dh\d-ent$'; Label = 'Windows 11 Enterprise {0}  (Windows 365, personal AVD)' }
        @{ Pub = 'MicrosoftWindowsServer'; Offer = 'WindowsServer'; Pattern = '^20(22|25)-datacenter-azure-edition$'; Label = 'Windows Server {0} Datacenter Azure Edition' }
    )
    foreach ($s in $sources) {
        $skus = @(Get-AzVMImageSku -Location $Location -PublisherName $s.Pub -Offer $s.Offer -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Skus | Where-Object { $_ -match $s.Pattern } | Sort-Object -Descending | Select-Object -First 3)
        foreach ($k in $skus) {
            $tag = if ($k -match '(\d\dh\d)') { $Matches[1].ToUpper() } elseif ($k -match '^(20\d\d)') { $Matches[1] } else { $k }
            $rows.Add([pscustomobject]@{ Value = "$($s.Pub):$($s.Offer):$k"; Label = ($s.Label -f $tag) })
        }
    }
    return $rows
}

function New-GalleryVersionNumber {
    <#
    .SYNOPSIS
        A version name from the date and time, for example 2026.1017.1430. Gallery
        versions must be three whole numbers; this keeps them sortable.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a string; changes nothing.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()] [datetime]$At = (Get-Date))
    return '{0}.{1}.{2}' -f $At.Year, [int]$At.ToString('MMdd'), [int]$At.ToString('HHmm')
}
#endregion

#region Create ----------------------------------------------------------------
function New-GalleryResource {
    <#
    .SYNOPSIS
        A Compute Gallery. Returns the existing one untouched if the name is taken.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9_.]{1,80}$')] [string]$Name,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter()] [string]$Description
    )
    $g = Get-AzGallery -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
    if ($g) { Write-Verbose "Gallery $Name exists."; return $g }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Create Compute Gallery')) { return }
    $p = @{ ResourceGroupName = $ResourceGroupName; Name = $Name; Location = $Location }
    if ($Description) { $p.Description = $Description }
    Write-Verbose "Creating gallery $Name."
    return New-AzGallery @p
}

function New-GalleryImageDefinitionResource {
    <#
    .SYNOPSIS
        An image definition: Windows, generalized, Gen2, Trusted Launch by default.
        Returns the existing one untouched if the name is taken.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$GalleryName,
        [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9_.-]{1,80}$')] [string]$Name,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter()] [string]$Publisher = 'Toolbox',
        [Parameter()] [string]$Offer = 'Desktop',
        [Parameter()] [string]$Sku,
        [Parameter()] [ValidateSet('TrustedLaunch', 'Standard')] [string]$SecurityType = 'TrustedLaunch',
        [Parameter()] [ValidateSet('Generalized', 'Specialized')] [string]$OsState = 'Generalized',
        [Parameter()] [string]$Description
    )
    $d = Get-AzGalleryImageDefinition -ResourceGroupName $ResourceGroupName -GalleryName $GalleryName -Name $Name -ErrorAction SilentlyContinue
    if ($d) { Write-Verbose "Definition $Name exists."; return $d }
    if (-not $Sku) { $Sku = $Name }
    if (-not $PSCmdlet.ShouldProcess("$GalleryName/$Name", "Create $OsState image definition ($SecurityType, Gen2)")) { return }
    $p = @{
        ResourceGroupName = $ResourceGroupName; GalleryName = $GalleryName; Name = $Name; Location = $Location
        Publisher = $Publisher; Offer = $Offer; Sku = $Sku; OsType = 'Windows'; OsState = $OsState; HyperVGeneration = 'V2'
    }
    if ($SecurityType -eq 'TrustedLaunch') { $p.Feature = @(@{ Name = 'SecurityType'; Value = 'TrustedLaunch' }) }
    if ($Description) { $p.Description = $Description }
    Write-Verbose "Creating image definition $GalleryName/$Name."
    return New-AzGalleryImageDefinition @p
}

function New-GalleryBuilderVm {
    <#
    .SYNOPSIS
        A VM to build an image on: marketplace image, no domain join, no AVD agent,
        a NIC in the given subnet, no public IP (use Generate RDP to reach it).
    .PARAMETER ImageKey
        publisher:offer:sku from Get-GalleryMarketplaceCatalog.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [ValidateLength(1, 15)] [string]$VMName,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string]$SubnetId,
        [Parameter(Mandatory)] [string]$ImageKey,
        [Parameter(Mandatory)] [pscredential]$LocalAdminCredential,
        [Parameter()] [string]$VMSize = 'Standard_D4s_v5',
        [Parameter()] [ValidateSet('TrustedLaunch', 'Standard')] [string]$SecurityType = 'TrustedLaunch'
    )
    if (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction SilentlyContinue) { throw "VM $VMName already exists in $ResourceGroupName." }
    $parts = $ImageKey -split ':'
    if ($parts.Count -ne 3) { throw "ImageKey '$ImageKey' must be publisher:offer:sku." }
    $img = Get-AzVMImage -Location $Location -PublisherName $parts[0] -Offer $parts[1] -Skus $parts[2] | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    if (-not $img) { throw "No versions of $ImageKey in $Location." }
    if (-not $PSCmdlet.ShouldProcess($VMName, "Create image builder VM ($VMSize) from $($parts[2]) $($img.Version)")) { return }
    $tags = @{ purpose = 'image-builder' }
    $nicName = "$VMName-nic"
    $nic = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $nicName -ErrorAction SilentlyContinue
    if (-not $nic) { Write-Verbose "Creating NIC $nicName."; $nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName -Location $Location -SubnetId $SubnetId -Tag $tags }
    $cfg = @{ VMName = $VMName; VMSize = $VMSize }
    if ($SecurityType -eq 'TrustedLaunch') { $cfg.SecurityType = 'TrustedLaunch' }
    if ($parts[0] -eq 'MicrosoftWindowsDesktop') { $cfg.LicenseType = 'Windows_Client' }
    $vm = New-AzVMConfig @cfg
    $vm = Set-AzVMOperatingSystem -VM $vm -Windows -ComputerName $VMName -Credential $LocalAdminCredential -ProvisionVMAgent
    $vm = Set-AzVMSourceImage -VM $vm -PublisherName $parts[0] -Offer $parts[1] -Skus $parts[2] -Version $img.Version
    $vm = Add-AzVMNetworkInterface -VM $vm -Id $nic.Id
    $vm = Set-AzVMOSDisk -VM $vm -Name "$VMName-osdisk" -CreateOption FromImage -StorageAccountType Premium_LRS
    $vm = Set-AzVMBootDiagnostic -VM $vm -Enable
    if ($SecurityType -eq 'TrustedLaunch') { $vm = Set-AzVMUefi -VM $vm -EnableVtpm $true -EnableSecureBoot $true }
    Write-Verbose "Creating builder VM $VMName. Install apps on it, then capture."
    $null = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vm -Tag $tags -DisableBginfoExtension
    $nic = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $nicName
    [pscustomobject]@{ VMName = $VMName; ResourceGroupName = $ResourceGroupName; PrivateIp = $nic.IpConfigurations[0].PrivateIpAddress; Image = "$ImageKey $($img.Version)"; SecurityType = $SecurityType }
}

function Get-ImgVmPowerState {
    param([string]$ResourceGroupName, [string]$VMName)
    $s = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status
    return (@($s.Statuses | Where-Object { $_.Code -like 'PowerState/*' }) | Select-Object -First 1).Code
}

function Invoke-GalleryVmSysprep {
    <#
    .SYNOPSIS
        Sysprep (generalize, OOBE, shut down) inside a builder VM, wait for it to
        stop, deallocate it and mark it Generalized in Azure. One-way: the VM
        cannot boot again afterwards.
    .PARAMETER TimeoutMinutes
        How long to wait for sysprep to shut the VM down.
    .PARAMETER AllowUntaggedVm
        Sysprep a VM that New-GalleryBuilderVm did not make (no purpose=image-builder
        tag). Without it such a VM is refused, so a typo cannot hit a server.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter()] [int]$TimeoutMinutes = 30,
        [Parameter()] [switch]$AllowUntaggedVm
    )
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
    $isBuilder = $vm.Tags -and $vm.Tags.ContainsKey('purpose') -and $vm.Tags['purpose'] -eq 'image-builder'
    if (-not $isBuilder -and -not $AllowUntaggedVm) {
        throw "$VMName has no purpose=image-builder tag, so it was not made as an image builder. Sysprep makes a VM unbootable; tag it, or pass -AllowUntaggedVm if you are sure."
    }
    $state = Get-ImgVmPowerState -ResourceGroupName $ResourceGroupName -VMName $VMName
    if ($state -ne 'PowerState/running') { throw "$VMName is $state. Start it first: sysprep runs inside the guest." }
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Sysprep and generalize (the VM cannot boot again afterwards)')) { return }
    # The run command only launches sysprep: sysprep shuts the VM down, which would
    # otherwise end the run command as failed.
    $script = @'
$sp = Join-Path $env:WINDIR 'System32\Sysprep\sysprep.exe'
if (Test-Path 'HKLM:\SYSTEM\Setup\Status\SysprepStatus') { Get-ItemProperty 'HKLM:\SYSTEM\Setup\Status\SysprepStatus' | Out-String | Write-Output }
Start-Process -FilePath $sp -ArgumentList '/generalize', '/oobe', '/shutdown', '/mode:vm', '/quiet'
'sysprep started'
'@
    Write-Verbose "Starting sysprep inside $VMName."
    $null = Set-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName -RunCommandName 'toolbox-sysprep' -Location $vm.Location -SourceScript $script -TimeoutInSecond 300
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds 30
        $state = Get-ImgVmPowerState -ResourceGroupName $ResourceGroupName -VMName $VMName
        Write-Verbose "  $VMName is $state."
    } while ($state -notin 'PowerState/stopped', 'PowerState/deallocated' -and (Get-Date) -lt $deadline)
    if ($state -notin 'PowerState/stopped', 'PowerState/deallocated') {
        throw "$VMName did not shut down within $TimeoutMinutes minutes, so sysprep probably failed. Look at C:\Windows\System32\Sysprep\Panther\setupact.log on the VM (common cause: a Store app installed for one user)."
    }
    Write-Verbose "Deallocating $VMName."
    $null = Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force
    Write-Verbose "Marking $VMName as Generalized."
    $null = Set-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Generalized
    [pscustomobject]@{ VMName = $VMName; State = 'Generalized'; Id = $vm.Id }
}

function New-GalleryImageVersionFromVm {
    <#
    .SYNOPSIS
        Capture a generalized VM as a new version of an image definition. The
        capture runs in Azure for 15 to 60 minutes; this returns once the version
        shows up (state Creating), unless -Wait is given.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$DefinitionId,
        [Parameter(Mandatory)] [string]$SourceVmId,
        [Parameter()] [string]$Version = (New-GalleryVersionNumber),
        [Parameter()] [ValidateSet('Standard_LRS', 'Standard_ZRS', 'Premium_LRS')] [string]$StorageAccountType = 'Standard_LRS',
        [Parameter()] [string[]]$ReplicaRegion = @(),
        [Parameter()] [switch]$ExcludeFromLatest,
        [Parameter()] [switch]$Wait
    )
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version '$Version' must be three whole numbers, like 1.0.0." }
    $r = Split-ImgResourceId $DefinitionId
    $def = Get-AzGalleryImageDefinition -ResourceGroupName $r.ResourceGroupName -GalleryName $r.GalleryName -Name $r.DefinitionName
    $vr = Split-ImgResourceId $SourceVmId
    $vm = Get-AzVM -ResourceGroupName $vr.ResourceGroupName -Name $vr.Name -Status
    $generalized = @($vm.Statuses | Where-Object { $_.Code -eq 'OSState/generalized' }).Count -gt 0
    if ("$($def.OsState)" -eq 'Generalized' -and -not $generalized) { throw "$($vr.Name) is not generalized. Run Invoke-GalleryVmSysprep on it first." }
    $regions = @(@($def.Location) + $ReplicaRegion | Where-Object { $_ } | Select-Object -Unique)
    $targets = @($regions | ForEach-Object { @{ Name = $_; ReplicaCount = 1; StorageAccountType = $StorageAccountType } })
    if (-not $PSCmdlet.ShouldProcess("$($r.GalleryName)/$($r.DefinitionName) $Version", "Capture from $($vr.Name) into $($regions -join ', ')")) { return }
    $p = @{
        ResourceGroupName = $r.ResourceGroupName; GalleryName = $r.GalleryName; GalleryImageDefinitionName = $r.DefinitionName
        Name = $Version; Location = $def.Location; SourceImageVMId = $SourceVmId; TargetRegion = $targets
    }
    if ($ExcludeFromLatest) { $p.PublishingProfileExcludeFromLatest = $true }
    if ($Wait) {
        Write-Verbose "Capturing $Version; this takes 15 to 60 minutes."
        $null = New-AzGalleryImageVersion @p
    } else {
        Write-Verbose "Submitting the capture of $Version; it carries on in Azure."
        $job = New-AzGalleryImageVersion @p -AsJob
        $deadline = (Get-Date).AddMinutes(5)
        do {
            Start-Sleep -Seconds 15
            $v = Get-AzGalleryImageVersion -ResourceGroupName $r.ResourceGroupName -GalleryName $r.GalleryName -GalleryImageDefinitionName $r.DefinitionName -Name $Version -ErrorAction SilentlyContinue
            if ($job.State -eq 'Failed') { throw "Capture failed: $(($job | Receive-Job -ErrorAction SilentlyContinue 2>&1 | Out-String).Trim())" }
        } while (-not $v -and (Get-Date) -lt $deadline)
        if (-not $v) { Write-Warning 'The version has not appeared yet. Refresh the versions list in a few minutes.' }
    }
    $v = Get-AzGalleryImageVersion -ResourceGroupName $r.ResourceGroupName -GalleryName $r.GalleryName -GalleryImageDefinitionName $r.DefinitionName -Name $Version -ErrorAction SilentlyContinue
    [pscustomobject]@{ Definition = "$($r.GalleryName)/$($r.DefinitionName)"; Version = $Version; State = $(if ($v) { "$($v.ProvisioningState)" } else { 'Submitted' }); Regions = ($regions -join ', ') }
}

function New-GalleryManagedImage {
    <#
    .SYNOPSIS
        A managed image from a generalized VM. Windows 365 custom images must be
        uploaded from one of these, not from a gallery version.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$SourceVmId,
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name
    )
    $existing = Get-AzImage -ResourceGroupName $ResourceGroupName -ImageName $Name -ErrorAction SilentlyContinue
    if ($existing) { Write-Verbose "Managed image $Name exists."; return $existing }
    $vr = Split-ImgResourceId $SourceVmId
    $vm = Get-AzVM -ResourceGroupName $vr.ResourceGroupName -Name $vr.Name -Status
    if (@($vm.Statuses | Where-Object { $_.Code -eq 'OSState/generalized' }).Count -eq 0) { throw "$($vr.Name) is not generalized. Run Invoke-GalleryVmSysprep on it first." }
    $vmObj = Get-AzVM -ResourceGroupName $vr.ResourceGroupName -Name $vr.Name
    if (-not $PSCmdlet.ShouldProcess($Name, "Create managed image from $($vr.Name)")) { return }
    $cfg = New-AzImageConfig -Location $vmObj.Location -SourceVirtualMachineId $SourceVmId -HyperVGeneration 'V2'
    Write-Verbose "Creating managed image $Name."
    return New-AzImage -Image $cfg -ImageName $Name -ResourceGroupName $ResourceGroupName
}
#endregion

#region Windows 365 -----------------------------------------------------------
#   GOTCHA The Az sign-in's Graph token has no Cloud PC permissions, so Windows 365
#          calls use the Microsoft.Graph.Authentication module and its own consent
#          (CloudPC.ReadWrite.All). The first call opens a browser to consent.
function Connect-W365Graph {
    <#
    .SYNOPSIS
        Make sure a Microsoft Graph session with Cloud PC rights exists, in the
        same tenant as the Az sign-in.
    #>
    [CmdletBinding()]
    param()
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw 'Windows 365 needs the Microsoft.Graph.Authentication module: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $tenant = (Get-AzContext).Tenant.Id
    $ctx = Get-MgContext
    if ($ctx -and $ctx.TenantId -eq $tenant -and @($ctx.Scopes) -contains 'CloudPC.ReadWrite.All') { return $ctx }
    Write-Verbose 'Signing in to Microsoft Graph for Windows 365 (a browser opens the first time).'
    Connect-MgGraph -TenantId $tenant -Scopes 'CloudPC.ReadWrite.All' -NoWelcome -ErrorAction Stop
    return Get-MgContext
}

function Invoke-W365Graph {
    param([string]$Method = 'GET', [string]$Path, [object]$Body)
    $null = Connect-W365Graph
    $uri = "https://graph.microsoft.com/v1.0/$Path"
    $p = @{ Method = $Method; Uri = $uri; OutputType = 'PSObject'; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 8 -Compress); $p.ContentType = 'application/json' }
    return Invoke-MgGraphRequest @p
}

function Get-W365DeviceImageInfo {
    <#
    .SYNOPSIS
        Windows 365 custom images and their upload status.
    #>
    [CmdletBinding()]
    param()
    $r = Invoke-W365Graph -Path 'deviceManagement/virtualEndpoint/deviceImages'
    foreach ($i in @($r.value)) {
        [pscustomobject]@{
            DisplayName = $i.displayName; Version = $i.version; Status = $i.status; Os = $i.operatingSystem; Build = $i.osBuildNumber
            Modified = $i.lastModifiedDateTime; Source = ("$($i.sourceImageResourceId)" -split '/')[-1]; Error = $i.errorCode; Id = $i.id
        }
    }
}

function Get-W365ProvisioningPolicyInfo {
    <#
    .SYNOPSIS
        Windows 365 provisioning policies and the image each one uses.
    #>
    [CmdletBinding()]
    param()
    $r = Invoke-W365Graph -Path 'deviceManagement/virtualEndpoint/provisioningPolicies'
    foreach ($p in @($r.value)) {
        [pscustomobject]@{ DisplayName = $p.displayName; ImageType = $p.imageType; Image = $p.imageDisplayName; Join = (@($p.domainJoinConfigurations | ForEach-Object { $_.domainJoinType }) -join ', '); Id = $p.id }
    }
}

function New-W365DeviceImage {
    <#
    .SYNOPSIS
        Upload a managed image to Windows 365. The upload runs for up to an hour;
        the status shows on Get-W365DeviceImageInfo.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter(Mandatory)] [ValidatePattern('^\d+\.\d+\.\d+$')] [string]$Version,
        [Parameter(Mandatory)] [ValidatePattern('/providers/Microsoft\.Compute/images/')] [string]$ManagedImageId
    )
    if (-not $PSCmdlet.ShouldProcess($DisplayName, "Upload $(($ManagedImageId -split '/')[-1]) to Windows 365")) { return }
    $r = Invoke-W365Graph -Method POST -Path 'deviceManagement/virtualEndpoint/deviceImages' -Body @{ displayName = $DisplayName; version = $Version; sourceImageResourceId = $ManagedImageId }
    [pscustomobject]@{ DisplayName = $DisplayName; Version = $Version; Status = $r.status; Id = $r.id }
}
#endregion
