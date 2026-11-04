<#
.SYNOPSIS
    Change an app attach package: active or not, registration, one more host
    pool, or one more group with access.
.DESCRIPTION
    Only what you pass changes. Host pools and access are only ever added here;
    taking them away is done in the portal.
.PARAMETER SubscriptionId
    Subscription of the package.
.PARAMETER ResourceGroupName
    Resource group of the package.
.PARAMETER Name
    Package name.
.PARAMETER Active
    true or false.
.PARAMETER RegisterAtSignIn
    true (at sign-in) or false (on demand).
.PARAMETER AddHostPoolId
    Host pool to assign as well.
.PARAMETER GrantObjectId
    Entra group or user to give access.
.EXAMPLE
    ./Set-AppAttachPackage.ps1 -SubscriptionId <sub> -ResourceGroupName rg-avd-lab -Name myapp -Active $false
.NOTES
    Requires: Az.Accounts, Az.DesktopVirtualization, Az.Resources
    Status:   Untested
    Roles:    Desktop Virtualization Contributor; User Access Administrator to grant access.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$Name,
    [Parameter()] [Nullable[bool]]$Active,
    [Parameter()] [Nullable[bool]]$RegisterAtSignIn,
    [Parameter()] [string]$AddHostPoolId,
    [Parameter()] [string]$GrantObjectId
)
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AppDeploy' 'AppDeploy.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
if ($null -ne $Active -or $null -ne $RegisterAtSignIn) { Set-AppAttachPackageState -ResourceGroupName $ResourceGroupName -Name $Name -Active $Active -RegisterAtSignIn $RegisterAtSignIn }
if ($AddHostPoolId) { Add-AppAttachPackageHostPool -ResourceGroupName $ResourceGroupName -Name $Name -HostPoolId $AddHostPoolId }
if ($GrantObjectId) { Grant-AppAttachPackageAccess -ResourceGroupName $ResourceGroupName -Name $Name -ObjectId $GrantObjectId }
if (-not $WhatIfPreference) { Get-AppAttachPackageInfo | Where-Object { $_.Name -eq $Name -and $_.ResourceGroupName -eq $ResourceGroupName } }
