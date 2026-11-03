<#
.SYNOPSIS
    Finds groups by display name and returns their object ids and type.
.DESCRIPTION
    The everyday "what is the object id of that group" lookup. Used to fill the security
    group ids in config/gdap-roles.local.json, and for any script that needs a group id.
    Read-only. Defaults to our own tenant.
.PARAMETER Name
    Display name starts with this text (case-insensitive). Omit to list all groups (capped).
.PARAMETER TenantId
    Tenant to query. Defaults to msp.homeTenantId.
.PARAMETER IncludeMemberCount
    Also count members (one extra call per group).
.PARAMETER Top
    Maximum rows when -Name is omitted. Default 200.
.EXAMPLE
    ./Get-M365Group.ps1 -Name 'GDAP' | Format-Table DisplayName, Id, SecurityEnabled
.NOTES
    Requires: Microsoft.Graph.Groups
    Graph scopes: Group.Read.All
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Name,

    [Parameter()]
    [string]$TenantId,

    [Parameter()]
    [switch]$IncludeMemberCount,

    [Parameter()]
    [int]$Top = 200
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
if (-not $TenantId) { $TenantId = (Get-M365Settings).msp.homeTenantId }
$null = Assert-M365Graph -TenantId $TenantId -Scopes 'Group.Read.All'
#endregion

#region 3. Query ----------------------------------------------------------------
#   GOTCHA startswith is the only name filter Graph supports without advanced query.
$groups = if ($Name) {
    $safe = $Name.Replace("'", "''")
    Get-MgGroup -Filter "startswith(displayName,'$safe')" -All -Property id, displayName, securityEnabled, mailEnabled, groupTypes, description
} else {
    Get-MgGroup -Top $Top -Property id, displayName, securityEnabled, mailEnabled, groupTypes, description
}
foreach ($g in $groups | Sort-Object DisplayName) {
    $kind = if ($g.GroupTypes -contains 'Unified') { 'Microsoft 365' } elseif ($g.SecurityEnabled -and -not $g.MailEnabled) { 'Security' } elseif ($g.MailEnabled -and $g.SecurityEnabled) { 'Mail-enabled security' } else { 'Distribution' }
    $count = $null
    if ($IncludeMemberCount) { $count = (Get-MgGroupMember -GroupId $g.Id -All -ConsistencyLevel eventual -CountVariable c -ErrorAction SilentlyContinue | Measure-Object).Count }
    [pscustomobject]@{
        DisplayName     = $g.DisplayName
        Id              = $g.Id
        Type            = $kind
        SecurityEnabled = $g.SecurityEnabled
        MemberCount     = $count
        Description     = $g.Description
    }
}
#endregion
