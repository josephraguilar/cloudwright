<#
.SYNOPSIS
    <One line: what this script does.>
.DESCRIPTION
    <A short paragraph. What it touches, what it does NOT touch, any gotchas.>
.PARAMETER SubscriptionId
    Subscription to run against. Defaults to the current Az context.
.PARAMETER Name
    <Describe every parameter.>
.EXAMPLE
    ./Verb-Noun.ps1 -Name example -WhatIf
    Shows what would happen without changing anything.
.NOTES
    Requires: Az.Accounts, <other Az.* modules this script uses>
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
#   WHAT   Declare every input up front. CmdletBinding turns on -Verbose, -WhatIf, etc.
#   WHY    No hard-coded names or IDs anywhere below. Everything client-specific
#          comes in through here, so the same script works in any tenant.
#   GOTCHA SupportsShouldProcess is only honest if you actually call
#          $PSCmdlet.ShouldProcess() before every change. See region 3.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$Name
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Strict mode, fail fast, load the shared module, confirm Azure context.
#   WHY    StrictMode catches typos in variable names. ErrorActionPreference = Stop
#          turns every cmdlet error into a terminating one so the script never
#          limps on after a failed step. Assert-AzContext makes the script behave
#          the same whether you were already logged in or not.
#   GOTCHA When this file lives in a service folder (avd/, backup/) the module
#          path is '..', 'modules', ...
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
# GOTCHA Module functions do not inherit -WhatIf, -Verbose or -Confirm:$false from
#        this script: preference variables stop at a module boundary, so a dry run
#        would make real changes. Set-AzScriptDefault hands them on. Call it after
#        the last Import-Module. The tests fail a script that forgets.
Set-AzScriptDefault
$null = Assert-AzContext -SubscriptionId $SubscriptionId
#endregion

#region 3. Do the work --------------------------------------------------------
#   WHAT   <The actual change, one logical step per sub-block.>
#   WHY    <Why this order. What depends on what.>
if ($PSCmdlet.ShouldProcess($Name, 'Describe the change in a few words')) {
    Write-Verbose "Doing the thing to $Name"
    # Do the thing here.
}
#endregion

#region 4. Output -------------------------------------------------------------
#   WHAT   Return objects, not formatted text, so the caller can pipe them.
#   WHY    A future app or runbook consuming this script needs data, not strings.
#endregion
