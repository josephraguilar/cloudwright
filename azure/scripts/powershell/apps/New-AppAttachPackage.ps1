<#
.SYNOPSIS
    Add an MSIX/AppX image or App-V package on a file share as an app attach
    package for a host pool, and optionally give a group access.
.DESCRIPTION
    A running session host in the pool reads the image, so its computer account
    needs read access to the share. The signing certificate must be trusted on
    the hosts (Install-GuestCertificate.ps1 -StoreName TrustedPublisher).
.PARAMETER SubscriptionId
    Subscription of the host pool.
.PARAMETER HostPoolResourceGroupName
    Resource group of the host pool (the package goes there too).
.PARAMETER HostPoolName
    Host pool.
.PARAMETER Path
    UNC path to the .vhdx, .cim or .appv on the share.
.PARAMETER Name
    Package resource name.
.PARAMETER DisplayName
    Name users see.
.PARAMETER Inactive
    Add it inactive (users do not get it yet).
.PARAMETER RegisterAtSignIn
    Register at sign-in instead of on demand.
.PARAMETER PackageFullName
    When the image holds several packages (x64 and x86), which one.
.PARAMETER GroupObjectId
    Entra group to give access (Desktop Virtualization User on the package).
.EXAMPLE
    ./New-AppAttachPackage.ps1 -SubscriptionId <sub> -HostPoolResourceGroupName rg-avd-lab -HostPoolName hp-lab -Path '\\stavd.file.core.windows.net\apps\MyApp.cim' -Name myapp -DisplayName 'My App' -GroupObjectId <group-id>
.NOTES
    Requires: Az.Accounts, Az.DesktopVirtualization, Az.Resources
    Status:   Untested
    Roles:    Desktop Virtualization Contributor on the resource group; User Access
              Administrator to grant access.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$HostPoolResourceGroupName,
    [Parameter(Mandatory)] [string]$HostPoolName,
    [Parameter(Mandatory)] [string]$Path,
    [Parameter(Mandatory)] [string]$Name,
    [Parameter(Mandatory)] [string]$DisplayName,
    [Parameter()] [switch]$Inactive,
    [Parameter()] [switch]$RegisterAtSignIn,
    [Parameter()] [string]$PackageFullName,
    [Parameter()] [string]$GroupObjectId
)
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AppDeploy' 'AppDeploy.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
$p = @{ HostPoolResourceGroupName = $HostPoolResourceGroupName; HostPoolName = $HostPoolName; Path = $Path; Name = $Name; DisplayName = $DisplayName; Inactive = $Inactive; RegisterAtSignIn = $RegisterAtSignIn }
if ($PackageFullName) { $p.PackageFullName = $PackageFullName }
New-AppAttachPackageResource @p
if ($GroupObjectId -and -not $WhatIfPreference) { Grant-AppAttachPackageAccess -ResourceGroupName $HostPoolResourceGroupName -Name $Name -ObjectId $GroupObjectId }
