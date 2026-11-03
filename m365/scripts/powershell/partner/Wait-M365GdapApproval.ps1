<#
.SYNOPSIS
    Watches a pending GDAP request until the customer approves it (or it fails / times out).
.DESCRIPTION
    Read-only polling. Ctrl+C stops waiting and leaves the request untouched; run again later
    with the same relationship id, or let Start-M365GdapOnboarding.ps1 resume from state.
.PARAMETER RelationshipId
    The relationship to watch. Defaults to the one in the customer's saved state when
    -CustomerTenantId is given instead.
.PARAMETER CustomerTenantId
    Look up the pending relationship id from runs/gdap/<tenant>.json.
.PARAMETER TimeoutMinutes
    Default from partner.approvalTimeoutMinutes, else 30.
.PARAMETER PollSeconds
    Default from partner.approvalPollSeconds, else 20.
.PARAMETER HomeTenantId
    Our partner tenant. Defaults to msp.homeTenantId.
.EXAMPLE
    ./Wait-M365GdapApproval.ps1 -CustomerTenantId contoso.onmicrosoft.com
.NOTES
    Requires: Microsoft.Graph.Identity.Partner
    Graph scopes: DelegatedAdminRelationship.Read.All
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter()]
    [string]$RelationshipId,

    [Parameter()]
    [string]$CustomerTenantId,

    [Parameter()]
    [int]$TimeoutMinutes,

    [Parameter()]
    [int]$PollSeconds,

    [Parameter()]
    [string]$HomeTenantId
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
Import-Module (Join-Path $modules 'GdapHelpers' 'GdapHelpers.psd1') -Force
$settings = Get-M365Settings
if (-not $HomeTenantId) { $HomeTenantId = $settings.msp.homeTenantId }
$partner = if ($settings.PSObject.Properties.Name -contains 'partner') { $settings.partner } else { $null }
if (-not $TimeoutMinutes) { $TimeoutMinutes = if ($partner -and $partner.approvalTimeoutMinutes) { [int]$partner.approvalTimeoutMinutes } else { 30 } }
if (-not $PollSeconds) { $PollSeconds = if ($partner -and $partner.approvalPollSeconds) { [int]$partner.approvalPollSeconds } else { 20 } }
if (-not $RelationshipId) {
    if (-not $CustomerTenantId) { throw 'Pass -RelationshipId or -CustomerTenantId.' }
    $state = Get-GdapState -CustomerTenantId (Resolve-M365TenantId -TenantId $CustomerTenantId)
    if (-not $state -or -not $state.relationshipId) { throw 'No saved GDAP request for that customer. Run New-M365GdapRequest.ps1 or pass -RelationshipId.' }
    $RelationshipId = $state.relationshipId
}
$null = Assert-M365Graph -TenantId $HomeTenantId -Scopes 'DelegatedAdminRelationship.Read.All'
#endregion

#region 3. Wait --------------------------------------------------------------------------
$record = Wait-GdapApproval -RelationshipId $RelationshipId -TimeoutMinutes $TimeoutMinutes -PollSeconds $PollSeconds
switch ($record.Result) {
    'Active' { Write-Verbose "Relationship '$($record.DisplayName)' is active." }
    'Failed' { Write-Warning "Relationship '$($record.DisplayName)' ended as $($record.Status)." }
    default { Write-Warning "Still $($record.Status) after $TimeoutMinutes minute(s). Approval link: $($record.ApprovalUrl)" }
}
$record
#endregion
