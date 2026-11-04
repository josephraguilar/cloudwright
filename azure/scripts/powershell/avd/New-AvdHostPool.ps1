<#
.SYNOPSIS
    Creates an AVD host pool, desktop application group, workspace, and registration token.
.DESCRIPTION
    The control-plane half of an AVD deployment. Idempotent: safe to re-run. Existing
    resources are reused, never recreated or reconfigured. A valid registration token is
    reused unless it expires within an hour or -ForceNewToken is set.

    Thin wrapper: every step is a function in the AvdBuild or AvdHelpers module.
    Does NOT create session hosts. See New-AvdSessionHost.ps1 for that.
.PARAMETER SubscriptionId
    Subscription to deploy into.
.PARAMETER ResourceGroupName
    Resource group for all AVD objects. Created if missing.
.PARAMETER Location
    Azure region for the resource group and the AVD metadata objects.
.PARAMETER HostPoolName
    Name of the host pool.
.PARAMETER WorkspaceName
    Name of the workspace users see in the Remote Desktop client.
.PARAMETER AppGroupName
    Name of the desktop application group. Defaults to "<HostPoolName>-dag".
.PARAMETER FriendlyName
    Display name of the desktop in the client. Defaults to "Desktop".
.PARAMETER HostPoolType
    Pooled (shared hosts, FSLogix profiles) or Personal (one host per user).
.PARAMETER LoadBalancerType
    BreadthFirst or DepthFirst for Pooled. Personal pools always use Persistent.
.PARAMETER MaxSessionLimit
    Max concurrent sessions per host. Pooled only.
.PARAMETER StartVMOnConnect
    Let the AVD service power on a deallocated host when a user connects.
.PARAMETER UserGroupObjectId
    Entra ID group object ID to grant "Desktop Virtualization User" on the app group.
.PARAMETER TokenValidHours
    Lifetime of a newly generated registration token. 1 to 648 hours (27 days).
.PARAMETER ForceNewToken
    Generate a fresh token even if a valid one exists. Invalidates the old one.
.PARAMETER EntraJoined
    Session hosts will be Entra ID joined (not AD). Sets the targetisaadjoined RDP
    property on the pool so clients on non-Entra-joined devices can connect.
.EXAMPLE
    ./New-AvdHostPool.ps1 -SubscriptionId <sub-id> -ResourceGroupName rg-avd-lab -Location westus3 `
        -HostPoolName hp-lab -WorkspaceName ws-lab -UserGroupObjectId <entra-group-object-id> -EntraJoined -Verbose
.EXAMPLE
    ./New-AvdHostPool.ps1 -SubscriptionId <sub-id> -ResourceGroupName rg-avd-lab -Location westus3 `
        -HostPoolName hp-lab -WorkspaceName ws-lab -WhatIf
    Lists what would be created without touching anything.
.NOTES
    Requires: Az.Accounts, Az.Resources, Az.DesktopVirtualization
    Status:   Tested 2026-10-17 (Entra-joined pooled lab)
    Roles:    Contributor on the subscription (resource provider registration) or on the
              resource group. User Access Administrator or Owner on the resource group if
              -UserGroupObjectId is used (role assignments need it).
#>

#region 1. Parameters ---------------------------------------------------------
#   WHAT   Everything client-specific comes in here. Defaults are only for things that
#          have a sensible universal answer (app group name, token lifetime).
#   WHY    No tenant, subscription, or resource names live in this file.
#   GOTCHA Host pool, app group, and workspace are "metadata" objects and are only
#          supported in a subset of Azure regions. The VMs can live elsewhere.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$Location,

    [Parameter(Mandatory)]
    [string]$HostPoolName,

    [Parameter(Mandatory)]
    [string]$WorkspaceName,

    [Parameter()]
    [string]$AppGroupName = "$HostPoolName-dag",

    [Parameter()]
    [string]$FriendlyName = 'Desktop',

    [Parameter()]
    [ValidateSet('Pooled', 'Personal')]
    [string]$HostPoolType = 'Pooled',

    [Parameter()]
    [ValidateSet('BreadthFirst', 'DepthFirst')]
    [string]$LoadBalancerType = 'BreadthFirst',

    [Parameter()]
    [ValidateRange(1, 999)]
    [int]$MaxSessionLimit = 10,

    [Parameter()]
    [switch]$StartVMOnConnect,

    [Parameter()]
    [string]$UserGroupObjectId,

    [Parameter()]
    [ValidateRange(1, 648)]
    [int]$TokenValidHours = 24,

    [Parameter()]
    [switch]$ForceNewToken,

    [Parameter()]
    [switch]$EntraJoined
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Strict mode, fail fast, the three modules, Azure context, provider.
#   WHY    Same opening as every script. Assert-AzResourceProvider waits for
#          registration, which a fresh subscription needs before the first pool.
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AvdHelpers' 'AvdHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AvdBuild' 'AvdBuild.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
$verbose = ($VerbosePreference -eq 'Continue')

Assert-AzResourceProvider -Namespace 'Microsoft.DesktopVirtualization' -Verbose:$verbose
#endregion

#region 3. Resource group -----------------------------------------------------
#   WHAT   Create the resource group if it does not exist.
#   WHY    Everything else in this script lands here.
if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Create resource group')) {
        Write-Verbose "Creating resource group $ResourceGroupName in $Location."
        $null = New-AzResourceGroup -Name $ResourceGroupName -Location $Location
    }
} else {
    Write-Verbose "Resource group $ResourceGroupName exists."
}
#endregion

#region 4. Host pool, app group, workspace -----------------------------------
#   WHAT   Three get-or-create calls, then link app group to workspace.
#   WHY    Users are never assigned to a pool directly: pool <- app group <- user,
#          and the workspace is what shows up in the client feed. Each function is
#          one object; see AvdBuild.psm1 "Host pool objects" for the details.
#   GOTCHA Under -WhatIf a missing object comes back $null, so dependents only
#          dereference it inside branches -WhatIf skips.
$hostPool = New-AvdHostPoolResource -ResourceGroupName $ResourceGroupName -Name $HostPoolName -Location $Location `
    -HostPoolType $HostPoolType -LoadBalancerType $LoadBalancerType -MaxSessionLimit $MaxSessionLimit `
    -StartVMOnConnect:$StartVMOnConnect -EntraJoined:$EntraJoined -Verbose:$verbose

$appGroup = if ($hostPool) {
    New-AvdApplicationGroupResource -ResourceGroupName $ResourceGroupName -Name $AppGroupName -Location $Location `
        -HostPoolId $hostPool.Id -FriendlyName $FriendlyName -Verbose:$verbose
} elseif ($PSCmdlet.ShouldProcess($AppGroupName, 'Create desktop application group')) { $null }

$workspace = New-AvdWorkspaceResource -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -Location $Location -Verbose:$verbose

if ($workspace -and $appGroup) {
    Register-AvdApplicationGroupToWorkspace -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -ApplicationGroupId $appGroup.Id -Verbose:$verbose
} elseif ($PSCmdlet.ShouldProcess("$AppGroupName -> $WorkspaceName", 'Register application group to workspace')) { $null }
#endregion

#region 5. User assignment (optional) ----------------------------------------
#   WHAT   Desktop Virtualization User on the app group for the given Entra group.
#   WHY    The app group is the least-privilege scope that makes the desktop appear
#          in the feed. Needs User Access Administrator.
if ($UserGroupObjectId) {
    if ($appGroup) {
        Grant-AvdDesktopAccess -ApplicationGroupId $appGroup.Id -ObjectId $UserGroupObjectId -Verbose:$verbose
    } elseif ($PSCmdlet.ShouldProcess("$UserGroupObjectId on $AppGroupName", "Assign role 'Desktop Virtualization User'")) { $null }
}
#endregion

#region 6. Registration token -------------------------------------------------
#   WHAT   Get a token for the pool, reusing the current one if it has an hour left.
#   WHY    See AvdHelpers.psm1 "Registration token" for why reuse is the default.
#   GOTCHA The token is a secret, returned on purpose for New-AvdSessionHost.ps1.
#          Do not pipe this script's output to a log file.
$registration = if ($hostPool) {
    Get-AvdRegistrationToken -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -ValidHours $TokenValidHours -Force:$ForceNewToken -Verbose:$verbose
}
#endregion

#region 7. Output -------------------------------------------------------------
#   WHAT   One object with the names, IDs, and token the next script needs.
#   WHY    $pool = ./New-AvdHostPool.ps1 ... ; then pass $pool.RegistrationToken along.
if (-not ($hostPool -and $appGroup -and $workspace -and $registration)) {
    Write-Verbose 'WhatIf run or partial state. No output object.'
    return
}
[pscustomobject]@{
    HostPool          = $hostPool.Name
    HostPoolId        = $hostPool.Id
    HostPoolType      = $hostPool.HostPoolType
    AppGroup          = $appGroup.Name
    AppGroupId        = $appGroup.Id
    Workspace         = $workspace.Name
    TokenExpiresUtc   = $registration.ExpirationTime
    RegistrationToken = $registration.Token
}
#endregion
