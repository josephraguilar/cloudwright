#region Module setup ----------------------------------------------------------
#   WHAT   One function per build step. Scripts in avd/ call these in order.
#   WHY    This is the layer a web app would import. Each function does one thing,
#          is idempotent where that makes sense, honours -WhatIf, and returns an
#          object the next step can consume. Nothing here prompts or prints.
#   GOTCHA Requires Az.Compute, Az.Network, Az.Resources, Az.DesktopVirtualization
#          at call time, not import time, so the module loads without Az for tests.
#          $ErrorActionPreference is set HERE, at module scope, because module
#          functions do not inherit the caller's value. Without it a failed Az call
#          inside a function is non-terminating and the script carries on as if the
#          step succeeded (seen on the first real run: the DSC extension failed and
#          the build continued to FSLogix).
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
#endregion

#region Internal helpers ------------------------------------------------------
#   WHAT   Role assignment with an "already there" check. Not exported.
#   WHY    Three public functions grant a role. Get-AzRoleAssignment also returns
#          inherited assignments, so a group with the role at a wider scope counts.
function Grant-AvdRoleAssignment {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$Scope,
        [Parameter(Mandatory)] [string]$ObjectId,
        [Parameter(Mandatory)] [string]$RoleDefinitionName,
        [Parameter()]          [string]$Label = $Scope
    )
    $existing = Get-AzRoleAssignment -ObjectId $ObjectId -Scope $Scope -RoleDefinitionName $RoleDefinitionName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Verbose "'$RoleDefinitionName' already assigned to $ObjectId on $Label."
        return $existing | Select-Object -First 1
    }
    if ($PSCmdlet.ShouldProcess("$ObjectId on $Label", "Assign role '$RoleDefinitionName'")) {
        Write-Verbose "Assigning '$RoleDefinitionName' to $ObjectId on $Label."
        return New-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $RoleDefinitionName -Scope $Scope
    }
}
#endregion

#region Host pool objects -----------------------------------------------------
#   WHAT   The control-plane half of AVD: host pool, application group,
#          workspace, the link between them, and user access.
#   WHY    Each is get-or-create. An existing object is returned untouched so a
#          re-run never reconfigures something tuned by hand.
function New-AvdHostPoolResource {
    <#
    .SYNOPSIS
        Gets or creates an AVD host pool.
    .PARAMETER EntraJoined
        Sets targetisaadjoined:i:1 in the RDP properties so clients on devices
        that are not Entra joined can connect. Creation only.
    .OUTPUTS
        The host pool, or $null under -WhatIf when it would be created.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter()] [ValidateSet('Pooled', 'Personal')] [string]$HostPoolType = 'Pooled',
        [Parameter()] [ValidateSet('BreadthFirst', 'DepthFirst')] [string]$LoadBalancerType = 'BreadthFirst',
        [Parameter()] [ValidateRange(1, 999)] [int]$MaxSessionLimit = 10,
        [Parameter()] [switch]$StartVMOnConnect,
        [Parameter()] [switch]$EntraJoined,
        [Parameter()] [switch]$ValidationEnvironment
    )
    $existing = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Verbose "Host pool $Name exists ($($existing.HostPoolType) / $($existing.LoadBalancerType))."
        return $existing
    }

    # Personal pools must use Persistent; the API rejects anything else.
    $effectiveLoadBalancer = if ($HostPoolType -eq 'Personal') { 'Persistent' } else { $LoadBalancerType }
    $p = @{
        ResourceGroupName     = $ResourceGroupName
        Name                  = $Name
        Location              = $Location
        HostPoolType          = $HostPoolType
        LoadBalancerType      = $effectiveLoadBalancer
        PreferredAppGroupType = 'Desktop'
        MaxSessionLimit       = $MaxSessionLimit
        ValidationEnvironment = $ValidationEnvironment.IsPresent
        StartVMOnConnect      = $StartVMOnConnect.IsPresent
    }
    if ($HostPoolType -eq 'Personal') { $p.PersonalDesktopAssignmentType = 'Automatic' }
    if ($EntraJoined)                 { $p.CustomRdpProperty = 'targetisaadjoined:i:1;' }

    if ($PSCmdlet.ShouldProcess($Name, "Create $HostPoolType host pool ($effectiveLoadBalancer)")) {
        Write-Verbose "Creating host pool $Name ($HostPoolType / $effectiveLoadBalancer)."
        return New-AzWvdHostPool @p
    }
}

function New-AvdApplicationGroupResource {
    <#
    .SYNOPSIS
        Gets or creates a Desktop application group pointed at a host pool.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string]$HostPoolId,
        [Parameter()]          [string]$FriendlyName = 'Desktop'
    )
    $existing = Get-AzWvdApplicationGroup -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Verbose "Application group $Name exists."
        return $existing
    }
    if ($PSCmdlet.ShouldProcess($Name, 'Create desktop application group')) {
        Write-Verbose "Creating desktop application group $Name."
        return New-AzWvdApplicationGroup -ResourceGroupName $ResourceGroupName -Name $Name -Location $Location `
            -HostPoolArmPath $HostPoolId -ApplicationGroupType Desktop -FriendlyName $FriendlyName
    }
}

function New-AvdWorkspaceResource {
    <#
    .SYNOPSIS
        Gets or creates an AVD workspace.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Location
    )
    $existing = Get-AzWvdWorkspace -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Verbose "Workspace $Name exists."
        return $existing
    }
    if ($PSCmdlet.ShouldProcess($Name, 'Create workspace')) {
        Write-Verbose "Creating workspace $Name."
        return New-AzWvdWorkspace -ResourceGroupName $ResourceGroupName -Name $Name -Location $Location
    }
}

function Register-AvdApplicationGroupToWorkspace {
    <#
    .SYNOPSIS
        Links an application group to a workspace if it is not already linked.
    .DESCRIPTION
        An app group that is not registered to a workspace is invisible to users
        even if they have the role on it. -contains is case-insensitive, which
        matters because ARM IDs come back with inconsistent casing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$WorkspaceName,
        [Parameter(Mandatory)] [string]$ApplicationGroupId
    )
    $ws = Get-AzWvdWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction SilentlyContinue
    if ($ws -and ($ws.ApplicationGroupReference -contains $ApplicationGroupId)) {
        Write-Verbose "Application group already registered to $WorkspaceName."
        return
    }
    $agName = ($ApplicationGroupId -split '/')[-1]
    if ($PSCmdlet.ShouldProcess("$agName -> $WorkspaceName", 'Register application group to workspace')) {
        Write-Verbose "Registering $agName to workspace $WorkspaceName."
        $null = Register-AzWvdApplicationGroup -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -ApplicationGroupPath $ApplicationGroupId
    }
}

function Grant-AvdDesktopAccess {
    <#
    .SYNOPSIS
        Grants an Entra group Desktop Virtualization User on an application group.
    .DESCRIPTION
        This role is what makes the desktop appear in a user's feed. The app group
        is the least-privilege scope for it. Needs User Access Administrator.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ApplicationGroupId,
        [Parameter(Mandatory)] [string]$ObjectId
    )
    $null = Grant-AvdRoleAssignment -Scope $ApplicationGroupId -ObjectId $ObjectId -RoleDefinitionName 'Desktop Virtualization User' `
        -Label (($ApplicationGroupId -split '/')[-1])
}
#endregion

#region Image -----------------------------------------------------------------
#   WHAT   Resolve "what image" to an exact version and ID, from a Compute
#          Gallery or the marketplace.
#   WHY    'latest' is resolved here, not by Azure, so callers can record and later
#          pin the exact version. Gallery versions flagged ExcludeFromLatest are
#          skipped. Sort is by [version], not string, so 1.0.10 beats 1.0.9.
function Resolve-AvdImage {
    <#
    .SYNOPSIS
        Resolves a gallery or marketplace image to an exact version.
    .OUTPUTS
        Object with Source, Label, Version, Id, and (marketplace) Publisher/Offer/Sku.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Location,
        [Parameter()] [ValidateSet('Gallery', 'Marketplace')] [string]$ImageSource = 'Gallery',
        [Parameter()] [string]$GalleryResourceGroupName,
        [Parameter()] [string]$GalleryName,
        [Parameter()] [string]$GalleryImageDefinitionName,
        [Parameter()] [string]$GalleryImageVersion = 'latest',
        [Parameter()] [string]$ImagePublisher = 'MicrosoftWindowsDesktop',
        [Parameter()] [string]$ImageOffer = 'office-365',
        [Parameter()] [string]$ImageSku = 'win11-25h2-avd-m365',
        [Parameter()] [string]$ImageVersion = 'latest'
    )
    if ($ImageSource -eq 'Gallery') {
        if (-not $GalleryResourceGroupName -or -not $GalleryName -or -not $GalleryImageDefinitionName) {
            throw 'ImageSource Gallery requires -GalleryResourceGroupName, -GalleryName and -GalleryImageDefinitionName.'
        }
        $image = if ($GalleryImageVersion -eq 'latest') {
            Get-AzGalleryImageVersion -ResourceGroupName $GalleryResourceGroupName -GalleryName $GalleryName -GalleryImageDefinitionName $GalleryImageDefinitionName |
                Where-Object { -not ($_.PublishingProfile -and $_.PublishingProfile.ExcludeFromLatest) } |
                Sort-Object { [version]$_.Name } -Descending |
                Select-Object -First 1
        } else {
            Get-AzGalleryImageVersion -ResourceGroupName $GalleryResourceGroupName -GalleryName $GalleryName -GalleryImageDefinitionName $GalleryImageDefinitionName -Name $GalleryImageVersion
        }
        if (-not $image) { throw "No image version found for $GalleryName/$GalleryImageDefinitionName ($GalleryImageVersion)." }
        return [pscustomobject]@{
            Source = 'Gallery'; Label = "$GalleryImageDefinitionName $($image.Name)"; Version = $image.Name; Id = $image.Id
            Publisher = $null; Offer = $null; Sku = $null
        }
    }

    $image = if ($ImageVersion -eq 'latest') {
        Get-AzVMImage -Location $Location -PublisherName $ImagePublisher -Offer $ImageOffer -Skus $ImageSku |
            Sort-Object { [version]$_.Version } -Descending |
            Select-Object -First 1
    } else {
        Get-AzVMImage -Location $Location -PublisherName $ImagePublisher -Offer $ImageOffer -Skus $ImageSku -Version $ImageVersion
    }
    if (-not $image) { throw "No marketplace image found for $ImagePublisher/$ImageOffer/$ImageSku ($ImageVersion) in $Location. List SKUs with Get-AzVMImageSku." }
    return [pscustomobject]@{
        Source = 'Marketplace'; Label = "$ImageOffer/$ImageSku $($image.Version)"; Version = $image.Version; Id = $image.Id
        Publisher = $ImagePublisher; Offer = $ImageOffer; Sku = $ImageSku
    }
}
#endregion

#region Session host VM -------------------------------------------------------
#   WHAT   NIC, then VM. Two functions because the NIC is deliberately reused on
#          reimage so the host keeps its private IP.
#   WHY    Az.Compute's config pattern: New-AzVMConfig gives an empty object and
#          each Set-/Add- fills a section; nothing hits Azure until New-AzVM.
function New-AvdSessionHostNic {
    <#
    .SYNOPSIS
        Gets or creates the NIC named <VMName>-nic in a subnet.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string]$SubnetId,
        [Parameter()]          [hashtable]$Tags = @{}
    )
    $nicName = "$VMName-nic"
    $nic = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $nicName -ErrorAction SilentlyContinue
    if ($nic) {
        Write-Verbose "Reusing existing NIC $nicName ($($nic.IpConfigurations[0].PrivateIpAddress))."
        return $nic
    }
    if ($PSCmdlet.ShouldProcess($nicName, 'Create network interface')) {
        Write-Verbose "Creating NIC $nicName."
        return New-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName -Location $Location -SubnetId $SubnetId -Tag $Tags
    }
}

function New-AvdSessionHostVm {
    <#
    .SYNOPSIS
        Creates a session host VM from a resolved image. Fails if the VM exists.
    .PARAMETER Image
        Output of Resolve-AvdImage.
    .PARAMETER SystemAssignedIdentity
        Required for Entra ID join.
    .DESCRIPTION
        LicenseType Windows_Client is the Azure Hybrid Benefit flag for Windows
        multi-session; without it you pay for a license M365 already covers.
        Trusted Launch needs SecurityType on the config AND vTPM/Secure Boot via
        Set-AzVMUefi, and a Gen2 image. -DisableBginfoExtension stops New-AzVM
        silently adding BGInfo to Windows VMs.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string]$VMSize,
        [Parameter(Mandatory)] [pscustomobject]$Image,
        [Parameter(Mandatory)] [string]$NicId,
        [Parameter(Mandatory)] [pscredential]$LocalAdminCredential,
        [Parameter()] [ValidateSet('TrustedLaunch', 'Standard')] [string]$SecurityType = 'TrustedLaunch',
        [Parameter()] [ValidateSet('Premium_LRS', 'StandardSSD_LRS', 'Standard_LRS')] [string]$OSDiskType = 'Premium_LRS',
        [Parameter()] [switch]$SystemAssignedIdentity,
        [Parameter()] [hashtable]$Tags = @{}
    )
    if (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction SilentlyContinue) {
        throw "VM $VMName already exists in $ResourceGroupName."
    }
    if (-not $PSCmdlet.ShouldProcess($VMName, "Create $VMSize VM from $($Image.Label)")) { return }

    $cfg = @{ VMName = $VMName; VMSize = $VMSize; LicenseType = 'Windows_Client' }
    if ($SecurityType -eq 'TrustedLaunch') { $cfg.SecurityType = 'TrustedLaunch' }
    if ($SystemAssignedIdentity)           { $cfg.IdentityType = 'SystemAssigned' }

    $vm = New-AzVMConfig @cfg
    $vm = Set-AzVMOperatingSystem -VM $vm -Windows -ComputerName $VMName -Credential $LocalAdminCredential -ProvisionVMAgent -EnableAutoUpdate
    $vm = if ($Image.Source -eq 'Gallery') {
        Set-AzVMSourceImage -VM $vm -Id $Image.Id
    } else {
        Set-AzVMSourceImage -VM $vm -PublisherName $Image.Publisher -Offer $Image.Offer -Skus $Image.Sku -Version $Image.Version
    }
    $vm = Add-AzVMNetworkInterface -VM $vm -Id $NicId
    $vm = Set-AzVMOSDisk -VM $vm -Name "$VMName-osdisk" -CreateOption FromImage -StorageAccountType $OSDiskType
    $vm = Set-AzVMBootDiagnostic -VM $vm -Enable
    if ($SecurityType -eq 'TrustedLaunch') { $vm = Set-AzVMUefi -VM $vm -EnableVtpm $true -EnableSecureBoot $true }

    Write-Verbose "Creating VM $VMName."
    $null = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vm -Tag $Tags -DisableBginfoExtension
    return Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
}
#endregion

#region Catalog lookups for front ends ----------------------------------------
#   WHAT   The data behind the console's and the GUI's pickers: VM sizes decoded
#          from Azure's naming convention, marketplace image SKUs, and Azure's VM
#          credential rules.
#   WHY    Both front ends need the same lists. Keeping them here means the GUI
#          and the console cannot drift.
function Get-AvdVmQuota {
    <#
    .SYNOPSIS
        vCPU quota per VM family in a region for this subscription: Family, Limit,
        Used, Available.
    .DESCRIPTION
        Quota is per family, per region, per subscription, and a new or personal
        subscription often carries 0 for several families. A size whose family has
        0 quota is offered by the catalog and fails only at VM creation with
        OperationNotAllowed, so front ends and the orchestrator check here first.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Location)
    Get-AzVMUsage -Location $Location -ErrorAction Stop |
        Where-Object { $_.Name.Value -like '*Family' } |
        ForEach-Object {
            [pscustomobject]@{
                Family    = $_.Name.Value
                Label     = $_.Name.LocalizedValue
                Limit     = [int]$_.Limit
                Used      = [int]$_.CurrentValue
                Available = [int]$_.Limit - [int]$_.CurrentValue
            }
        }
}

function Test-AvdVmSizeQuota {
    <#
    .SYNOPSIS
        Whether the region has enough family quota to create N VMs of a size.
    .OUTPUTS
        Object with VMSize, Family, CoresEach, Needed, Limit, Used, Available, Ok,
        Message. Message is ready to show a person when Ok is false.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string]$VMSize,
        [Parameter()] [int]$Count = 1
    )
    $sku = Get-AzComputeResourceSku -Location $Location -ErrorAction Stop |
        Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $VMSize } | Select-Object -First 1
    if (-not $sku) { throw "VM size $VMSize is not offered in $Location." }
    $cores = [int](($sku.Capabilities | Where-Object Name -eq 'vCPUs' | Select-Object -First 1).Value)
    $needed = $cores * $Count
    $q = Get-AvdVmQuota -Location $Location | Where-Object Family -eq $sku.Family | Select-Object -First 1
    $limit = if ($q) { $q.Limit } else { 0 }
    $used  = if ($q) { $q.Used } else { 0 }
    $ok = ($limit - $used) -ge $needed
    $message = if ($ok) { "Quota OK: $($sku.Family) in $Location has $($limit - $used) of $limit vCPUs free; $Count x $VMSize needs $needed." }
               else { "Quota: $($sku.Family) in $Location allows $limit vCPUs ($used in use); $Count x $VMSize needs $needed. Request an increase (portal: Subscriptions > Usage + quotas, usually approved in minutes for small numbers) or pick a size from a family that has quota." }
    [pscustomobject]@{
        VMSize = $VMSize; Family = $sku.Family; CoresEach = $cores; Needed = $needed
        Limit = $limit; Used = $used; Available = $limit - $used; Ok = $ok; Message = $message
    }
}

function Get-AvdVmSizeCatalog {
    <#
    .SYNOPSIS
        Every VM size offered in a region, decoded, excluding sizes restricted for
        this subscription, ARM sizes, and sizes without premium disk support.
    .DESCRIPTION
        Standard_[Family][vCPUs][features]_[accelerator]_v[version]
          family D general purpose, E memory, F compute, B burstable, NV GPU, DC confidential
          features a = AMD, p = ARM, s = premium disk, d = local temp disk, l = low memory
    .PARAMETER IncludeNoQuota
        Also return sizes whose family has 0 vCPU quota here. Hidden by default
        because they cannot be created until a quota increase is approved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Location,
        [Parameter()] [switch]$IncludeNoQuota
    )
    $quota = @{}
    try { foreach ($q in Get-AvdVmQuota -Location $Location) { $quota[$q.Family] = $q } }
    catch { Write-Warning "Could not read vCPU quota for ${Location}: $($_.Exception.Message). Sizes are listed without quota." }
    Get-AzComputeResourceSku -Location $Location -ErrorAction Stop |
        Where-Object { $_.ResourceType -eq 'virtualMachines' -and -not $_.Restrictions } |
        ForEach-Object {
            if ($_.Name -match '^Standard_([A-Z]+)(\d+)([a-z]*)(?:_(?!v\d+$)([A-Za-z0-9]+))?(?:_v(\d+))?$') {
                $features = $Matches[3]
                $cap = @{}
                foreach ($c in $_.Capabilities) { $cap[$c.Name] = $c.Value }
                $cpu = if ($cap['CpuArchitectureType'] -eq 'Arm64' -or $features -like '*p*') { 'ARM' } elseif ($features -like '*a*') { 'AMD' } else { 'Intel' }
                $premium = ($cap['PremiumIO'] -eq 'True') -or ($features -like '*s*')
                if ($cpu -eq 'ARM' -or -not $premium) { return }
                $q = if ($_.Family -and $quota.ContainsKey($_.Family)) { $quota[$_.Family] } else { $null }
                $limit = if ($q) { $q.Limit } elseif ($quota.Count -gt 0) { 0 } else { $null }
                if ($null -ne $limit -and $limit -eq 0 -and -not $IncludeNoQuota) { return }
                $quotaText = if ($null -eq $limit) { '' } else { "  quota $($q.Available ?? 0)/$limit vCPU free" }
                [pscustomobject]@{
                    Name           = $_.Name
                    Family         = $Matches[1]
                    QuotaFamily    = $_.Family
                    Features       = $features
                    Accelerator    = $Matches[4]
                    Version        = if ($Matches[5]) { [int]$Matches[5] } else { 1 }
                    Cpu            = $cpu
                    Cores          = [int]($cap['vCPUs'] ?? 0)
                    MemoryGB       = [math]::Round([double]($cap['MemoryGB'] ?? 0))
                    QuotaLimit     = $limit
                    QuotaAvailable = if ($q) { $q.Available } elseif ($null -ne $limit) { 0 } else { $null }
                    Label          = ('{0,-22} {1,2} vCPU, {2,3} GB  {3} {4} v{5}' -f $_.Name, [int]($cap['vCPUs'] ?? 0), [math]::Round([double]($cap['MemoryGB'] ?? 0)), $Matches[1], $cpu, $(if ($Matches[5]) { $Matches[5] } else { 1 })) + $quotaText
                }
            }
        }
}

function Get-AvdMarketplaceImageSku {
    <#
    .SYNOPSIS
        Windows multi-session + Microsoft 365 Apps SKUs available in a region, newest first.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Location)
    $skus = @(Get-AzVMImageSku -Location $Location -PublisherName 'MicrosoftWindowsDesktop' -Offer 'office-365' -ErrorAction Stop |
        Select-Object -ExpandProperty Skus |
        Where-Object { $_ -match '^win1[01]-\d\dh\d-avd-m365$' } |
        Sort-Object -Descending)
    foreach ($s in $skus) {
        $label = if ($s -match '^win(1[01])-(\d\dh\d)-avd-m365$') { "Windows $($Matches[1]) $($Matches[2].ToUpper()) multi-session + Microsoft 365 Apps" } else { $s }
        [pscustomobject]@{ Value = $s; Label = $label }
    }
}

function Test-AvdVmCredentialPolicy {
    <#
    .SYNOPSIS
        Problems with a local admin credential against Azure's Windows VM rules. Empty = OK.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [pscredential]$Credential)
    $UserName = $Credential.UserName
    $Password = $Credential.GetNetworkCredential().Password
    $problems = @()
    $reservedNames = @('administrator', 'admin', 'user', 'user1', 'test', 'user2', 'test1', 'user3', 'admin1', '1', '123', 'a',
                       'actuser', 'adm', 'admin2', 'aspnet', 'backup', 'console', 'david', 'guest', 'john', 'owner', 'root',
                       'server', 'sql', 'support', 'support_388945a0', 'sys', 'test2', 'test3', 'user4', 'user5')
    if ($UserName.ToLowerInvariant() -in $reservedNames) { $problems += "User name '$UserName' is reserved by Azure. Try avdadmin." }
    if ($UserName.Length -gt 20)                           { $problems += 'User name must be 20 characters or fewer.' }
    if ($UserName -match '[\\/"\[\]:|<>+=;,?*@]')          { $problems += 'User name contains a character Azure does not allow.' }
    if ($Password.Length -lt 12 -or $Password.Length -gt 123) { $problems += 'Password must be 12 to 123 characters.' }
    $classes = 0
    if ($Password -cmatch '[a-z]') { $classes++ }
    if ($Password -cmatch '[A-Z]') { $classes++ }
    if ($Password -match '\d')     { $classes++ }
    if ($Password -match '[^A-Za-z0-9]') { $classes++ }
    if ($classes -lt 3) { $problems += 'Password needs at least 3 of: lowercase, uppercase, digit, special character.' }
    $weak = @('abc@123', 'P@$$w0rd', 'P@ssw0rd', 'P@ssword123', 'Pa$$word', 'pass@word1', 'Password!', 'Password1', 'Password22', 'iloveyou!')
    if ($Password -in $weak) { $problems += "That password is on Azure's blocked list." }
    return $problems
}
#endregion

#region Permission preflight --------------------------------------------------
#   WHAT   Compare what the signed-in account can do against what a build needs,
#          at the subscription (and resource group, if it exists), plus the Entra
#          directory roles needed for groups, device records and admin consent.
#   WHY    A missing role otherwise surfaces twenty minutes in, as a confusing
#          AuthorizationFailed on step six. This turns it into a table before step one.
#   GOTCHA Azure RBAC and Entra directory roles are different systems. Owner on the
#          subscription says nothing about whether you can delete a device record.
function Test-AvdBuildPermission {
    <#
    .SYNOPSIS
        Reports whether the signed-in account holds every permission an AVD build needs.
    .PARAMETER ResourceGroupName
        Checked too if it exists; a role on the group counts for group-scoped work.
    .PARAMETER IncludeBackup
        Also require Recovery Services permissions.
    .OUTPUTS
        One row per capability: Capability, Scope, Granted, Required, FixWith.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter()] [string]$ResourceGroupName,
        [Parameter()] [switch]$IncludeBackup
    )
    $rows = [System.Collections.Generic.List[object]]::new()

    # --- Azure RBAC -------------------------------------------------------
    $needs = @(
        @{ Capability = 'Register resource providers';         Action = 'Microsoft.DesktopVirtualization/register/action';          FixWith = 'Contributor on the subscription';           SubscriptionOnly = $true }
        @{ Capability = 'Create resource groups';              Action = 'Microsoft.Resources/subscriptions/resourceGroups/write';    FixWith = 'Contributor on the subscription';           SubscriptionOnly = $true }
        @{ Capability = 'Run Bicep deployments';               Action = 'Microsoft.Resources/deployments/write';                     FixWith = 'Contributor' }
        @{ Capability = 'Create virtual networks';             Action = 'Microsoft.Network/virtualNetworks/write';                   FixWith = 'Network Contributor or Contributor' }
        @{ Capability = 'Create storage accounts';             Action = 'Microsoft.Storage/storageAccounts/write';                   FixWith = 'Storage Account Contributor or Contributor' }
        @{ Capability = 'Read storage account keys (NTFS step)'; Action = 'Microsoft.Storage/storageAccounts/listKeys/action';      FixWith = 'Storage Account Contributor or Contributor' }
        @{ Capability = 'Create host pools';                   Action = 'Microsoft.DesktopVirtualization/hostpools/write';           FixWith = 'Desktop Virtualization Contributor or Contributor' }
        @{ Capability = 'Create application groups';           Action = 'Microsoft.DesktopVirtualization/applicationgroups/write';   FixWith = 'Desktop Virtualization Contributor or Contributor' }
        @{ Capability = 'Create workspaces';                   Action = 'Microsoft.DesktopVirtualization/workspaces/write';          FixWith = 'Desktop Virtualization Contributor or Contributor' }
        @{ Capability = 'Create virtual machines';             Action = 'Microsoft.Compute/virtualMachines/write';                   FixWith = 'Virtual Machine Contributor or Contributor' }
        @{ Capability = 'Install VM extensions (join, agent)'; Action = 'Microsoft.Compute/virtualMachines/extensions/write';        FixWith = 'Virtual Machine Contributor or Contributor' }
        @{ Capability = 'Run commands in VMs (FSLogix, NTFS)'; Action = 'Microsoft.Compute/virtualMachines/runCommand/action';       FixWith = 'Virtual Machine Contributor or Contributor' }
        @{ Capability = 'Assign roles (desktop access, VM login)'; Action = 'Microsoft.Authorization/roleAssignments/write';        FixWith = 'User Access Administrator or Owner (Contributor is NOT enough)' }
    )
    if ($IncludeBackup) {
        $needs += @{ Capability = 'Create backup vaults and policies'; Action = 'Microsoft.RecoveryServices/vaults/write'; FixWith = 'Backup Contributor or Contributor' }
    }

    $subScope = "/subscriptions/$SubscriptionId"
    $subPerms = Get-AzEffectivePermission -Scope $subScope
    $rgPerms = $null
    if ($ResourceGroupName -and (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
        $rgPerms = Get-AzEffectivePermission -Scope "$subScope/resourceGroups/$ResourceGroupName"
    }
    foreach ($n in $needs) {
        $atSub = Test-AzActionAllowed -Action $n.Action -Permissions $subPerms
        $atRg  = if ($rgPerms -and -not $n.SubscriptionOnly) { Test-AzActionAllowed -Action $n.Action -Permissions $rgPerms } else { $false }
        $rows.Add([pscustomobject]@{
            Area       = 'Azure RBAC'
            Capability = $n.Capability
            Granted    = ($atSub -or $atRg)
            Scope      = if ($atSub) { 'subscription' } elseif ($atRg) { 'resource group' } else { '-' }
            Required   = $true
            FixWith    = $n.FixWith
        })
    }

    # --- Entra directory roles ------------------------------------------
    $roles = $null
    try { $roles = @(Get-AzDirectoryRoleMembership) } catch { Write-Verbose "Directory role lookup failed: $($_.Exception.Message)" }
    $dirNeeds = @(
        @{ Capability = 'Create Entra security groups (console "new" group)'; Roles = @('Global Administrator', 'Groups Administrator', 'User Administrator');                                   Required = $false }
        @{ Capability = 'Delete stale Entra device records';               Roles = @('Global Administrator', 'Cloud Device Administrator', 'Intune Administrator');                             Required = $true }
        @{ Capability = 'Grant admin consent (storage Entra Kerberos)';     Roles = @('Global Administrator', 'Privileged Role Administrator', 'Cloud Application Administrator', 'Application Administrator'); Required = $true }
    )
    foreach ($d in $dirNeeds) {
        $has = if ($null -eq $roles) { $null } else { @($roles | Where-Object { $_ -in $d.Roles }).Count -gt 0 }
        $rows.Add([pscustomobject]@{
            Area       = 'Entra ID'
            Capability = $d.Capability
            Granted    = $has
            Scope      = if ($null -eq $has) { 'unknown (Graph lookup failed)' } elseif ($has) { 'directory role' } else { '-' }
            Required   = $d.Required
            FixWith    = 'Directory role: ' + ($d.Roles -join ' or ')
        })
    }
    return $rows
}
#endregion

#region Storage account Entra Kerberos consent -------------------------------
#   WHAT   The "Grant admin consent" click, done through Microsoft Graph.
#   WHY    Enabling Entra Kerberos on a storage account creates a service principal
#          named "[Storage Account] <name>.file.core.windows.net" that needs delegated
#          openid, profile and User.Read on Microsoft Graph, consented for all users.
#          Consent is one Graph object: an oauth2PermissionGrant with consentType
#          AllPrincipals. Creating it is what the portal button does.
#   GOTCHA Needs Global Administrator (or Privileged Role / Cloud Application
#          Administrator). The service principal can take a minute to appear after
#          Entra Kerberos is enabled, so callers retry briefly.
function Grant-AvdStorageKerberosConsent {
    <# .SYNOPSIS
        Refuses tenant-wide consent based only on a service principal display name.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Compatibility entry point always refuses consent before any API call.')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$StorageAccountName,
        [Parameter()] [int]$WaitForPrincipalSeconds = 90
    )
    $null = $WaitForPrincipalSeconds
    throw "Automatic Kerberos consent for '$StorageAccountName' is disabled: display names do not prove application ownership. Verify the storage account's exact service principal in the Azure portal before any separate consent decision."
}

#endregion

#region Storage account Entra app cleanup -------------------------------------
# Compatibility entry point only. Names are not ownership evidence, so directory
# cleanup stays disabled until a reviewed design can bind exact object ids to VMs.
function Remove-AvdStorageKerberosApp {
    <#
    .SYNOPSIS
        Refuses automatic directory cleanup based only on an application display name.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Compatibility entry point always throws, including WhatIf and Confirm calls; it never performs an operation.')]
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string]$StorageAccountName)
    throw "Automatic Entra application cleanup for '$StorageAccountName' is disabled: a display name does not prove ownership. Review the exact application object and its ownership before removing it outside Cloudwright."
}
#endregion

#region Entra device records --------------------------------------------------
# Inspection is supported. Automatic deletion is disabled because unrelated
# devices can share a display name; even one match does not establish ownership.
function Find-AvdEntraDevice {
    <#
    .SYNOPSIS
        Entra ID device objects whose display name matches exactly.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')] [string]$Name)
    $filter = [uri]::EscapeDataString("displayName eq '$($Name.Replace("'", "''"))'")
    $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=$filter"
    $resp = Invoke-AzRestMethod -Method GET -Uri $uri -ErrorAction Stop
    if ($resp.StatusCode -ne 200) {
        throw "Graph device lookup for '$Name' returned HTTP $($resp.StatusCode): $($resp.Content)"
    }
    $devices = @(($resp.Content | ConvertFrom-Json).value)
    if (@($devices | Where-Object displayName -ine $Name).Count) { throw 'Graph returned a device with a different display name; refusing the result.' }
    return $devices
}

function Remove-AvdEntraDevice {
    <#
    .SYNOPSIS
        Refuses automatic directory cleanup based only on a device display name.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Compatibility entry point always throws, including WhatIf and Confirm calls; it never performs an operation.')]
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string]$Name)
    throw "Automatic Entra device cleanup for '$Name' is disabled: a display name does not prove ownership. Review the exact device object and its ownership before removing it outside Cloudwright."
}

function Test-AvdEntraJoin {
    <#
    .SYNOPSIS
        True if dsregcmd inside the VM reports AzureAdJoined : YES.
    .DESCRIPTION
        The only trustworthy check. The AADLoginForWindows extension reports
        ProvisioningState Succeeded even when the join failed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$VMName
    )
    $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName -CommandId 'RunPowerShellScript' `
        -ScriptString 'dsregcmd /status | Select-String "AzureAdJoined"'
    $out = ($result.Value | ForEach-Object Message) -join "`n"
    Write-Verbose "  [host] $($out.Trim())"
    return ($out -match 'AzureAdJoined\s*:\s*YES')
}

function Get-AvdEntraJoinLogTail {
    <#
    .SYNOPSIS
        Last lines of the AADLoginForWindows handler log inside the VM, for error messages.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter()] [int]$Lines = 15
    )
    $script = "Get-ChildItem 'C:\WindowsAzure\Logs\Plugins\Microsoft.Azure.ActiveDirectory.AADLoginForWindows' -Recurse -Filter *.log | Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content -Tail $Lines | Select-String 'error|fail|subcode|message' "
    $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName -CommandId 'RunPowerShellScript' -ScriptString $script
    return (($result.Value | ForEach-Object Message) -join "`n").Trim()
}
#endregion

#region Join, agent, FSLogix, login role --------------------------------------
#   WHAT   The in-guest steps, each one extension or Run Command.
#   WHY    Order matters and the scripts enforce it: join before agent (the agent
#          registers under the domain identity), agent before FSLogix (so a failed
#          agent install does not waste time on config). Azure runs extensions on a
#          VM serially, so the AD join reboot is waited for automatically.
function Join-AvdSessionHost {
    <#
    .SYNOPSIS
        Joins a VM to Active Directory (JsonADDomainExtension) or Entra ID (AADLoginForWindows).
    .DESCRIPTION
        JoinOption 3 = join + create the computer account if missing. The AD
        extension reboots the VM. The Entra path restarts the VM explicitly after the
        extension so device registration settles before the AVD agent installs.
        Entra join needs a system-assigned identity on the VM and
        targetisaadjoined:i:1 on the host pool.
    .PARAMETER RemoveStaleEntraDevice
        Retired. Supplying this switch stops before any operation because directory
        ownership cannot be established from a display name.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [ValidateSet('ActiveDirectory', 'EntraId')] [string]$JoinType,
        [Parameter()] [string]$DomainName,
        [Parameter()] [pscredential]$DomainJoinCredential,
        [Parameter()] [string]$OUPath,
        [Parameter()] [switch]$RemoveStaleEntraDevice
    )
    if ($RemoveStaleEntraDevice) { throw 'RemoveStaleEntraDevice is disabled: automatic directory cleanup cannot establish ownership by name.' }
    if ($JoinType -eq 'ActiveDirectory') {
        if (-not $DomainName -or -not $DomainJoinCredential) { throw 'JoinType ActiveDirectory requires -DomainName and -DomainJoinCredential.' }
        if ($PSCmdlet.ShouldProcess($VMName, "Join Active Directory domain $DomainName")) {
            $p = @{
                ResourceGroupName = $ResourceGroupName; VMName = $VMName; Name = 'ADDomainJoin'; Location = $Location
                DomainName = $DomainName; Credential = $DomainJoinCredential; JoinOption = 3; Restart = $true
            }
            if ($OUPath) { $p.OUPath = $OUPath }
            Write-Verbose "Joining $VMName to $DomainName."
            $null = Set-AzVMADDomainExtension @p
        }
        return
    }
    if ($PSCmdlet.ShouldProcess($VMName, 'Join Entra ID')) {
        # Fail closed on stale records or lookup errors before any extension changes.
        $stale = @(Find-AvdEntraDevice -Name $VMName)
        if ($stale.Count -gt 0) {
            throw "Entra ID already has device records named $VMName. Automatic cleanup is disabled; verify their exact identities and ownership before a separate manual cleanup. No join changes were made."
        }

        # 2. Join. If a failed attempt is already on the VM, remove it so this is a fresh run.
        $previous = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -Name 'AADLoginForWindows' -ErrorAction SilentlyContinue
        if ($previous) {
            Write-Verbose 'Removing the previous AADLoginForWindows extension so the join runs again.'
            $null = Remove-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -Name 'AADLoginForWindows' -Force
        }
        Write-Verbose "Joining $VMName to Entra ID."
        $null = Set-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -Location $Location `
            -Name 'AADLoginForWindows' -Publisher 'Microsoft.Azure.ActiveDirectory' -ExtensionType 'AADLoginForWindows' -TypeHandlerVersion '2.0'

        # 3. Restart so device registration settles before the AVD agent installs. The
        #    AD join path reboots as part of the join; this path did not, and the agent
        #    ran its first health checks too early.
        Write-Verbose "Restarting $VMName so the Entra join settles."
        $null = Restart-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName   # Restart-AzVM takes -Name, not -VMName

        # 4. Verify from inside the guest. ProvisioningState Succeeded on the extension
        #    means nothing; dsregcmd is the truth. Right after a restart the guest agent
        #    can take a minute to accept Run Commands, so this tries a few times.
        $joined = $false
        foreach ($attempt in 1..4) {
            try {
                $joined = Test-AvdEntraJoin -ResourceGroupName $ResourceGroupName -VMName $VMName
            } catch {
                Write-Verbose "Join check attempt $attempt could not run yet: $($_.Exception.Message.Split([char]10)[0])"
            }
            if ($joined) { break }
            if ($attempt -lt 4) { Write-Verbose "Not joined yet; checking again in 30 seconds."; Start-Sleep -Seconds 30 }
        }
        if (-not $joined) {
            $tail = try { Get-AvdEntraJoinLogTail -ResourceGroupName $ResourceGroupName -VMName $VMName } catch { '(could not read the handler log)' }
            throw "Entra join of $VMName did not take: dsregcmd reports AzureAdJoined NO. Handler log:`n$tail"
        }
        Write-Verbose "$VMName is Entra joined (dsregcmd AzureAdJoined : YES)."
    }
}

function Install-AvdAgent {
    <#
    .SYNOPSIS
        Installs the AVD agent and boot loader and registers the host to a pool, via Microsoft's DSC configuration.
    .DESCRIPTION
        Same mechanism the portal uses. The package is Microsoft's own, from the
        Azure/RDS-Templates repo (ARM-wvd-templates/DSC/Configuration.zip); its
        AddSessionHost accepts HostPoolName, RegistrationInfoToken, AadJoin,
        AadJoinPreview, MdmId, SessionHostConfigurationLastUpdateTime,
        EnableVerboseMsiLogging and UseAgentDownloadEndpoint. The older
        wvdportalstorageblob "Configuration.zip" predates Entra join and rejects
        aadJoin, which is how this default got corrected.
        The token sits in extension settings in plain text; it is short-lived and
        only lets a VM join this one pool, but it is still a secret. The package
        also accepts RegistrationInfoTokenCredential via protectedSettings for a
        future improvement.
        A previous failed attempt of this extension is removed first so a retry
        gets a clean run instead of "extension already exists in failed state".
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string]$HostPoolName,
        [Parameter(Mandatory)] [string]$RegistrationToken,
        [Parameter()] [switch]$EntraJoined,
        [Parameter()] [string]$DscArtifactsUrl = 'https://raw.githubusercontent.com/Azure/RDS-Templates/master/ARM-wvd-templates/DSC/Configuration.zip'
    )
    if ($PSCmdlet.ShouldProcess($VMName, "Install AVD agent and register to $HostPoolName")) {
        $previous = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -Name 'AvdAgentDsc' -ErrorAction SilentlyContinue
        if ($previous -and $previous.ProvisioningState -ne 'Succeeded') {
            Write-Verbose "Removing previous AvdAgentDsc extension (state $($previous.ProvisioningState)) before retrying."
            $null = Remove-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -Name 'AvdAgentDsc' -Force
        }
        $settings = @{
            modulesUrl            = $DscArtifactsUrl
            configurationFunction = 'Configuration.ps1\AddSessionHost'
            properties            = @{
                hostPoolName             = $HostPoolName
                registrationInfoToken    = $RegistrationToken
                aadJoin                  = $EntraJoined.IsPresent
                UseAgentDownloadEndpoint = $true
            }
        }
        Write-Verbose "Installing AVD agent on $VMName."
        $null = Set-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -Location $Location `
            -Name 'AvdAgentDsc' -Publisher 'Microsoft.Powershell' -ExtensionType 'DSC' -TypeHandlerVersion '2.73' -Settings $settings
    }
}

function Set-AvdSessionHostFsLogix {
    <#
    .SYNOPSIS
        Configures FSLogix profile registry on a host via Run Command.
    .DESCRIPTION
        Runs hostconfig/Set-FsLogixProfile.ps1 inside the VM as SYSTEM. With
        -EntraKerberos it also sets the two values Entra-joined hosts need to get
        Kerberos tickets for Azure Files. Anything else that must happen on the
        host after build goes in hostconfig/ and runs the same way.
    .OUTPUTS
        The lines the host-side script printed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [string]$ProfileShare,
        [Parameter()] [switch]$EntraKerberos
    )
    if ($PSCmdlet.ShouldProcess($VMName, "Configure FSLogix profiles at $ProfileShare")) {
        $scriptPath = Join-Path $PSScriptRoot 'hostconfig' 'Set-FsLogixProfile.ps1'
        Write-Verbose "Configuring FSLogix on $VMName."
        $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName -CommandId 'RunPowerShellScript' `
            -ScriptPath $scriptPath -Parameter @{ ProfileShare = $ProfileShare; EntraKerberos = $(if ($EntraKerberos) { 1 } else { 0 }) }
        foreach ($line in $result.Value) { Write-Verbose "  [host] $($line.Message)"; $line.Message }
    }
}

function Set-AvdProfileShareAcl {
    <#
    .SYNOPSIS
        Applies the FSLogix NTFS permission set to a share root from inside a session host.
    .DESCRIPTION
        Runs hostconfig/Set-ProfileShareNtfs.ps1 on the VM via Run Command. The VM is
        inside the VNet, so TCP 445 to the storage account works even when the admin's
        ISP blocks it. The storage key is passed as a Run Command parameter.
    .OUTPUTS
        The lines the host-side script printed (includes the resulting ACL).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [string]$StorageAccountName,
        [Parameter(Mandatory)] [string]$StorageAccountResourceGroupName,
        [Parameter(Mandatory)] [string]$ShareName
    )
    $unc = "\\$StorageAccountName.file.core.windows.net\$ShareName"
    if ($PSCmdlet.ShouldProcess("$unc via $VMName", 'Apply FSLogix NTFS permissions')) {
        $key = (Get-AzStorageAccountKey -ResourceGroupName $StorageAccountResourceGroupName -Name $StorageAccountName)[0].Value
        $scriptPath = Join-Path $PSScriptRoot 'hostconfig' 'Set-ProfileShareNtfs.ps1'
        Write-Verbose "Applying NTFS to $unc from $VMName."
        $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName -CommandId 'RunPowerShellScript' `
            -ScriptPath $scriptPath -Parameter @{ ShareUnc = $unc; UserName = "Azure\$StorageAccountName"; Key = $key }
        foreach ($line in $result.Value) { Write-Verbose "  [host] $($line.Message)"; $line.Message }
        if (($result.Value | ForEach-Object Message) -join "`n" -notmatch 'NTFS applied') {
            throw "Run Command finished but did not report success. Output: $(($result.Value | ForEach-Object Message) -join ' | ')"
        }
    }
}

function Grant-AvdVmLogin {
    <#
    .SYNOPSIS
        Grants an Entra group Virtual Machine User Login on one VM.
    .DESCRIPTION
        Entra-joined hosts check Azure RBAC at sign-in. Desktop Virtualization User
        on the app group gets the desktop into the feed; this role lets the user
        log on to the VM. AD-joined hosts do not need it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [string]$ObjectId
    )
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Verbose "VM $VMName not found (WhatIf run?). Skipping login role."
        return
    }
    $null = Grant-AvdRoleAssignment -Scope $vm.Id -ObjectId $ObjectId -RoleDefinitionName 'Virtual Machine User Login' -Label $VMName
}
#endregion

#region Autoscale and agent updates -------------------------------------------
#   WHAT   Native AVD scaling plans (the service powers hosts on and off on a
#          schedule) and the pool's agent update maintenance window.
#   WHY    Autoscale is the biggest cost lever in AVD and the main reason people
#          buy Nerdio. The service needs one role on the subscription (or group) to
#          touch VMs; the plan itself is one resource with schedules; attaching it
#          to a pool is a property on the plan. The agent update window keeps agent
#          upgrades (and their reboots) out of business hours.
#   GOTCHA A scaling plan must live in the same region as the host pool, and a pool
#          can have only one plan enabled at a time. Schedules are per pool type:
#          this covers Pooled; Personal plans use a different schedule shape.
#          Times are given as 'HH:mm' and converted to the {Hour, Minute} objects the
#          API wants. Time zones are Windows IDs ('Pacific Standard Time').
$script:AvdServiceAppId = '9cdead84-a844-4324-93f2-b2e6bb768d07'     # "Azure Virtual Desktop" first-party app
$script:AvdAutoscaleRole = 'Desktop Virtualization Power On Off Contributor'

function ConvertTo-AvdClockTime {
    # 'HH:mm' -> @{ Hour = h; Minute = m } for scaling plan schedules.
    param([Parameter(Mandatory)] [string]$Text)
    if ($Text -notmatch '^(\d{1,2}):(\d{2})$') { throw "Time '$Text' must be HH:mm (24 hour)." }
    $h = [int]$Matches[1]; $m = [int]$Matches[2]
    if ($h -gt 23 -or $m -gt 59) { throw "Time '$Text' is out of range." }
    return @{ Hour = $h; Minute = $m }
}

function Get-AvdServicePrincipal {
    $sp = Get-AzADServicePrincipal -ApplicationId $script:AvdServiceAppId -ErrorAction Stop
    if (-not $sp) { throw "The Azure Virtual Desktop service principal ($script:AvdServiceAppId) is not in this tenant. Registering Microsoft.DesktopVirtualization creates it." }
    return $sp
}

function Test-AvdAutoscaleRole {
    <#
    .SYNOPSIS
        True if the AVD service already holds the power on/off role at the subscription
        or, when given, the resource group.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter()] [string]$ResourceGroupName
    )
    $sp = Get-AvdServicePrincipal
    $scopes = @("/subscriptions/$SubscriptionId")
    if ($ResourceGroupName) { $scopes += "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName" }
    foreach ($scope in $scopes) {
        if (Get-AzRoleAssignment -ObjectId $sp.Id -Scope $scope -RoleDefinitionName $script:AvdAutoscaleRole -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Grant-AvdAutoscaleRole {
    <#
    .SYNOPSIS
        Gives the AVD service the role it needs to start and deallocate session host
        VMs. Subscription scope by default (Microsoft's recommendation), or one
        resource group with -ResourceGroupName.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter()] [string]$ResourceGroupName
    )
    $sp = Get-AvdServicePrincipal
    $scope = if ($ResourceGroupName) { "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName" } else { "/subscriptions/$SubscriptionId" }
    $label = if ($ResourceGroupName) { "resource group $ResourceGroupName" } else { "subscription $SubscriptionId" }
    Grant-AvdRoleAssignment -Scope $scope -ObjectId $sp.Id -RoleDefinitionName $script:AvdAutoscaleRole -Label $label
}

function ConvertTo-AvdScheduleHashtable {
    # An existing IScalingSchedule -> the hashtable shape New/Update-AzWvdScalingPlan accept.
    param([Parameter(Mandatory)] $Schedule)
    @{
        Name                           = $Schedule.Name
        DaysOfWeek                     = @($Schedule.DaysOfWeek | ForEach-Object { "$_" })
        RampUpStartTime                = @{ Hour = [int]$Schedule.RampUpStartTimeHour; Minute = [int]$Schedule.RampUpStartTimeMinute }
        RampUpLoadBalancingAlgorithm   = "$($Schedule.RampUpLoadBalancingAlgorithm)"
        RampUpMinimumHostsPct          = [int]$Schedule.RampUpMinimumHostsPct
        RampUpCapacityThresholdPct     = [int]$Schedule.RampUpCapacityThresholdPct
        PeakStartTime                  = @{ Hour = [int]$Schedule.PeakStartTimeHour; Minute = [int]$Schedule.PeakStartTimeMinute }
        PeakLoadBalancingAlgorithm     = "$($Schedule.PeakLoadBalancingAlgorithm)"
        RampDownStartTime              = @{ Hour = [int]$Schedule.RampDownStartTimeHour; Minute = [int]$Schedule.RampDownStartTimeMinute }
        RampDownLoadBalancingAlgorithm = "$($Schedule.RampDownLoadBalancingAlgorithm)"
        RampDownMinimumHostsPct        = [int]$Schedule.RampDownMinimumHostsPct
        RampDownCapacityThresholdPct   = [int]$Schedule.RampDownCapacityThresholdPct
        RampDownForceLogoffUser        = [bool]$Schedule.RampDownForceLogoffUser
        RampDownWaitTimeMinute         = [int]$Schedule.RampDownWaitTimeMinute
        RampDownNotificationMessage    = "$($Schedule.RampDownNotificationMessage)"
        RampDownStopHostsWhen          = "$($Schedule.RampDownStopHostsWhen)"
        OffPeakStartTime               = @{ Hour = [int]$Schedule.OffPeakStartTimeHour; Minute = [int]$Schedule.OffPeakStartTimeMinute }
        OffPeakLoadBalancingAlgorithm  = "$($Schedule.OffPeakLoadBalancingAlgorithm)"
    }
}

function ConvertTo-AvdClockText {
    param([hashtable]$Time)
    return ('{0:d2}:{1:d2}' -f [int]$Time.Hour, [int]$Time.Minute)
}

function Get-AvdWeekendSchedule {
    # Off-peak all day on the days the weekday schedule does not cover: every phase
    # at the same minute, minimum hosts 0.
    param([Parameter(Mandatory)] [hashtable]$Weekday)
    $days = @([System.DayOfWeek].GetEnumNames() | Where-Object { $_ -notin $Weekday.DaysOfWeek })
    if ($days.Count -eq 0) { return $null }
    @{
        Name = 'weekend'; DaysOfWeek = $days
        RampUpStartTime = @{ Hour = 0; Minute = 0 };  RampUpLoadBalancingAlgorithm = 'DepthFirst'; RampUpMinimumHostsPct = 0; RampUpCapacityThresholdPct = 90
        PeakStartTime = @{ Hour = 0; Minute = 1 };    PeakLoadBalancingAlgorithm = 'DepthFirst'
        RampDownStartTime = @{ Hour = 0; Minute = 2 }; RampDownLoadBalancingAlgorithm = 'DepthFirst'; RampDownMinimumHostsPct = 0; RampDownCapacityThresholdPct = 90
        RampDownForceLogoffUser = $Weekday.RampDownForceLogoffUser; RampDownWaitTimeMinute = $Weekday.RampDownWaitTimeMinute
        RampDownNotificationMessage = $Weekday.RampDownNotificationMessage; RampDownStopHostsWhen = 'ZeroSessions'
        OffPeakStartTime = @{ Hour = 0; Minute = 3 }; OffPeakLoadBalancingAlgorithm = 'DepthFirst'
    }
}

function Get-AvdScalingPlanSchedule {
    <#
    .SYNOPSIS
        A plan's schedules as flat rows a form can show: times as HH:mm, days as a
        list, every percentage and the ramp-down behaviour.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name
    )
    $plan = Get-AzWvdScalingPlan -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop
    foreach ($sch in @($plan.Schedule)) {
        $h = ConvertTo-AvdScheduleHashtable $sch
        [pscustomobject]@{
            Plan                         = $plan.Name
            TimeZone                     = $plan.TimeZone
            ExclusionTag                 = $plan.ExclusionTag
            Name                         = $h.Name
            Days                         = $h.DaysOfWeek
            RampUpStart                  = ConvertTo-AvdClockText $h.RampUpStartTime
            PeakStart                    = ConvertTo-AvdClockText $h.PeakStartTime
            RampDownStart                = ConvertTo-AvdClockText $h.RampDownStartTime
            OffPeakStart                 = ConvertTo-AvdClockText $h.OffPeakStartTime
            RampUpMinimumHostsPct        = $h.RampUpMinimumHostsPct
            RampUpCapacityThresholdPct   = $h.RampUpCapacityThresholdPct
            RampDownMinimumHostsPct      = $h.RampDownMinimumHostsPct
            RampDownCapacityThresholdPct = $h.RampDownCapacityThresholdPct
            RampDownWaitTimeMinutes      = $h.RampDownWaitTimeMinute
            RampDownForceLogoff          = $h.RampDownForceLogoffUser
            RampDownMessage              = $h.RampDownNotificationMessage
            RampDownStopHostsWhen        = $h.RampDownStopHostsWhen
            RampUpLoadBalancing          = $h.RampUpLoadBalancingAlgorithm
            PeakLoadBalancing            = $h.PeakLoadBalancingAlgorithm
        }
    }
}

function Set-AvdScalingPlanResource {
    <#
    .SYNOPSIS
        Change an existing pooled scaling plan: time zone, exclusion tag, any field
        of its weekday schedule, and whether it has the weekend off-peak schedule.
        Only the parameters you pass change; everything else is kept.
    .DESCRIPTION
        Update-AzWvdScalingPlan replaces the whole schedule list, so this reads the
        plan, edits the 'weekdays' schedule in memory (the first schedule when none
        is named that), adds or drops 'weekend', and writes the list back.
    .PARAMETER WeekendOffPeak
        $true adds the weekend off-peak schedule if missing; $false removes it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter()] [string]$TimeZone,
        [Parameter()] [string]$ExclusionTag,
        [Parameter()] [string[]]$Days,
        [Parameter()] [string]$RampUpStart,
        [Parameter()] [string]$PeakStart,
        [Parameter()] [string]$RampDownStart,
        [Parameter()] [string]$OffPeakStart,
        [Parameter()] [ValidateRange(0, 100)] [int]$RampUpMinimumHostsPct,
        [Parameter()] [ValidateRange(1, 100)] [int]$RampUpCapacityThresholdPct,
        [Parameter()] [ValidateRange(0, 100)] [int]$RampDownMinimumHostsPct,
        [Parameter()] [ValidateRange(1, 100)] [int]$RampDownCapacityThresholdPct,
        [Parameter()] [ValidateRange(0, 120)] [int]$RampDownWaitTimeMinutes,
        [Parameter()] [bool]$RampDownForceLogoff,
        [Parameter()] [string]$RampDownMessage,
        [Parameter()] [ValidateSet('ZeroSessions', 'ZeroActiveSessions')] [string]$RampDownStopHostsWhen,
        [Parameter()] [bool]$WeekendOffPeak
    )
    $plan = Get-AzWvdScalingPlan -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop
    if ("$($plan.HostPoolType)" -ne 'Pooled') { throw "Scaling plan $Name is $($plan.HostPoolType); this edits Pooled schedules." }
    $schedules = @(@($plan.Schedule) | ForEach-Object { ConvertTo-AvdScheduleHashtable $_ })
    $weekday = $schedules | Where-Object { $_.Name -eq 'weekdays' } | Select-Object -First 1
    if (-not $weekday) { $weekday = $schedules | Where-Object { $_.Name -ne 'weekend' } | Select-Object -First 1 }
    if (-not $weekday) { throw "Scaling plan $Name has no schedule to edit." }

    $b = $PSBoundParameters
    $changed = @()
    if ($b.ContainsKey('Days'))                         { $weekday.DaysOfWeek = $Days; $changed += 'days' }
    if ($b.ContainsKey('RampUpStart'))                  { $weekday.RampUpStartTime = ConvertTo-AvdClockTime $RampUpStart; $changed += 'ramp-up' }
    if ($b.ContainsKey('PeakStart'))                    { $weekday.PeakStartTime = ConvertTo-AvdClockTime $PeakStart; $changed += 'peak' }
    if ($b.ContainsKey('RampDownStart'))                { $weekday.RampDownStartTime = ConvertTo-AvdClockTime $RampDownStart; $changed += 'ramp-down' }
    if ($b.ContainsKey('OffPeakStart'))                 { $weekday.OffPeakStartTime = ConvertTo-AvdClockTime $OffPeakStart; $changed += 'off-peak' }
    if ($b.ContainsKey('RampUpMinimumHostsPct'))        { $weekday.RampUpMinimumHostsPct = $RampUpMinimumHostsPct; $changed += 'ramp-up minimum' }
    if ($b.ContainsKey('RampUpCapacityThresholdPct'))   { $weekday.RampUpCapacityThresholdPct = $RampUpCapacityThresholdPct; $changed += 'ramp-up threshold' }
    if ($b.ContainsKey('RampDownMinimumHostsPct'))      { $weekday.RampDownMinimumHostsPct = $RampDownMinimumHostsPct; $changed += 'ramp-down minimum' }
    if ($b.ContainsKey('RampDownCapacityThresholdPct')) { $weekday.RampDownCapacityThresholdPct = $RampDownCapacityThresholdPct; $changed += 'ramp-down threshold' }
    if ($b.ContainsKey('RampDownWaitTimeMinutes'))      { $weekday.RampDownWaitTimeMinute = $RampDownWaitTimeMinutes; $changed += 'wait' }
    if ($b.ContainsKey('RampDownForceLogoff'))          { $weekday.RampDownForceLogoffUser = $RampDownForceLogoff; $changed += 'force log-off' }
    if ($b.ContainsKey('RampDownMessage'))              { $weekday.RampDownNotificationMessage = $RampDownMessage; $changed += 'message' }
    if ($b.ContainsKey('RampDownStopHostsWhen'))        { $weekday.RampDownStopHostsWhen = $RampDownStopHostsWhen; $changed += 'stop hosts when' }

    $weekend = $schedules | Where-Object { $_.Name -eq 'weekend' } | Select-Object -First 1
    if ($b.ContainsKey('WeekendOffPeak')) {
        if ($WeekendOffPeak -and -not $weekend) { $w = Get-AvdWeekendSchedule -Weekday $weekday; if ($w) { $schedules += $w; $changed += 'weekend added' } }
        elseif (-not $WeekendOffPeak -and $weekend) { $schedules = @($schedules | Where-Object { $_.Name -ne 'weekend' }); $changed += 'weekend removed' }
    } elseif ($weekend -and $b.ContainsKey('Days')) {
        # Weekday days changed: the weekend schedule must cover exactly the rest.
        $weekend.DaysOfWeek = @([System.DayOfWeek].GetEnumNames() | Where-Object { $_ -notin $Days })
    }

    $p = @{ ResourceGroupName = $ResourceGroupName; Name = $Name; Schedule = $schedules }
    if ($b.ContainsKey('TimeZone'))     { $p.TimeZone = $TimeZone; $changed += 'time zone' }
    if ($b.ContainsKey('ExclusionTag')) { $p.ExclusionTag = $ExclusionTag; $changed += 'exclusion tag' }
    if ($changed.Count -eq 0) { Write-Verbose "Nothing to change on $Name."; return $plan }
    if ($PSCmdlet.ShouldProcess($Name, "Update scaling plan: $($changed -join ', ')")) {
        Write-Verbose "Updating $Name ($($changed -join ', '))."
        return Update-AzWvdScalingPlan @p
    }
}

function Get-AvdScalingPlan {
    <#
    .SYNOPSIS
        Scaling plans in a resource group, flat, with whether each one is attached
        to (and enabled for) the given host pool.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter()] [string]$HostPoolName
    )
    $poolId = $null
    if ($HostPoolName) { $poolId = (Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName -ErrorAction Stop).Id }
    foreach ($plan in @(Get-AzWvdScalingPlan -ResourceGroupName $ResourceGroupName -ErrorAction Stop)) {
        $ref = if ($poolId) { @($plan.HostPoolReference | Where-Object { $_.HostPoolArmPath -eq $poolId }) } else { @() }
        $sched = @($plan.Schedule | ForEach-Object {
            "{0}: {1} ramp-up {2:d2}:{3:d2}, peak {4:d2}:{5:d2}, ramp-down {6:d2}:{7:d2}, off-peak {8:d2}:{9:d2}" -f $_.Name, (@($_.DaysOfWeek) -join '/'),
                $_.RampUpStartTimeHour, $_.RampUpStartTimeMinute, $_.PeakStartTimeHour, $_.PeakStartTimeMinute,
                $_.RampDownStartTimeHour, $_.RampDownStartTimeMinute, $_.OffPeakStartTimeHour, $_.OffPeakStartTimeMinute
        })
        $weekday = @($plan.Schedule) | Where-Object { $_.Name -eq 'weekdays' } | Select-Object -First 1
        if (-not $weekday) { $weekday = @($plan.Schedule) | Where-Object { $_.Name -ne 'weekend' } | Select-Object -First 1 }
        $detail = $null
        if ($weekday) {
            $h = ConvertTo-AvdScheduleHashtable $weekday
            $detail = [pscustomobject]@{
                Days = $h.DaysOfWeek; RampUpStart = ConvertTo-AvdClockText $h.RampUpStartTime; PeakStart = ConvertTo-AvdClockText $h.PeakStartTime
                RampDownStart = ConvertTo-AvdClockText $h.RampDownStartTime; OffPeakStart = ConvertTo-AvdClockText $h.OffPeakStartTime
                RampUpMinimumHostsPct = $h.RampUpMinimumHostsPct; RampUpCapacityThresholdPct = $h.RampUpCapacityThresholdPct
                RampDownMinimumHostsPct = $h.RampDownMinimumHostsPct; RampDownCapacityThresholdPct = $h.RampDownCapacityThresholdPct
                RampDownWaitTimeMinutes = $h.RampDownWaitTimeMinute; RampDownForceLogoff = $h.RampDownForceLogoffUser
                RampDownMessage = $h.RampDownNotificationMessage; RampDownStopHostsWhen = $h.RampDownStopHostsWhen
            }
        }
        [pscustomobject]@{
            Name          = $plan.Name
            Location      = $plan.Location
            HostPoolType  = "$($plan.HostPoolType)"
            TimeZone      = $plan.TimeZone
            AttachedToPool = ($ref.Count -gt 0)
            EnabledForPool = ($ref.Count -gt 0 -and [bool]$ref[0].ScalingPlanEnabled)
            PoolCount     = @($plan.HostPoolReference).Count
            Schedules     = ($sched -join '; ')
            HasWeekend    = (@($plan.Schedule | Where-Object { $_.Name -eq 'weekend' }).Count -gt 0)
            ExclusionTag  = $plan.ExclusionTag
            Weekday       = $detail
            Id            = $plan.Id
        }
    }
}

function New-AvdScalingPlanResource {
    <#
    .SYNOPSIS
        Creates a pooled scaling plan with a weekday schedule (and optionally a
        weekend all-off-peak schedule) and attaches it to a host pool.
    .DESCRIPTION
        The four phases of a day: ramp-up (start hosts ahead of people), peak
        (keep capacity), ramp-down (consolidate, ask stragglers to leave), off-peak
        (minimum hosts). Percentages are of the pool's total host count. Capacity
        threshold is the percent of the pool's session capacity at which another
        host is started.
    .PARAMETER RampDownForceLogoff
        At ramp-down, after -RampDownWaitTimeMinutes and the notification message,
        sign remaining users out so hosts can stop. Off by default; without it hosts
        with sessions stay on until users leave.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string]$HostPoolId,
        [Parameter(Mandatory)] [string]$TimeZone,
        [Parameter()] [string[]]$Days = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'),
        [Parameter()] [string]$RampUpStart = '07:00',
        [Parameter()] [string]$PeakStart = '09:00',
        [Parameter()] [string]$RampDownStart = '18:00',
        [Parameter()] [string]$OffPeakStart = '20:00',
        [Parameter()] [ValidateRange(0, 100)] [int]$RampUpMinimumHostsPct = 20,
        [Parameter()] [ValidateRange(1, 100)] [int]$RampUpCapacityThresholdPct = 60,
        [Parameter()] [ValidateRange(0, 100)] [int]$RampDownMinimumHostsPct = 10,
        [Parameter()] [ValidateRange(1, 100)] [int]$RampDownCapacityThresholdPct = 90,
        [Parameter()] [ValidateRange(0, 120)] [int]$RampDownWaitTimeMinutes = 30,
        [Parameter()] [switch]$RampDownForceLogoff,
        [Parameter()] [string]$RampDownMessage = 'This desktop will shut down for the night in 30 minutes. Please save your work and sign out.',
        [Parameter()] [switch]$WeekendOffPeak,
        [Parameter()] [bool]$Enable = $true,
        [Parameter()] [string]$ExclusionTag,
        [Parameter()] [string]$Description = 'Created by New-AvdScalingPlan.ps1'
    )
    $schedules = @(
        @{
            Name                         = 'weekdays'
            DaysOfWeek                   = $Days
            RampUpStartTime              = ConvertTo-AvdClockTime $RampUpStart
            RampUpLoadBalancingAlgorithm = 'BreadthFirst'
            RampUpMinimumHostsPct        = $RampUpMinimumHostsPct
            RampUpCapacityThresholdPct   = $RampUpCapacityThresholdPct
            PeakStartTime                = ConvertTo-AvdClockTime $PeakStart
            PeakLoadBalancingAlgorithm   = 'DepthFirst'
            RampDownStartTime            = ConvertTo-AvdClockTime $RampDownStart
            RampDownLoadBalancingAlgorithm = 'DepthFirst'
            RampDownMinimumHostsPct      = $RampDownMinimumHostsPct
            RampDownCapacityThresholdPct = $RampDownCapacityThresholdPct
            RampDownForceLogoffUser      = [bool]$RampDownForceLogoff
            RampDownWaitTimeMinute       = $RampDownWaitTimeMinutes
            RampDownNotificationMessage  = $RampDownMessage
            RampDownStopHostsWhen        = 'ZeroSessions'
            OffPeakStartTime             = ConvertTo-AvdClockTime $OffPeakStart
            OffPeakLoadBalancingAlgorithm = 'DepthFirst'
        }
    )
    if ($WeekendOffPeak) {
        $w = Get-AvdWeekendSchedule -Weekday $schedules[0]
        if ($w) { $schedules += $w }
    }
    $existing = Get-AzWvdScalingPlan -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Verbose "Scaling plan $Name already exists; leaving it as is."
        return $existing
    }
    if ($PSCmdlet.ShouldProcess($Name, "Create pooled scaling plan in $Location ($TimeZone) attached to $(($HostPoolId -split '/')[-1])")) {
        $p = @{
            ResourceGroupName = $ResourceGroupName; Name = $Name; Location = $Location; HostPoolType = 'Pooled'
            TimeZone = $TimeZone; Schedule = $schedules; Description = $Description; FriendlyName = $Name
            HostPoolReference = @(@{ HostPoolArmPath = $HostPoolId; ScalingPlanEnabled = $Enable })
        }
        if ($ExclusionTag) { $p.ExclusionTag = $ExclusionTag }
        Write-Verbose "Creating scaling plan $Name."
        return New-AzWvdScalingPlan @p
    }
}

function Set-AvdScalingPlanEnabled {
    <#
    .SYNOPSIS
        Turns a scaling plan on or off for one host pool without touching its
        schedules or its other pools. Attaches the pool if it was not referenced.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$HostPoolId,
        [Parameter(Mandatory)] [bool]$Enabled
    )
    $plan = Get-AzWvdScalingPlan -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop
    $refs = @($plan.HostPoolReference | ForEach-Object { @{ HostPoolArmPath = $_.HostPoolArmPath; ScalingPlanEnabled = [bool]$_.ScalingPlanEnabled } })
    $mine = $refs | Where-Object { $_.HostPoolArmPath -eq $HostPoolId }
    if ($mine) { $mine.ScalingPlanEnabled = $Enabled } else { $refs += @{ HostPoolArmPath = $HostPoolId; ScalingPlanEnabled = $Enabled } }
    $verb = if ($Enabled) { 'Enable' } else { 'Disable' }
    if ($PSCmdlet.ShouldProcess($Name, "$verb for host pool $(($HostPoolId -split '/')[-1])")) {
        Write-Verbose "$verb scaling plan $Name for $(($HostPoolId -split '/')[-1])."
        return Update-AzWvdScalingPlan -ResourceGroupName $ResourceGroupName -Name $Name -HostPoolReference $refs
    }
}

function Set-AvdHostPoolAgentUpdate {
    <#
    .SYNOPSIS
        Sets the host pool's agent update maintenance window, or puts it back to
        Microsoft's default timing.
    .PARAMETER UseSessionHostLocalTime
        Interpret the hour in each host's own time zone instead of -TimeZone.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$HostPoolName,
        [Parameter(ParameterSetName = 'Scheduled', Mandatory)] [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')] [string]$DayOfWeek,
        [Parameter(ParameterSetName = 'Scheduled', Mandatory)] [ValidateRange(0, 23)] [int]$Hour,
        [Parameter(ParameterSetName = 'Scheduled')] [string]$TimeZone,
        [Parameter(ParameterSetName = 'Scheduled')] [switch]$UseSessionHostLocalTime,
        [Parameter(ParameterSetName = 'Default', Mandatory)] [switch]$Default
    )
    if ($Default) {
        if ($PSCmdlet.ShouldProcess($HostPoolName, 'Agent updates back to Default timing')) {
            return Update-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName -AgentUpdateType Default
        }
        return
    }
    if (-not $UseSessionHostLocalTime -and -not $TimeZone) { throw 'Give -TimeZone (a Windows time zone ID) or -UseSessionHostLocalTime.' }
    $what = "Agent updates every $DayOfWeek at $('{0:d2}:00' -f $Hour) $(if ($UseSessionHostLocalTime) { 'host local time' } else { $TimeZone })"
    if ($PSCmdlet.ShouldProcess($HostPoolName, $what)) {
        $p = @{
            ResourceGroupName = $ResourceGroupName; Name = $HostPoolName
            AgentUpdateType = 'Scheduled'
            AgentUpdateMaintenanceWindow = @(@{ DayOfWeek = $DayOfWeek; Hour = $Hour })
            AgentUpdateUseSessionHostLocalTime = [bool]$UseSessionHostLocalTime
        }
        if (-not $UseSessionHostLocalTime) { $p.AgentUpdateMaintenanceWindowTimeZone = $TimeZone }
        Write-Verbose $what
        return Update-AzWvdHostPool @p
    }
}
#endregion

Export-ModuleMember -Function @(
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
