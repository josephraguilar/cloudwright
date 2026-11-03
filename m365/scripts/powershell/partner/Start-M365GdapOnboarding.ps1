<#
.SYNOPSIS
    Guided, idempotent GDAP onboarding for one customer: inspect, compare, request, wait, assign, verify.
.DESCRIPTION
    The GDAP orchestrator. Order:

      1. Sign in to our partner tenant (Assert-M365Graph).
      2. Resolve the customer tenant (GUID or domain) and look up whose it is: its display
         name and default domain are shown before anything is requested.
      3. List existing relationships and assignments; load saved state (runs/gdap/).
      4. Compare against the template (Compare-GdapRelationship) and print the assessment.
      5. Act on the state:
           NoRelationship / Expired   create + lock (confirmation listing every role), show link
           MissingRoles               supplementary request with only the missing roles (confirmation)
           PendingApproval            reuse the request in flight and its link; never request again.
                                      If our own request was created but its lock failed
                                      ('created'), retry the lock instead of waiting for an
                                      approval the customer cannot give. A 'created' request
                                      this toolkit did not create is never locked.
           MissingAssignments         create or extend only the missing group assignments
           Compliant                  nothing to change
      6. If a request is pending, wait for approval (unless -NoWait). Ctrl+C keeps the request.
      7. Assign the template groups on active relationships (after approval, on the new one).
      8. Re-query and report the final state. Success is claimed only when the re-query says so.

    Never terminates or replaces an existing relationship. Every Graph change goes through
    Invoke-M365Change, so -WhatIf lists each exact call (including the assignments the run
    would make after approval). A dry run signs in with the same write scope as a real run,
    so the real run needs no second consent; it only reads. Re-running is how you finish
    after the customer approves days later.
.PARAMETER CustomerTenantId
    Customer tenant GUID or any verified domain.
.PARAMETER CustomerName
    Display name for the relationship. Defaults to the GDAP customer list name, else the
    tenant's own display name.
.PARAMETER NoWait
    Create, lock or reuse the request (and assign groups on relationships that are already
    active), then return without polling. Never prompts: the confirmation is skipped unless
    you add -Confirm, so review a -WhatIf dry run first. This is how the GUI can run it.
.PARAMETER NoBrowser
    Do not open the approval page here. Default is to open it in a private browser window on
    this machine, because the technician is normally the approver with their own admin account
    in the customer tenant. The link is printed and copied either way.
.PARAMETER TimeoutMinutes
    How long to wait for approval. Default from partner.approvalTimeoutMinutes, else 30.
.PARAMETER TemplatePath
    Override the template file.
.PARAMETER HomeTenantId
    Our partner tenant. Defaults to msp.homeTenantId.
.EXAMPLE
    ./Start-M365GdapOnboarding.ps1 -CustomerTenantId contoso.onmicrosoft.com -CustomerName 'Contoso Dental' -WhatIf
.EXAMPLE
    ./Start-M365GdapOnboarding.ps1 -CustomerTenantId contoso.onmicrosoft.com -NoWait
.NOTES
    Requires: Microsoft.Graph.Identity.Partner, Microsoft.Graph.Groups, Microsoft.Graph.Identity.Governance
    Graph scopes: DelegatedAdminRelationship.ReadWrite.All, Group.Read.All, RoleManagement.Read.Directory, CrossTenantInformation.ReadBasic.All
    Status:   Untested
    Interactive: yes (waits for customer approval at the keyboard; add -NoWait to run it without waiting)
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Guided workflow output for the operator; results are also returned as an object.')]
param(
    [Parameter(Mandatory)]
    [string]$CustomerTenantId,

    [Parameter()]
    [string]$CustomerName,

    [Parameter()]
    [switch]$NoWait,

    [Parameter()]
    [switch]$NoBrowser,

    [Parameter()]
    [int]$TimeoutMinutes,

    [Parameter()]
    [string]$TemplatePath,

    [Parameter()]
    [string]$HomeTenantId
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   GOTCHA -NoWait means "runs without anyone at the keyboard" (the GUI's worker has no
#          console): no approval wait and no confirmation prompt, unless -Confirm is passed.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($NoWait -and -not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference = 'None' }
$modules = Join-Path $PSScriptRoot '..' 'modules'
Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
Import-Module (Join-Path $modules 'GdapHelpers' 'GdapHelpers.psd1') -Force
$settings = Get-M365Settings
if (-not $HomeTenantId) { $HomeTenantId = $settings.msp.homeTenantId }
$partner = if ($settings.PSObject.Properties.Name -contains 'partner') { $settings.partner } else { $null }
if (-not $TimeoutMinutes) { $TimeoutMinutes = if ($partner -and $partner.PSObject.Properties.Name -contains 'approvalTimeoutMinutes' -and $partner.approvalTimeoutMinutes) { [int]$partner.approvalTimeoutMinutes } else { 30 } }
$pollSeconds = if ($partner -and $partner.PSObject.Properties.Name -contains 'approvalPollSeconds' -and $partner.approvalPollSeconds) { [int]$partner.approvalPollSeconds } else { 20 }
$templateParams = @{ Settings = $settings }
if ($TemplatePath) { $templateParams.Path = $TemplatePath }
$template = Get-GdapTemplate @templateParams
$scopes = 'DelegatedAdminRelationship.ReadWrite.All', 'Group.Read.All', 'RoleManagement.Read.Directory', 'CrossTenantInformation.ReadBasic.All'
$cid = New-M365CorrelationId
$tenantGuid = $null
$log = { param($m, $d) $null = Write-M365Log -Operation 'Start-M365GdapOnboarding' -TenantId $tenantGuid -CorrelationId $cid -Message $m -Data $d }

Write-Host ''
Write-Host "GDAP onboarding  template '$($template.name)'  ($($template.RoleIds.Count) roles, $($template.Groups.Count) groups)$(if ($WhatIfPreference) { '   (WhatIf: nothing will change)' })" -ForegroundColor White
#endregion

#region 3. Sign in and resolve customer -----------------------------------------
$tenantGuid = Resolve-M365TenantId -TenantId $CustomerTenantId
if ($tenantGuid -eq (Resolve-M365TenantId -TenantId $HomeTenantId)) { throw "'$CustomerTenantId' is our own partner tenant. GDAP is requested from a customer tenant." }
Write-M365Step -Id 'G.1' -Name 'Partner sign-in' -Status Info -Detail $HomeTenantId
$null = Assert-M365Graph -TenantId $HomeTenantId -Scopes $scopes
#   WHY    A mistyped domain is somebody else's tenant: show whose it really is first.
$tenantInfo = Get-GdapTenantInfo -TenantId $tenantGuid
$known = Get-GdapCustomer -TenantId $tenantGuid | Select-Object -First 1
if (-not $CustomerName) { $CustomerName = if ($known) { $known.DisplayName } elseif ($tenantInfo.DisplayName) { $tenantInfo.DisplayName } else { $CustomerTenantId } }
Write-M365Step -Id 'G.2' -Name "Customer $CustomerName" -Status Info -Detail "tenant '$($tenantInfo.DisplayName)'  $($tenantInfo.DefaultDomainName)  ($tenantGuid)$(if (-not $known) { '  (not yet a GDAP customer)' })"
$ci = [StringComparison]::OrdinalIgnoreCase
if ($tenantInfo.DisplayName -and $tenantInfo.DisplayName.IndexOf($CustomerName, $ci) -lt 0 -and $CustomerName.IndexOf($tenantInfo.DisplayName, $ci) -lt 0) {
    Write-Warning "The tenant calls itself '$($tenantInfo.DisplayName)', not '$CustomerName'. Make sure this is the right customer before going ahead."
}
& $log 'Run started' @{ customer = $CustomerName; template = $template.name; whatIf = [bool]$WhatIfPreference }
#endregion

#region 4. Inspect and compare ------------------------------------------------------
$state = Get-GdapState -CustomerTenantId $tenantGuid
if ($state -and $state.PSObject.Properties.Name -contains 'relationshipId' -and $state.relationshipId) { Write-Verbose "Saved state points at relationship $($state.relationshipId)." }
$assessment = Test-GdapCompliance -CustomerTenantId $tenantGuid -Template $template
Write-M365Step -Id 'G.3' -Name 'Existing relationships' -Status Info -Detail "$($assessment.ActiveCount) active, $($assessment.PendingCount) pending, $($assessment.ExpiredCount) expired/terminated"
foreach ($r in @($assessment.Active) + @($assessment.Pending)) { Write-Host ("{0,-16}{1}  [{2}]  {3} role(s), ends {4}, auto-extend {5}, {6} assignment(s)" -f '', $r.DisplayName, $r.Status, $r.RoleIds.Count, $(if ($r.EndDateTime) { ([datetime]$r.EndDateTime).ToString('yyyy-MM-dd') } else { 'n/a' }), $r.AutoExtend, $r.Assignments.Count) -ForegroundColor DarkGray }
$stateStatus = switch ($assessment.State) { 'Compliant' { 'Done' } 'PendingApproval' { 'Info' } default { 'Manual' } }
Write-M365Step -Id 'G.4' -Name "Compliance: $($assessment.State)" -Status $stateStatus -Detail "covered $($assessment.CoveredRoles.Count), missing roles $($assessment.MissingRoles.Count), missing assignments $($assessment.MissingAssignments.Count)"
foreach ($w in $assessment.Warnings) { Write-Warning $w }
foreach ($a in $assessment.ProposedActions) { Write-Host ("{0,-16}-> [{1}] {2}" -f '', $a.Action, $a.Detail) -ForegroundColor DarkGray }
#endregion

#region 5. Request, retry the lock, or reuse ---------------------------------------------
#   GOTCHA Creation only happens after a fresh, successful listing. A failed listing
#          threw above and never reaches this point.
#   WHAT   $waitFor: a real request to wait for. $planned: a request that is not active yet
#          (dry-run create, or one in flight) used to plan the post-approval assignments.
$pending = $assessment.Pending | Select-Object -First 1
$waitFor = $null
$planned = $null
if ($assessment.State -in 'NoRelationship', 'Expired', 'MissingRoles') {
    $roleIds = @(if ($assessment.State -eq 'MissingRoles') { $assessment.MissingRoleIds } else { $template.RoleIds })
    $what = if ($assessment.State -eq 'MissingRoles') { "supplementary relationship with $($roleIds.Count) missing role(s)" } else { "relationship with $($roleIds.Count) role(s)" }
    $summary = Get-GdapRequestSummary -CustomerTenantId $tenantGuid -CustomerName $CustomerName -Template $template -RoleIds $roleIds -TenantInfo $tenantInfo
    Write-Host ("{0,-16}{1}" -f '', $summary.Text) -ForegroundColor Gray
    if ($WhatIfPreference -or $PSCmdlet.ShouldProcess($summary.Text, "$($summary.Text)`n`nCreate this GDAP request and send it for approval?", 'Confirm GDAP request')) {
        $created = New-GdapRequest -CustomerTenantId $tenantGuid -CustomerName $CustomerName -Template $template -RoleIds $roleIds -TenantInfo $tenantInfo -CorrelationId $cid -WhatIf:$WhatIfPreference -Confirm:$false
        if ($created.WhatIf) {
            Write-M365Step -Id 'G.5' -Name "Create $what" -Status WhatIf -Detail "$($created.DisplayName), then lock it for approval"
            $planned = $created
        } elseif ($created.Declined) {
            Write-M365Step -Id 'G.5' -Name "Create $what" -Status Skipped -Detail 'Not confirmed; nothing was created.'
        } elseif ($created.LockError) {
            Write-M365Step -Id 'G.5' -Name "Create $what" -Status Failed -Detail "$($created.Id) created but NOT locked for approval: $($created.LockError). Re-run to retry the lock."
        } else {
            Write-M365Step -Id 'G.5' -Name "Create $what" -Status Done -Detail "$($created.Id)  status $($created.Status)"
            $waitFor = $created
        }
    } else {
        Write-M365Step -Id 'G.5' -Name "Create $what" -Status Skipped -Detail 'Not confirmed; nothing was created.'
    }
} elseif ($pending -and $pending.Status -eq 'created') {
    #   WHAT   Lock-failure recovery. Lock-GdapRelationship refuses a relationship our saved
    #          state does not name as ours, and anything not in status 'created'.
    $question = "Send relationship '$($pending.DisplayName)' to customer '$($tenantInfo.DisplayName)' ($($tenantInfo.DefaultDomainName)) for approval (retry lockForApproval): $(Format-GdapRoleList -RoleIds $pending.RoleIds)"
    try {
        if ($WhatIfPreference -or $PSCmdlet.ShouldProcess($question, "$question`n`nLock it for approval now?", 'Confirm GDAP lock')) {
            $locked = Lock-GdapRelationship -RelationshipId $pending.Id -TenantInfo $tenantInfo -CorrelationId $cid -WhatIf:$WhatIfPreference -Confirm:$false
            if ($locked.WhatIf) { Write-M365Step -Id 'G.5' -Name 'Retry lock for approval' -Status WhatIf -Detail "$($pending.DisplayName) was created but never locked"; $planned = $pending }
            elseif ($locked.Locked) { Write-M365Step -Id 'G.5' -Name 'Retry lock for approval' -Status Done -Detail "$($locked.DisplayName)  status $($locked.Status)"; $waitFor = $locked }
            else { Write-M365Step -Id 'G.5' -Name 'Retry lock for approval' -Status Skipped -Detail 'Not confirmed; the request stays unlocked.' }
        } else {
            Write-M365Step -Id 'G.5' -Name 'Retry lock for approval' -Status Skipped -Detail 'Not confirmed; the request stays unlocked.'
        }
    } catch {
        Write-M365Step -Id 'G.5' -Name 'Retry lock for approval' -Status Failed -Detail $_.Exception.Message
        & $log "Lock retry failed: $($_.Exception.Message)" @{ relationshipId = $pending.Id }
    }
} elseif ($pending) {
    Write-M365Step -Id 'G.5' -Name 'Reuse pending request' -Status Done -Detail "$($pending.DisplayName)  [$($pending.Status)]"
    if ($WhatIfPreference) { $planned = $pending } else { $waitFor = $pending }
} else {
    Write-M365Step -Id 'G.5' -Name 'Create request' -Status Skipped -Detail 'Not needed.'
}

$linkFrom = if ($waitFor) { $waitFor } elseif ($planned -and $planned.Id) { $planned } else { $null }
if ($linkFrom -and $linkFrom.PSObject.Properties.Name -contains 'ApprovalUrl' -and $linkFrom.ApprovalUrl) {
    Write-Host ''
    Write-Host '  Customer approval required. Sign in as a Global Administrator of the customer tenant, review the roles and approve:' -ForegroundColor Yellow
    Write-Host "  $($linkFrom.ApprovalUrl)" -ForegroundColor Cyan
    Write-Host ''
    #   GOTCHA Clipboard and browser are local side effects: never under -WhatIf.
    if (-not $WhatIfPreference) {
        if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) { try { Set-Clipboard -Value $linkFrom.ApprovalUrl; Write-Host '  (copied to clipboard)' -ForegroundColor DarkGray } catch { Write-Verbose 'Clipboard not available.' } }
        if (-not $NoBrowser) {
            $opened = Open-GdapApprovalPage -Url $linkFrom.ApprovalUrl -Confirm:$false
            Write-Host "  (opened in $($opened.Browser)$(if ($opened.Private) { ', private window' }); if the wrong account is offered, pick the customer-tenant admin)" -ForegroundColor DarkGray
        }
    }
}
#endregion

#region 6. Wait for approval -----------------------------------------------------------
$activeRel = $null
if ($waitFor) {
    if ($NoWait) {
        Write-M365Step -Id 'G.6' -Name 'Wait for customer approval' -Status Skipped -Detail "-NoWait. Re-run this script later, or Wait-M365GdapApproval.ps1 -CustomerTenantId $CustomerTenantId"
    } else {
        Write-M365Step -Id 'G.6' -Name 'Wait for customer approval' -Status Info -Detail "polling every $pollSeconds s for up to $TimeoutMinutes min; Ctrl+C keeps the request"
        $waited = Wait-GdapApproval -RelationshipId $waitFor.Id -TimeoutMinutes $TimeoutMinutes -PollSeconds $pollSeconds
        switch ($waited.Result) {
            'Active' { Write-M365Step -Id 'G.6' -Name 'Customer approved' -Status Done -Detail $waited.DisplayName; $activeRel = $waited }
            'Failed' { Write-M365Step -Id 'G.6' -Name 'Request ended' -Status Failed -Detail "status $($waited.Status) (rejected/expired). Re-run with a new request if the customer agrees." }
            default { Write-M365Step -Id 'G.6' -Name 'Still awaiting approval' -Status Manual -Detail "status $($waited.Status) after $TimeoutMinutes min. Re-run later; the request and link are saved." }
        }
    }
} elseif ($planned) {
    Write-M365Step -Id 'G.6' -Name 'Wait for customer approval' -Status WhatIf -Detail $(if ($NoWait) { '-NoWait: would not wait; group assignments happen on a later run.' } else { 'Would poll until active, then make the assignments below.' })
}
#endregion

#region 7. Assignments ---------------------------------------------------------------------
#   WHAT   Real run: after approval, re-assess so assignments target the now-active
#          relationship; otherwise assign what is missing on relationships active now.
#          Dry run without -NoWait: assess as if the request in flight were approved (same
#          Compare logic the real run uses afterwards), so the plan lists those assignments too.
$plannedId = $null
$current = if ($activeRel) {
    Test-GdapCompliance -CustomerTenantId $tenantGuid -Template $template
} elseif ($planned -and -not $NoWait) {
    $plannedId = if ($planned.Id) { "$($planned.Id)" } else { 'planned-new-relationship' }
    $asActive = [pscustomobject]@{ Id = $plannedId; DisplayName = $planned.DisplayName; Status = 'active'; RoleIds = @($planned.RoleIds); Assignments = @(); DaysToExpiry = $null; AutoExtend = "$($template.autoExtendDuration)" }
    Compare-GdapRelationship -Relationships (@($assessment.Active) + $asActive) -Template $template
} else { $assessment }
if (@($current.MissingAssignments).Count -eq 0) {
    $detail = if ($current.ActiveCount -gt 0 -or $activeRel) { 'All template groups already assigned on active relationship(s).' } else { 'Needs an active relationship first.' }
    Write-M365Step -Id 'G.7' -Name 'Security group assignments' -Status $(if ($current.ActiveCount -gt 0) { 'Done' } else { 'Skipped' }) -Detail $detail
} else {
    foreach ($m in $current.MissingAssignments) {
        $relName = if ($plannedId -and "$($m.RelationshipId)" -eq $plannedId) { "$($m.RelationshipName) (after approval)" } else { $m.RelationshipName }
        $question = "Give our group '$($m.GroupName)' admin roles in customer '$($tenantInfo.DisplayName)' ($($tenantInfo.DefaultDomainName)) through relationship '$relName': $(Format-GdapRoleList -RoleIds $m.RoleIds)"
        try {
            if (-not ($WhatIfPreference -or $PSCmdlet.ShouldProcess($question, "$question`n`nMake this assignment?", 'Confirm GDAP group assignment'))) {
                Write-M365Step -Id 'G.7' -Name "Assign '$($m.GroupName)' on '$relName'" -Status Skipped -Detail 'Not confirmed.'
                continue
            }
            $r = if ($plannedId -and "$($m.RelationshipId)" -eq $plannedId) {
                Set-GdapAccessAssignment -PlannedRelationship $planned -GroupId $m.GroupId -RoleIds $m.RoleIds -TenantInfo $tenantInfo -CorrelationId $cid -WhatIf:$WhatIfPreference -Confirm:$false
            } else {
                Set-GdapAccessAssignment -RelationshipId $m.RelationshipId -GroupId $m.GroupId -RoleIds $m.RoleIds -TenantInfo $tenantInfo -CorrelationId $cid -WhatIf:$WhatIfPreference -Confirm:$false
            }
            $status = if ($r.WhatIf) { 'WhatIf' } elseif ($r.Declined) { 'Skipped' } else { 'Done' }
            $verb = switch ($r.Change) { 'Create' { 'new assignment' } 'Update' { "adds $(@($r.AddedRoleIds).Count) to existing assignment" } default { 'already held' } }
            Write-M365Step -Id 'G.7' -Name "Assign '$($m.GroupName)' on '$relName'" -Status $status -Detail "$(@($m.RoleIds).Count) role(s), $verb$(if ($r.AssignmentId) { "  assignment $($r.AssignmentId) [$($r.Status)]" })"
        } catch {
            Write-M365Step -Id 'G.7' -Name "Assign '$($m.GroupName)'" -Status Failed -Detail $_.Exception.Message
            & $log "Assignment failed: $($_.Exception.Message)" @{ groupId = $m.GroupId; relationshipId = "$($m.RelationshipId)" }
        }
    }
}
#endregion

#region 8. Verify and report --------------------------------------------------------------
#   GOTCHA { $_.Detail }, not "ForEach-Object Detail": the member form honours -WhatIf and
#          returns nothing in a dry run.
$final = if ($WhatIfPreference) { $assessment } else { Test-GdapCompliance -CustomerTenantId $tenantGuid -Template $template }
$finalStatus = switch ($final.State) { 'Compliant' { 'Done' } default { 'Manual' } }
Write-M365Step -Id 'G.8' -Name "Final state: $($final.State)$(if ($WhatIfPreference) { ' (before any change; dry run)' })" -Status $finalStatus -Detail $(if ($final.Compliant) { 'GDAP configuration completed and verified.' } else { (@($final.ProposedActions) | ForEach-Object { $_.Detail }) -join ' | ' })
& $log 'Run finished' @{ state = $final.State; active = $final.ActiveCount; pending = $final.PendingCount }
Write-Host ''
[pscustomobject]@{
    Customer          = $CustomerName
    CustomerTenantId  = $tenantGuid
    TenantDisplayName = $tenantInfo.DisplayName
    TenantDomain      = $tenantInfo.DefaultDomainName
    State             = $final.State
    Compliant         = $final.Compliant
    WhatIf            = [bool]$WhatIfPreference
    Relationships     = @(@($final.Active) + @($final.Pending) | Select-Object Id, DisplayName, Status, EndDateTime, AutoExtend, @{ n = 'Roles'; e = { $_.RoleIds.Count } }, @{ n = 'Assignments'; e = { $_.Assignments.Count } })
    ApprovalUrl       = if (@($final.Pending).Count -gt 0) { @($final.Pending)[0].ApprovalUrl } else { $null }
    MissingRoles      = $final.MissingRoles
    Warnings          = $final.Warnings
    CorrelationId     = $cid
}
#endregion
