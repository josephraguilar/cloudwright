<#
.SYNOPSIS
    Import a .pfx or .cer from this computer into the local machine certificate
    store of VMs or a host pool's hosts.
.DESCRIPTION
    The file (base64) and its password travel as protected Run Command
    parameters: encrypted, not logged, not shown in the result. Files over 120 KB
    are refused. A certificate already in the store is left alone.
.PARAMETER VM
    Target VMs as resource-group/name.
.PARAMETER HostPoolName
    Or every session host of this host pool.
.PARAMETER HostPoolResourceGroupName
    Resource group of the host pool.
.PARAMETER SubscriptionId
    Subscription of the VMs.
.PARAMETER FilePath
    The .pfx, .p12 or .cer file.
.PARAMETER Password
    The PFX password.
.PARAMETER StoreName
    My (Personal, default), Root, CA or TrustedPublisher (MSIX signing certificates).
.EXAMPLE
    ./Install-GuestCertificate.ps1 -SubscriptionId <sub> -HostPoolName hp-lab -HostPoolResourceGroupName rg-avd-lab -FilePath .\msix-signing.cer -StoreName TrustedPublisher
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
    [Parameter(Mandatory)] [string]$FilePath,
    [Parameter()] [securestring]$Password,
    [Parameter()] [ValidateSet('My', 'Root', 'CA', 'TrustedPublisher')] [string]$StoreName = 'My'
)
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AppDeploy' 'AppDeploy.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
$targets = @(Resolve-GuestTarget -VM $VM -HostPoolName $HostPoolName -HostPoolResourceGroupName $HostPoolResourceGroupName)
$p = @{ Target = $targets; FilePath = $FilePath; StoreName = $StoreName }
if ($Password) { $p.Password = $Password }
Install-GuestCertificate @p | Select-Object VM, State, ExitCode, Output, Error
