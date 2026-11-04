#region Module setup ----------------------------------------------------------
#   WHAT   Strict mode, then M365Helpers (loaded by path if the caller has not).
#   WHY    Every function here needs either an Exchange Online session
#          (Assert-M365Exchange) or DNS (Resolve-DnsRecord) from M365Helpers, and every
#          change goes through M365Helpers' Invoke-M365Change.
Set-StrictMode -Version Latest
#   GOTCHA The repo is not on PSModulePath, so M365Helpers cannot be a manifest
#          RequiredModule (Test-ModuleManifest would fail). Load it by path instead.
if (-not (Get-Module -Name M365Helpers)) {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Helpers' 'M365Helpers.psd1') -ErrorAction Stop
}
#endregion

#region Exact lookups (internal helpers + Get-M365ExactRecipient) ----------------
#   WHAT   One way to pick the object a change applies to, and one way to name it.
#   WHY    Exchange identity strings match names, aliases and ANY proxy address, and they
#          accept wildcards. "911@contoso.com" can be a secondary alias on Jane's personal
#          mailbox. So every function reads the object first, checks it is exactly one
#          object of the right kind with the right primary address, and then hands the
#          write that object's primary SMTP address (unique in the tenant, readable in the
#          plan), never the name the operator typed.
#   GOTCHA "Not found" and "could not read" are different answers. A read that fails
#          (throttling, permissions, a dropped session) must stop the function; only
#          Exchange's own "couldn't be found" error means the object does not exist.
function Test-M365NotFoundError {
    # Internal. True when an Exchange error record means "no such object", not a failure to read.
    param($ErrorRecord)
    $text = "$($ErrorRecord.FullyQualifiedErrorId) $($ErrorRecord.CategoryInfo.Reason) $($ErrorRecord.Exception.GetType().Name) $($ErrorRecord.Exception.Message)"
    return [bool]($text -match "ManagementObjectNotFound|couldn't be found on|could not be found on")
}

function Get-M365Prop {
    # Internal. A property value, or $null when the object does not have that property (StrictMode-safe).
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function ConvertTo-M365BareAddress {
    # Internal. 'SMTP:Jane@Contoso.com' -> 'jane@contoso.com'.
    param([AllowEmptyString()][AllowNull()][string]$Address)
    return ("$Address" -replace '^(?i)smtp:', '').Trim().ToLowerInvariant()
}

function Get-M365RecipientId {
    # Internal. The string a write uses to name an object that was read and checked:
    # its primary SMTP address, else its directory object id, else its Exchange GUID.
    param($Object)
    foreach ($name in 'PrimarySmtpAddress', 'ExternalDirectoryObjectId', 'Guid') {
        $value = Get-M365Prop $Object $name
        if ($value -and "$value") { return "$value" }
    }
    throw "Internal error: the object '$Object' has no primary address or id to name it by. Nothing was changed."
}

function Get-M365RecipientType {
    # Internal. RecipientTypeDetails, else RecipientType, as a string.
    param($Object)
    $t = "$(Get-M365Prop $Object 'RecipientTypeDetails')"
    if (-not $t) { $t = "$(Get-M365Prop $Object 'RecipientType')" }
    return $t
}

function Get-M365RecipientLabel {
    # Internal. "UserMailbox 'Jane Doe' (jane@contoso.com)" for messages.
    param($Object)
    "$(Get-M365RecipientType $Object) '$(Get-M365Prop $Object 'Name')' ($(Get-M365Prop $Object 'PrimarySmtpAddress'))"
}

function Get-M365RecipientExternalAddress {
    # Internal. The outside address a mail contact or mail user delivers to, when that address
    # is outside the tenant's accepted domains; $null for anything that delivers inside.
    param($Recipient, [string[]]$AcceptedDomains)
    $ext = Get-M365Prop $Recipient 'ExternalEmailAddress'
    if (-not "$ext" -and (Get-M365RecipientType $Recipient) -match 'MailContact|MailUser') { $ext = Get-M365Prop $Recipient 'PrimarySmtpAddress' }
    if (-not "$ext") { return $null }
    $address = ConvertTo-M365BareAddress "$ext"
    if (Test-M365ExternalAddress -Address $address -AcceptedDomains $AcceptedDomains) { return $address }
    return $null
}

function Get-M365ExactRecipient {
    <#
    .SYNOPSIS
        Reads exactly one Exchange object by identity; $null only when Exchange says it does not exist. Read-only.
    .DESCRIPTION
        The lookup every change in this module uses to pick its target:
          - refuses identities with wildcards (* or ?);
          - throws when the identity matches more than one object, listing them;
          - throws (instead of returning nothing) when the read itself fails, so "could not
            read" is never mistaken for "does not exist".
        Callers then check the kind (RecipientTypeDetails) and the primary address.
    .PARAMETER Kind
        Mailbox, Recipient, DistributionGroup or MailContact (runs Get-Mailbox, Get-Recipient, ...).
    .PARAMETER Identity
        Address, name or id of one object. No wildcards.
    .PARAMETER What
        Words for messages, e.g. 'forwarding target'. Defaults to the kind.
    .EXAMPLE
        $mbx = Get-M365ExactRecipient -Kind Mailbox -Identity jane@contoso.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Mailbox', 'Recipient', 'DistributionGroup', 'MailContact')]
        [string]$Kind,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Identity,

        [Parameter()]
        [string]$What
    )
    if (-not $What) { $What = switch ($Kind) { 'DistributionGroup' { 'distribution list' } 'MailContact' { 'mail contact' } default { $Kind.ToLowerInvariant() } } }
    if ([string]::IsNullOrWhiteSpace($Identity)) { throw "No $What was given. Nothing was changed." }
    if ($Identity -match '[*?]') { throw "'$Identity' contains a wildcard (* or ?). Name exactly one $What. Nothing was changed." }
    $command = "Get-$Kind"
    try {
        $found = @(& $command -Identity $Identity -ErrorAction Stop)
    } catch {
        if (Test-M365NotFoundError $_) { return $null }
        if ($_.Exception.Message -match 'matches multiple entries') { throw "'$Identity' matches more than one $What. Use its primary SMTP address. Nothing was changed." }
        throw "Could not read $What '$Identity': $($_.Exception.Message) Nothing was changed."
    }
    $found = @($found | Where-Object { $null -ne $_ })
    if ($found.Count -eq 0) { return $null }
    if ($found.Count -gt 1) {
        $list = ($found | ForEach-Object { Get-M365RecipientLabel $_ }) -join '; '
        throw "'$Identity' matches $($found.Count) objects: $list. Name exactly one $What by its primary SMTP address. Nothing was changed."
    }
    return $found[0]
}
#endregion

#region Mail authentication: SPF ----------------------------------------------
function Get-SpfAnalysis {
    <#
    .SYNOPSIS
        Fetches and evaluates a domain's SPF record against Exchange Online expectations.
    .DESCRIPTION
        Pure analysis over DNS data, so it is unit-testable with a fake resolver. Checks:
          - exactly one v=spf1 record (zero or two are both failures)
          - include:spf.protection.outlook.com is present (mail from EXO passes)
          - the record ends in -all or ~all (not +all, ?all or nothing)
          - the total DNS-lookup count (include, a, mx, ptr, exists, redirect, followed
            recursively) is 10 or fewer; 11+ is a PermError at every receiver
        A top-level redirect=<domain> (with no all mechanism) is followed: the target's
        mechanisms count as this domain's policy, and its lookups count toward the 10.
        Returns one object with Status Pass / Warn / Fail and a Findings list.
    .PARAMETER Domain
        The domain to check.
    .PARAMETER Resolver
        Scriptblock taking (name, type) and returning record strings. Defaults to
        Resolve-DnsRecord. Tests pass a hashtable-backed fake.
    .EXAMPLE
        Get-SpfAnalysis -Domain contoso.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Domain,

        [Parameter()]
        [scriptblock]$Resolver = { param($n, $t) Resolve-DnsRecord -Name $n -Type $t }
    )

    #region 1. Fetch -----------------------------------------------------------
    $findings = [System.Collections.Generic.List[string]]::new()
    $txt = @(& $Resolver $Domain 'TXT')
    $spf = @($txt | Where-Object { $_ -match '^v=spf1(\s|$)' })
    $record = if ($spf.Count -ge 1) { $spf[0] } else { $null }
    if ($spf.Count -eq 0) { $findings.Add('No SPF record (v=spf1) found.') }
    if ($spf.Count -gt 1) { $findings.Add("Found $($spf.Count) SPF records. Receivers treat multiple records as PermError. Merge them into one.") }
    #endregion

    #region 2. Evaluate mechanisms -------------------------------------------
    #   WHAT   Tokenize the record (and any redirect= target) and inspect the pieces that matter.
    #   WHY    The two failures we actually see in the field are "EXO include is
    #          missing because the old host's record was left alone" and
    #          "too many includes" after years of adding SaaS senders.
    #   GOTCHA redirect= is ignored when the same record has an all mechanism (RFC 7208
    #          6.1), so it is followed only when there is none. Its target's include: list
    #          is this domain's policy, so the EXO check looks there too.
    $includes = @()
    $allMechanism = $null
    $lookups = 0
    $redirects = @()
    $current = $record
    $hops = 0
    while ($current -and $hops -lt 10) {
        $redirect = $null
        $hasAll = $false
        foreach ($term in ($current -split '\s+' | Select-Object -Skip 1)) {
            $bare = $term -replace '^[+\-~?]', ''
            if ($bare -match '^include:(.+)$') { $includes += $Matches[1] }
            if ($bare -match '^(include:|a$|a:|mx$|mx:|ptr|exists:)') { $lookups++ }
            if ($bare -match '^all$') { $allMechanism = $term; $hasAll = $true }
            if ($bare -match '^redirect=(.+)$') { $redirect = $Matches[1] }
        }
        if (-not $redirect -or $hasAll) { break }
        $lookups++
        $redirects += $redirect
        $target = @(& $Resolver $redirect 'TXT' | Where-Object { $_ -match '^v=spf1(\s|$)' })
        if ($target.Count -ne 1) {
            $findings.Add("redirect=$redirect points to a domain with $($target.Count) SPF records. Receivers return PermError.")
            break
        }
        $current = $target[0]
        $hops++
    }
    if ($record) {
        $lookups += Get-SpfIncludeLookupCount -Includes $includes -Resolver $Resolver -Depth 1
        if ($includes -notcontains 'spf.protection.outlook.com') {
            $findings.Add('include:spf.protection.outlook.com is missing. Mail sent from Exchange Online will fail SPF.')
        }
        switch -Regex ($allMechanism) {
            '^-all$' { }
            '^~all$' { }
            '^\+all$' { $findings.Add('Record ends in +all, which authorizes every sender on earth. Change to -all or ~all.') }
            '^\?all$' { $findings.Add('Record ends in ?all (neutral). Change to -all or ~all.') }
            default { $findings.Add('Record has no all mechanism. Add -all (or ~all while testing).') }
        }
        if ($lookups -gt 10) {
            $findings.Add("SPF needs $lookups DNS lookups; the limit is 10. Receivers return PermError. Flatten or remove includes.")
        } elseif ($lookups -ge 9) {
            $findings.Add("SPF uses $lookups of 10 allowed DNS lookups. One more include will break it.")
        }
    }
    #endregion

    #region 3. Status ------------------------------------------------------------
    $status = if ($spf.Count -ne 1 -or ($record -and $includes -notcontains 'spf.protection.outlook.com') -or $lookups -gt 10 -or $allMechanism -match '^\+all$') {
        'Fail'
    } elseif ($findings.Count -gt 0) { 'Warn' } else { 'Pass' }
    #endregion

    [pscustomobject]@{
        Domain                 = $Domain
        Record                 = $record
        RecordCount            = $spf.Count
        Redirect               = @($redirects)
        Includes               = $includes
        IncludesExchangeOnline = ($includes -contains 'spf.protection.outlook.com')
        AllMechanism           = $allMechanism
        LookupCount            = $lookups
        Status                 = $status
        Findings               = @($findings)
    }
}

function Get-SpfIncludeLookupCount {
    <#
    .SYNOPSIS
        Counts DNS lookups hidden inside include: and redirect= targets, recursively.
    .NOTES
        Internal. Depth is capped at 10 to survive a circular include.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Includes,
        [scriptblock]$Resolver,
        [int]$Depth
    )
    if ($Depth -gt 10 -or -not $Includes) { return 0 }
    $count = 0
    foreach ($target in $Includes) {
        $txt = @(& $Resolver $target 'TXT')
        $record = $txt | Where-Object { $_ -match '^v=spf1(\s|$)' } | Select-Object -First 1
        if (-not $record) { continue }
        $nested = @()
        foreach ($term in ($record -split '\s+' | Select-Object -Skip 1)) {
            $bare = $term -replace '^[+\-~?]', ''
            if ($bare -match '^(include:|redirect=)(.+)$') { $nested += $Matches[2] }
            if ($bare -match '^(include:|a$|a:|mx$|mx:|ptr|exists:|redirect=)') { $count++ }
        }
        $count += Get-SpfIncludeLookupCount -Includes $nested -Resolver $Resolver -Depth ($Depth + 1)
    }
    return $count
}
#endregion

#region Mail authentication: DMARC -------------------------------------------
function Get-DmarcAnalysis {
    <#
    .SYNOPSIS
        Fetches a domain's DMARC record and suggests one if it is missing.
    .DESCRIPTION
        Reads _dmarc.<domain> TXT. Reports policy (p=), aggregate report address (rua) and
        whether the record is parseable. When nothing is published it returns the
        monitoring-mode record from our 'DKIM and DMARC Setup - Exchange Online' SOP:
        p=none with rua/ruf to a mailbox you name. Publishing DMARC is a DNS change the
        tech makes; this only tells them what to publish.
    .PARAMETER Domain
        The domain to check.
    .PARAMETER ReportMailbox
        Address for aggregate/forensic reports in the suggested record. Default dmarc@<domain>.
    .PARAMETER Resolver
        Scriptblock taking (name, type). Defaults to Resolve-DnsRecord.
    .EXAMPLE
        Get-DmarcAnalysis -Domain contoso.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Domain,

        [Parameter()]
        [string]$ReportMailbox,

        [Parameter()]
        [scriptblock]$Resolver = { param($n, $t) Resolve-DnsRecord -Name $n -Type $t }
    )

    if (-not $ReportMailbox) { $ReportMailbox = "dmarc@$Domain" }
    $findings = [System.Collections.Generic.List[string]]::new()
    $txt = @(& $Resolver "_dmarc.$Domain" 'TXT')
    $records = @($txt | Where-Object { $_ -match '^v=DMARC1' })
    $record = if ($records.Count -ge 1) { $records[0] } else { $null }
    $policy = $null; $rua = $null
    if ($record) {
        if ($record -match '(?:^|;)\s*p=(\w+)') { $policy = $Matches[1] }
        if ($record -match '(?:^|;)\s*rua=([^;]+)') { $rua = $Matches[1].Trim() }
        if (-not $policy) { $findings.Add('DMARC record has no p= tag; receivers ignore it.') }
        if (-not $rua) { $findings.Add('DMARC record has no rua= tag, so nobody receives aggregate reports.') }
        if ($policy -eq 'none') { $findings.Add('DMARC is in monitoring mode (p=none). Fine for a new client; tighten after 2-4 weeks of reports.') }
    } else {
        $findings.Add('No DMARC record published.')
    }
    if ($records.Count -gt 1) { $findings.Add("Found $($records.Count) DMARC records; only one is allowed.") }

    $status = if (-not $record -or $records.Count -gt 1 -or -not $policy) { 'Fail' } elseif ($findings.Count -gt 0) { 'Warn' } else { 'Pass' }

    [pscustomobject]@{
        Domain          = $Domain
        Record          = $record
        Policy          = $policy
        ReportAddress   = $rua
        Status          = $status
        Findings        = @($findings)
        SuggestedRecord = "v=DMARC1; p=none; rua=mailto:$ReportMailbox; ruf=mailto:$ReportMailbox; fo=1"
        SuggestedHost   = "_dmarc.$Domain"
    }
}
#endregion

#region Mail authentication: DKIM --------------------------------------------
function Get-M365DkimStatus {
    <#
    .SYNOPSIS
        Reports DKIM signing state for a domain and whether its two CNAMEs are published.
    .DESCRIPTION
        Reads Get-DkimSigningConfig for the domain (requires an Exchange Online session)
        and resolves selector1._domainkey / selector2._domainkey in public DNS. Returns
        the CNAME values the tech must publish, taken from Exchange, never guessed.
        Status: Pass (enabled and published), Warn (enabled, DNS not matching), Fail (no
        config or not enabled), Unknown (the config could not be read; see Error).
        "No config" and "could not read" are never confused: only Exchange's own
        not-found answer means there is no config.
    .PARAMETER Domain
        An accepted domain in the connected tenant.
    .PARAMETER Resolver
        Scriptblock taking (name, type). Defaults to Resolve-DnsRecord.
    .EXAMPLE
        Get-M365DkimStatus -Domain contoso.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Domain,

        [Parameter()]
        [scriptblock]$Resolver = { param($n, $t) Resolve-DnsRecord -Name $n -Type $t }
    )

    if ($Domain -match '[*?]') { throw "'$Domain' contains a wildcard (* or ?). Name exactly one domain." }
    $config = $null
    $readError = $null
    try {
        $config = Get-DkimSigningConfig -Identity $Domain -ErrorAction Stop | Select-Object -First 1
    } catch {
        if (-not (Test-M365NotFoundError $_)) { $readError = $_.Exception.Message }
    }
    if ($readError) {
        return [pscustomobject]@{
            Domain = $Domain; ConfigExists = $null; Enabled = $null; KeySize = $null; Selector1Cname = $null; Selector2Cname = $null
            Selector1Published = $null; Selector2Published = $null; ReadyToEnable = $false; Status = 'Unknown'
            Error = "Could not read the DKIM signing config for ${Domain}: $readError"
        }
    }
    $selector1Published = $false; $selector2Published = $false
    if ($config) {
        $selector1Published = @(& $Resolver "selector1._domainkey.$Domain" 'CNAME') -contains $config.Selector1CNAME
        $selector2Published = @(& $Resolver "selector2._domainkey.$Domain" 'CNAME') -contains $config.Selector2CNAME
    }
    [pscustomobject]@{
        Domain             = $Domain
        ConfigExists       = [bool]$config
        Enabled            = if ($config) { [bool]$config.Enabled } else { $false }
        KeySize            = if ($config) { $config.Selector1KeySize } else { $null }
        Selector1Cname     = if ($config) { $config.Selector1CNAME } else { $null }
        Selector2Cname     = if ($config) { $config.Selector2CNAME } else { $null }
        Selector1Published = $selector1Published
        Selector2Published = $selector2Published
        ReadyToEnable      = [bool]$config -and $selector1Published -and $selector2Published
        Status             = if ($config -and $config.Enabled -and $selector1Published -and $selector2Published) { 'Pass' }
                             elseif ($config -and $config.Enabled) { 'Warn' } else { 'Fail' }
        Error              = $null
    }
}

function Enable-M365Dkim {
    <#
    .SYNOPSIS
        Creates the DKIM signing config for a domain if needed and enables it once DNS is ready.
    .DESCRIPTION
        Step 1 of our DKIM SOP in code. If no signing config exists, creates one (disabled,
        2048-bit) so Exchange generates the selector CNAME values. Then checks public DNS:
        if both CNAMEs resolve, enables signing; if not, returns the records to publish and
        leaves signing off. Safe to run repeatedly: the second run after the tech publishes
        DNS is the one that flips it on. Stops (changes nothing) when the current config
        cannot be read. Every change goes through Invoke-M365Change.
    .PARAMETER Domain
        An accepted domain in the connected tenant.
    .PARAMETER KeySize
        1024 or 2048. Microsoft recommends 2048 for new configs.
    .EXAMPLE
        Enable-M365Dkim -Domain contoso.com -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [string]$Domain,

        [Parameter()]
        [ValidateSet(1024, 2048)]
        [int]$KeySize = 2048
    )

    #region 1. Ensure config exists ------------------------------------------
    #   WHAT   New-DkimSigningConfig -Enabled $false generates the keys/CNAMEs.
    #   WHY    You cannot know the CNAME targets until Exchange creates the config.
    #          Creating it disabled does not change mail flow.
    #   GOTCHA A config that could not be READ is not a missing config: creating one
    #          then would fail or, worse, replace what is there.
    $status = Get-M365DkimStatus -Domain $Domain
    if ($status.Status -eq 'Unknown') { throw "$($status.Error) Nothing was changed for $Domain." }
    $dry = $false
    if (-not $status.ConfigExists) {
        $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Create DKIM signing config for $Domain ($KeySize-bit, signing stays off until DNS is ready)" `
            -Command 'New-DkimSigningConfig' -Parameters ([ordered]@{ DomainName = $Domain; Enabled = $false; KeySize = $KeySize })
        if (-not $run.Ran) {
            $status | Add-Member -NotePropertyName WhatIf -NotePropertyValue $true -Force
            return $status
        }
        $status = Get-M365DkimStatus -Domain $Domain
    }
    #endregion

    #region 2. Enable when DNS is ready ---------------------------------------
    #   WHAT   Only flip Enabled when both selectors resolve to the right targets.
    #   WHY    Set-DkimSigningConfig -Enabled $true errors if the CNAMEs are not
    #          live, and a half-published state just confuses the next tech.
    if ($status.Enabled) {
        Write-Verbose "DKIM already enabled for $Domain."
    } elseif ($status.ReadyToEnable) {
        $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Turn on DKIM signing for $Domain (both selector CNAMEs are published)" `
            -Command 'Set-DkimSigningConfig' -Parameters ([ordered]@{ Identity = $Domain; Enabled = $true })
        if ($run.Ran) { $status = Get-M365DkimStatus -Domain $Domain } else { $dry = $true }
    } else {
        Write-Warning "DKIM CNAMEs for $Domain are not published yet. Publish these, wait for propagation, then re-run:"
        Write-Warning "  CNAME selector1._domainkey.$Domain -> $($status.Selector1Cname)"
        Write-Warning "  CNAME selector2._domainkey.$Domain -> $($status.Selector2Cname)"
    }
    #endregion

    $status | Add-Member -NotePropertyName WhatIf -NotePropertyValue $dry -Force
    return $status
}
#endregion

#region Recipients -------------------------------------------------------------
function New-M365MailContact {
    <#
    .SYNOPSIS
        Creates a mail contact (external address in the GAL) if it does not already exist, optionally hidden from the GAL.
    .DESCRIPTION
        Idempotent on the external address: an existing mail contact that delivers to the
        same address is kept (and hidden if asked). If the address belongs to anything
        else (a mailbox, a group, or a contact that delivers elsewhere), nothing is created
        or hidden and the output says so. Hiding is how we add our own clients@ alias to a
        client tenant without it showing up for their users. Every change goes through
        Invoke-M365Change.
    .PARAMETER Name
        Contact name (also the display name unless -DisplayName is given).
    .PARAMETER ExternalEmailAddress
        The outside address mail is forwarded to.
    .PARAMETER DisplayName
        Display name. Defaults to -Name.
    .PARAMETER HiddenFromAddressLists
        Hide from the GAL.
    .EXAMPLE
        New-M365MailContact -Name 'Example MSP' -ExternalEmailAddress contoso@msp.example -HiddenFromAddressLists
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$ExternalEmailAddress,

        [Parameter()]
        [string]$DisplayName,

        [Parameter()]
        [switch]$HiddenFromAddressLists
    )

    #region 1. Find the contact for this address, or create it --------------------------
    #   WHAT   Exactly one recipient holds the address, or none. A holder that is not a
    #          mail contact for exactly this address is reported, never touched.
    if (-not $DisplayName) { $DisplayName = $Name }
    $wanted = ConvertTo-M365BareAddress $ExternalEmailAddress
    $existing = Get-M365ExactRecipient -Kind Recipient -Identity $ExternalEmailAddress -What 'recipient with that address'
    $dry = $false; $created = $false; $hidden = $false; $contactId = $null; $note = $null; $shownName = $Name
    if ($existing) {
        if ((Get-M365RecipientType $existing) -ne 'MailContact') {
            $note = "$ExternalEmailAddress already belongs to $(Get-M365RecipientLabel $existing). No mail contact was created and nothing was hidden."
            Write-Warning $note
            return [pscustomobject]@{
                Name = "$(Get-M365Prop $existing 'Name')"; ExternalEmailAddress = $ExternalEmailAddress; Identity = (Get-M365RecipientId $existing)
                Created = $false; HiddenFromAddressLists = [bool](Get-M365Prop $existing 'HiddenFromAddressListsEnabled'); WhatIf = $false; Note = $note
            }
        }
        $contact = Get-M365ExactRecipient -Kind MailContact -Identity (Get-M365RecipientId $existing)
        if (-not $contact) { throw "The mail contact holding $ExternalEmailAddress could not be read back. Nothing was changed." }
        $deliversTo = ConvertTo-M365BareAddress "$(Get-M365Prop $contact 'ExternalEmailAddress')"
        if ($deliversTo -and $deliversTo -ne $wanted) {
            throw "$ExternalEmailAddress is a secondary address of mail contact '$($contact.Name)', which delivers to $deliversTo. Nothing was changed."
        }
        $contactId = Get-M365RecipientId $contact
        $hidden = [bool](Get-M365Prop $contact 'HiddenFromAddressListsEnabled')
        $shownName = "$($contact.Name)"
        if ($shownName -ne $Name) { $note = "A mail contact for $ExternalEmailAddress already exists as '$shownName'; it was kept (not renamed)." }
        Write-Verbose "Mail contact for $ExternalEmailAddress already exists ('$shownName')."
    } else {
        $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Create mail contact '$Name' that delivers to $ExternalEmailAddress" `
            -Command 'New-MailContact' -Parameters ([ordered]@{ Name = $Name; DisplayName = $DisplayName; ExternalEmailAddress = $ExternalEmailAddress })
        if ($run.Ran) {
            $created = $true
            $contactId = Get-M365RecipientId $run.Output
            $hidden = [bool](Get-M365Prop $run.Output 'HiddenFromAddressListsEnabled')
        } else {
            $dry = $true
            $contactId = New-M365Placeholder "the mail contact created above ($ExternalEmailAddress)"
        }
    }
    #endregion

    #region 2. Hide ------------------------------------------------------------------
    #   GOTCHA New-MailContact has no hidden switch, so hiding is a second change. In a dry
    #          run for a new contact, a placeholder stands in for the contact not created yet.
    if ($HiddenFromAddressLists -and -not $hidden) {
        $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Hide mail contact $ExternalEmailAddress from the address lists (GAL)" `
            -Command 'Set-MailContact' -Parameters ([ordered]@{ Identity = $contactId; HiddenFromAddressListsEnabled = $true })
        if ($run.Ran) { $hidden = $true } else { $dry = $true }
    }
    #endregion

    [pscustomobject]@{
        Name                   = $shownName
        ExternalEmailAddress   = $ExternalEmailAddress
        Identity               = if ($contactId -is [string]) { $contactId } else { $null }
        Created                = $created
        HiddenFromAddressLists = $hidden
        WhatIf                 = $dry
        Note                   = $note
    }
}

function Add-M365ListMemberChange {
    # Internal. Adds one member to a distribution list through Invoke-M365Change unless it is
    # already a member. The member must exist; in a dry run a missing member is planned with a
    # placeholder (an earlier step, such as a new mail contact, may create it) and a warning.
    param(
        [System.Management.Automation.PSCmdlet]$Caller,
        [string]$ListId,
        [AllowEmptyCollection()]
        [object[]]$CurrentMembers,
        [string]$Member,
        $Target,
        [switch]$Resolved
    )
    $target = if ($Resolved) { $Target } else { Get-M365ExactRecipient -Kind Recipient -Identity $Member -What 'member' }
    if ($target) {
        $memberId = Get-M365RecipientId $target
        $label = "$(Get-M365RecipientType $target) $memberId"
        $guid = "$(Get-M365Prop $target 'Guid')"
        $isMember = @($CurrentMembers | Where-Object {
                ((ConvertTo-M365BareAddress "$(Get-M365Prop $_ 'PrimarySmtpAddress')") -eq (ConvertTo-M365BareAddress $memberId)) -or
                ($guid -and "$(Get-M365Prop $_ 'Guid')" -eq $guid)
            }).Count -gt 0
        if ($isMember) {
            Write-Verbose "$memberId is already a member of $ListId."
            return [pscustomobject]@{ Member = $Member; Added = $false; AlreadyMember = $true; Planned = $false }
        }
    } elseif ($WhatIfPreference) {
        Write-Warning "Member '$Member' does not exist in this tenant yet. The real run stops at this step unless an earlier step creates it."
        $memberId = New-M365Placeholder "$Member (must exist by the real run)"
        $label = $Member
    } else {
        throw "Member '$Member' was not found in this tenant. An outside address needs a mail contact first (New-M365MailContact). Nothing was changed."
    }
    $run = Invoke-M365Change -Caller $Caller -Service Exchange -Action "Add $label to distribution list $ListId" `
        -Command 'Add-DistributionGroupMember' -Parameters ([ordered]@{ Identity = $ListId; Member = $memberId })
    [pscustomobject]@{ Member = $Member; Added = $run.Ran; AlreadyMember = $false; Planned = (-not $run.Ran) }
}

function New-M365DistributionList {
    <#
    .SYNOPSIS
        Creates a distribution list if missing and ensures the given members are in it.
    .DESCRIPTION
        Idempotent on the primary SMTP address: an existing distribution list whose PRIMARY
        address is the one asked for is kept. If the address belongs to anything else (a
        secondary address of another list, a mailbox, a security or Microsoft 365 group),
        the function stops and names the owner. When an existing list's sender restriction
        differs from -RequireSenderAuthentication, the output warns instead of changing it.
        Defaults to accepting mail from outside the organization, because the lists we
        create during onboarding (IT@, alerts@) exist to receive vendor and monitoring mail.
        Members can be users, contacts or other groups, by address or identity.
    .PARAMETER Name
        Group name.
    .PARAMETER PrimarySmtpAddress
        Address of the list, e.g. IT@contoso.com.
    .PARAMETER Members
        Recipients to ensure are members.
    .PARAMETER RequireSenderAuthentication
        Only accept mail from inside the tenant. Off by default.
    .EXAMPLE
        New-M365DistributionList -Name IT -PrimarySmtpAddress IT@contoso.com -Members contoso@msp.example
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$PrimarySmtpAddress,

        [Parameter()]
        [string[]]$Members = @(),

        [Parameter()]
        [switch]$RequireSenderAuthentication
    )

    #region 1. Members must exist before anything is created ---------------------------
    #   WHY    Finding a missing member after the list was created leaves a half-done list.
    #          In a dry run a missing member is planned with a placeholder and a warning
    #          (an earlier step, such as a new mail contact, may create it).
    $resolved = @{}
    $missing = @()
    foreach ($member in $Members) {
        $found = Get-M365ExactRecipient -Kind Recipient -Identity $member -What 'member'
        if ($found) { $resolved[$member] = $found } else { $missing += $member }
    }
    if ($missing.Count -gt 0 -and -not $WhatIfPreference) {
        throw "Member(s) not found in this tenant: $($missing -join ', '). An outside address needs a mail contact first (New-M365MailContact). Nothing was changed."
    }
    #endregion

    #region 2. The list: exactly this primary address, exactly this kind --------------
    $wanted = ConvertTo-M365BareAddress $PrimarySmtpAddress
    $existing = Get-M365ExactRecipient -Kind Recipient -Identity $PrimarySmtpAddress -What 'recipient with that address'
    $warnings = [System.Collections.Generic.List[string]]::new()
    $dry = $false; $created = $false; $shownName = $Name; $current = @()
    if ($existing) {
        $type = Get-M365RecipientType $existing
        $primary = ConvertTo-M365BareAddress "$(Get-M365Prop $existing 'PrimarySmtpAddress')"
        if ($type -ne 'MailUniversalDistributionGroup' -or $primary -ne $wanted) {
            throw "$PrimarySmtpAddress already belongs to $(Get-M365RecipientLabel $existing), which is not a distribution list with that primary address. Nothing was changed."
        }
        $group = Get-M365ExactRecipient -Kind DistributionGroup -Identity (Get-M365RecipientId $existing)
        if (-not $group) { throw "Distribution list $PrimarySmtpAddress could not be read back. Nothing was changed." }
        $listId = Get-M365RecipientId $group
        $shownName = "$($group.Name)"
        if ($shownName -ne $Name) { $warnings.Add("Distribution list $listId already exists as '$shownName'; it was kept (not renamed).") }
        $rsa = "$(Get-M365Prop $group 'RequireSenderAuthenticationEnabled')" -eq 'True'
        if ($rsa -ne [bool]$RequireSenderAuthentication) {
            $warnings.Add("Distribution list $listId already exists with RequireSenderAuthenticationEnabled=$rsa ($(if ($rsa) { 'internal senders only' } else { 'accepts mail from outside' })), not $([bool]$RequireSenderAuthentication) as requested. It was left unchanged.")
        }
        $current = @(Get-DistributionGroupMember -Identity $listId -ResultSize Unlimited -ErrorAction Stop)
    } else {
        $senders = if ($RequireSenderAuthentication) { 'internal senders only' } else { 'accepts mail from outside' }
        $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Create distribution list '$Name' ($PrimarySmtpAddress), $senders, closed membership" `
            -Command 'New-DistributionGroup' -Parameters ([ordered]@{
                Name = $Name; DisplayName = $Name; PrimarySmtpAddress = $PrimarySmtpAddress; Type = 'Distribution'
                MemberJoinRestriction = 'Closed'; MemberDepartRestriction = 'Closed'; RequireSenderAuthenticationEnabled = [bool]$RequireSenderAuthentication
            })
        if ($run.Ran) {
            $created = $true
            $got = ConvertTo-M365BareAddress "$(Get-M365Prop $run.Output 'PrimarySmtpAddress')"
            if ($got -and $got -ne $wanted) { throw "Exchange created the list with primary address $got, not $PrimarySmtpAddress. Stopped before adding members." }
        } else { $dry = $true }
        #   GOTCHA The address was free and the new list owns it, so the members are added
        #          to "$PrimarySmtpAddress" in both the dry run and the real run.
        $listId = $PrimarySmtpAddress
    }
    #endregion

    #region 3. Members ----------------------------------------------------------------
    $added = @(); $already = @(); $planned = @()
    foreach ($member in $Members) {
        $r = Add-M365ListMemberChange -Caller $PSCmdlet -ListId $listId -CurrentMembers $current -Member $member -Target $resolved[$member] -Resolved
        if ($r.Added) { $added += $member } elseif ($r.AlreadyMember) { $already += $member } elseif ($r.Planned) { $planned += $member; $dry = $true }
    }
    foreach ($w in $warnings) { Write-Warning $w }
    #endregion

    [pscustomobject]@{
        Name               = $shownName
        PrimarySmtpAddress = $PrimarySmtpAddress
        Created            = $created
        MembersAdded       = $added
        MembersAlready     = $already
        MembersPlanned     = $planned
        Warnings           = @($warnings)
        WhatIf             = $dry
    }
}

function Add-M365DistributionListMember {
    <#
    .SYNOPSIS
        Adds a member to a distribution list unless already present.
    .DESCRIPTION
        The list and the member must each match exactly one object (no wildcards). The change
        names both by primary SMTP address and goes through Invoke-M365Change.
    .PARAMETER Identity
        The list, by address or identity.
    .PARAMETER Member
        The recipient to add, by address or identity.
    .EXAMPLE
        Add-M365DistributionListMember -Identity 'Client Notifications' -Member jane@contoso.com
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [string]$Identity,

        [Parameter(Mandatory)]
        [string]$Member
    )

    $group = Get-M365ExactRecipient -Kind DistributionGroup -Identity $Identity -What 'distribution list'
    if (-not $group) { throw "Distribution list '$Identity' was not found in this tenant. Nothing was changed." }
    $listId = Get-M365RecipientId $group
    $current = @(Get-DistributionGroupMember -Identity $listId -ResultSize Unlimited -ErrorAction Stop)
    $r = Add-M365ListMemberChange -Caller $PSCmdlet -ListId $listId -CurrentMembers $current -Member $Member
    [pscustomobject]@{ Identity = $Identity; List = $listId; Member = $Member; Added = $r.Added; AlreadyMember = $r.AlreadyMember; WhatIf = $r.Planned }
}

function New-M365SharedMailbox {
    <#
    .SYNOPSIS
        Creates a shared mailbox if missing and optionally grants Full Access (no automapping).
    .DESCRIPTION
        Idempotent on the primary SMTP address, and strict about it: an existing SHARED
        mailbox whose PRIMARY address is the one asked for is kept. If the address belongs
        to anything else (an alias on someone's personal mailbox, a user mailbox, a group),
        the function stops, names the owner, and grants nothing, so Full Access can never
        land on the wrong mailbox. Full Access is granted only on that verified mailbox,
        and a dry run plans the grants too. Used for the 911@ phishing-report mailbox
        (ironScales) and for any other shared mailbox a client needs.
    .PARAMETER Name
        Mailbox name and display name.
    .PARAMETER PrimarySmtpAddress
        Address, e.g. 911@contoso.com.
    .PARAMETER FullAccess
        Users to grant Full Access (with automapping off, so Outlook does not force it open).
    .EXAMPLE
        New-M365SharedMailbox -Name '911' -PrimarySmtpAddress 911@contoso.com -FullAccess bob@contoso.com -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$PrimarySmtpAddress,

        [Parameter()]
        [string[]]$FullAccess = @()
    )

    #region 1. The mailbox: shared, with exactly this primary address -----------------
    $wanted = ConvertTo-M365BareAddress $PrimarySmtpAddress
    $existing = Get-M365ExactRecipient -Kind Recipient -Identity $PrimarySmtpAddress -What 'recipient with that address'
    $dry = $false; $created = $false; $note = $null
    if ($existing) {
        $type = Get-M365RecipientType $existing
        $primary = ConvertTo-M365BareAddress "$(Get-M365Prop $existing 'PrimarySmtpAddress')"
        if ($type -ne 'SharedMailbox' -or $primary -ne $wanted) {
            throw "$PrimarySmtpAddress already belongs to $(Get-M365RecipientLabel $existing), which is not a shared mailbox with that primary address. Nothing was created and no Full Access was granted."
        }
        $mailboxId = Get-M365RecipientId $existing
        if ("$(Get-M365Prop $existing 'Name')" -ne $Name) { $note = "Shared mailbox $mailboxId already exists as '$(Get-M365Prop $existing 'Name')'; it was kept (not renamed)." }
        Write-Verbose "Shared mailbox $mailboxId already exists."
    } else {
        $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Create shared mailbox '$Name' ($PrimarySmtpAddress)" `
            -Command 'New-Mailbox' -Parameters ([ordered]@{ Name = $Name; Shared = [switch]::new($true); DisplayName = $Name; PrimarySmtpAddress = $PrimarySmtpAddress })
        if ($run.Ran) {
            $created = $true
            $got = ConvertTo-M365BareAddress "$(Get-M365Prop $run.Output 'PrimarySmtpAddress')"
            if ($got -and $got -ne $wanted) { throw "Exchange created the mailbox with primary address $got, not $PrimarySmtpAddress. Stopped before granting Full Access." }
        } else { $dry = $true }
        $mailboxId = $PrimarySmtpAddress
    }
    #endregion

    #region 2. Full Access on that mailbox only -----------------------------------------
    $granted = @(); $already = @(); $planned = @()
    foreach ($user in $FullAccess) {
        $trustee = Get-M365ExactRecipient -Kind Recipient -Identity $user -What 'Full Access user'
        if (-not $trustee) { throw "Full Access user '$user' was not found in this tenant. Nothing more was changed." }
        $trusteeId = Get-M365RecipientId $trustee
        if ($existing) {
            $has = @(Get-MailboxPermission -Identity $mailboxId -User $trusteeId -ErrorAction Stop | Where-Object { "$($_.AccessRights)" -match 'FullAccess' -and "$(Get-M365Prop $_ 'Deny')" -ne 'True' }).Count -gt 0
            if ($has) { $already += $user; continue }
        }
        $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Give $trusteeId Full Access to shared mailbox $mailboxId (no automapping)" `
            -Command 'Add-MailboxPermission' -Parameters ([ordered]@{ Identity = $mailboxId; User = $trusteeId; AccessRights = 'FullAccess'; AutoMapping = $false })
        if ($run.Ran) { $granted += $user } else { $planned += $user; $dry = $true }
    }
    #endregion

    [pscustomobject]@{
        Name               = $Name
        PrimarySmtpAddress = $PrimarySmtpAddress
        Created            = $created
        FullAccessGranted  = $granted
        FullAccessAlready  = $already
        FullAccessPlanned  = $planned
        WhatIf             = $dry
        Note               = $note
    }
}

function Add-M365MailboxAlias {
    <#
    .SYNOPSIS
        Adds a secondary SMTP address to a mailbox unless it already has it.
    .DESCRIPTION
        This is how a client-specific alias (contoso@msp.example) gets attached to our
        clients@ shared mailbox so vendor mail for that client lands with us. The mailbox
        must match exactly one object; the alias must not belong to any other recipient.
        Adds with @{ Add = ... } so existing addresses are kept.
    .PARAMETER Mailbox
        The mailbox, by address or identity.
    .PARAMETER Alias
        Full SMTP address to add. The domain must be accepted in the connected tenant.
    .EXAMPLE
        Add-M365MailboxAlias -Mailbox clients@msp.example -Alias contoso@msp.example
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [string]$Mailbox,

        [Parameter(Mandatory)]
        [string]$Alias
    )

    if ($Alias -notmatch '^[^@\s*?]+@[^@\s*?]+\.[^@\s*?]+$') { throw "'$Alias' is not a single SMTP address. Nothing was changed." }
    $mbx = Get-M365ExactRecipient -Kind Mailbox -Identity $Mailbox
    if (-not $mbx) { throw "Mailbox '$Mailbox' was not found in this tenant. Nothing was changed." }
    $mailboxId = Get-M365RecipientId $mbx
    $wanted = ConvertTo-M365BareAddress $Alias
    $has = @(@(Get-M365Prop $mbx 'EmailAddresses') | Where-Object { "$_" -match '^(?i)smtp:' -and (ConvertTo-M365BareAddress "$_") -eq $wanted }).Count -gt 0
    if ($has) {
        Write-Verbose "$mailboxId already has alias $Alias."
        return [pscustomobject]@{ Mailbox = $mailboxId; Alias = $Alias; Added = $false; WhatIf = $false }
    }
    $taken = Get-M365ExactRecipient -Kind Recipient -Identity $Alias -What 'recipient with that address'
    if ($taken) { throw "$Alias is already assigned to $(Get-M365RecipientLabel $taken). Nothing was changed." }
    $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Add alias $Alias to mailbox $mailboxId (existing addresses kept)" `
        -Command 'Set-Mailbox' -Parameters ([ordered]@{ Identity = $mailboxId; EmailAddresses = @{ Add = $Alias } })
    [pscustomobject]@{ Mailbox = $mailboxId; Alias = $Alias; Added = $run.Ran; WhatIf = (-not $run.Ran) }
}

function New-M365MailboxFolder {
    <#
    .SYNOPSIS
        Creates a mail folder in a mailbox (yours or a shared one) via Microsoft Graph.
    .DESCRIPTION
        New-MailboxFolder in Exchange PowerShell only works on your own mailbox, so shared
        mailboxes go through Graph. Needs Mail.ReadWrite.Shared (delegated) and Full Access
        on the target mailbox. Idempotent on display name under the parent. The change goes
        through Invoke-M365Change (Service Graph).
    .PARAMETER Mailbox
        UPN or address of the mailbox.
    .PARAMETER Name
        Folder display name.
    .PARAMETER ParentFolder
        Well-known name (inbox) or folder id. Default inbox.
    .EXAMPLE
        New-M365MailboxFolder -Mailbox clients@msp.example -Name 'Contoso'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [string]$Mailbox,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [string]$ParentFolder = 'inbox'
    )

    $existing = @(Get-MgUserMailFolderChildFolder -UserId $Mailbox -MailFolderId $ParentFolder -All -ErrorAction Stop | Where-Object { $_.DisplayName -eq $Name })
    if ($existing.Count -gt 0) {
        Write-Verbose "Folder '$Name' already exists under $ParentFolder in $Mailbox."
        return [pscustomobject]@{ Mailbox = $Mailbox; Name = $Name; Id = $existing[0].Id; Created = $false; WhatIf = $false }
    }
    $run = Invoke-M365Change -Caller $PSCmdlet -Service Graph -Action "Create mail folder '$Name' under $ParentFolder in mailbox $Mailbox" `
        -Command 'New-MgUserMailFolderChildFolder' -Parameters ([ordered]@{ UserId = $Mailbox; MailFolderId = $ParentFolder; BodyParameter = @{ displayName = $Name } })
    [pscustomobject]@{ Mailbox = $Mailbox; Name = $Name; Id = $(if ($run.Ran) { Get-M365Prop $run.Output 'Id' } else { $null }); Created = $run.Ran; WhatIf = (-not $run.Ran) }
}

function New-M365InboxRule {
    <#
    .SYNOPSIS
        Creates a server-side inbox rule that files matching mail into a folder. Note: per Microsoft, creating rules from PowerShell can remove Outlook client-only rules in that mailbox.
    .DESCRIPTION
        Idempotent on rule name. Either condition can be used alone or together (they are
        ANDed by Exchange, so for "subject mentions client OR sent to alias" create two
        rules). The folder must already exist; see New-M365MailboxFolder.

        Microsoft behaviour to know before running: when a rule is created or changed with
        PowerShell or Outlook on the web, rules that exist only in the Outlook client (for
        example rules turned off in Outlook) can be deleted. Exchange normally asks before
        doing that; Invoke-M365Change answers that prompt (-Confirm:$false) because the
        operator already confirmed this exact change, so nothing waits on a hidden prompt.
        Later rules still run after this one unless -StopProcessingRules is given.
    .PARAMETER Mailbox
        Mailbox the rule lives in.
    .PARAMETER Name
        Rule name.
    .PARAMETER SubjectOrBodyContainsWords
        Words or phrases to match in subject or body.
    .PARAMETER SentTo
        Recipient addresses to match (the alias on a shared mailbox, for example).
    .PARAMETER MoveToFolder
        Folder path relative to the mailbox root, e.g. 'Inbox\Contoso'.
    .PARAMETER StopProcessingRules
        Stop evaluating later rules once this one matches. Off by default.
    .EXAMPLE
        New-M365InboxRule -Mailbox clients@msp.example -Name 'Client - Contoso' -SubjectOrBodyContainsWords 'Contoso' -MoveToFolder 'Inbox\Contoso'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [string]$Mailbox,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [string[]]$SubjectOrBodyContainsWords,

        [Parameter()]
        [string[]]$SentTo,

        [Parameter(Mandatory)]
        [string]$MoveToFolder,

        [Parameter()]
        [switch]$StopProcessingRules
    )

    if (-not $SubjectOrBodyContainsWords -and -not $SentTo) { throw 'Pass -SubjectOrBodyContainsWords and/or -SentTo.' }
    $mbx = Get-M365ExactRecipient -Kind Mailbox -Identity $Mailbox
    if (-not $mbx) { throw "Mailbox '$Mailbox' was not found in this tenant. Nothing was changed." }
    $mailboxId = Get-M365RecipientId $mbx
    $existing = @(Get-InboxRule -Mailbox $mailboxId -ErrorAction Stop | Where-Object { $_.Name -eq $Name })
    if ($existing.Count -gt 0) {
        Write-Verbose "Inbox rule '$Name' already exists in $mailboxId."
        return [pscustomobject]@{ Mailbox = $mailboxId; Name = $Name; Created = $false; WhatIf = $false }
    }
    $params = [ordered]@{ Mailbox = $mailboxId; Name = $Name }
    $conditions = @()
    if ($SubjectOrBodyContainsWords) { $params.SubjectOrBodyContainsWords = @($SubjectOrBodyContainsWords); $conditions += "subject or body contains $(($SubjectOrBodyContainsWords | ForEach-Object { "'$_'" }) -join ' or ')" }
    if ($SentTo) { $params.SentTo = @($SentTo); $conditions += "sent to $($SentTo -join ' or ')" }
    $params.MoveToFolder = "${mailboxId}:\$MoveToFolder"
    $params.StopProcessingRules = [bool]$StopProcessingRules
    #   GOTCHA Exchange may ask before removing the mailbox's Outlook client-only rules. -Force
    #          answers that the same way every time (no hidden prompt in the GUI worker), and
    #          the plan line says so, so the operator approves it knowingly.
    $params.Force = [switch]::new($true)
    $then = if ($StopProcessingRules) { ', then stop processing later rules' } else { '' }
    $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Create inbox rule '$Name' in $($mailboxId): when $($conditions -join ' and '), move to $MoveToFolder$then (Exchange removes any Outlook client-only rules in this mailbox)" `
        -Command 'New-InboxRule' -Parameters $params
    [pscustomobject]@{ Mailbox = $mailboxId; Name = $Name; Created = $run.Ran; WhatIf = (-not $run.Ran) }
}
#endregion

#region Templated mail ---------------------------------------------------------
function Format-M365Template {
    <#
    .SYNOPSIS
        Replaces {{token}} placeholders in a template string, literally (values are never treated as patterns).
    .DESCRIPTION
        Pure function. Tokens are case-insensitive and filled in one pass, so a value that
        contains $, \ or {{other}} is inserted exactly as given. With -HtmlEncode every
        value is HTML-encoded first (& < > " '), which is what an HTML template needs: a
        client name like "Smith & Sons" or a value with < must not break or inject markup.
        Any {{token}} left without a value is an error, so a welcome letter never goes out
        reading "Dear {{FirstName}}".
    .PARAMETER Template
        The template text.
    .PARAMETER Tokens
        Hashtable of token name to value.
    .PARAMETER HtmlEncode
        HTML-encode the values (use for HTML templates).
    .EXAMPLE
        Format-M365Template -Template '<p>Hello {{Name}}</p>' -Tokens @{ Name = 'Smith & Sons' } -HtmlEncode
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Template,

        [Parameter(Mandatory)]
        [hashtable]$Tokens,

        [Parameter()]
        [switch]$HtmlEncode
    )

    $values = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $Tokens.Keys) { $values["$key".Trim()] = if ($null -eq $Tokens[$key]) { '' } else { [string]$Tokens[$key] } }
    $missing = [System.Collections.Generic.List[string]]::new()
    $encode = [bool]$HtmlEncode
    #   GOTCHA A MatchEvaluator's return value is inserted literally; a replacement STRING
    #          would turn "USD $50" into "USD 0" or "$$" into "$".
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($match)
        $name = $match.Groups[1].Value
        if ($values.ContainsKey($name)) {
            if ($encode) { [System.Net.WebUtility]::HtmlEncode($values[$name]) } else { $values[$name] }
        } else {
            $missing.Add($name)
            $match.Value
        }
    }
    $result = [regex]::Replace($Template, '\{\{\s*([A-Za-z0-9_]+)\s*\}\}', $evaluator)
    if ($missing.Count -gt 0) { throw "Template still has unfilled tokens: $(($missing | Sort-Object -Unique) -join ', ')" }
    return $result
}

function Send-M365TemplateMail {
    <#
    .SYNOPSIS
        Sends an HTML email from a template through Microsoft Graph as a given mailbox, one separate message per recipient.
    .DESCRIPTION
        Fills the template with Format-M365Template (values HTML-encoded), then calls
        Send-MgUserMail as -From once PER RECIPIENT, so recipients never see each other's
        addresses on a shared To line. -Bcc goes on every message. Sending as a shared
        mailbox needs Mail.Send.Shared and Send As rights; sending as yourself needs
        Mail.Send. The Graph session must be in the tenant that owns -From (ours, for the
        welcome letter), not the client's. Every send goes through Invoke-M365Change.
    .PARAMETER From
        Mailbox to send as.
    .PARAMETER To
        Recipient addresses. Each one gets its own message.
    .PARAMETER Subject
        Subject line. Also token-expanded (not HTML-encoded).
    .PARAMETER TemplatePath
        Path to an HTML template with {{tokens}}.
    .PARAMETER Tokens
        Token values.
    .PARAMETER Bcc
        Optional blind copies on every message (e.g. our clients@ mailbox for the record).
    .EXAMPLE
        Send-M365TemplateMail -From support@msp.example -To jane@contoso.com -Subject 'Welcome' -TemplatePath ./templates/welcome-letter.html -Tokens @{ ClientName = 'Contoso' }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [string]$From,

        [Parameter(Mandatory)]
        [string[]]$To,

        [Parameter(Mandatory)]
        [string]$Subject,

        [Parameter(Mandatory)]
        [string]$TemplatePath,

        [Parameter()]
        [hashtable]$Tokens = @{},

        [Parameter()]
        [string[]]$Bcc = @()
    )

    #region 1. Render once, before anything is sent -------------------------------
    #   WHY    An unfilled token throws here, so no recipient gets a half-merged letter.
    $html = Format-M365Template -Template (Get-Content -Path $TemplatePath -Raw) -Tokens $Tokens -HtmlEncode
    $subjectText = Format-M365Template -Template $Subject -Tokens $Tokens
    $templateName = Split-Path -Path $TemplatePath -Leaf
    #endregion

    #region 2. One message per recipient ------------------------------------------------
    foreach ($recipient in $To) {
        $message = @{
            subject      = $subjectText
            body         = @{ contentType = 'HTML'; content = $html }
            toRecipients = @(@{ emailAddress = @{ address = $recipient } })
        }
        if ($Bcc) { $message.bccRecipients = @($Bcc | ForEach-Object { @{ emailAddress = @{ address = $_ } } }) }
        $bccText = if ($Bcc) { ", bcc $($Bcc -join ', ')" } else { '' }
        $run = Invoke-M365Change -Caller $PSCmdlet -Service Graph -Action "Send '$subjectText' as $From to $recipient only (template $templateName$bccText)" `
            -Command 'Send-MgUserMail' -Parameters ([ordered]@{ UserId = $From; BodyParameter = @{ message = $message; saveToSentItems = $true } })
        [pscustomobject]@{ From = $From; To = $recipient; Subject = $subjectText; Sent = $run.Ran; WhatIf = (-not $run.Ran) }
    }
    #endregion
}
#endregion

#region Audits (read-only) -----------------------------------------------------
function Test-M365ExternalAddress {
    <#
    .SYNOPSIS
        True when an SMTP address is outside the given accepted domains. Pure.
    .EXAMPLE
        Test-M365ExternalAddress -Address 'x@gmail.example' -AcceptedDomains 'contoso.com'
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Address,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$AcceptedDomains
    )
    $clean = $Address -replace '^(?i)smtp:', ''
    if ($clean -notmatch '@') { return $false }
    $domain = ($clean -split '@')[-1].ToLowerInvariant()
    return -not ($AcceptedDomains | Where-Object { $_ -and $domain -eq $_.ToLowerInvariant() })
}

function Resolve-M365ForwardTarget {
    # Internal. Classifies a forwarding target that is a recipient identity (ForwardingAddress,
    # or an inbox rule's [EX:...] target). A mail contact or mail user whose outside address is
    # not in an accepted domain is External. Returns @{ Target; External; Error }; never throws.
    param([string]$Identity, [string[]]$AcceptedDomains, [hashtable]$Cache)
    if ($Cache.ContainsKey($Identity)) { return $Cache[$Identity] }
    $result = try {
        $r = Get-M365ExactRecipient -Kind Recipient -Identity $Identity -What 'forwarding target'
        if (-not $r) {
            [pscustomobject]@{ Target = $Identity; External = $null; Error = "Forwarding target '$Identity' was not found in this tenant." }
        } else {
            $ext = Get-M365RecipientExternalAddress -Recipient $r -AcceptedDomains $AcceptedDomains
            if ($ext) { [pscustomobject]@{ Target = $ext; External = $true; Error = $null } }
            else { [pscustomobject]@{ Target = (Get-M365RecipientId $r); External = $false; Error = $null } }
        }
    } catch {
        [pscustomobject]@{ Target = $Identity; External = $null; Error = $_.Exception.Message }
    }
    $Cache[$Identity] = $result
    return $result
}

function Get-M365ForwardingAudit {
    <#
    .SYNOPSIS
        Lists mailbox-level forwarding and (optionally) inbox rules that forward or redirect, flagging external targets.
    .DESCRIPTION
        Mailbox forwarding (ForwardingSmtpAddress / ForwardingAddress) is one call. Inbox rules
        are one call per mailbox, so -IncludeInboxRules is slow on large tenants; run it on
        onboarding and when a compromise is suspected.

        Forwarding to a mail contact or mail user whose address is outside the tenant counts
        as External, even though Exchange stores it as an internal recipient. A mailbox
        whose inbox rules cannot be read, or a target that cannot be resolved, produces a
        row with the Error column filled and a warning: it is never silently skipped, so a
        mailbox the audit could not see never looks clean. External is $null (unknown) on
        those rows.
    .PARAMETER IncludeInboxRules
        Also inspect inbox rules.
    .EXAMPLE
        Get-M365ForwardingAudit -IncludeInboxRules | Where-Object { $_.External -or $_.Error }
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$IncludeInboxRules
    )
    $accepted = @(Get-AcceptedDomain -ErrorAction Stop | ForEach-Object { "$($_.DomainName)" })
    $mailboxes = @(Get-Mailbox -ResultSize Unlimited -ErrorAction Stop)
    $cache = @{}
    $row = {
        param($Mailbox, $Source, $Rule, $Target, $External, $KeepsCopy, $ErrorText)
        if ($ErrorText) { Write-Warning "$($Mailbox): $ErrorText" }
        [pscustomobject]@{ Mailbox = $Mailbox; Source = $Source; Rule = $Rule; Target = $Target; External = $External; KeepsCopy = $KeepsCopy; Error = $ErrorText }
    }
    foreach ($m in $mailboxes) {
        $mailboxId = Get-M365RecipientId $m
        $keeps = "$(Get-M365Prop $m 'DeliverToMailboxAndForward')" -eq 'True'
        $fa = "$(Get-M365Prop $m 'ForwardingAddress')"
        $fsa = "$(Get-M365Prop $m 'ForwardingSmtpAddress')"
        if ($fa) {
            $t = Resolve-M365ForwardTarget -Identity $fa -AcceptedDomains $accepted -Cache $cache
            & $row $mailboxId 'Mailbox' $null $t.Target $t.External $keeps $t.Error
        }
        if ($fsa) {
            $addr = ConvertTo-M365BareAddress $fsa
            & $row $mailboxId 'Mailbox' $null $addr (Test-M365ExternalAddress -Address $addr -AcceptedDomains $accepted) $keeps $null
        }
        if (-not $IncludeInboxRules) { continue }
        try {
            $rules = @(Get-InboxRule -Mailbox $mailboxId -ErrorAction Stop)
        } catch {
            & $row $mailboxId 'InboxRule' $null $null $null $null "Could not read inbox rules: $($_.Exception.Message)"
            continue
        }
        foreach ($rule in $rules) {
            $redirect = @(Get-M365Prop $rule 'RedirectTo') | Where-Object { $_ }
            $targets = @(@(Get-M365Prop $rule 'ForwardTo') + @(Get-M365Prop $rule 'ForwardAsAttachmentTo') + $redirect | Where-Object { $_ })
            foreach ($t in $targets) {
                $text = "$t"
                if ($text -match '\[SMTP:([^\]]+)\]') {
                    $addr = $Matches[1]
                    & $row $mailboxId 'InboxRule' $rule.Name $addr (Test-M365ExternalAddress -Address $addr -AcceptedDomains $accepted) (-not $redirect) $null
                } else {
                    #   GOTCHA "[EX:/o=...]" is an internal recipient's legacy DN, which can be
                    #          a mail contact that delivers outside. Resolve it.
                    $id = if ($text -match '\[EX:([^\]]+)\]') { $Matches[1] } else { $text }
                    $r = if ($id -match '@' -and $id -notmatch '^/o=') {
                        [pscustomobject]@{ Target = $id; External = (Test-M365ExternalAddress -Address $id -AcceptedDomains $accepted); Error = $null }
                    } else { Resolve-M365ForwardTarget -Identity $id -AcceptedDomains $accepted -Cache $cache }
                    & $row $mailboxId 'InboxRule' $rule.Name $r.Target $r.External (-not $redirect) $r.Error
                }
            }
        }
    }
}

function Get-M365MailboxPermissionAudit {
    <#
    .SYNOPSIS
        Lists non-default Full Access, Send As and Send on Behalf grants across all mailboxes.
    .DESCRIPTION
        Skips SELF and inherited entries. One Get-MailboxPermission and one
        Get-RecipientPermission per mailbox, so expect a minute or two on larger tenants.
        A mailbox whose permissions cannot be read produces a row with the Error column
        filled (and a warning) instead of being silently skipped.
    .PARAMETER RecipientTypeDetails
        Limit to mailbox types, e.g. SharedMailbox, UserMailbox. Default all.
    .EXAMPLE
        Get-M365MailboxPermissionAudit | Sort-Object Mailbox | Format-Table
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string[]]$RecipientTypeDetails
    )
    $params = @{ ResultSize = 'Unlimited'; ErrorAction = 'Stop' }
    if ($RecipientTypeDetails) { $params.RecipientTypeDetails = $RecipientTypeDetails }
    foreach ($m in @(Get-Mailbox @params)) {
        $mailboxId = Get-M365RecipientId $m
        $type = Get-M365RecipientType $m
        $row = {
            param($Permission, $Trustee, $Deny, $ErrorText)
            if ($ErrorText) { Write-Warning "$($mailboxId): $ErrorText" }
            [pscustomobject]@{ Mailbox = $mailboxId; MailboxType = $type; Permission = $Permission; Trustee = $Trustee; Deny = $Deny; Error = $ErrorText }
        }
        try {
            foreach ($p in @(Get-MailboxPermission -Identity $mailboxId -ErrorAction Stop | Where-Object { "$(Get-M365Prop $_ 'IsInherited')" -ne 'True' -and "$($_.User)" -notmatch 'NT AUTHORITY\\SELF' -and "$($_.User)" -notmatch '^S-1-5-' })) {
                & $row 'FullAccess' "$($p.User)" ("$(Get-M365Prop $p 'Deny')" -eq 'True') $null
            }
        } catch { & $row 'FullAccess' $null $null "Could not read Full Access permissions: $($_.Exception.Message)" }
        try {
            foreach ($p in @(Get-RecipientPermission -Identity $mailboxId -ErrorAction Stop | Where-Object { "$($_.Trustee)" -notmatch 'NT AUTHORITY\\SELF' })) {
                & $row 'SendAs' "$($p.Trustee)" ("$(Get-M365Prop $p 'AccessControlType')" -eq 'Deny') $null
            }
        } catch { & $row 'SendAs' $null $null "Could not read Send As permissions: $($_.Exception.Message)" }
        foreach ($t in @(Get-M365Prop $m 'GrantSendOnBehalfTo')) {
            if ($t) { & $row 'SendOnBehalf' "$t" $false $null }
        }
    }
}
#endregion

#region Lifecycle --------------------------------------------------------------
function ConvertTo-M365SharedMailbox {
    <#
    .SYNOPSIS
        Converts a user mailbox to a shared mailbox (keeps the mail, frees the license) and verifies it.
    .DESCRIPTION
        Offboarding step. Idempotent. Only a user mailbox is converted (a room, equipment or
        other type stops the function). After a real run the mailbox is read back and
        IsShared is $true only when Exchange reports RecipientTypeDetails SharedMailbox;
        callers must not remove the license unless IsShared is $true. Under -WhatIf
        IsShared reports the current state. A shared mailbox over 50 GB or with an archive
        still needs a license; the function warns when the mailbox is over 50 GB.
    .PARAMETER Identity
        The mailbox, by address or identity. Must match exactly one mailbox.
    .EXAMPLE
        ConvertTo-M365SharedMailbox -Identity jane@contoso.com -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [string]$Identity
    )
    $m = Get-M365ExactRecipient -Kind Mailbox -Identity $Identity
    if (-not $m) { throw "Mailbox '$Identity' was not found in this tenant. Nothing was changed." }
    $mailboxId = Get-M365RecipientId $m
    $type = Get-M365RecipientType $m
    if ($type -eq 'SharedMailbox') {
        Write-Verbose "$mailboxId is already a shared mailbox."
        return [pscustomobject]@{ Mailbox = $mailboxId; Converted = $false; Type = 'SharedMailbox'; IsShared = $true; WhatIf = $false }
    }
    if ($type -ne 'UserMailbox') { throw "$mailboxId is a $type, not a user mailbox. Only user mailboxes are converted. Nothing was changed." }
    try {
        $stats = Get-MailboxStatistics -Identity $mailboxId -ErrorAction Stop
        if ("$(Get-M365Prop $stats 'TotalItemSize')" -match '\(([\d,]+) bytes\)' -and ([long]($Matches[1] -replace ',', '')) -gt 50GB) {
            Write-Warning "$mailboxId is over 50 GB; a shared mailbox that size still needs an Exchange Online Plan 2 license."
        }
    } catch { Write-Warning "Could not read the size of $mailboxId ($($_.Exception.Message)); check it is under 50 GB before removing the license." }

    $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Convert user mailbox $mailboxId to a shared mailbox" `
        -Command 'Set-Mailbox' -Parameters ([ordered]@{ Identity = $mailboxId; Type = 'Shared' })
    if (-not $run.Ran) {
        return [pscustomobject]@{ Mailbox = $mailboxId; Converted = $false; Type = $type; IsShared = $false; WhatIf = $true }
    }
    #   WHAT   Read it back. Only a verified SharedMailbox lets the caller free the license.
    #   GOTCHA No polling: if Exchange does not report SharedMailbox yet, IsShared is $false
    #          and the license stays. Re-running the offboarding later is safe (idempotent).
    $now = Get-M365ExactRecipient -Kind Mailbox -Identity $mailboxId
    $after = if ($now) { Get-M365RecipientType $now } else { 'not found' }
    $isShared = ($after -eq 'SharedMailbox')
    if (-not $isShared) { Write-Warning "Set-Mailbox -Type Shared ran, but $mailboxId still reads as $after. Do NOT remove its license until it shows as SharedMailbox (re-run to check)." }
    [pscustomobject]@{ Mailbox = $mailboxId; Converted = $isShared; Type = $after; IsShared = $isShared; WhatIf = $false }
}

function Set-M365MailboxForwarding {
    <#
    .SYNOPSIS
        Forwards a mailbox to a recipient in the tenant (keeping a copy by default), or clears forwarding. Outside addresses need -AllowExternal.
    .DESCRIPTION
        -ForwardTo must resolve to exactly one recipient in this tenant; that recipient is set
        as ForwardingAddress. A target that is not found stops the function unless
        -AllowExternal is given, so a typo (manager@cotnoso.example) never becomes silent
        external forwarding. A mail contact or mail user whose address is outside the
        tenant counts as external too. An address in one of the tenant's own domains that
        no recipient has is always refused (a typo of an internal address). The outbound
        spam policy may still block external automatic forwarding; the baseline recommends
        that, so prefer internal targets. Every change goes through Invoke-M365Change.
    .PARAMETER Identity
        The mailbox. Must match exactly one mailbox.
    .PARAMETER ForwardTo
        Target address. Omit with -Clear to remove forwarding.
    .PARAMETER NoCopy
        Do not keep a copy in the mailbox.
    .PARAMETER Clear
        Remove any forwarding.
    .PARAMETER AllowExternal
        Allow a target outside the organization (an address not in the tenant, or a contact
        or mail user that delivers outside).
    .EXAMPLE
        Set-M365MailboxForwarding -Identity jane@contoso.com -ForwardTo manager@contoso.com -WhatIf
    .EXAMPLE
        Set-M365MailboxForwarding -Identity jane@contoso.com -ForwardTo jane.archive@partner.example -AllowExternal -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [string]$Identity,

        [Parameter()]
        [string]$ForwardTo,

        [Parameter()]
        [switch]$NoCopy,

        [Parameter()]
        [switch]$Clear,

        [Parameter()]
        [switch]$AllowExternal
    )

    #region 1. The mailbox and its current forwarding -------------------------------------
    $m = Get-M365ExactRecipient -Kind Mailbox -Identity $Identity
    if (-not $m) { throw "Mailbox '$Identity' was not found in this tenant. Nothing was changed." }
    $mailboxId = Get-M365RecipientId $m
    $currentFa = "$(Get-M365Prop $m 'ForwardingAddress')"
    $currentFsa = ConvertTo-M365BareAddress "$(Get-M365Prop $m 'ForwardingSmtpAddress')"
    $currentKeep = "$(Get-M365Prop $m 'DeliverToMailboxAndForward')" -eq 'True'
    #endregion

    #region 2. Clear ---------------------------------------------------------------------
    if ($Clear) {
        if (-not $currentFa -and -not $currentFsa) { return [pscustomobject]@{ Mailbox = $mailboxId; ForwardTo = $null; Changed = $false; WhatIf = $false } }
        $was = if ($currentFa) { $currentFa } else { $currentFsa }
        $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Stop forwarding mailbox $mailboxId (currently forwards to $was)" `
            -Command 'Set-Mailbox' -Parameters ([ordered]@{ Identity = $mailboxId; ForwardingAddress = $null; ForwardingSmtpAddress = $null; DeliverToMailboxAndForward = $false })
        return [pscustomobject]@{ Mailbox = $mailboxId; ForwardTo = $null; Changed = $run.Ran; WhatIf = (-not $run.Ran) }
    }
    if (-not $ForwardTo) { throw 'Pass -ForwardTo <address> or -Clear.' }
    #endregion

    #region 3. Resolve the target: in this tenant, or explicitly allowed outside ----------
    #   GOTCHA Get-Recipient is read with -ErrorAction Stop: a failed read must not look
    #          like "not found", which would turn into external forwarding.
    $accepted = @(Get-AcceptedDomain -ErrorAction Stop | ForEach-Object { "$($_.DomainName)" })
    $target = Get-M365ExactRecipient -Kind Recipient -Identity $ForwardTo -What 'forwarding target'
    $keep = -not $NoCopy
    if ($target) {
        $targetId = Get-M365RecipientId $target
        if ((ConvertTo-M365BareAddress $targetId) -eq (ConvertTo-M365BareAddress $mailboxId)) { throw "$mailboxId cannot forward to itself. Nothing was changed." }
        $outside = Get-M365RecipientExternalAddress -Recipient $target -AcceptedDomains $accepted
        $external = [bool]$outside
        if ($external -and -not $AllowExternal) {
            throw "'$ForwardTo' is $(Get-M365RecipientLabel $target), which delivers outside the organization to $outside. Pass -AllowExternal to forward outside. Nothing was changed."
        }
        $describe = if ($external) { "$targetId ($(Get-M365RecipientType $target) that delivers OUTSIDE to $outside)" } else { "$targetId (internal)" }
        $params = [ordered]@{ Identity = $mailboxId; ForwardingAddress = $targetId; ForwardingSmtpAddress = $null; DeliverToMailboxAndForward = $keep }
        $names = @('Name', 'Identity', 'PrimarySmtpAddress', 'DisplayName', 'Alias', 'Guid', 'ExternalDirectoryObjectId', 'DistinguishedName') | ForEach-Object { "$(Get-M365Prop $target $_)" } | Where-Object { $_ }
        $same = $currentFa -and (@($names) -contains $currentFa) -and -not $currentFsa
    } else {
        if ($ForwardTo -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw "'$ForwardTo' was not found in this tenant and is not an email address. Nothing was changed." }
        if (-not (Test-M365ExternalAddress -Address $ForwardTo -AcceptedDomains $accepted)) {
            throw "$ForwardTo is in one of this tenant's own domains, but no recipient has that address. Check the spelling. Nothing was changed."
        }
        if (-not $AllowExternal) { throw "'$ForwardTo' was not found in this tenant; pass -AllowExternal to forward outside the organization. Nothing was changed." }
        $external = $true
        $describe = "$ForwardTo (OUTSIDE the organization)"
        $params = [ordered]@{ Identity = $mailboxId; ForwardingAddress = $null; ForwardingSmtpAddress = "smtp:$ForwardTo"; DeliverToMailboxAndForward = $keep }
        $same = (-not $currentFa) -and $currentFsa -eq (ConvertTo-M365BareAddress $ForwardTo)
    }
    #endregion

    #region 4. Change only when different ---------------------------------------------
    if ($same -and $currentKeep -eq $keep) {
        return [pscustomobject]@{ Mailbox = $mailboxId; ForwardTo = $ForwardTo; Internal = (-not $external); External = $external; Changed = $false; WhatIf = $false }
    }
    if ($external) { Write-Warning "$mailboxId will forward outside the organization ($describe). The outbound spam policy may block automatic external forwarding." }
    $copy = if ($keep) { 'keep a copy' } else { 'no copy kept in the mailbox' }
    $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Forward mailbox $mailboxId to $describe, $copy" -Command 'Set-Mailbox' -Parameters $params
    [pscustomobject]@{ Mailbox = $mailboxId; ForwardTo = $ForwardTo; Internal = (-not $external); External = $external; Changed = $run.Ran; WhatIf = (-not $run.Ran) }
    #endregion
}

function Add-M365MailboxPermission {
    <#
    .SYNOPSIS
        Grants Full Access (and optionally Send As) on a mailbox to a user, if not already granted.
    .DESCRIPTION
        The mailbox and the user must each match exactly one object (no wildcards); both are
        named by primary SMTP address in the change. Existing grants are read with errors
        surfaced, never assumed. Every change goes through Invoke-M365Change.
    .PARAMETER Identity
        The mailbox.
    .PARAMETER User
        Who gets access.
    .PARAMETER SendAs
        Also grant Send As.
    .PARAMETER AutoMapping
        Let Outlook open the mailbox automatically. Off by default.
    .EXAMPLE
        Add-M365MailboxPermission -Identity jane@contoso.com -User manager@contoso.com -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [string]$Identity,

        [Parameter(Mandatory)]
        [string]$User,

        [Parameter()]
        [switch]$SendAs,

        [Parameter()]
        [switch]$AutoMapping
    )
    $m = Get-M365ExactRecipient -Kind Mailbox -Identity $Identity
    if (-not $m) { throw "Mailbox '$Identity' was not found in this tenant. Nothing was changed." }
    $mailboxId = Get-M365RecipientId $m
    $trustee = Get-M365ExactRecipient -Kind Recipient -Identity $User -What 'user to grant access'
    if (-not $trustee) { throw "'$User' was not found in this tenant. Nothing was changed." }
    $trusteeId = Get-M365RecipientId $trustee
    $dry = $false

    $hasFull = @(Get-MailboxPermission -Identity $mailboxId -User $trusteeId -ErrorAction Stop | Where-Object { "$($_.AccessRights)" -match 'FullAccess' -and "$(Get-M365Prop $_ 'Deny')" -ne 'True' }).Count -gt 0
    $grantedFull = $false
    if (-not $hasFull) {
        $mapping = if ($AutoMapping) { 'with automapping' } else { 'no automapping' }
        $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Give $trusteeId Full Access to mailbox $mailboxId ($mapping)" `
            -Command 'Add-MailboxPermission' -Parameters ([ordered]@{ Identity = $mailboxId; User = $trusteeId; AccessRights = 'FullAccess'; AutoMapping = [bool]$AutoMapping })
        $grantedFull = $run.Ran
        if (-not $run.Ran) { $dry = $true }
    }
    $grantedSendAs = $false; $hasSendAs = $null
    if ($SendAs) {
        $hasSendAs = @(Get-RecipientPermission -Identity $mailboxId -Trustee $trusteeId -ErrorAction Stop | Where-Object { "$($_.AccessRights)" -match 'SendAs' }).Count -gt 0
        if (-not $hasSendAs) {
            $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Give $trusteeId Send As on mailbox $mailboxId" `
                -Command 'Add-RecipientPermission' -Parameters ([ordered]@{ Identity = $mailboxId; Trustee = $trusteeId; AccessRights = 'SendAs' })
            $grantedSendAs = $run.Ran
            if (-not $run.Ran) { $dry = $true }
        }
    }
    [pscustomobject]@{ Mailbox = $mailboxId; User = $User; FullAccessGranted = $grantedFull; FullAccessAlready = $hasFull; SendAsGranted = $grantedSendAs; SendAsAlready = $hasSendAs; WhatIf = $dry }
}

function Set-M365MailboxAutoReply {
    <#
    .SYNOPSIS
        Sets (or disables) an automatic reply on a mailbox, same text inside and outside.
    .DESCRIPTION
        The mailbox must match exactly one mailbox. State in the output is the state after
        a real run; under -WhatIf it is $null (nothing was set) and RequestedState says what
        would be set. The change goes through Invoke-M365Change, which shows the message text.
    .PARAMETER Identity
        The mailbox.
    .PARAMETER Message
        HTML or plain text. Required unless -Disable.
    .PARAMETER Disable
        Turn automatic replies off.
    .EXAMPLE
        Set-M365MailboxAutoReply -Identity jane@contoso.com -Message 'Jane has left Contoso. Please contact office@contoso.com.' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [string]$Identity,

        [Parameter()]
        [string]$Message,

        [Parameter()]
        [switch]$Disable
    )
    if (-not $Disable -and -not $Message) { throw 'Pass -Message or -Disable.' }
    $m = Get-M365ExactRecipient -Kind Mailbox -Identity $Identity
    if (-not $m) { throw "Mailbox '$Identity' was not found in this tenant. Nothing was changed." }
    $mailboxId = Get-M365RecipientId $m
    if ($Disable) {
        $requested = 'Disabled'
        $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Turn off automatic replies for $mailboxId" `
            -Command 'Set-MailboxAutoReplyConfiguration' -Parameters ([ordered]@{ Identity = $mailboxId; AutoReplyState = 'Disabled' })
    } else {
        $requested = 'Enabled'
        $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Turn on automatic replies for $mailboxId (same text for internal and all external senders)" `
            -Command 'Set-MailboxAutoReplyConfiguration' -Parameters ([ordered]@{ Identity = $mailboxId; AutoReplyState = 'Enabled'; InternalMessage = $Message; ExternalMessage = $Message; ExternalAudience = 'All' })
    }
    [pscustomobject]@{ Mailbox = $mailboxId; State = $(if ($run.Ran) { $requested } else { $null }); RequestedState = $requested; WhatIf = (-not $run.Ran) }
}

function Set-M365MailboxRegionalConfig {
    <#
    .SYNOPSIS
        Sets a mailbox's language and time zone (and localizes default folder names) if they differ.
    .DESCRIPTION
        New mailboxes default to UTC until the user picks a zone in Outlook on the web, which
        makes early calendar invites wrong. Idempotent. The mailbox must match exactly one
        mailbox. Under -WhatIf, TimeZone and Language report the current values.
    .PARAMETER Identity
        The mailbox.
    .PARAMETER TimeZone
        Windows time zone id, e.g. 'Pacific Standard Time'.
    .PARAMETER Language
        Culture, e.g. 'en-US'.
    .EXAMPLE
        Set-M365MailboxRegionalConfig -Identity jane@contoso.com -TimeZone 'Pacific Standard Time' -Language en-US -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-M365Change calls ShouldProcess with this function''s PSCmdlet for every change.')]
    param(
        [Parameter(Mandatory)]
        [string]$Identity,

        [Parameter()]
        [string]$TimeZone = 'Pacific Standard Time',

        [Parameter()]
        [string]$Language = 'en-US'
    )
    $m = Get-M365ExactRecipient -Kind Mailbox -Identity $Identity
    if (-not $m) { throw "Mailbox '$Identity' was not found in this tenant. Nothing was changed." }
    $mailboxId = Get-M365RecipientId $m
    $current = Get-MailboxRegionalConfiguration -Identity $mailboxId -ErrorAction Stop
    if ("$($current.TimeZone)" -eq $TimeZone -and "$($current.Language)" -eq $Language) {
        return [pscustomobject]@{ Mailbox = $mailboxId; TimeZone = $TimeZone; Language = $Language; Changed = $false; WhatIf = $false }
    }
    $run = Invoke-M365Change -Caller $PSCmdlet -Service Exchange -Action "Set mailbox $mailboxId to language $Language and time zone '$TimeZone' (was $($current.Language), '$($current.TimeZone)'), folder names localized" `
        -Command 'Set-MailboxRegionalConfiguration' -Parameters ([ordered]@{ Identity = $mailboxId; Language = $Language; TimeZone = $TimeZone; LocalizeDefaultFolderName = [switch]::new($true) })
    if ($run.Ran) { return [pscustomobject]@{ Mailbox = $mailboxId; TimeZone = $TimeZone; Language = $Language; Changed = $true; WhatIf = $false } }
    [pscustomobject]@{ Mailbox = $mailboxId; TimeZone = "$($current.TimeZone)"; Language = "$($current.Language)"; Changed = $false; WhatIf = $true }
}
#endregion

Export-ModuleMember -Function Get-SpfAnalysis, Get-DmarcAnalysis, Get-M365DkimStatus, Enable-M365Dkim,
    New-M365MailContact, New-M365DistributionList, Add-M365DistributionListMember, New-M365SharedMailbox,
    Add-M365MailboxAlias, New-M365MailboxFolder, New-M365InboxRule, Format-M365Template, Send-M365TemplateMail,
    Test-M365ExternalAddress, Get-M365ForwardingAudit, Get-M365MailboxPermissionAudit,
    ConvertTo-M365SharedMailbox, Set-M365MailboxForwarding, Add-M365MailboxPermission, Set-M365MailboxAutoReply, Set-M365MailboxRegionalConfig,
    Get-M365ExactRecipient
