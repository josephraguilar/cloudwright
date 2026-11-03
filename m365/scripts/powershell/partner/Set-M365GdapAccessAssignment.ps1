<#
.SYNOPSIS
    Assigns our MSP security groups (from the template) to an active GDAP relationship.
.DESCRIPTION
    For each template group whose roles the relationship can grant, ensures the group holds
    them: creates its access assignment, or extends the one it already has (adds only the
    missing roles; Graph allows one assignment per group per relationship). Groups that
    already hold their roles are left alone. Verifies the relationship is active, the groups
    exist and the roles are within the relationship before writing.
    In a terminal it asks before each group, naming the customer and every role (Global
    Administrator, Privileged Role Administrator, Privileged Authentication Administrator first).
    A dry run (-WhatIf) signs in with the same write scope as a real run; it only reads.
.PARAMETER RelationshipId
    Active relationship id.
.PARAMETER GroupName
    Limit to these template groups (exact names). Default all.
.PARAMETER TemplatePath
    Override the template file.
.PARAMETER HomeTenantId
    Our partner tenant. Defaults to msp.homeTenantId.
.EXAMPLE
    ./Set-M365GdapAccessAssignment.ps1 -RelationshipId <id> -WhatIf
.NOTES
    Requires: Microsoft.Graph.Identity.Partner, Microsoft.Graph.Groups, Microsoft.Graph.Identity.Governance
    Graph scopes: DelegatedAdminRelationship.ReadWrite.All, Group.Read.All, RoleManagement.Read.Directory
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$RelationshipId,

    [Parameter()]
    [string[]]$GroupName,

    [Parameter()]
    [string]$TemplatePath,

    [Parameter()]
    [string]$HomeTenantId
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
Assert-M365WriteAllowed   # Refuse legacy write tasks before sign-in, lookups, or prompts.
Import-Module (Join-Path $modules 'GdapHelpers' 'GdapHelpers.psd1') -Force
$settings = Get-M365Settings
if (-not $HomeTenantId) { $HomeTenantId = $settings.msp.homeTenantId }
$templateParams = @{ Settings = $settings }
if ($TemplatePath) { $templateParams.Path = $TemplatePath }
$template = Get-GdapTemplate @templateParams
$null = Assert-M365Graph -TenantId $HomeTenantId -Scopes 'DelegatedAdminRelationship.ReadWrite.All', 'Group.Read.All', 'RoleManagement.Read.Directory'
#endregion

#region 3. Relationship and groups ----------------------------------------------------
$rel = Get-GdapRelationship -RelationshipId $RelationshipId -IncludeAssignments | Select-Object -First 1
if (-not $rel) { throw "Relationship $RelationshipId not found." }
if ($rel.Status -ne 'active') { throw "Relationship '$($rel.DisplayName)' for $($rel.Customer) is $($rel.Status); groups can only be assigned on an active relationship." }
$groups = @($template.Groups)
if ($GroupName) {
    $unknown = @($GroupName | Where-Object { $n = $_; -not @($groups | Where-Object { $_.Name -ieq $n }) })
    if ($unknown.Count -gt 0) { throw "Not template group(s): $($unknown -join ', '). Template groups: $(($groups | ForEach-Object { $_.Name }) -join ', ')." }
    $groups = @($groups | Where-Object { $n = $_.Name; @($GroupName | Where-Object { $_ -ieq $n }).Count -gt 0 })
}
#endregion

#region 4. Assign ---------------------------------------------------------------------------
#   WHAT   ConfirmImpact High: in a terminal each group is confirmed with its role names. The
#          module call then runs with -Confirm:$false; under -WhatIf it plans the exact call.
foreach ($g in $groups) {
    $grantable = @($g.RoleIds | Where-Object { $rel.RoleIds -contains $_ })
    if ($grantable.Count -eq 0) { Write-Warning "Relationship '$($rel.DisplayName)' grants none of the roles for group '$($g.Name)'; skipping."; continue }
    if ($grantable.Count -lt $g.RoleIds.Count) { Write-Warning "Group '$($g.Name)': $($g.RoleIds.Count - $grantable.Count) role(s) are not in this relationship and will need a supplementary one." }
    $held = @($rel.Assignments | Where-Object { $_.GroupId -ieq $g.Id -and $_.Status -notin 'deleted', 'deleting' } | ForEach-Object { $_.RoleIds })
    $toAdd = @($grantable | Where-Object { $held -notcontains $_ })
    $question = "Give our group '$($g.Name)' admin roles in customer '$($rel.Customer)' (tenant $($rel.CustomerTenantId)) through relationship '$($rel.DisplayName)'$(if ($held.Count -gt 0) { ", in addition to the $(@($held | Sort-Object -Unique).Count) role(s) it already holds there" }): $(Format-GdapRoleList -RoleIds $toAdd)"
    if ($toAdd.Count -eq 0 -or $WhatIfPreference -or $PSCmdlet.ShouldProcess($question, "$question`n`nMake this assignment?", 'Confirm GDAP group assignment')) {
        Set-GdapAccessAssignment -RelationshipId $rel.Id -GroupId $g.Id -RoleIds $grantable -WhatIf:$WhatIfPreference -Confirm:$false
    } else {
        Write-Warning "Not confirmed; group '$($g.Name)' was not changed."
    }
}
#endregion
