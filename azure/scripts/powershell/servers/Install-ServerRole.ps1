<#
.SYNOPSIS
    Turn an existing Windows VM into an IIS web server, the first domain
    controller of a new forest, or a configured SQL Server, by running scripts
    inside the guest.
.DESCRIPTION
    Roles:
      IIS       Web-Server with management console and ASP.NET 4.8, test page.
      ADForest  AD DS + DNS, new forest, database on the data drive if there is one,
                restart, DNS forwarder to Azure DNS, domain verified. Optionally
                points the VNet's DNS at the new DC (-SetVNetDns): a live change.
      SQL       For a SQL marketplace VM: default folders on the data drive,
                optional mixed-mode with sa, firewall rule, SQL IaaS registration.

    A raw data disk is formatted as F: first when -DataDrive is given and the drive
    does not exist yet. Secrets travel as protected run command parameters.
.PARAMETER SubscriptionId
    Subscription containing the VM.
.PARAMETER ResourceGroupName
    Resource group of the VM.
.PARAMETER Name
    VM name.
.PARAMETER Role
    IIS, ADForest or SQL.
.PARAMETER DataDrive
    Drive letter of the data disk (formatted if raw). Default F for ADForest and
    SQL, none for IIS.
.PARAMETER DomainName
    ADForest: DNS name of the new forest, e.g. corp.example.com.
.PARAMETER NetbiosName
    ADForest: NetBIOS name. Default: first label of the domain, upper case.
.PARAMETER SafeModeCredential
    ADForest: Directory Services Restore Mode password (the user name is ignored).
.PARAMETER SetVNetDns
    ADForest: set the VNet's DNS servers to this DC and Azure DNS.
.PARAMETER SaCredential
    SQL: enable mixed-mode authentication and set the sa password (user name ignored).
.PARAMETER SqlLicenseType
    SQL: PAYG (default), AHUB (Hybrid Benefit) or DR for the SQL IaaS registration.
.EXAMPLE
    ./Install-ServerRole.ps1 -SubscriptionId <sub> -ResourceGroupName rg-servers -Name web01 -Role IIS
.EXAMPLE
    ./Install-ServerRole.ps1 ... -Name dc01 -Role ADForest -DomainName corp.example.com -SafeModeCredential (Get-Credential dsrm) -SetVNetDns
.NOTES
    Requires: Az.Accounts, Az.Compute, Az.Network (Az.SqlVirtualMachine for SQL registration)
    Status:   Untested
    Roles:    Virtual Machine Contributor on the VM; Network Contributor on the VNet for -SetVNetDns.
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [ValidateSet('IIS', 'ADForest', 'SQL')]
    [string]$Role,

    [Parameter()]
    [string]$DataDrive,

    [Parameter()]
    [string]$DomainName,

    [Parameter()]
    [string]$NetbiosName,

    [Parameter()]
    [pscredential]$SafeModeCredential,

    [Parameter()]
    [switch]$SetVNetDns,

    [Parameter()]
    [pscredential]$SaCredential,

    [Parameter()]
    [ValidateSet('PAYG', 'AHUB', 'DR')]
    [string]$SqlLicenseType = 'PAYG'
)
#endregion

#region 2. Setup --------------------------------------------------------------
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'ServerBuild' 'ServerBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
$verbose = $VerbosePreference -eq 'Continue'

$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop
if (-not $PSBoundParameters.ContainsKey('DataDrive')) { $DataDrive = if ($Role -eq 'IIS') { '' } else { 'F' } }
if ($Role -eq 'ADForest' -and (-not $DomainName -or -not $SafeModeCredential)) { throw 'Role ADForest needs -DomainName and -SafeModeCredential.' }
$common = @{ ResourceGroupName = $ResourceGroupName; VMName = $Name; Location = $vm.Location; Verbose = $verbose }
#endregion

#region 3. Data disk ----------------------------------------------------------
#   WHAT   Format the raw data disk when one is attached and a drive is wanted.
#   WHY    AD database and SQL data belong on a disk with caching None, not the OS disk.
if ($DataDrive) {
    if (@($vm.StorageProfile.DataDisks).Count -eq 0) {
        Write-Warning "No data disk on $Name; $Role files will stay on the OS disk."
        $DataDrive = ''
    } else {
        $null = Initialize-ServerDataDisk @common -DriveLetter $DataDrive -Label "$Role-data"
    }
}
#endregion

#region 4. Role ---------------------------------------------------------------
$result = switch ($Role) {
    'IIS' {
        Install-ServerWebRole @common
    }
    'ADForest' {
        $out = Install-ServerAdForest @common -DomainName $DomainName -NetbiosName $NetbiosName -SafeModeCredential $SafeModeCredential -DataDrive $DataDrive
        if ($SetVNetDns -and -not $WhatIfPreference) {
            $nic = Get-AzNetworkInterface -ResourceId $vm.NetworkProfile.NetworkInterfaces[0].Id
            $ip = $nic.IpConfigurations[0].PrivateIpAddress
            $vnetId = ($nic.IpConfigurations[0].Subnet.Id -split '/subnets/')[0]
            $null = Set-ServerVNetDnsServer -VirtualNetworkId $vnetId -DcPrivateIp $ip -Verbose:$verbose
            $out += "`nVNet DNS now $ip then Azure DNS. Restart other VMs on the VNet to pick it up."
        }
        $out
    }
    'SQL' {
        $out = Set-ServerSqlConfig @common -DataDrive $DataDrive -SaCredential $SaCredential
        try { $null = Register-ServerSqlVm @common -LicenseType $SqlLicenseType } catch { Write-Warning "SQL IaaS registration failed: $($_.Exception.Message)" }
        $out
    }
}
if (-not $WhatIfPreference) {
    $tags = @{}   # VM.Tags is a .NET dictionary without Clone(); copy it by hand
    if ($vm.Tags) { foreach ($k in $vm.Tags.Keys) { $tags[$k] = $vm.Tags[$k] } }
    $tags['role'] = $Role
    $null = Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vm -Tag $tags
}
[pscustomobject]@{ VM = $Name; Role = $Role; DataDrive = $(if ($DataDrive) { "${DataDrive}:" } else { 'none' }); Output = "$result" }
#endregion
