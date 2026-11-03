<#
.SYNOPSIS
    Offboards a user in the safe order: block sign-in, auto-reply, convert mailbox to shared, forward, grant manager access, remove licenses.
.DESCRIPTION
    A composition of the single-purpose lifecycle steps, run in order with a checklist
    log. The account is never deleted; deletion (after the retention period your contract
    specifies) stays a human action in the portal.

      1. Disable-M365UserSignIn         block + revoke sessions
      2. Set-M365MailboxAutoReply       if -AutoReplyMessage
      3. ConvertTo-M365SharedMailbox    keeps the mail, frees the license
      4. Set-M365MailboxForwarding      if -ForwardTo (internal only, unless -AllowExternalForward)
      5. Add-M365MailboxPermission      if -GrantAccessTo (Full Access, no automapping)
      6. Remove-M365UserLicense         only once the mailbox is verified shared

    Safety rules:
      - -TenantId (Graph) and -Organization (Exchange) must be the same tenant, and the
        mailbox must belong to the Entra user found for -UserPrincipalName.
      - The run stops at the first step that fails; nothing after it is attempted.
      - Before step 6 the mailbox is read again. It must be a SharedMailbox (or the user has
        no mailbox), with no archive, no litigation or in-place hold, and at most 50 GB. A
        shared mailbox like that still needs a license, so step 6 is refused with the reason.

    -WhatIf shows every step. Use -Only / -Skip to run a subset.
.PARAMETER TenantId
    Client tenant (GUID or any verified domain) for Graph.
.PARAMETER Organization
    Tenant to change: its onmicrosoft.com domain or any verified domain. For our own tenant pass our domain (msp.homeTenantId in settings). Must be the same tenant as -TenantId.
.PARAMETER UserPrincipalName
    The user leaving.
.PARAMETER ForwardTo
    Forward their mail here (keeps a copy in the shared mailbox). Must be a recipient in this tenant unless -AllowExternalForward.
.PARAMETER AllowExternalForward
    Allow -ForwardTo to be an address outside this tenant. Without it an external target is refused.
.PARAMETER GrantAccessTo
    Give this person Full Access to the (now shared) mailbox.
.PARAMETER AutoReplyMessage
    Automatic reply text.
.PARAMETER Skip
    Step numbers to skip.
.PARAMETER Only
    Step numbers to run.
.PARAMETER SignInAs
    Partner account to sign in as. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./Invoke-M365UserOffboarding.ps1 -TenantId contoso.onmicrosoft.com -Organization contoso.onmicrosoft.com -UserPrincipalName jane@contoso.com -ForwardTo manager@contoso.com -GrantAccessTo manager@contoso.com -WhatIf
.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Users.Actions, Microsoft.Graph.Identity.DirectoryManagement, ExchangeOnlineManagement
    Graph scopes: User.ReadWrite.All, User.RevokeSessions.All, Organization.Read.All
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Checklist output for the operator; results are returned as objects too.')]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$Organization,

    [Parameter(Mandatory)]
    [string]$UserPrincipalName,

    [Parameter()]
    [string]$ForwardTo,

    [Parameter()]
    [switch]$AllowExternalForward,

    [Parameter()]
    [string]$GrantAccessTo,

    [Parameter()]
    [string]$AutoReplyMessage,

    [Parameter()]
    [int[]]$Skip = @(),

    [Parameter()]
    [int[]]$Only,

    [Parameter()]
    [string]$SignInAs
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Sign in to Graph, then Exchange with -ExpectedTenantId: a -TenantId and an
#          -Organization that name two different clients stop the run here.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
foreach ($m in 'M365Helpers', 'EntraHelpers', 'ExchangeHelpers') { Import-Module (Join-Path $modules $m "$m.psd1") -Force }
Assert-M365WriteAllowed   # Refuse legacy write tasks before sign-in, lookups, or prompts.
$settings = try { Get-M365Settings } catch { $null }
if (-not $SignInAs -and $settings -and $settings.msp.adminUpn -notmatch '^<') { $SignInAs = $settings.msp.adminUpn }
if ($UserPrincipalName -notmatch '^[^@\s*?]+@[^@\s*?]+\.[^@\s*?]+$') { throw "UserPrincipalName '$UserPrincipalName' is not one exact address." }
$null = Assert-M365Graph -TenantId $TenantId -Scopes 'User.ReadWrite.All', 'User.RevokeSessions.All', 'Organization.Read.All'
$null = Assert-M365Exchange -Organization $Organization -UserPrincipalName $SignInAs -ExpectedTenantId $TenantId
$cid = New-M365CorrelationId
$results = [System.Collections.Generic.List[object]]::new()
$prop = { param($o, [string]$n) if ($null -ne $o -and $o.PSObject.Properties[$n]) { $o.$n } }
#endregion

#region 3. Who is leaving: the Entra user and their mailbox, cross-checked ---------------
#   WHAT   Exactly one Entra user; the mailbox (if any) must be that user's own
#          (ExternalDirectoryObjectId = the user's object id).
#   WHY    Get-Mailbox also matches secondary addresses: the address of a leaver can sit on
#          someone else's mailbox, and every Exchange step would then change that mailbox.
#   GOTCHA "Not found" means no mailbox (allowed); any other read error stops the run.
$found = @(Get-MgUser -Filter "userPrincipalName eq '$($UserPrincipalName.Replace("'", "''"))'" -Property id, userPrincipalName, displayName -ErrorAction Stop)
if ($found.Count -ne 1) { throw "Expected exactly one user $UserPrincipalName in tenant $TenantId, found $($found.Count). Nothing was changed." }
$user = $found[0]
$readMailbox = {
    $m = $null
    try { $m = @(Get-Mailbox -Identity $UserPrincipalName -ErrorAction Stop) }
    catch {
        if ($_.Exception.Message -match "couldn't be found|could not be found|ManagementObjectNotFound") { return $null }
        throw "Could not read the mailbox of ${UserPrincipalName}: $($_.Exception.Message)"
    }
    if ($m.Count -ne 1) { throw "Expected one mailbox for $UserPrincipalName, found $($m.Count)." }
    $owner = "$(& $prop $m[0] 'ExternalDirectoryObjectId')"
    if ($owner -ne "$($user.Id)") {
        throw "The mailbox found for $UserPrincipalName ($(& $prop $m[0] 'PrimarySmtpAddress')) belongs to directory object '$owner', not to this user ($($user.Id))."
    }
    return $m[0]
}
$mailbox = & $readMailbox
$smtp = if ($mailbox) { "$(& $prop $mailbox 'PrimarySmtpAddress')" } else { $null }
Write-Host ''
Write-Host "Offboarding $UserPrincipalName ($($user.DisplayName)) in $Organization$(if ($WhatIfPreference) { '   (WhatIf: nothing will change)' })" -ForegroundColor White
if (-not $mailbox) { Write-Host '  The user has no mailbox: mailbox steps are skipped.' -ForegroundColor DarkGray }
#endregion

#region 4. The license gate (step 6) ----------------------------------------------------
#   WHAT   Reasons not to remove the license, from a fresh read of the mailbox; $null = go.
#   WHY    Removing the license from a user mailbox deletes the mail after the grace period.
#          A shared mailbox with an archive, a hold or over 50 GB also still needs a license.
#   GOTCHA Under -WhatIf the mailbox is not shared yet when step 3 was only planned; the real
#          run reads it again after the conversion.
$script:convertPlanned = $false
$licenseGate = {
    $m = & $readMailbox
    if ($null -eq $m) { return $null }
    $reasons = [System.Collections.Generic.List[string]]::new()
    $type = "$(& $prop $m 'RecipientTypeDetails')"
    if ($type -ne 'SharedMailbox' -and -not ($WhatIfPreference -and $script:convertPlanned)) {
        $reasons.Add("the mailbox is a $type, not a SharedMailbox (step 3 must convert it first)")
    }
    $archiveStatus = "$(& $prop $m 'ArchiveStatus')"; $archiveState = "$(& $prop $m 'ArchiveState')"
    if ($archiveStatus -eq 'Active' -or ($archiveState -and $archiveState -ne 'None')) { $reasons.Add('it has an archive mailbox') }
    if (& $prop $m 'LitigationHoldEnabled') { $reasons.Add('it is on litigation hold') }
    $inPlace = @(@(& $prop $m 'InPlaceHolds') | Where-Object { $_ -and "$_" -notmatch '^-' })
    if ($inPlace.Count -gt 0) { $reasons.Add("it has $($inPlace.Count) in-place / retention hold(s)") }
    if (& $prop $m 'ComplianceTagHoldApplied') { $reasons.Add('it holds items under a retention label hold') }
    if (& $prop $m 'DelayHoldApplied') { $reasons.Add('a hold was removed less than 30 days ago (delay hold)') }
    $stats = Get-MailboxStatistics -Identity "$(& $prop $m 'PrimarySmtpAddress')" -ErrorAction Stop
    $size = & $prop $stats 'TotalItemSize'
    $bytes = $null
    if ("$size" -match '\(([\d,.\s]+) bytes\)') { $bytes = [long](($Matches[1]) -replace '[^\d]', '') }
    elseif ($size -and $size.PSObject.Properties['Value'] -and $size.Value) { try { $bytes = [long]$size.Value.ToBytes() } catch { $bytes = $null } }
    if ($null -eq $bytes) { $reasons.Add("its size could not be read ('$size')") }
    elseif ($bytes -gt 50GB) { $reasons.Add("it is $([math]::Round($bytes / 1GB, 1)) GB, over the 50 GB a shared mailbox may hold without a license") }
    if ($reasons.Count -gt 0) { return ($reasons -join '; ') }
    return $null
}
#endregion

#region 5. Steps (stop at the first failure) ----------------------------------------------
$steps = @(
    @{ N = 1; Name = 'Block sign-in and revoke sessions'; Applies = $true; Mailbox = $false; Action = { Disable-M365UserSignIn -UserPrincipalName $UserPrincipalName -WhatIf:$WhatIfPreference } }
    @{ N = 2; Name = 'Set automatic reply'; Applies = [bool]$AutoReplyMessage; Mailbox = $true; Action = { Set-M365MailboxAutoReply -Identity $smtp -Message $AutoReplyMessage -WhatIf:$WhatIfPreference } }
    @{ N = 3; Name = 'Convert mailbox to shared'; Applies = $true; Mailbox = $true; Action = {
            $r = ConvertTo-M365SharedMailbox -Identity $smtp -WhatIf:$WhatIfPreference
            if ($WhatIfPreference) { $script:convertPlanned = $true }
            else {
                $isShared = if ($r -and $r.PSObject.Properties['IsShared']) { [bool]$r.IsShared } else { "$(& $prop $r 'Type')" -eq 'SharedMailbox' }
                if (-not $isShared) { throw 'The mailbox was not confirmed as shared after the conversion.' }
            }
            $r
        } }
    @{ N = 4; Name = "Forward mail to $ForwardTo$(if ($AllowExternalForward) { ' (external allowed)' })"; Applies = [bool]$ForwardTo; Mailbox = $true; Action = {
            $fwd = @{ Identity = $smtp; ForwardTo = $ForwardTo }
            if ($AllowExternalForward) { $fwd.AllowExternal = $true }
            Set-M365MailboxForwarding @fwd -WhatIf:$WhatIfPreference
        } }
    @{ N = 5; Name = "Grant Full Access to $GrantAccessTo"; Applies = [bool]$GrantAccessTo; Mailbox = $true; Action = { Add-M365MailboxPermission -Identity $smtp -User $GrantAccessTo -WhatIf:$WhatIfPreference } }
    @{ N = 6; Name = 'Remove directly assigned licenses'; Applies = $true; Mailbox = $false; Action = {
            $why = & $licenseGate
            if ($why) { throw "REFUSED: licenses not removed because $why." }
            Remove-M365UserLicense -UserPrincipalName $UserPrincipalName -WhatIf:$WhatIfPreference
        } }
)
$detailOf = {
    param($out)
    (@($out) | Where-Object { $null -ne $_ } | ForEach-Object {
            ($_.PSObject.Properties | Where-Object { $_.Name -notin 'Id', 'Mailbox', 'UserPrincipalName', 'Password', 'Pass' -and $null -ne $_.Value -and "$($_.Value)" -ne '' } |
                ForEach-Object { "$($_.Name)=$($_.Value -join ',')" }) -join ' ' }) -join ' | '
}
$stoppedAt = $null
foreach ($s in $steps) {
    $id = "O.$($s.N)"
    if ($stoppedAt) {
        if ($s.Applies) { Write-M365Step -Id $id -Name $s.Name -Status Skipped -Detail "Not run: the run stopped at step $stoppedAt."; $results.Add([pscustomobject]@{ Step = $s.N; Name = $s.Name; Status = 'NotRun'; Detail = "Stopped at step $stoppedAt." }) }
        continue
    }
    if (-not $s.Applies) { Write-M365Step -Id $id -Name $s.Name -Status Skipped -Detail 'Not requested.'; continue }
    if (($Only -and $Only -notcontains $s.N) -or $Skip -contains $s.N) { Write-M365Step -Id $id -Name $s.Name -Status Skipped -Detail 'Excluded by -Only / -Skip.'; continue }
    if ($s.Mailbox -and -not $mailbox) {
        Write-M365Step -Id $id -Name $s.Name -Status Skipped -Detail 'The user has no mailbox.'
        if ($s.N -ne 3) { Write-Warning "Step $($s.N) ($($s.Name)) was requested but $UserPrincipalName has no mailbox." }
        $results.Add([pscustomobject]@{ Step = $s.N; Name = $s.Name; Status = 'Skipped'; Detail = 'No mailbox.' })
        continue
    }
    try {
        $out = & $s.Action
        $detail = & $detailOf $out
        $status = if ($WhatIfPreference) { 'WhatIf' } else { 'Done' }
        Write-M365Step -Id $id -Name $s.Name -Status $status -Detail $detail
        $results.Add([pscustomobject]@{ Step = $s.N; Name = $s.Name; Status = $status; Detail = $detail })
        Write-M365Log -Operation 'Invoke-M365UserOffboarding' -TenantId $TenantId -CorrelationId $cid -Message "$id $($s.Name)" -Data @{ user = $UserPrincipalName; detail = $detail; whatIf = [bool]$WhatIfPreference }
    } catch {
        $message = $_.Exception.Message
        $status = if ($message -like 'REFUSED:*') { 'Refused' } else { 'Failed' }
        Write-M365Step -Id $id -Name $s.Name -Status Failed -Detail $message
        $results.Add([pscustomobject]@{ Step = $s.N; Name = $s.Name; Status = $status; Detail = $message })
        Write-M365Log -Level Error -Operation 'Invoke-M365UserOffboarding' -TenantId $TenantId -CorrelationId $cid -Message "$id $status`: $message" -Data @{ user = $UserPrincipalName }
        $stoppedAt = $s.N
    }
}
#endregion

#region 6. Result ---------------------------------------------------------------------
Write-Host ''
Write-Host 'Still manual: remove from groups and Teams as needed, reassign OneDrive (Entra > user > OneDrive settings), collect devices, and delete the account after the agreed retention period.' -ForegroundColor Yellow
$results.ToArray()
if ($stoppedAt) {
    $last = $results | Where-Object { $_.Step -eq $stoppedAt } | Select-Object -Last 1
    throw "Offboarding of $UserPrincipalName stopped at step $stoppedAt ($($last.Name)): $($last.Detail) Steps after it were not run."
}
#endregion
