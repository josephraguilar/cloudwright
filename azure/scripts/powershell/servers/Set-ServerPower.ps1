<#
.SYNOPSIS
    Start, deallocate, stop or restart one or more VMs by name.
.DESCRIPTION
    Deallocate is the stop that ends the compute bill. Stop (stay provisioned)
    keeps billing and the private IP lease, which is almost never what you want.
    Unlike the AVD version, there is no session check here: a server has no AVD
    sessions to look at. Restarting a domain controller or a SQL box affects
    whoever depends on it; the confirmation names the VMs.
.PARAMETER SubscriptionId
    Subscription containing the VMs.
.PARAMETER ResourceGroupName
    Resource group of the VMs.
.PARAMETER Name
    One or more VM names.
.PARAMETER Action
    Start, Deallocate, Stop or Restart.
.EXAMPLE
    ./Set-ServerPower.ps1 -SubscriptionId <sub> -ResourceGroupName rg-servers -Name dc01, web01 -Action Start
.NOTES
    Requires: Az.Accounts, Az.Compute
    Status:   Untested
    Roles:    Virtual Machine Contributor on the resource group.
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string[]]$Name,

    [Parameter(Mandatory)]
    [ValidateSet('Start', 'Deallocate', 'Stop', 'Restart')]
    [string]$Action
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'ServerBuild' 'ServerBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
#endregion

#region 3. Action -------------------------------------------------------------
#   WHAT   One call per VM; a failure on one is reported and the loop continues.
foreach ($n in $Name) {
    try {
        switch ($Action) {
            'Start'      { Start-ServerVm   -ResourceGroupName $ResourceGroupName -Name $n }
            'Deallocate' { Stop-ServerVm    -ResourceGroupName $ResourceGroupName -Name $n }
            'Stop'       { Stop-ServerVm    -ResourceGroupName $ResourceGroupName -Name $n -StayProvisioned }
            'Restart'    { Restart-ServerVm -ResourceGroupName $ResourceGroupName -Name $n }
        }
        [pscustomobject]@{ VM = $n; Action = $Action; Result = 'OK' }
    } catch {
        Write-Warning "$n`: $($_.Exception.Message)"
        [pscustomobject]@{ VM = $n; Action = $Action; Result = "Failed: $($_.Exception.Message)" }
    }
}
#endregion
