<#
.SYNOPSIS
    Finishes or repairs an existing session host VM: agent, FSLogix, login role, wait for Available.
.DESCRIPTION
    For a VM that exists but is not (or no longer) a healthy session host: a build that
    failed after the VM was created, an agent that will not register, a host that was
    built by hand. Re-runs the in-guest steps of New-AvdSessionHost.ps1 on the existing
    VM, each one idempotent:

      0. With -RejoinEntra: redo the Entra join (stale device record reported, or removed with -RemoveStaleEntraDevice; extension
         re-run, restart, verified with dsregcmd)
      1. Virtual Machine User Login for the user group (Entra ID only, optional)
      2. AVD agent via the DSC extension (a previous failed attempt is removed first)
      3. FSLogix registry via Run Command (optional)
      4. Wait for the host to show Available

    Does not touch the VM itself, the NIC, the disk, or the domain join.
.PARAMETER SubscriptionId
    Subscription containing the VM and host pool.
.PARAMETER ResourceGroupName
    Resource group of the VM.
.PARAMETER HostPoolName
    Host pool to (re)register to.
.PARAMETER HostPoolResourceGroupName
    Resource group of the host pool. Defaults to -ResourceGroupName.
.PARAMETER VMName
    The existing VM.
.PARAMETER JoinType
    How the VM is joined. EntraId (default) or ActiveDirectory. Decides the aadJoin
    flag for the agent and the Entra Kerberos registry values for FSLogix.
.PARAMETER UserGroupObjectId
    Entra group to grant Virtual Machine User Login on the VM. EntraId only.
.PARAMETER FsLogixProfileShare
    UNC path of the profile share. If set, FSLogix registry is (re)applied.
.PARAMETER RejoinEntra
    Redo the Entra ID join first: remove any stale device record with this name,
    remove and re-add the AADLoginForWindows extension, restart, verify with dsregcmd.
    Use when dsregcmd on the host says AzureAdJoined NO.
.PARAMETER ForceNewToken
    Generate a new registration token instead of reusing a valid one.
.PARAMETER DscArtifactsUrl
    Microsoft's AVD DSC package. Default is the current one.
.PARAMETER TimeoutMinutes
    How long to wait for Available. Default 20.
.EXAMPLE
    ./Repair-AvdSessionHost.ps1 -SubscriptionId <sub> -ResourceGroupName rg-avd-lab -HostPoolName hp-lab `
        -VMName avd-lab-01 -JoinType EntraId -UserGroupObjectId <group> `
        -FsLogixProfileShare '\\stavdlab.file.core.windows.net\profiles' -Verbose
.NOTES
    Requires: Az.Accounts, Az.Compute, Az.Resources, Az.DesktopVirtualization
    Status:   Untested
    Roles:    Contributor on the VM and host pool resource groups. User Access
              Administrator on the VM resource group if -UserGroupObjectId is used.
#>

#region 1. Parameters ---------------------------------------------------------
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
    [string]$VMName,

    [Parameter()]
    [ValidateSet('EntraId', 'ActiveDirectory')]
    [string]$JoinType = 'EntraId',

    [Parameter()]
    [string]$UserGroupObjectId,

    [Parameter()]
    [string]$FsLogixProfileShare,

    [Parameter()]
    [switch]$RejoinEntra,

    [Parameter()]
    [switch]$RemoveStaleEntraDevice,

    [Parameter()]
    [switch]$ForceNewToken,

    [Parameter()]
    [string]$DscArtifactsUrl = 'https://raw.githubusercontent.com/Azure/RDS-Templates/master/ARM-wvd-templates/DSC/Configuration.zip',

    [Parameter()]
    [int]$TimeoutMinutes = 20
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Modules, context, and confirm the VM exists. Everything else is
#          idempotent and safe to re-run.
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($RemoveStaleEntraDevice) { throw 'RemoveStaleEntraDevice is disabled: automatic directory cleanup cannot establish ownership by name. No changes were made.' }

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AvdHelpers' 'AvdHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AvdBuild' 'AvdBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
$verbose = ($VerbosePreference -eq 'Continue')

$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) { throw "VM $VMName not found in $ResourceGroupName. Repair is for a VM that already exists; use New-AvdSessionHost.ps1 to build one." }
$entra = ($JoinType -eq 'EntraId')
#endregion

#region 3. Token, login role, agent, FSLogix ---------------------------------
#   WHAT   The same in-guest steps as New-AvdSessionHost.ps1 regions 5, minus the
#          join (the VM is already joined; re-joining is a different problem).
#   WHY    A fresh token is fetched because the one from the original build may
#          have expired. Install-AvdAgent removes a failed previous attempt first.
if ($RejoinEntra) {
    if (-not $entra) { throw '-RejoinEntra only applies to JoinType EntraId.' }
    Join-AvdSessionHost -ResourceGroupName $ResourceGroupName -VMName $VMName -Location $vm.Location -JoinType EntraId -RemoveStaleEntraDevice:$RemoveStaleEntraDevice -Verbose:$verbose
}

$token = Get-AvdRegistrationToken -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName -Force:$ForceNewToken -Verbose:$verbose

if ($entra -and $UserGroupObjectId) {
    Grant-AvdVmLogin -ResourceGroupName $ResourceGroupName -VMName $VMName -ObjectId $UserGroupObjectId -Verbose:$verbose
}

Install-AvdAgent -ResourceGroupName $ResourceGroupName -VMName $VMName -Location $vm.Location -HostPoolName $HostPoolName `
    -RegistrationToken $token.Token -EntraJoined:$entra -DscArtifactsUrl $DscArtifactsUrl -Verbose:$verbose

if ($FsLogixProfileShare) {
    $null = Set-AvdSessionHostFsLogix -ResourceGroupName $ResourceGroupName -VMName $VMName -ProfileShare $FsLogixProfileShare -EntraKerberos:$entra -Verbose:$verbose
}
#endregion

#region 4. Verify and output --------------------------------------------------
if ($WhatIfPreference) {
    Write-Verbose 'WhatIf run. Nothing changed, nothing to verify.'
    return
}
$sessionHost = Wait-AvdSessionHostStatus -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName `
    -Name $VMName -Status 'Available' -TimeoutMinutes $TimeoutMinutes -RestartVmAfterMinutes 5 -Verbose:$verbose

[pscustomobject]@{
    VMName      = $VMName
    SessionHost = $sessionHost.Name
    Status      = $sessionHost.Status
    HostPool    = $HostPoolName
    JoinType    = $JoinType
}
#endregion
