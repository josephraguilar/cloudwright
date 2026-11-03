<#
.SYNOPSIS
    Onboards a new user the standard way for a client: create, license, groups, lists, mailbox region, Temporary Access Pass.
.DESCRIPTION
    A composition of the single-purpose lifecycle steps, driven by the client's
    newUserDefaults (config/clients/<client>.local.json): usage location, license SKUs,
    Entra groups, distribution lists, time zone and language, and whether to issue a
    Temporary Access Pass. Order:

      1. New-M365User                    create (names, title, department, manager)
      2. Add-M365UserLicense             SKUs from -Sku or the client defaults
      3. Add-M365GroupMember             Entra groups from -Group or defaults
      4. Distribution lists              Exchange lists from -DistributionList or defaults
      5. Mailbox region                  time zone and language (waits for the mailbox)
      6. New-M365TemporaryAccessPass     one-time pass for first sign-in and MFA setup

    It never takes over an existing account. If the UPN already exists (a second "John
    Smith"), the run stops before any change; under -WhatIf the plan says "user already
    exists - run would stop". To finish an earlier run that stopped part-way for the SAME
    person, pass -ResumeExisting: steps 2-5 then run for that account, but no Temporary
    Access Pass is issued for an account this run did not create unless
    -IssuePassForExistingUser is also passed.

    Under -WhatIf every step for a new user is planned against "<id of the new user>".
    The initial password is only shown when no Temporary Access Pass is issued.
.PARAMETER Client
    Client short name. Supplies tenant, root domain, mail domain and newUserDefaults.
.PARAMETER FirstName
    Given name.
.PARAMETER LastName
    Surname.
.PARAMETER UserPrincipalName
    UPN. Default: first.last@<client primaryDomain>, lower-case.
.PARAMETER DisplayName
    Default: "First Last".
.PARAMETER JobTitle
    Optional.
.PARAMETER Department
    Optional.
.PARAMETER ManagerUpn
    Optional. Must exist in the tenant.
.PARAMETER Sku
    Override the client's default license SKUs.
.PARAMETER Group
    Override the client's default Entra groups (exact names or object ids).
.PARAMETER DistributionList
    Override the client's default distribution lists (primary addresses or exact names).
.PARAMETER NoTemporaryAccessPass
    Skip the pass and show the initial password instead.
.PARAMETER GeneratePassword
    When no Temporary Access Pass is issued, generate the initial password (shown once) instead of asking you to type one.
.PARAMETER ResumeExisting
    The UPN already exists because an earlier run for this same person stopped part-way: run steps 2-5 for it instead of stopping.
.PARAMETER IssuePassForExistingUser
    With -ResumeExisting, also issue a Temporary Access Pass for the existing account.
.PARAMETER Skip
    Step numbers to skip.
.PARAMETER Only
    Step numbers to run.
.PARAMETER SignInAs
    Partner account to sign in as. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./Invoke-M365UserOnboarding.ps1 -Client contoso -FirstName Jane -LastName Doe -JobTitle 'Office Manager' -WhatIf
.EXAMPLE
    ./Invoke-M365UserOnboarding.ps1 -Client contoso -FirstName Jane -LastName Doe -ResumeExisting -Only 4, 5
.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Identity.DirectoryManagement, ExchangeOnlineManagement
    Graph scopes: User.ReadWrite.All, Organization.Read.All, GroupMember.ReadWrite.All, UserAuthenticationMethod.ReadWrite.All
    Interactive: yes (prompts for the initial password when no Temporary Access Pass is issued, unless -GeneratePassword)
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Checklist output and the one-time pass for the operator; results are returned as objects too.')]
param(
    [Parameter(Mandatory)]
    [string]$Client,

    [Parameter(Mandatory)]
    [string]$FirstName,

    [Parameter(Mandatory)]
    [string]$LastName,

    [Parameter()]
    [string]$UserPrincipalName,

    [Parameter()]
    [string]$DisplayName,

    [Parameter()]
    [string]$JobTitle,

    [Parameter()]
    [string]$Department,

    [Parameter()]
    [string]$ManagerUpn,

    [Parameter()]
    [string[]]$Sku,

    [Parameter()]
    [string[]]$Group,

    [Parameter()]
    [string[]]$DistributionList,

    [Parameter()]
    [switch]$NoTemporaryAccessPass,

    [Parameter()]
    [switch]$GeneratePassword,

    [Parameter()]
    [switch]$ResumeExisting,

    [Parameter()]
    [switch]$IssuePassForExistingUser,

    [Parameter()]
    [int[]]$Skip = @(),

    [Parameter()]
    [int[]]$Only,

    [Parameter()]
    [string]$SignInAs
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
foreach ($m in 'M365Helpers', 'EntraHelpers', 'ExchangeHelpers') { Import-Module (Join-Path $modules $m "$m.psd1") -Force }
$settings = Get-M365Settings
$c = Get-M365ClientConfig -Name $Client -Settings $settings
$d = $c.newUserDefaults
if (-not $SignInAs -and $settings.msp.adminUpn -notmatch '^<') { $SignInAs = $settings.msp.adminUpn }

#   WHAT   Resolve names and defaults before any sign-in.
#   WHY    A typo in the UPN should fail here, not after the user is half created.
$clean = { param([string]$s) ($s -replace '[^A-Za-z0-9]', '').ToLowerInvariant() }
if (-not $UserPrincipalName) { $UserPrincipalName = "$(& $clean $FirstName).$(& $clean $LastName)@$($c.primaryDomain)" }
if ($UserPrincipalName -notmatch '^[^@\s*?]+@[^@\s*?]+\.[^@\s*?]+$') { throw "UserPrincipalName '$UserPrincipalName' is not a valid address." }
if (-not $DisplayName) { $DisplayName = "$FirstName $LastName" }
$skus = @(if ($Sku) { $Sku } else { @($d.licenses) })
$groups = @(if ($Group) { $Group } else { @($d.groups) })
$lists = @(if ($DistributionList) { $DistributionList } else { @($d.distributionLists) })
$issueTap = (-not $NoTemporaryAccessPass) -and [bool]$d.issueTemporaryAccessPass
$userExtras = @{}
if ($JobTitle) { $userExtras.JobTitle = $JobTitle }
if ($Department) { $userExtras.Department = $Department }
if ($ManagerUpn) { $userExtras.ManagerUpn = $ManagerUpn }
$tapHours = if ($d.temporaryAccessPassHours) { [int]$d.temporaryAccessPassHours } else { 8 }
$selected = @(foreach ($n in 1..6) { if (-not (($Only -and $Only -notcontains $n) -or $Skip -contains $n)) { $n } })
$runs = { param([int]$n) $selected -contains $n }
$generate = $GeneratePassword.IsPresent
$passForExisting = $IssuePassForExistingUser.IsPresent

#   WHAT   Graph, then Exchange only if a step needs it, checked to be the same tenant.
$null = Assert-M365Graph -TenantId $c.tenantId -Scopes 'User.ReadWrite.All', 'Organization.Read.All', 'GroupMember.ReadWrite.All', 'UserAuthenticationMethod.ReadWrite.All'
if (($lists.Count -gt 0 -and (& $runs 4)) -or (& $runs 5)) {
    $null = Assert-M365Exchange -Organization $c.onmicrosoftDomain -UserPrincipalName $SignInAs -ExpectedTenantId $c.tenantId
}
$cid = New-M365CorrelationId
$results = [System.Collections.Generic.List[object]]::new()
Write-Host ''
Write-Host "New user for $($c.name): $DisplayName <$UserPrincipalName>$(if ($WhatIfPreference) { '   (WhatIf: nothing will change)' })" -ForegroundColor White
Write-Host "  licenses: $(if ($skus) { $skus -join ', ' } else { 'none' })   groups: $(if ($groups) { $groups -join ', ' } else { 'none' })   lists: $(if ($lists) { $lists -join ', ' } else { 'none' })   TAP: $issueTap" -ForegroundColor DarkGray
#endregion

#region 3. Does the UPN exist already? Stop unless told to resume ---------------------------
#   WHAT   An existing account is never taken over. A second "John Smith" gets the same
#          default UPN as the first; without this check the later steps would change the first
#          John's mailbox, licenses and groups and hand out a pass for HIS account.
$existing = @(Get-MgUser -Filter "userPrincipalName eq '$($UserPrincipalName.Replace("'", "''"))'" -Property id, userPrincipalName, displayName, givenName, surname -ErrorAction Stop)
if ($existing.Count -gt 1) { throw "$($existing.Count) users match $UserPrincipalName. Nothing was changed." }
$existingUser = if ($existing.Count -eq 1) { $existing[0] } else { $null }
if ($existingUser -and -not $ResumeExisting) {
    $why = "user already exists - run would stop: $UserPrincipalName is already '$($existingUser.DisplayName)' (id $($existingUser.Id)). For a different person with the same name pass another -UserPrincipalName; to finish an earlier run for this same person pass -ResumeExisting."
    Write-M365Step -Id 'U.1' -Name 'Create user' -Status Failed -Detail $why
    Write-M365Log -Level Warning -Operation 'Invoke-M365UserOnboarding' -TenantId $c.tenantId -CorrelationId $cid -Message 'Stopped: user already exists' -Data @{ user = $UserPrincipalName; whatIf = [bool]$WhatIfPreference }
    if (-not $WhatIfPreference) { throw "Stopped before any change: $why" }
    Write-Warning $why
    [pscustomobject]@{ Client = $c.name; UserPrincipalName = $UserPrincipalName; DisplayName = $DisplayName; Stopped = $true; StopReason = $why; Steps = @([pscustomobject]@{ Step = 1; Name = 'Create user'; Status = 'Stopped'; Detail = $why }); CorrelationId = $cid }
    return
}
if ($existingUser) {
    #   WHY    -ResumeExisting is for the SAME person. A first/last name that differs from the
    #          existing account's is a different person.
    foreach ($pair in @(@('GivenName', $FirstName), @('Surname', $LastName))) {
        $have = if ($existingUser.PSObject.Properties[$pair[0]]) { "$($existingUser.($pair[0]))" } else { '' }
        if ($have -and $have -ne $pair[1]) { throw "$UserPrincipalName belongs to '$($existingUser.DisplayName)' ($($pair[0]) '$have', not '$($pair[1])'): a different person. Nothing was changed." }
    }
    Write-Warning "Resuming for the existing account $UserPrincipalName ('$($existingUser.DisplayName)'): it was not created by this run."
} elseif (-not (& $runs 1)) {
    throw "$UserPrincipalName does not exist and step 1 (create) is excluded by -Only / -Skip. Nothing was changed."
}
#endregion

#region 4. Steps ------------------------------------------------------------------------
#   WHAT   $script:userId is the new account's id after step 1 (a placeholder under -WhatIf),
#          or the existing account's id with -ResumeExisting.
#   GOTCHA For a user this run creates, step 5 calls Set-MailboxRegionalConfiguration through
#          Invoke-M365Change here instead of Set-M365MailboxRegionalConfig: that function reads
#          the mailbox first, which does not exist in a dry run, and the dry run must plan the
#          same command the real run makes. A new mailbox has no regional settings, so nothing
#          needs reading. For an existing account the ExchangeHelpers function is used.
$script:userId = if ($existingUser) { "$($existingUser.Id)" } else { $null }
$script:createdThisRun = $false
$script:initialPassword = $null
$script:typedPassword = $false
$script:tapResult = $null
$script:mailboxReady = $false
$isNew = -not $existingUser
$waitForMailbox = {
    if ($WhatIfPreference -or $script:mailboxReady) { return }
    #   GOTCHA The mailbox appears a minute or two after licensing. Wait up to 5 minutes, and make
    #          sure what appears is this user's mailbox (Get-Mailbox also matches other addresses).
    $deadline = (Get-Date).AddMinutes(5)
    while ($true) {
        $m = $null
        try { $m = @(Get-Mailbox -Identity $UserPrincipalName -ErrorAction Stop) }
        catch { if ($_.Exception.Message -notmatch "couldn't be found|could not be found|ManagementObjectNotFound") { throw } }
        if ($m) {
            $owner = if ($m[0].PSObject.Properties['ExternalDirectoryObjectId']) { "$($m[0].ExternalDirectoryObjectId)" } else { '' }
            if ($m.Count -ne 1 -or $owner -ne "$script:userId") { throw "Get-Mailbox $UserPrincipalName returned a mailbox that is not the new user's ($owner). Nothing more was done." }
            $script:mailboxReady = $true; return
        }
        if ((Get-Date) -ge $deadline) { throw 'Mailbox not provisioned yet; re-run in a few minutes with -ResumeExisting -Only 4, 5.' }
        Start-Sleep -Seconds 15
    }
}
$steps = @(
    @{ N = 1; Name = 'Create user'; Applies = $true; Action = {
            if (-not $isNew) { return [pscustomobject]@{ Id = $script:userId; Created = $false; Note = 'existing account (resumed): nothing created' } }
            $p = @{ UserPrincipalName = $UserPrincipalName; DisplayName = $DisplayName; GivenName = $FirstName; Surname = $LastName; UsageLocation = $(if ($d.usageLocation) { $d.usageLocation } else { 'US' }) } + $userExtras
            #   WHY    With a Temporary Access Pass the password is never used, so a random one is fine.
            #          Without one, the operator types the initial password (twice) and hands it over.
            if (-not $issueTap -and -not $generate -and -not $WhatIfPreference) { $p.Password = Read-M365Password -Prompt "Initial password for $UserPrincipalName" -MinimumLength 12; $script:typedPassword = $true }
            $r = New-M365User @p -WhatIf:$WhatIfPreference
            if ($r.AlreadyExisted) { throw "$UserPrincipalName appeared while this run was starting ('$($r.DisplayName)'). Stopped before any other change." }
            if ($r.Created) {
                $script:userId = $r.Id; $script:createdThisRun = $true
                if ($r.Password) { $script:initialPassword = $r.Password }
            } elseif ($WhatIfPreference) {
                $script:userId = New-M365Placeholder "id of the new user $UserPrincipalName"
            } else { throw 'The user was not created (declined). Stopped.' }
            if ($r.ManagerError) { Write-Warning "Manager not set: $($r.ManagerError)" }
            $r | Select-Object UserPrincipalName, Id, Created, ManagerSet, ManagerError
        } }
    @{ N = 2; Name = "Assign license(s) $($skus -join ', ')"; Applies = ($skus.Count -gt 0); Action = { Add-M365UserLicense -UserPrincipalName $UserPrincipalName -Sku $skus -UserId $script:userId -WhatIf:$WhatIfPreference } }
    @{ N = 3; Name = "Add to group(s) $($groups -join ', ')"; Applies = ($groups.Count -gt 0); Action = { Add-M365GroupMember -UserPrincipalName $UserPrincipalName -GroupName $groups -UserId $script:userId -WhatIf:$WhatIfPreference } }
    @{ N = 4; Name = "Add to list(s) $($lists -join ', ')"; Applies = ($lists.Count -gt 0); Action = {
            #   GOTCHA A new user's mailbox must exist before it can join a list: wait for it first.
            #          Under -WhatIf Add-M365DistributionListMember plans the member that does not
            #          exist yet (it warns that the real run needs it to exist by then).
            if ($isNew) { & $waitForMailbox }
            foreach ($l in $lists) { Add-M365DistributionListMember -Identity $l -Member $UserPrincipalName -WhatIf:$WhatIfPreference }
        } }
    @{ N = 5; Name = "Mailbox region $($d.timeZone) / $($d.language)"; Applies = $true; Action = {
            if (-not $isNew) { return (Set-M365MailboxRegionalConfig -Identity $UserPrincipalName -TimeZone $d.timeZone -Language $d.language -WhatIf:$WhatIfPreference) }
            & $waitForMailbox
            $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Set time zone '$($d.timeZone)' and language $($d.language) on the new mailbox $UserPrincipalName (default folder names localized)" `
                -Command 'Set-MailboxRegionalConfiguration' -Parameters ([ordered]@{ Identity = $UserPrincipalName; TimeZone = "$($d.timeZone)"; Language = "$($d.language)"; LocalizeDefaultFolderName = [switch]::new($true) })
            [pscustomobject]@{ TimeZone = $d.timeZone; Language = $d.language; Changed = $run.Ran; WhatIf = -not $run.Ran }
        } }
    @{ N = 6; Name = "Temporary Access Pass ($tapHours h, one-time)"; Applies = $issueTap; Action = {
            if (-not $isNew -and -not $passForExisting) {
                return [pscustomobject]@{ Issued = $false; Note = 'not issued: this run did not create the account (pass -IssuePassForExistingUser to issue one)' }
            }
            $r = New-M365TemporaryAccessPass -UserPrincipalName $UserPrincipalName -LifetimeHours $tapHours -UserId $script:userId -WhatIf:$WhatIfPreference
            if ($r.Pass) { $script:tapResult = $r }
            $r | Select-Object ExpiresAt, UsableOnce, Issued
        } }
)
$detailOf = {
    param($out)
    (@($out) | Where-Object { $null -ne $_ } | ForEach-Object {
            ($_.PSObject.Properties | Where-Object { $_.Name -notin 'UserPrincipalName', 'Mailbox', 'Id', 'Password', 'Pass' -and $null -ne $_.Value -and "$($_.Value)" -ne '' } |
                ForEach-Object { "$($_.Name)=$($_.Value -join ',')" }) -join ' ' }) -join ' | '
}
foreach ($s in $steps) {
    $id = "U.$($s.N)"
    if (-not $s.Applies) { Write-M365Step -Id $id -Name $s.Name -Status Skipped -Detail 'Not requested / not in client defaults.'; continue }
    if (-not (& $runs $s.N)) { Write-M365Step -Id $id -Name $s.Name -Status Skipped -Detail 'Excluded by -Only / -Skip.'; continue }
    try {
        $detail = & $detailOf @(& $s.Action)
        $status = if ($WhatIfPreference) { 'WhatIf' } else { 'Done' }
        Write-M365Step -Id $id -Name $s.Name -Status $status -Detail $detail
        $results.Add([pscustomobject]@{ Step = $s.N; Name = $s.Name; Status = $status; Detail = $detail })
        Write-M365Log -Operation 'Invoke-M365UserOnboarding' -TenantId $c.tenantId -CorrelationId $cid -Message "$id $($s.Name)" -Data @{ user = $UserPrincipalName; whatIf = [bool]$WhatIfPreference }
    } catch {
        Write-M365Step -Id $id -Name $s.Name -Status Failed -Detail $_.Exception.Message
        $results.Add([pscustomobject]@{ Step = $s.N; Name = $s.Name; Status = 'Failed'; Detail = $_.Exception.Message })
        Write-M365Log -Level Error -Operation 'Invoke-M365UserOnboarding' -TenantId $c.tenantId -CorrelationId $cid -Message "$id failed: $($_.Exception.Message)" -Data @{ user = $UserPrincipalName }
        if ($s.N -eq 1) { Write-Warning 'User creation failed; stopping.'; break }
    }
}
#endregion

#region 5. Hand-off -------------------------------------------------------------------
#   WHAT   Exactly one secret for the user: the pass if issued, else the generated password.
#   WHY    Printed once and returned once in the result (the GUI shows no Write-Host), never
#          logged, never in the run record.
Write-Host ''
$handPass = $null; $handPassword = $null
if ($script:tapResult) {
    $handPass = $script:tapResult.Pass
    Write-Host "  First sign-in: give $DisplayName this Temporary Access Pass (valid until $($script:tapResult.ExpiresAt), one-time). They sign in at https://aka.ms/mfasetup, register MFA, then set their password." -ForegroundColor Yellow
    Write-Host "  $handPass" -ForegroundColor Yellow
} elseif ($script:initialPassword -and $script:typedPassword) {
    Write-Host '  Created with the initial password you typed; the user must change it at first sign-in.' -ForegroundColor Yellow
} elseif ($script:initialPassword) {
    $handPassword = $script:initialPassword
    Write-Host "  Initial password (shown once; must be changed at first sign-in): $handPassword" -ForegroundColor Yellow
}
Write-Host ''
$failed = @($results | Where-Object Status -eq 'Failed')
if ($failed.Count -gt 0) { Write-Warning "Not finished: step(s) $(($failed | ForEach-Object { $_.Step }) -join ', ') failed. Fix the cause and re-run with -ResumeExisting -Only <those steps>." }
[pscustomobject]@{
    Client              = $c.name
    UserPrincipalName   = $UserPrincipalName
    DisplayName         = $DisplayName
    CreatedThisRun      = $script:createdThisRun
    Completed           = ($failed.Count -eq 0)
    Steps               = $results.ToArray()
    TemporaryAccessPass = $handPass
    InitialPassword     = $handPassword
    CorrelationId       = $cid
}
#endregion
