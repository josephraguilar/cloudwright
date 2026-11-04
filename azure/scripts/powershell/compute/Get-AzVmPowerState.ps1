<#
.SYNOPSIS
    Lists every VM in a subscription with its current power state.
.DESCRIPTION
    Wraps Get-AzVM -Status and flattens the result to Name, ResourceGroupName, Location
    and PowerState. Handy for a quick "what is running right now" check before stopping
    things to save money. Read-only.
.PARAMETER SubscriptionId
    Subscription to query. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Limit results to one resource group.
.EXAMPLE
    ./Get-AzVmPowerState.ps1
.EXAMPLE
    ./Get-AzVmPowerState.ps1 -ResourceGroupName rg-lab-dev | Where-Object PowerState -eq 'VM running'
.NOTES
    Requires: Az.Accounts, Az.Compute
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
#   WHAT   Both inputs optional. No SupportsShouldProcess because nothing changes.
#   WHY    A read-only script should never prompt or need -WhatIf.
[CmdletBinding()]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ResourceGroupName
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Strict mode, fail fast, load AzHelpers, confirm Azure context.
#   WHY    Same opening as every script in this repo. See _template.ps1.
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
#endregion

#region 3. Query --------------------------------------------------------------
#   WHAT   Build the Get-AzVM arguments as a hashtable and splat them.
#   WHY    Splatting lets us add ResourceGroupName only when it was supplied,
#          instead of writing two nearly identical Get-AzVM calls.
#   GOTCHA Without -Status, Get-AzVM returns no PowerState at all. -Status makes an
#          extra call per VM, so it is slower on big subscriptions.
$vmParams = @{ Status = $true }
if ($ResourceGroupName) { $vmParams.ResourceGroupName = $ResourceGroupName }
#endregion

#region 4. Output -------------------------------------------------------------
#   WHAT   Trim to the four useful columns and sort for readability.
#   WHY    Select-Object returns objects, so the caller can still pipe into
#          Where-Object or Export-Csv. Format-Table would have destroyed that.
Get-AzVM @vmParams |
    Select-Object Name, ResourceGroupName, Location, PowerState |
    Sort-Object ResourceGroupName, Name
#endregion
