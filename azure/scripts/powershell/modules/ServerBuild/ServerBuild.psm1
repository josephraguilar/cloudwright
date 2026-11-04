#region Module setup ----------------------------------------------------------
#   WHAT   Plain Windows servers, as opposed to AVD session hosts: list them, power
#          them, build one, and turn it into an IIS box, the first DC of a new
#          forest, or a SQL Server, by running scripts inside the guest.
#   WHY    Same shape as AvdBuild: one function per step, -WhatIf everywhere, no
#          prompts, objects out. The role scripts live in hostconfig/ and run via
#          the managed Run Command, which can carry secrets (safe-mode and sa
#          passwords) as protected parameters that never land in a log.
#   GOTCHA $ErrorActionPreference is set here at module scope; module functions do
#          not inherit the caller's. Nothing in this module deletes a resource.
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
#endregion

#region Inventory and power ---------------------------------------------------
#   WHAT   Flat VM rows (power state, size, image, private IP, role tag) and the
#          three power verbs by VM name.
#   WHY    Get-AzVM -Status in list form gives power state for a whole group in one
#          call; the private IP needs one NIC read per VM.
#   GOTCHA VM lifecycle cmdlets take -Name. tests/Static.Tests.ps1 enforces it.
function Get-ServerVmInfo {
    <#
    .SYNOPSIS
        VMs in a resource group (or the whole subscription) as flat rows.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [string]$ResourceGroupName,
        [Parameter()] [string]$Name
    )
    $vms = if ($ResourceGroupName -and $Name) { @(Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -Status) }
           elseif ($ResourceGroupName) { @(Get-AzVM -ResourceGroupName $ResourceGroupName -Status) }
           else { @(Get-AzVM -Status) }
    foreach ($vm in $vms) {
        $ip = $null
        try {
            $nicId = $vm.NetworkProfile.NetworkInterfaces[0].Id
            if ($nicId) { $ip = (Get-AzNetworkInterface -ResourceId $nicId -ErrorAction Stop).IpConfigurations[0].PrivateIpAddress }
        } catch { Write-Verbose "No private IP for $($vm.Name): $($_.Exception.Message)" }
        $img = $vm.StorageProfile.ImageReference
        $power = if ($vm.PSObject.Properties['PowerState'] -and $vm.PowerState) { $vm.PowerState -replace '^VM ', '' }
                 elseif ($vm.PSObject.Properties['Statuses']) { (($vm.Statuses | Where-Object Code -like 'PowerState/*' | Select-Object -First 1).Code -replace '^PowerState/', '') }
                 else { 'unknown' }
        [pscustomobject]@{
            Name              = $vm.Name
            ResourceGroupName = $vm.ResourceGroupName
            PowerState        = $power
            VMSize            = $vm.HardwareProfile.VmSize
            OS                = "$($vm.StorageProfile.OsDisk.OsType)"
            Image             = if ($img -and $img.Sku) { "$($img.Offer)/$($img.Sku)" } elseif ($img -and $img.Id) { ($img.Id -split '/')[-1] } else { '' }
            PrivateIp         = $ip
            Role              = if ($vm.Tags -and $vm.Tags.ContainsKey('role')) { $vm.Tags['role'] } else { '' }
            Location          = $vm.Location
            Id                = $vm.Id
        }
    }
}

function Start-ServerVm {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string]$ResourceGroupName, [Parameter(Mandatory)] [string]$Name)
    if ($PSCmdlet.ShouldProcess($Name, 'Start VM')) { Write-Verbose "Starting $Name."; $null = Start-AzVM -ResourceGroupName $ResourceGroupName -Name $Name }
}

function Stop-ServerVm {
    <#
    .SYNOPSIS
        Deallocates a VM (stops billing). -StayProvisioned powers off without
        deallocating, which keeps billing and the private IP lease.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string]$ResourceGroupName, [Parameter(Mandatory)] [string]$Name, [Parameter()] [switch]$StayProvisioned)
    $what = if ($StayProvisioned) { 'Stop VM (stay provisioned, still billed)' } else { 'Deallocate VM' }
    if ($PSCmdlet.ShouldProcess($Name, $what)) { Write-Verbose "$what $Name."; $null = Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -Force -StayProvisioned:$StayProvisioned }
}

function Restart-ServerVm {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string]$ResourceGroupName, [Parameter(Mandatory)] [string]$Name)
    if ($PSCmdlet.ShouldProcess($Name, 'Restart VM')) { Write-Verbose "Restarting $Name."; $null = Restart-AzVM -ResourceGroupName $ResourceGroupName -Name $Name }
}
#endregion

#region Images ----------------------------------------------------------------
#   WHAT   The Windows Server and SQL Server marketplace images worth offering, and
#          the latest version of one of them.
#   WHY    "2025-datacenter-azure-edition" is the one to pick unless you know why
#          not: Gen2, Trusted Launch, hotpatch-capable. SQL images come with SQL
#          licensed pay-as-you-go and already configured; the edition is in the SKU.
#   GOTCHA An image key is publisher-independent on purpose: 'windowsserver:<sku>'
#          or 'sql:<offer>:<sku>', so a form can hold one string.
function Get-ServerImageCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Location)
    $rows = [System.Collections.Generic.List[object]]::new()
    $ws = @(Get-AzVMImageSku -Location $Location -PublisherName 'MicrosoftWindowsServer' -Offer 'WindowsServer' -ErrorAction Stop |
        Select-Object -ExpandProperty Skus | Where-Object { $_ -match '^(2019|2022|2025)-datacenter(-azure-edition)?(-core)?(-g2)?$' } | Sort-Object -Descending)
    foreach ($s in $ws) {
        $label = "Windows Server $($s.Substring(0,4)) Datacenter" + $(if ($s -like '*azure-edition*') { ' Azure Edition' }) + $(if ($s -like '*-core*') { ' Core (no desktop)' }) + $(if ($s -like '*azure-edition*') { '  recommended' })
        $rows.Add([pscustomobject]@{ Value = "windowsserver:$s"; Label = $label; Kind = 'Windows Server'; Publisher = 'MicrosoftWindowsServer'; Offer = 'WindowsServer'; Sku = $s })
    }
    $offers = @(Get-AzVMImageOffer -Location $Location -PublisherName 'MicrosoftSQLServer' -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Offer | Where-Object { $_ -match '^sql20\d\d-ws20\d\d$' } | Sort-Object -Descending)
    foreach ($o in $offers) {
        $skus = @(Get-AzVMImageSku -Location $Location -PublisherName 'MicrosoftSQLServer' -Offer $o -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Skus | Where-Object { $_ -match '^(standard|enterprise|sqldev|web)(-gen2)?$' } | Sort-Object)
        foreach ($s in $skus) {
            $edition = switch -Regex ($s) { '^enterprise' { 'Enterprise' } '^standard' { 'Standard' } '^sqldev' { 'Developer (free, non-production)' } '^web' { 'Web' } }
            $rows.Add([pscustomobject]@{ Value = "sql:${o}:$s"; Label = "SQL Server $($o.Substring(3,4)) $edition on Windows Server $($o.Substring(10,4))"; Kind = 'SQL Server'; Publisher = 'MicrosoftSQLServer'; Offer = $o; Sku = $s })
        }
    }
    return $rows
}

function Resolve-ServerImage {
    <#
    .SYNOPSIS
        Image key ('windowsserver:<sku>' or 'sql:<offer>:<sku>') to the latest
        version's publisher/offer/sku/version.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Location, [Parameter(Mandatory)] [string]$ImageKey)
    $parts = $ImageKey -split ':'
    switch ($parts[0]) {
        'windowsserver' { $pub = 'MicrosoftWindowsServer'; $offer = 'WindowsServer'; $sku = $parts[1] }
        'sql'           { $pub = 'MicrosoftSQLServer'; $offer = $parts[1]; $sku = $parts[2] }
        default         { throw "Image key '$ImageKey' must be 'windowsserver:<sku>' or 'sql:<offer>:<sku>'." }
    }
    $latest = Get-AzVMImage -Location $Location -PublisherName $pub -Offer $offer -Skus $sku -ErrorAction Stop |
        Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    if (-not $latest) { throw "No versions of $pub/$offer/$sku in $Location." }
    [pscustomobject]@{ Source = 'Marketplace'; Publisher = $pub; Offer = $offer; Sku = $sku; Version = $latest.Version; Label = "$offer/$sku $($latest.Version)"; IsSql = ($pub -eq 'MicrosoftSQLServer') }
}
#endregion

#region NIC and VM ------------------------------------------------------------
#   WHAT   NIC (optionally static private IP, optionally a public IP) and the VM.
#   WHY    A domain controller must keep its private IP: Azure hands out the same
#          dynamic address while the NIC exists, but static removes the doubt.
#          A public IP gets no NSG rule here; opening RDP to the internet is a
#          decision, not a default.
#   GOTCHA LicenseType Windows_Server is Azure Hybrid Benefit and is only lawful
#          with Software Assurance, so it is opt-in (-HybridBenefit). Data disks get
#          caching None by default (right for AD and SQL logs).
function New-ServerNic {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string]$SubnetId,
        [Parameter()] [switch]$StaticPrivateIp,
        [Parameter()] [string]$PrivateIpAddress,
        [Parameter()] [switch]$PublicIp,
        [Parameter()] [hashtable]$Tags = @{}
    )
    $nicName = "$VMName-nic"
    $nic = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $nicName -ErrorAction SilentlyContinue
    if ($nic) { Write-Verbose "Reusing NIC $nicName ($($nic.IpConfigurations[0].PrivateIpAddress))."; return $nic }
    if (-not $PSCmdlet.ShouldProcess($nicName, 'Create network interface')) { return }
    $p = @{ Name = $nicName; ResourceGroupName = $ResourceGroupName; Location = $Location; SubnetId = $SubnetId; Tag = $Tags }
    if ($PrivateIpAddress) { $p.PrivateIpAddress = $PrivateIpAddress }
    if ($PublicIp) {
        $pipName = "$VMName-pip"
        $pip = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $pipName -ErrorAction SilentlyContinue
        if (-not $pip) {
            Write-Verbose "Creating public IP $pipName (Standard, static)."
            $pip = New-AzPublicIpAddress -Name $pipName -ResourceGroupName $ResourceGroupName -Location $Location -Sku Standard -AllocationMethod Static -Tag $Tags
        }
        $p.PublicIpAddressId = $pip.Id
    }
    Write-Verbose "Creating NIC $nicName."
    $nic = New-AzNetworkInterface @p
    if ($StaticPrivateIp -and -not $PrivateIpAddress) {
        # Keep the address Azure just assigned, but pin it.
        $nic.IpConfigurations[0].PrivateIpAllocationMethod = 'Static'
        $nic = Set-AzNetworkInterface -NetworkInterface $nic
        Write-Verbose "Private IP $($nic.IpConfigurations[0].PrivateIpAddress) pinned as static."
    }
    return $nic
}

function New-ServerVm {
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
        [Parameter()] [ValidateRange(0, 32767)] [int]$DataDiskGB = 0,
        [Parameter()] [ValidateSet('None', 'ReadOnly', 'ReadWrite')] [string]$DataDiskCaching = 'None',
        [Parameter()] [ValidateRange(0, 32767)] [int]$GeneralDataDiskGB = 0,
        [Parameter()] [switch]$HybridBenefit,
        [Parameter()] [hashtable]$Tags = @{}
    )
    if (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction SilentlyContinue) { throw "VM $VMName already exists in $ResourceGroupName." }
    $disks = @(); if ($DataDiskGB -gt 0) { $disks += "$DataDiskGB GB role disk" }; if ($GeneralDataDiskGB -gt 0) { $disks += "$GeneralDataDiskGB GB general disk" }
    if (-not $PSCmdlet.ShouldProcess($VMName, "Create $VMSize VM from $($Image.Label)$(if ($disks.Count) { ' with ' + ($disks -join ' and ') })")) { return }

    $cfg = @{ VMName = $VMName; VMSize = $VMSize; IdentityType = 'SystemAssigned' }
    if ($SecurityType -eq 'TrustedLaunch') { $cfg.SecurityType = 'TrustedLaunch' }
    if ($HybridBenefit) { $cfg.LicenseType = 'Windows_Server' }
    $vm = New-AzVMConfig @cfg
    $vm = Set-AzVMOperatingSystem -VM $vm -Windows -ComputerName $VMName -Credential $LocalAdminCredential -ProvisionVMAgent -EnableAutoUpdate
    $vm = Set-AzVMSourceImage -VM $vm -PublisherName $Image.Publisher -Offer $Image.Offer -Skus $Image.Sku -Version $Image.Version
    $vm = Add-AzVMNetworkInterface -VM $vm -Id $NicId
    $vm = Set-AzVMOSDisk -VM $vm -Name "$VMName-osdisk" -CreateOption FromImage -StorageAccountType $OSDiskType
    # LUN 0 is the role disk (AD database, SQL data); LUN 1 a general-purpose disk.
    if ($DataDiskGB -gt 0)        { $vm = Add-AzVMDataDisk -VM $vm -Name "$VMName-data01" -Lun 0 -CreateOption Empty -DiskSizeInGB $DataDiskGB -Caching $DataDiskCaching -StorageAccountType $OSDiskType }
    if ($GeneralDataDiskGB -gt 0) { $vm = Add-AzVMDataDisk -VM $vm -Name "$VMName-data02" -Lun 1 -CreateOption Empty -DiskSizeInGB $GeneralDataDiskGB -Caching ReadOnly -StorageAccountType $OSDiskType }
    $vm = Set-AzVMBootDiagnostic -VM $vm -Enable
    if ($SecurityType -eq 'TrustedLaunch') { $vm = Set-AzVMUefi -VM $vm -EnableVtpm $true -EnableSecureBoot $true }
    Write-Verbose "Creating VM $VMName."
    $null = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vm -Tag $Tags -DisableBginfoExtension
    return Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
}
#endregion

#region In-guest scripts ------------------------------------------------------
#   WHAT   Run a hostconfig/ script inside a VM through the managed Run Command,
#          with ordinary and protected (secret) parameters, and return its output.
#   WHY    The legacy RunPowerShellScript action logs its parameters in the clear.
#          Managed run commands keep protected parameters out of every log and
#          report output, error and execution state as a resource you can read back.
#   GOTCHA The run command resource stays on the VM (named per step), which is also
#          a record of what was done. Nothing is deleted. A script that reboots the
#          VM cannot report back; the AD script therefore does not reboot and the
#          caller restarts the VM.
function Invoke-ServerScript {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$ScriptPath,
        [Parameter()] [hashtable]$Parameter = @{},
        [Parameter()] [hashtable]$ProtectedParameter = @{},
        [Parameter()] [int]$TimeoutSeconds = 3600
    )
    if (-not (Test-Path $ScriptPath)) { throw "Script not found: $ScriptPath" }
    if (-not $PSCmdlet.ShouldProcess($VMName, "Run $(Split-Path $ScriptPath -Leaf) inside the VM")) { return }
    $p = @{
        ResourceGroupName = $ResourceGroupName; VMName = $VMName; RunCommandName = $Name; Location = $Location
        SourceScript = (Get-Content -Path $ScriptPath -Raw); TimeoutInSecond = $TimeoutSeconds
    }
    if ($Parameter.Count -gt 0)          { $p.Parameter = @($Parameter.GetEnumerator() | ForEach-Object { @{ Name = $_.Key; Value = "$($_.Value)" } }) }
    if ($ProtectedParameter.Count -gt 0) { $p.ProtectedParameter = @($ProtectedParameter.GetEnumerator() | ForEach-Object { @{ Name = $_.Key; Value = "$($_.Value)" } }) }
    Write-Verbose "Running $(Split-Path $ScriptPath -Leaf) inside $VMName as run command '$Name'."
    $null = Set-AzVMRunCommand @p
    $rc = Get-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName -RunCommandName $Name -Expand InstanceView
    $view = $rc.InstanceView
    $out = "$($view.Output)".Trim()
    foreach ($line in ($out -split "`r?`n")) { if ($line) { Write-Verbose "  [guest] $line" } }
    if ("$($view.ExecutionState)" -ne 'Succeeded') {
        throw "Run command '$Name' on $VMName ended $($view.ExecutionState). Error: $("$($view.Error)".Trim()) Output: $out"
    }
    return $out
}

function Initialize-ServerDataDisk {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter()] [int]$Lun = 0,
        [Parameter()] [string]$DriveLetter = 'F',
        [Parameter()] [string]$Label = 'Data'
    )
    Invoke-ServerScript -ResourceGroupName $ResourceGroupName -VMName $VMName -Location $Location -Name "InitDataDiskLun$Lun" `
        -ScriptPath (Join-Path $PSScriptRoot 'hostconfig' 'Initialize-DataDisk.ps1') -Parameter @{ Lun = $Lun; DriveLetter = $DriveLetter; Label = $Label }
}

function Install-ServerWebRole {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter()] [string]$SiteTitle = 'IIS is running'
    )
    Invoke-ServerScript -ResourceGroupName $ResourceGroupName -VMName $VMName -Location $Location -Name 'InstallIis' `
        -ScriptPath (Join-Path $PSScriptRoot 'hostconfig' 'Install-IisRole.ps1') -Parameter @{ SiteTitle = $SiteTitle }
}

function Install-ServerAdForest {
    <#
    .SYNOPSIS
        Promote a VM to the first domain controller of a new forest: install, promote
        without reboot, restart the VM, then set the DNS forwarder and verify.
    .PARAMETER SafeModeCredential
        Only the password is used (Directory Services Restore Mode). Sent as a
        protected parameter.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string]$DomainName,
        [Parameter()] [string]$NetbiosName,
        [Parameter(Mandatory)] [pscredential]$SafeModeCredential,
        [Parameter()] [string]$DataDrive = '',
        [Parameter()] [int]$VerifyAttempts = 10
    )
    if ($DomainName -notmatch '^[a-z0-9-]+(\.[a-z0-9-]+)+$') { throw "Domain name '$DomainName' must be a DNS name with at least two labels, e.g. corp.example.com. Single-label names break AD." }
    $params = @{ DomainName = $DomainName; DataDrive = $DataDrive }
    if ($NetbiosName) { $params.NetbiosName = $NetbiosName }
    $out = Invoke-ServerScript -ResourceGroupName $ResourceGroupName -VMName $VMName -Location $Location -Name 'InstallAdForest' `
        -ScriptPath (Join-Path $PSScriptRoot 'hostconfig' 'Install-AdForest.ps1') -Parameter $params `
        -ProtectedParameter @{ SafeModePassword = $SafeModeCredential.GetNetworkCredential().Password }
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Restart after promotion, then set DNS forwarder and verify the domain')) { return $out }
    if ("$out" -like '*already a domain controller*') { Write-Verbose 'Already a DC; skipping the restart.' }
    else {
        Write-Verbose "Restarting $VMName to finish the promotion."
        $null = Restart-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
    }
    $verified = $null
    foreach ($attempt in 1..$VerifyAttempts) {
        try {
            $verified = Invoke-ServerScript -ResourceGroupName $ResourceGroupName -VMName $VMName -Location $Location -Name 'AdPostConfig' `
                -ScriptPath (Join-Path $PSScriptRoot 'hostconfig' 'Set-AdPostConfig.ps1')
            break
        } catch {
            Write-Verbose "Domain not answering yet (attempt $attempt of $VerifyAttempts): $($_.Exception.Message.Split([char]10)[0])"
            if ($attempt -lt $VerifyAttempts) { Start-Sleep -Seconds 30 }
        }
    }
    if (-not $verified) { throw "The domain controller did not answer after $VerifyAttempts attempts. Check the VM's boot diagnostics and the AdPostConfig run command." }
    return $verified
}

function Set-ServerSqlConfig {
    <#
    .SYNOPSIS
        Post-install for a SQL marketplace VM: default folders on the data drive,
        optional mixed-mode with the sa password (protected parameter), firewall.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter()] [string]$DataDrive = 'F',
        [Parameter()] [pscredential]$SaCredential
    )
    $params = @{ DataDrive = $DataDrive; EnableSqlAuth = $(if ($SaCredential) { 1 } else { 0 }) }
    $protected = @{}
    if ($SaCredential) { $protected.SaPassword = $SaCredential.GetNetworkCredential().Password }
    Invoke-ServerScript -ResourceGroupName $ResourceGroupName -VMName $VMName -Location $Location -Name 'SqlPostConfig' `
        -ScriptPath (Join-Path $PSScriptRoot 'hostconfig' 'Set-SqlPostConfig.ps1') -Parameter $params -ProtectedParameter $protected
}

function Register-ServerSqlVm {
    <#
    .SYNOPSIS
        Registers the VM with the SQL IaaS Agent extension (SQL virtual machine
        resource) so the portal shows SQL settings, patching and backup options.
        Needs Az.SqlVirtualMachine; skipped with a warning when absent.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter()] [ValidateSet('PAYG', 'AHUB', 'DR')] [string]$LicenseType = 'PAYG'
    )
    if (-not (Get-Command New-AzSqlVM -ErrorAction SilentlyContinue)) {
        Write-Warning 'Az.SqlVirtualMachine is not installed; SQL IaaS extension registration skipped. Install-Module Az.SqlVirtualMachine, then register in the portal or re-run.'
        return $null
    }
    if (Get-AzSqlVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction SilentlyContinue) { Write-Verbose "$VMName is already a SQL virtual machine resource."; return }
    if ($PSCmdlet.ShouldProcess($VMName, "Register with the SQL IaaS Agent extension ($LicenseType)")) {
        Write-Verbose "Registering $VMName as a SQL virtual machine ($LicenseType)."
        return New-AzSqlVM -ResourceGroupName $ResourceGroupName -Name $VMName -Location $Location -LicenseType $LicenseType -SqlManagementType Full
    }
}

function Set-ServerVNetDnsServer {
    <#
    .SYNOPSIS
        Points a virtual network's DNS at the new domain controller (and Azure DNS
        as second). Every VM on the VNet picks it up on its next restart.
    .NOTES
        This is a live network change. Machines that depend on Azure DNS still get
        it as the second server, through the DC's forwarder as well.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$VirtualNetworkId,
        [Parameter(Mandatory)] [string]$DcPrivateIp
    )
    $parts = $VirtualNetworkId -split '/'
    $rg = $parts[4]; $name = $parts[-1]
    $vnet = Get-AzVirtualNetwork -ResourceGroupName $rg -Name $name -ErrorAction Stop
    $current = @($vnet.DhcpOptions.DnsServers)
    if ($current.Count -gt 0 -and $current[0] -eq $DcPrivateIp) { Write-Verbose "VNet $name already uses $DcPrivateIp for DNS."; return $vnet }
    if ($PSCmdlet.ShouldProcess($name, "Set VNet DNS servers to $DcPrivateIp, 168.63.129.16 (was: $(if ($current.Count) { $current -join ', ' } else { 'Azure default' }))")) {
        $vnet.DhcpOptions.DnsServers = @($DcPrivateIp, '168.63.129.16')
        Write-Verbose "Setting DNS on VNet $name to $DcPrivateIp then Azure DNS."
        return Set-AzVirtualNetwork -VirtualNetwork $vnet
    }
}
#endregion

#region Just-in-time RDP ------------------------------------------------------
#   WHAT   Open RDP to one VM from the caller's public IP for a set number of
#          minutes, hand back a .rdp file, and close it again when time is up.
#   WHY    The Nerdio "generate RDP" button: no permanent public RDP, no Bastion
#          bill, no remembering to close the port. Works for servers and for AVD
#          session hosts alike (anything with a NIC).
#   HOW    One NSG rule per VM, named jit-rdp-<vm>, allowing 3389 from the caller's
#          IP to the VM's private IP, with the expiry in its description. Revoking
#          sets the rule to Deny: nothing is deleted, the rule is reused next time.
#          The NSG is the NIC's, else the subnet's (rule scoped to this VM's private
#          IP), else a NIC-level NSG is created. A Standard public IP named
#          <vm>-jit-pip is created once and reused; Standard SKU denies all inbound
#          until an NSG rule allows it, so a parked IP is closed by design.
#   GOTCHA Expiry is enforced by whoever calls Revoke (the GUI does it on a timer
#          and on every Servers page refresh, Get-ServerRdpAccess reports it).
#          A rule left Allow because the GUI was closed is closed on the next visit.
$script:JitRulePrefix = 'jit-rdp-'

function Get-ServerNicContext {
    # VM -> NIC, IP configuration, private IP, and the NSG that governs it (NIC first, then subnet).
    param([Parameter(Mandatory)] [string]$ResourceGroupName, [Parameter(Mandatory)] [string]$Name)
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop
    $nic = Get-AzNetworkInterface -ResourceId $vm.NetworkProfile.NetworkInterfaces[0].Id -ErrorAction Stop
    $ipcfg = $nic.IpConfigurations[0]
    $nsg = $null; $nsgScope = 'none'
    if ($nic.NetworkSecurityGroup -and $nic.NetworkSecurityGroup.Id) {
        $p = $nic.NetworkSecurityGroup.Id -split '/'
        $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $p[4] -Name $p[-1] -ErrorAction Stop; $nsgScope = 'nic'
    } elseif ($ipcfg.Subnet -and $ipcfg.Subnet.Id) {
        $sp = $ipcfg.Subnet.Id -split '/'
        $vnet = Get-AzVirtualNetwork -ResourceGroupName $sp[4] -Name $sp[8] -ErrorAction Stop
        $subnet = $vnet.Subnets | Where-Object Name -eq $sp[-1] | Select-Object -First 1
        if ($subnet -and $subnet.NetworkSecurityGroup -and $subnet.NetworkSecurityGroup.Id) {
            $p = $subnet.NetworkSecurityGroup.Id -split '/'
            $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $p[4] -Name $p[-1] -ErrorAction Stop; $nsgScope = 'subnet'
        }
    }
    [pscustomobject]@{ Vm = $vm; Nic = $nic; IpConfig = $ipcfg; PrivateIp = $ipcfg.PrivateIpAddress; Nsg = $nsg; NsgScope = $nsgScope }
}

function Get-ServerCallerIp {
    <#
    .SYNOPSIS
        The public IPv4 address this machine appears from, via a public echo service.
    #>
    [CmdletBinding()]
    param()
    foreach ($uri in 'https://api.ipify.org?format=text', 'https://ifconfig.me/ip', 'https://icanhazip.com') {
        try {
            $ip = "$(Invoke-RestMethod -Uri $uri -TimeoutSec 10 -ErrorAction Stop)".Trim()
            if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') { return $ip }
        } catch { Write-Verbose "$uri did not answer: $($_.Exception.Message)" }
    }
    throw 'Could not determine your public IP. Pass -SourceIp.'
}

function Get-ServerRdpAccess {
    <#
    .SYNOPSIS
        State of the jit-rdp rule for a VM: Open (until when, from where), Expired,
        or Closed, plus the public IP if one is attached.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$ResourceGroupName, [Parameter(Mandatory)] [string]$Name)
    $ctx = Get-ServerNicContext -ResourceGroupName $ResourceGroupName -Name $Name
    $rule = $null
    if ($ctx.Nsg) { $rule = $ctx.Nsg.SecurityRules | Where-Object Name -eq "$script:JitRulePrefix$Name" | Select-Object -First 1 }
    $expires = $null
    if ($rule -and $rule.Description -match 'expires=([^;]+)') { try { $expires = [datetime]::Parse($Matches[1], $null, 'AdjustToUniversal') } catch { $expires = $null } }
    $state = if (-not $rule -or $rule.Access -ne 'Allow') { 'Closed' } elseif ($expires -and $expires -lt (Get-Date).ToUniversalTime()) { 'Expired' } else { 'Open' }
    $pip = $null
    if ($ctx.IpConfig.PublicIpAddress -and $ctx.IpConfig.PublicIpAddress.Id) {
        $pp = $ctx.IpConfig.PublicIpAddress.Id -split '/'
        $pip = (Get-AzPublicIpAddress -ResourceGroupName $pp[4] -Name $pp[-1] -ErrorAction SilentlyContinue).IpAddress
    }
    [pscustomobject]@{
        VM = $Name; State = $state; ExpiresUtc = $expires; SourceIp = $(if ($rule) { $rule.SourceAddressPrefix -join ',' } else { $null })
        PublicIp = $pip; PrivateIp = $ctx.PrivateIp; Nsg = $(if ($ctx.Nsg) { $ctx.Nsg.Name } else { $null }); NsgScope = $ctx.NsgScope
    }
}

function Grant-ServerRdpAccess {
    <#
    .SYNOPSIS
        Open RDP (3389) to a VM from one public IP for N minutes. Returns the
        address to connect to and when the access expires.
    .PARAMETER SourceIp
        The IP to allow. Default: this machine's public IP, looked up online.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter()] [ValidateRange(5, 1440)] [int]$Minutes = 60,
        [Parameter()] [string]$SourceIp,
        [Parameter()] [int]$Port = 3389
    )
    if (-not $SourceIp) { $SourceIp = Get-ServerCallerIp }
    if ($SourceIp -notmatch '^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$') { throw "SourceIp '$SourceIp' is not an IPv4 address or CIDR." }
    $ctx = Get-ServerNicContext -ResourceGroupName $ResourceGroupName -Name $Name
    $expires = (Get-Date).ToUniversalTime().AddMinutes($Minutes)
    $account = try { (Get-AzContext).Account.Id } catch { 'unknown' }
    $ruleName = "$script:JitRulePrefix$Name"
    if (-not $PSCmdlet.ShouldProcess($Name, "Allow RDP from $SourceIp until $($expires.ToString('u')) (public IP attached if missing)")) { return }

    # 1. Public IP: reuse <vm>-jit-pip, else whatever is attached, else create one.
    $ipcfg = $ctx.Nic.IpConfigurations[0]
    if (-not ($ipcfg.PublicIpAddress -and $ipcfg.PublicIpAddress.Id)) {
        $pipName = "$Name-jit-pip"
        $pip = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $pipName -ErrorAction SilentlyContinue
        if (-not $pip) {
            Write-Verbose "Creating public IP $pipName (Standard, static; closed until an NSG rule allows)."
            $pip = New-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $pipName -Location $ctx.Vm.Location -Sku Standard -AllocationMethod Static -Tag @{ purpose = 'jit-rdp' }
        }
        Write-Verbose "Attaching $pipName to $($ctx.Nic.Name)."
        $ctx.Nic.IpConfigurations[0].PublicIpAddress = $pip
        $ctx.Nic = Set-AzNetworkInterface -NetworkInterface $ctx.Nic
    }
    $pp = $ctx.Nic.IpConfigurations[0].PublicIpAddress.Id -split '/'
    $publicIp = (Get-AzPublicIpAddress -ResourceGroupName $pp[4] -Name $pp[-1]).IpAddress

    # 2. NSG: NIC's, else subnet's, else create one on the NIC.
    $nsg = $ctx.Nsg
    if (-not $nsg) {
        $nsgName = "$Name-nsg"
        $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $nsgName -ErrorAction SilentlyContinue
        if (-not $nsg) {
            Write-Verbose "Creating NSG $nsgName on the NIC (default rules only)."
            $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $nsgName -Location $ctx.Vm.Location
        }
        $ctx.Nic.NetworkSecurityGroup = $nsg
        $ctx.Nic = Set-AzNetworkInterface -NetworkInterface $ctx.Nic
        $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $nsgName
    }

    # 3. The rule: scoped to this VM's private IP so a subnet NSG does not open the whole subnet.
    $desc = "expires=$($expires.ToString('o'));by=$account;tool=jit-rdp"
    $existing = $nsg.SecurityRules | Where-Object Name -eq $ruleName | Select-Object -First 1
    $ruleParams = @{
        Name = $ruleName; Description = $desc; Access = 'Allow'; Protocol = 'Tcp'; Direction = 'Inbound'
        SourceAddressPrefix = $SourceIp; SourcePortRange = '*'; DestinationAddressPrefix = $ctx.PrivateIp; DestinationPortRange = "$Port"
    }
    if ($existing) {
        $ruleParams.Priority = $existing.Priority
        $null = Set-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg @ruleParams
    } else {
        $used = @($nsg.SecurityRules | ForEach-Object { [int]$_.Priority })
        $priority = 100; while ($priority -in $used) { $priority++ }
        $ruleParams.Priority = $priority
        $null = Add-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg @ruleParams
    }
    Write-Verbose "Rule ${ruleName}: allow TCP $Port from $SourceIp to $($ctx.PrivateIp) until $($expires.ToString('u'))."
    $null = Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg

    [pscustomobject]@{ VM = $Name; PublicIp = $publicIp; Port = $Port; SourceIp = $SourceIp; ExpiresUtc = $expires; ExpiresLocal = $expires.ToLocalTime(); Nsg = $nsg.Name; Rule = $ruleName }
}

function Revoke-ServerRdpAccess {
    <#
    .SYNOPSIS
        Close the jit-rdp rule for a VM by setting it to Deny. Nothing is deleted;
        the rule and the public IP stay for next time.
    .PARAMETER OnlyIfExpired
        Close only when the rule's expiry has passed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter()] [switch]$OnlyIfExpired
    )
    $ctx = Get-ServerNicContext -ResourceGroupName $ResourceGroupName -Name $Name
    $ruleName = "$script:JitRulePrefix$Name"
    $rule = if ($ctx.Nsg) { $ctx.Nsg.SecurityRules | Where-Object Name -eq $ruleName | Select-Object -First 1 } else { $null }
    if (-not $rule) { Write-Verbose "No $ruleName rule on $Name; nothing to close."; return [pscustomobject]@{ VM = $Name; State = 'Closed'; Changed = $false } }
    if ($rule.Access -eq 'Deny') { Write-Verbose "$ruleName is already Deny."; return [pscustomobject]@{ VM = $Name; State = 'Closed'; Changed = $false } }
    if ($OnlyIfExpired) {
        $expires = if ($rule.Description -match 'expires=([^;]+)') { [datetime]::Parse($Matches[1], $null, 'AdjustToUniversal') } else { $null }
        if ($expires -and $expires -gt (Get-Date).ToUniversalTime()) { return [pscustomobject]@{ VM = $Name; State = 'Open'; Changed = $false; ExpiresUtc = $expires } }
    }
    if ($PSCmdlet.ShouldProcess($Name, "Set $ruleName to Deny")) {
        Write-Verbose "Closing RDP on $Name ($ruleName -> Deny)."
        $null = Set-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $ctx.Nsg -Name $ruleName -Description "$($rule.Description -replace 'expires=[^;]+', 'expires=closed')" `
            -Access Deny -Protocol Tcp -Direction Inbound -Priority $rule.Priority -SourceAddressPrefix $rule.SourceAddressPrefix -SourcePortRange '*' `
            -DestinationAddressPrefix $rule.DestinationAddressPrefix -DestinationPortRange $rule.DestinationPortRange
        $null = Set-AzNetworkSecurityGroup -NetworkSecurityGroup $ctx.Nsg
    }
    [pscustomobject]@{ VM = $Name; State = 'Closed'; Changed = $true }
}

function New-ServerRdpFile {
    <#
    .SYNOPSIS
        Write a .rdp file for an address. Prompts for credentials on connect.
    .PARAMETER EntraAuth
        Add enablerdsaadauth:i:1 for Entra-joined machines (sign in with an Entra account).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$Address,
        [Parameter(Mandatory)] [string]$Path,
        [Parameter()] [int]$Port = 3389,
        [Parameter()] [string]$UserName,
        [Parameter()] [switch]$EntraAuth
    )
    $lines = @(
        "full address:s:${Address}:$Port"
        'prompt for credentials:i:1'
        'authentication level:i:2'
        'screen mode id:i:2'
        'use multimon:i:0'
        'redirectclipboard:i:1'
        'audiomode:i:0'
    )
    if ($UserName) { $lines += "username:s:$UserName" }
    if ($EntraAuth) { $lines += 'enablerdsaadauth:i:1' }
    if ($PSCmdlet.ShouldProcess($Path, "Write RDP file for ${Address}:$Port")) {
        $dir = Split-Path $Path -Parent
        if ($dir -and -not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        Set-Content -Path $Path -Value ($lines -join "`r`n") -Encoding ASCII
    }
    return $Path
}
#endregion

Export-ModuleMember -Function @(
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
