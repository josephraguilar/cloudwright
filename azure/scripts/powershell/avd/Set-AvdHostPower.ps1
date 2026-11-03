<#
.SYNOPSIS
    Start, deallocate, stop or restart the VMs behind one or more session hosts.
.DESCRIPTION
    Power control by session host name, so you never have to look up which VM
    belongs to which host. Deallocate is the stop that ends the compute bill; Stop
    (stay provisioned) keeps billing and is rarely what you want.

    Stop and Restart refuse a host that still has user sessions unless -Force.
    Drain and log off first (Set-AvdHostDrain.ps1), or use Invoke-AvdRollingRestart.ps1,
    which does that dance for you one host at a time.
.PARAMETER SubscriptionId
    Subscription containing the host pool.
.PARAMETER ResourceGroupName
    Resource group of the host pool.
.PARAMETER HostPoolName
    Host pool name.
.PARAMETER SessionHostName
    One or more hosts: VM name, FQDN, or 'pool/fqdn'.
.PARAMETER Action
    Start, Deallocate, Stop or Restart.
.PARAMETER Force
    Stop or Restart even with users signed in.
.EXAMPLE
    ./Set-AvdHostPower.ps1 -SubscriptionId <sub> -ResourceGroupName rg-avd-lab -HostPoolName hp-lab -SessionHostName avd-lab-01 -Action Start
.EXAMPLE
    ./Set-AvdHostPower.ps1 ... -SessionHostName avd-lab-01, avd-lab-02 -Action Deallocate
.NOTES
    Requires: Az.Accounts, Az.DesktopVirtualization, Az.Compute
    Status:   Untested
    Roles:    Virtual Machine Contributor on the VMs' resource group (or Desktop
              Virtualization Power On Off Contributor), plus Reader on the host pool.
#>

#region 1. Parameters ---------------------------------------------------------
#   WHAT   Hosts and one action.
#   WHY    Several hosts per run so the GUI can act on a multi-select; one action
#          so the confirmation line is unambiguous.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$HostPoolName,

    [Parameter(Mandatory)]
    [string[]]$SessionHostName,

    [Parameter(Mandatory)]
    [ValidateSet('Start', 'Deallocate', 'Stop', 'Restart')]
    [string]$Action,

    [Parameter()]
    [switch]$Force
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AvdHelpers' 'AvdHelpers.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
#endregion

#region 3. Action -------------------------------------------------------------
#   WHAT   One module call per host; a failure on one host is reported and the
#          loop continues, so a multi-select does as much as it can.
#   WHY    -WhatIf flows into the module functions through SupportsShouldProcess.
$common = @{ ResourceGroupName = $ResourceGroupName; HostPoolName = $HostPoolName }
foreach ($h in $SessionHostName) {
    try {
        $vm = switch ($Action) {
            'Start'      { Start-AvdSessionHostVm   @common -SessionHostName $h }
            'Deallocate' { Stop-AvdSessionHostVm    @common -SessionHostName $h -Force:$Force }
            'Stop'       { Stop-AvdSessionHostVm    @common -SessionHostName $h -StayProvisioned -Force:$Force }
            'Restart'    { Restart-AvdSessionHostVm @common -SessionHostName $h -Force:$Force }
        }
        if ($vm) { [pscustomobject]@{ SessionHost = $vm.SessionHost; VM = $vm.Name; Action = $Action; Result = 'OK' } }
    } catch {
        Write-Warning "$h`: $($_.Exception.Message)"
        [pscustomobject]@{ SessionHost = $h; VM = $null; Action = $Action; Result = "Failed: $($_.Exception.Message)" }
    }
}
#endregion
