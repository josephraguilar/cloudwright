<#
.SYNOPSIS
    Creates a GDAP relationship from our template and locks it for customer approval.
.DESCRIPTION
    Looks up whose tenant the id or domain really is (display name and default domain) and
    shows it with the full role list (Global Administrator, Privileged Role Administrator and
    Privileged Authentication Administrator first) before asking to go ahead.

    Refuses when a request for this customer is already waiting for approval, or when active
    relationships already cover the template; -Force overrides that. When an active
    relationship exists, only the roles it lacks are requested (a supplementary request);
    the full template only when nothing usable exists.

    Prints and copies the approval link. Does not wait; see Wait-M365GdapApproval.ps1 or
    Start-M365GdapOnboarding.ps1 for the guided flow (which also retries a failed lock).
    A dry run (-WhatIf) signs in with the same write scope as a real run, so the real run
    needs no second consent; it only reads, and lists the exact Graph calls the real run makes.
.PARAMETER CustomerTenantId
    Customer tenant GUID or a verified domain (resolved and validated).
.PARAMETER CustomerName
    Used in the relationship display name (with today's date, max 50 characters).
.PARAMETER Force
    Create even when a request is pending or active relationships cover the template. Still
    requests only the roles no active relationship grants.
.PARAMETER NoBrowser
    Do not open the approval page on this machine (default opens a private browser window).
.PARAMETER TemplatePath
    Override the template file.
.PARAMETER HomeTenantId
    Our partner tenant. Defaults to msp.homeTenantId.
.EXAMPLE
    ./New-M365GdapRequest.ps1 -CustomerTenantId contoso.onmicrosoft.com -CustomerName 'Contoso Dental' -WhatIf
.NOTES
    Requires: Microsoft.Graph.Identity.Partner, Microsoft.Graph.Identity.Governance
    Graph scopes: DelegatedAdminRelationship.ReadWrite.All, CrossTenantInformation.ReadBasic.All, RoleManagement.Read.Directory
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The request summary and approval link must reach the operator.')]
param(
    [Parameter(Mandatory)]
    [string]$CustomerTenantId,

    [Parameter(Mandatory)]
    [string]$CustomerName,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$NoBrowser,

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
$tenantGuid = Resolve-M365TenantId -TenantId $CustomerTenantId
if ($tenantGuid -eq (Resolve-M365TenantId -TenantId $HomeTenantId)) { throw "'$CustomerTenantId' is our own partner tenant. GDAP is requested from a customer tenant." }
$null = Assert-M365Graph -TenantId $HomeTenantId -Scopes 'DelegatedAdminRelationship.ReadWrite.All', 'CrossTenantInformation.ReadBasic.All', 'RoleManagement.Read.Directory'
#endregion

#region 3. Whose tenant is this? -----------------------------------------------------
#   WHY    A mistyped domain (contoso.co) is somebody else's tenant. Show its real name and
#          domain before anything is requested.
$tenantInfo = Get-GdapTenantInfo -TenantId $tenantGuid
Write-Host "Customer tenant: '$($tenantInfo.DisplayName)'  $($tenantInfo.DefaultDomainName)  ($tenantGuid)" -ForegroundColor White
$ci = [StringComparison]::OrdinalIgnoreCase
if ($tenantInfo.DisplayName -and $tenantInfo.DisplayName.IndexOf($CustomerName, $ci) -lt 0 -and $CustomerName.IndexOf($tenantInfo.DisplayName, $ci) -lt 0) {
    Write-Warning "The tenant calls itself '$($tenantInfo.DisplayName)', not '$CustomerName'. Make sure this is the right customer before going ahead."
}
#endregion

#region 4. Check first ------------------------------------------------------------
$assessment = Test-GdapCompliance -CustomerTenantId $tenantGuid -Template $template
if ($assessment.PendingCount -gt 0 -and -not $Force) {
    $p = $assessment.Pending[0]
    throw "A GDAP request for this customer is already in flight: '$($p.DisplayName)' [$($p.Status)]$(if ($p.ApprovalUrl) { ". Approval link: $($p.ApprovalUrl)" }). Use Start-M365GdapOnboarding.ps1 to finish it (it retries a failed lock, waits and assigns), or -Force to create another request anyway."
}
if ($assessment.State -in 'Compliant', 'MissingAssignments' -and -not $Force) {
    throw "Customer already has active relationship(s) covering every template role (state $($assessment.State)). Use Set-M365GdapAccessAssignment.ps1 / Start-M365GdapOnboarding.ps1 for group assignments, or -Force to request anyway."
}
#   WHAT   Only what no ACTIVE relationship grants; the whole template when none is active.
$roleIds = @($template.RoleIds | Where-Object { @($assessment.CoveredRoleIds) -notcontains $_ })
if ($roleIds.Count -eq 0) { throw 'Active relationship(s) already grant every template role; there is nothing to request.' }
$summary = Get-GdapRequestSummary -CustomerTenantId $tenantGuid -CustomerName $CustomerName -Template $template -RoleIds $roleIds -TenantInfo $tenantInfo
Write-Host "  $($summary.Text)" -ForegroundColor Gray
#endregion

#region 5. Confirm and create ---------------------------------------------------------
#   WHAT   ConfirmImpact High: in a terminal this asks before anything is created, naming the
#          customer, tenant and every role. The module call then runs with -Confirm:$false.
#   GOTCHA Under -WhatIf the module still runs, so its plan (create + lock) is recorded.
if ($WhatIfPreference -or $PSCmdlet.ShouldProcess($summary.Text, "$($summary.Text)`n`nCreate this GDAP request?", 'Confirm GDAP request')) {
    $record = New-GdapRequest -CustomerTenantId $tenantGuid -CustomerName $CustomerName -Template $template -RoleIds $roleIds -TenantInfo $tenantInfo -WhatIf:$WhatIfPreference -Confirm:$false
} else {
    Write-Warning 'Not confirmed. Nothing was created.'
    return
}
if ($record.LockError) {
    Write-Warning "The relationship was created but not locked for approval, so the customer cannot approve it yet. Run Start-M365GdapOnboarding.ps1 -CustomerTenantId $tenantGuid -NoWait to retry the lock."
}
if ($record.ApprovalUrl -and -not $record.WhatIf) {
    Write-Host ''
    Write-Host '  Customer approval required. Sign in as a Global Administrator of the customer tenant, review the roles and approve:' -ForegroundColor Yellow
    Write-Host "  $($record.ApprovalUrl)" -ForegroundColor Cyan
    Write-Host ''
    if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) { try { Set-Clipboard -Value $record.ApprovalUrl; Write-Verbose 'Approval link copied to clipboard.' } catch { Write-Verbose 'Clipboard not available.' } }
    if (-not $NoBrowser) { $null = Open-GdapApprovalPage -Url $record.ApprovalUrl -WhatIf:$WhatIfPreference -Confirm:$false }
}
$record
#endregion
