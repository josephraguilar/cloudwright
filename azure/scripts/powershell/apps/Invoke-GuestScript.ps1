<#
.SYNOPSIS
    Run a library script, or a script group, inside VMs or a host pool's hosts.
.DESCRIPTION
    Scripts come from scripts/powershell/library (windows/ in the repo, local/ for
    your own). They run as SYSTEM through a managed Run Command on every target at
    once; VMs that are not running are skipped. A script group (saved in the
    local store) runs its scripts one after another, stopping at the first
    script that fails on any VM.
.PARAMETER VM
    Target VMs as resource-group/name.
.PARAMETER HostPoolName
    Or every session host of this host pool.
.PARAMETER HostPoolResourceGroupName
    Resource group of the host pool.
.PARAMETER SubscriptionId
    Subscription of the VMs.
.PARAMETER ScriptName
    Library script name (without .ps1).
.PARAMETER ScriptGroup
    Or a script group from the local store.
.PARAMETER Parameter
    Parameters for the script, name = value.
.EXAMPLE
    ./Invoke-GuestScript.ps1 -SubscriptionId <sub> -HostPoolName hp-lab -HostPoolResourceGroupName rg-avd-lab -ScriptName Get-DiskSpace -Parameter @{ MinFreePercent = 15 }
.NOTES
    Requires: Az.Accounts, Az.Compute, Az.DesktopVirtualization
    Status:   Untested
    Roles:    Virtual Machine Contributor on the VMs.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter()] [string[]]$VM = @(),
    [Parameter()] [string]$HostPoolName,
    [Parameter()] [string]$HostPoolResourceGroupName,
    [Parameter()] [string]$ScriptName,
    [Parameter()] [string]$ScriptGroup,
    [Parameter()] [hashtable]$Parameter = @{}
)
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AppDeploy' 'AppDeploy.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
if (-not $ScriptName -and -not $ScriptGroup) { throw 'Give -ScriptName or -ScriptGroup.' }
$library = @(Get-GuestScriptLibrary)
$names = if ($ScriptGroup) {
    $store = Get-ToolboxStore
    if (-not $store.ScriptGroups.ContainsKey($ScriptGroup)) { throw "No script group '$ScriptGroup' in the local store." }
    @($store.ScriptGroups[$ScriptGroup].Scripts)
} else { @($ScriptName) }
$targets = @(Resolve-GuestTarget -VM $VM -HostPoolName $HostPoolName -HostPoolResourceGroupName $HostPoolResourceGroupName)
foreach ($n in $names) {
    $entry = $library | Where-Object Name -eq $n | Select-Object -First 1
    if (-not $entry) { throw "No library script named '$n'." }
    $rc = 'toolbox-script-' + (($n -replace '[^A-Za-z0-9-]', '-').ToLower())
    $rows = @(Invoke-GuestRunCommand -Target $targets -Name $rc.Substring(0, [Math]::Min(60, $rc.Length)) -ScriptText (Get-Content $entry.Path -Raw) -Parameter $Parameter)
    $rows | Select-Object @{ n = 'Script'; e = { $n } }, VM, State, ExitCode, Output, Error
    $bad = @($rows | Where-Object { $_.State -notlike 'Skipped*' -and ($_.State -ne 'Succeeded' -or ($_.ExitCode -and $_.ExitCode -ne '0')) })
    if ($ScriptGroup -and $bad.Count -gt 0) { Write-Warning "$n failed on $($bad.VM -join ', '); stopping the group."; break }
}
