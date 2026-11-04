<#
.SYNOPSIS
    Build a Windows server VM from a marketplace image, optionally with a data disk,
    and optionally make it an IIS box, the first DC of a new forest, or a SQL Server.
.DESCRIPTION
    Order:
      1. Quota and credential checks (nothing is created if they fail)
      2. NIC: static private IP for a DC (the address Azure assigns, pinned),
         optional public IP (no NSG rule is opened)
      3. VM: Trusted Launch, system-assigned identity, Premium OS disk,
         optional data disk (caching None; ReadOnly for SQL)
      4. Role, through Install-ServerRole.ps1

    Images are chosen by key: 'windowsserver:2025-datacenter-azure-edition' (the
    default) or 'sql:sql2022-ws2022:standard-gen2'. Get-ServerImageCatalog lists
    what the region offers. Role SQL expects a SQL image.
.PARAMETER SubscriptionId
    Subscription to build in.
.PARAMETER ResourceGroupName
    Existing resource group.
.PARAMETER Name
    VM name, 15 characters or fewer (it becomes the computer name).
.PARAMETER SubnetId
    Resource ID of the subnet.
.PARAMETER VMSize
    Default Standard_D2s_v5.
.PARAMETER ImageKey
    See above.
.PARAMETER LocalAdminCredential
    Local administrator. Azure's rules apply (not administrator/admin, 12+ chars).
.PARAMETER Role
    None (default), IIS, ADForest, SQL.
.PARAMETER DataDiskGB
    The role disk (F:, LUN 0, host caching off): AD database and SYSVOL, or SQL
    data, log and backup folders. Default: 32 GB for ADForest, 256 GB for SQL,
    none otherwise, which is Microsoft's recommendation. Pass 0 to build a DC or
    SQL box without one; the role then uses the OS disk.
.PARAMETER GeneralDataDiskGB
    An extra general-purpose disk (G:, LUN 1, read caching), any role. Default none.
.PARAMETER StaticPrivateIp
    Pin the private IP. On by default for ADForest.
.PARAMETER PublicIp
    Also create a Standard static public IP. Nothing is opened on any NSG.
.PARAMETER HybridBenefit
    Azure Hybrid Benefit (Windows_Server license). Only with Software Assurance.
.PARAMETER DomainName
    ADForest: DNS name of the new forest.
.PARAMETER NetbiosName
    ADForest: NetBIOS name.
.PARAMETER SafeModeCredential
    ADForest: DSRM password.
.PARAMETER SetVNetDns
    ADForest: point the VNet at the new DC.
.PARAMETER SaCredential
    SQL: enable mixed mode with this sa password.
.PARAMETER SqlLicenseType
    SQL: PAYG, AHUB or DR for the SQL IaaS registration.
.PARAMETER Tags
    Extra tags. 'role' is set automatically.
.EXAMPLE
    ./New-Server.ps1 -SubscriptionId <sub> -ResourceGroupName rg-servers -Name web01 -SubnetId <subnet-id> -LocalAdminCredential (Get-Credential srvadmin) -Role IIS
.EXAMPLE
    ./New-Server.ps1 ... -Name dc01 -Role ADForest -DomainName corp.example.com -SafeModeCredential (Get-Credential dsrm) -SetVNetDns -Verbose
.EXAMPLE
    ./New-Server.ps1 ... -Name sql01 -ImageKey 'sql:sql2022-ws2022:standard-gen2' -Role SQL -VMSize Standard_D4s_v5 -SaCredential (Get-Credential sa)
.NOTES
    Requires: Az.Accounts, Az.Compute, Az.Network, Az.Resources
    Status:   Untested
    Roles:    Virtual Machine Contributor and Network Contributor on the resource group.
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [ValidateLength(1, 15)] [string]$Name,
    [Parameter(Mandatory)] [string]$SubnetId,
    [Parameter()] [string]$VMSize = 'Standard_D2s_v5',
    [Parameter()] [string]$ImageKey = 'windowsserver:2025-datacenter-azure-edition',
    [Parameter(Mandatory)] [pscredential]$LocalAdminCredential,
    [Parameter()] [ValidateSet('None', 'IIS', 'ADForest', 'SQL')] [string]$Role = 'None',
    [Parameter()] [int]$DataDiskGB = -1,
    [Parameter()] [ValidateRange(0, 32767)] [int]$GeneralDataDiskGB = 0,
    [Parameter()] [switch]$StaticPrivateIp,
    [Parameter()] [switch]$PublicIp,
    [Parameter()] [switch]$HybridBenefit,
    [Parameter()] [ValidateSet('TrustedLaunch', 'Standard')] [string]$SecurityType = 'TrustedLaunch',
    [Parameter()] [string]$DomainName,
    [Parameter()] [string]$NetbiosName,
    [Parameter()] [pscredential]$SafeModeCredential,
    [Parameter()] [switch]$SetVNetDns,
    [Parameter()] [pscredential]$SaCredential,
    [Parameter()] [ValidateSet('PAYG', 'AHUB', 'DR')] [string]$SqlLicenseType = 'PAYG',
    [Parameter()] [hashtable]$Tags = @{}
)
#endregion

#region 2. Setup and checks ---------------------------------------------------
#   WHAT   Modules, context, resource group region, image, quota, credential rules.
#   WHY    Everything that can fail cheaply fails here, before a NIC exists.
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AvdBuild' 'AvdBuild.psd1') -Force      # quota and credential checks are generic -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'ServerBuild' 'ServerBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
$verbose = $VerbosePreference -eq 'Continue'

$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop
$location = $rg.Location
if ($DataDiskGB -lt 0) { $DataDiskGB = switch ($Role) { 'ADForest' { 32 } 'SQL' { 256 } default { 0 } } }   # -1 = recommended default
if ($DataDiskGB -gt 32767) { throw 'DataDiskGB must be 32767 or less.' }
if ($Role -in 'SQL', 'ADForest' -and $DataDiskGB -eq 0) { Write-Warning "No role disk: $Role files will live on the OS disk. Fine for a lab; Microsoft recommends a separate disk for production." }
if ($Role -eq 'ADForest') { $StaticPrivateIp = $true }
if ($Role -eq 'ADForest' -and (-not $DomainName -or -not $SafeModeCredential)) { throw 'Role ADForest needs -DomainName and -SafeModeCredential.' }
if ($Role -eq 'SQL' -and $ImageKey -notlike 'sql:*') { throw "Role SQL needs a SQL Server image, e.g. -ImageKey 'sql:sql2022-ws2022:standard-gen2'. Get-ServerImageCatalog lists them." }

$problems = @(Test-AvdVmCredentialPolicy -Credential $LocalAdminCredential)
if ($problems.Count -gt 0) { throw "Local admin credential: $($problems -join ' ')" }
$quota = Test-AvdVmSizeQuota -Location $location -VMSize $VMSize -Count 1
if (-not $quota.Ok) { throw "Quota preflight failed. $($quota.Message)" }
Write-Verbose $quota.Message
$image = Resolve-ServerImage -Location $location -ImageKey $ImageKey
Write-Verbose "Image: $($image.Label)."
$tags = $Tags.Clone(); $tags['role'] = $Role; $tags['workload'] = 'server'
#endregion

#region 3. NIC and VM ---------------------------------------------------------
$nic = New-ServerNic -ResourceGroupName $ResourceGroupName -VMName $Name -Location $location -SubnetId $SubnetId `
    -StaticPrivateIp:$StaticPrivateIp -PublicIp:$PublicIp -Tags $tags -Verbose:$verbose
$caching = if ($Role -eq 'SQL') { 'ReadOnly' } else { 'None' }
$vm = New-ServerVm -ResourceGroupName $ResourceGroupName -VMName $Name -Location $location -VMSize $VMSize -Image $image `
    -NicId $(if ($nic) { $nic.Id } else { '<nic>' }) -LocalAdminCredential $LocalAdminCredential -SecurityType $SecurityType `
    -DataDiskGB $DataDiskGB -DataDiskCaching $caching -GeneralDataDiskGB $GeneralDataDiskGB -HybridBenefit:$HybridBenefit -Tags $tags -Verbose:$verbose
if ($GeneralDataDiskGB -gt 0 -and -not $WhatIfPreference) {
    $generalLetter = if ($DataDiskGB -gt 0) { 'G' } else { 'F' }
    $null = Initialize-ServerDataDisk -ResourceGroupName $ResourceGroupName -VMName $Name -Location $location -Lun 1 -DriveLetter $generalLetter -Label 'Data' -Verbose:$verbose
}
#endregion

#region 4. Role ---------------------------------------------------------------
$roleOut = $null
if ($Role -ne 'None' -and -not $WhatIfPreference) {
    $p = @{ SubscriptionId = $SubscriptionId; ResourceGroupName = $ResourceGroupName; Name = $Name; Role = $Role; Verbose = $verbose }
    if ($DataDiskGB -gt 0) { $p.DataDrive = 'F' } else { $p.DataDrive = '' }
    if ($Role -eq 'ADForest') { $p.DomainName = $DomainName; $p.SafeModeCredential = $SafeModeCredential; if ($NetbiosName) { $p.NetbiosName = $NetbiosName }; if ($SetVNetDns) { $p.SetVNetDns = $true } }
    if ($Role -eq 'SQL') { if ($SaCredential) { $p.SaCredential = $SaCredential }; $p.SqlLicenseType = $SqlLicenseType }
    $roleOut = & (Join-Path $PSScriptRoot 'Install-ServerRole.ps1') @p
}
#endregion

#region 5. Result -------------------------------------------------------------
[pscustomobject]@{
    VM        = $Name
    PrivateIp = if ($nic) { $nic.IpConfigurations[0].PrivateIpAddress } else { $null }
    PublicIp  = if ($PublicIp -and $nic -and $nic.IpConfigurations[0].PublicIpAddress) { (Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name "$Name-pip").IpAddress } else { $null }
    Size      = $VMSize
    Image     = $image.Label
    RoleDisk  = if ($DataDiskGB -gt 0) { "$DataDiskGB GB (F:)" } else { 'none, role files on C:' }
    GeneralDisk = if ($GeneralDataDiskGB -gt 0) { "$GeneralDataDiskGB GB ($(if ($DataDiskGB -gt 0) { 'G' } else { 'F' }):)" } else { 'none' }
    Role      = $Role
    RoleOutput = if ($roleOut) { $roleOut.Output } else { $null }
    VmId      = if ($vm) { $vm.Id } else { $null }
}
#endregion
