<#
.SYNOPSIS
    Start an Azure Automation runbook, or a runbook group, optionally waiting
    for the result.
.DESCRIPTION
    A runbook group (saved in the local store) runs its runbooks one after
    another, each waited for, stopping at the first that does not complete.
.PARAMETER SubscriptionId
    Subscription of the Automation account.
.PARAMETER AccountId
    Resource ID of the Automation account. A runbook group carries its own.
.PARAMETER Name
    Runbook name.
.PARAMETER RunbookGroup
    Or a runbook group from the local store.
.PARAMETER Parameter
    Runbook parameters, name = value.
.PARAMETER Wait
    Wait for the job and return its output.
.EXAMPLE
    ./Start-ToolboxRunbook.ps1 -SubscriptionId <sub> -AccountId <account-id> -Name Test-AvdHostHealth -Wait
.NOTES
    Requires: Az.Accounts, Az.Automation
    Status:   Untested
    Roles:    Automation Job Operator on the account.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter()] [string]$AccountId,
    [Parameter()] [string]$Name,
    [Parameter()] [string]$RunbookGroup,
    [Parameter()] [hashtable]$Parameter = @{},
    [Parameter()] [switch]$Wait
)
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AutomationAdmin' 'AutomationAdmin.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AppDeploy' 'AppDeploy.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
if ($RunbookGroup) {
    $store = Get-ToolboxStore
    if (-not $store.RunbookGroups.ContainsKey($RunbookGroup)) { throw "No runbook group '$RunbookGroup' in the local store." }
    $g = $store.RunbookGroups[$RunbookGroup]
    foreach ($rb in @($g.Runbooks)) {
        $r = Start-RunbookNow -AccountId $g.AccountId -Name $rb -Wait
        $r
        if ($r -and $r.Status -ne 'Completed') { Write-Warning "$rb ended $($r.Status); stopping the group."; break }
    }
} else {
    if (-not $AccountId -or -not $Name) { throw 'Give -AccountId and -Name, or -RunbookGroup.' }
    Start-RunbookNow -AccountId $AccountId -Name $Name -Parameter $Parameter -Wait:$Wait
}
