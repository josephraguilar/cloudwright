<#
.SYNOPSIS
    Install apps on VMs or a host pool's hosts: winget packages, shell apps, app
    groups, or a saved deployment.
.DESCRIPTION
    winget packages install machine-wide, silently (the VM needs App Installer:
    Windows 11 and 10 multi-session have it). Shell apps are your own install
    scripts with a detection check, kept in the local store. An app group is a
    named list of both. A saved deployment holds its own targets and items.
.PARAMETER VM
    Target VMs as resource-group/name.
.PARAMETER HostPoolName
    Or every session host of this host pool.
.PARAMETER HostPoolResourceGroupName
    Resource group of the host pool.
.PARAMETER SubscriptionId
    Subscription of the VMs.
.PARAMETER WingetId
    winget package IDs, for example Google.Chrome.
.PARAMETER ShellApp
    Shell app names from the local store.
.PARAMETER AppGroup
    App group names from the local store.
.PARAMETER Deployment
    A saved deployment from the local store (its targets and items).
.PARAMETER Upgrade
    Upgrade the winget packages instead of installing.
.EXAMPLE
    ./Install-App.ps1 -SubscriptionId <sub> -HostPoolName hp-lab -HostPoolResourceGroupName rg-avd-lab -WingetId Google.Chrome, 7zip.7zip
.EXAMPLE
    ./Install-App.ps1 -SubscriptionId <sub> -Deployment 'Office hosts baseline'
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
    [Parameter()] [string[]]$WingetId = @(),
    [Parameter()] [string[]]$ShellApp = @(),
    [Parameter()] [string[]]$AppGroup = @(),
    [Parameter()] [string]$Deployment,
    [Parameter()] [switch]$Upgrade
)
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AppDeploy' 'AppDeploy.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
$store = Get-ToolboxStore
if ($Deployment) {
    if (-not $store.Deployments.ContainsKey($Deployment)) { throw "No deployment '$Deployment' in the local store." }
    $d = $store.Deployments[$Deployment]
    $VM = @($d.VM); $HostPoolName = $d.HostPoolName; $HostPoolResourceGroupName = $d.HostPoolResourceGroupName
    $WingetId += @($d.WingetId); $ShellApp += @($d.ShellApp); $AppGroup += @($d.AppGroup)
}
foreach ($g in $AppGroup | Where-Object { $_ }) {
    if (-not $store.AppGroups.ContainsKey($g)) { throw "No app group '$g' in the local store." }
    $WingetId += @($store.AppGroups[$g].WingetId); $ShellApp += @($store.AppGroups[$g].ShellApp)
}
$WingetId = @($WingetId | Where-Object { $_ } | Select-Object -Unique)
$ShellApp = @($ShellApp | Where-Object { $_ } | Select-Object -Unique)
if ($WingetId.Count -eq 0 -and $ShellApp.Count -eq 0) { throw 'Nothing to install: give -WingetId, -ShellApp, -AppGroup or -Deployment.' }
$targets = @(Resolve-GuestTarget -VM $VM -HostPoolName $HostPoolName -HostPoolResourceGroupName $HostPoolResourceGroupName)
if ($WingetId.Count) { Install-WingetPackage -Target $targets -Id $WingetId -Upgrade:$Upgrade | Select-Object @{ n = 'App'; e = { 'winget: ' + ($WingetId -join ', ') } }, VM, State, ExitCode, Output, Error }
foreach ($s in $ShellApp) { Install-ShellApp -Target $targets -Name $s | Select-Object @{ n = 'App'; e = { $s } }, VM, State, ExitCode, Output, Error }
