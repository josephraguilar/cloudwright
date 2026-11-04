[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Write stubs are global (like the real EXO and Graph commands) and record into a global log.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Stubs of Exchange and Graph cmdlets; Invoke-M365Change does the asking.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameter lists mirror the real cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build objects; they change nothing.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Stub named after the real Get-MailboxStatistics.')]
param()

# Legacy domain behavior runs only against the fake APIs in this test file.
# Mock the release policy here so these tests still exercise plan matching and
# mutation semantics. Safety.Tests.ps1 and EndToEnd.Tests.ps1 use the real policy.
BeforeAll {
    $modules = Join-Path $PSScriptRoot '..' 'scripts' 'powershell' 'modules'
    Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
    $script:ManifestPath = Join-Path $modules 'ExchangeHelpers' 'ExchangeHelpers.psd1'
    Import-Module $script:ManifestPath -Force
    $env:M365_TOOLKIT_LOG_PATH = Join-Path $TestDrive 'logs'

    # A fake DNS: name -> records. Anything not listed resolves to nothing.
    $script:Dns = @{
        'pass.example'                    = @('v=spf1 include:spf.protection.outlook.com -all', 'google-site-verification=abc')
        'noexo.example'                   = @('v=spf1 include:_spf.google.com ~all')
        'plusall.example'                 = @('v=spf1 include:spf.protection.outlook.com +all')
        'two.example'                     = @('v=spf1 include:spf.protection.outlook.com -all', 'v=spf1 mx -all')
        'none.example'                    = @('some other txt')
        'deep.example'                    = @('v=spf1 include:spf.protection.outlook.com include:l1.example include:l2.example mx a -all')
        'l1.example'                      = @('v=spf1 include:l1a.example include:l1b.example include:l1c.example -all')
        'l2.example'                      = @('v=spf1 include:l2a.example include:l2b.example include:l2c.example -all')
        'redir.example'                   = @('v=spf1 redirect=_spf.redir.example')
        '_spf.redir.example'              = @('v=spf1 include:spf.protection.outlook.com mx -all')
        'redirbad.example'                = @('v=spf1 redirect=_spf.nothing.example')
        '_dmarc.pass.example'             = @('v=DMARC1; p=quarantine; rua=mailto:dmarc@pass.example')
        '_dmarc.monitor.example'          = @('v=DMARC1; p=none; rua=mailto:dmarc@monitor.example')
        '_dmarc.broken.example'           = @('v=DMARC1; rua=mailto:x@broken.example')
    }
    $script:Resolver = { param($n, $t) if ($script:Dns.ContainsKey($n)) { $script:Dns[$n] } else { @() } }

    # What Exchange Online says for an identity that does not exist, and for a failed read.
    $script:NotFound = "Ex6F9304|Microsoft.Exchange.Configuration.Tasks.ManagementObjectNotFoundException|The operation couldn't be performed because object 'x' couldn't be found on 'NAMPR01A001.PROD.OUTLOOK.COM'."
    $script:ReadFails = 'The remote server returned an error: (429) Too Many Requests.'

    function New-TestRecipient {
        param([string]$Type, [string]$Name, [string]$Primary, [hashtable]$Extra = @{})
        $o = [ordered]@{ Name = $Name; Identity = $Name; RecipientTypeDetails = $Type; PrimarySmtpAddress = $Primary; Guid = [guid]::NewGuid().ToString() }
        foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
        [pscustomobject]$o
    }

    # Exchange and Graph cmdlets are not installed in CI. READS are stubbed in the module's
    # scope so Pester can mock them per test. WRITES are global recording stubs, as the real
    # EXO and Graph commands are global commands: every write that Invoke-M365Change runs
    # lands in $global:ExoWriteLog with its exact parameters (including -Confirm:$false).
    InModuleScope ExchangeHelpers {
        function script:Get-Recipient { [CmdletBinding()] param($Identity, $ResultSize) }
        function script:Get-Mailbox { [CmdletBinding()] param($Identity, $ResultSize, $RecipientTypeDetails) }
        function script:Get-MailContact { [CmdletBinding()] param($Identity) }
        function script:Get-DistributionGroup { [CmdletBinding()] param($Identity) }
        function script:Get-DistributionGroupMember { [CmdletBinding()] param($Identity, $ResultSize) }
        function script:Get-AcceptedDomain { [CmdletBinding()] param() }
        function script:Get-MailboxPermission { [CmdletBinding()] param($Identity, $User) }
        function script:Get-RecipientPermission { [CmdletBinding()] param($Identity, $Trustee) }
        function script:Get-InboxRule { [CmdletBinding()] param($Mailbox) }
        function script:Get-MailboxStatistics { [CmdletBinding()] param($Identity) }
        function script:Get-MailboxRegionalConfiguration { [CmdletBinding()] param($Identity) }
        function script:Get-DkimSigningConfig { [CmdletBinding()] param($Identity) }
        function script:Get-MgUserMailFolderChildFolder { [CmdletBinding()] param($UserId, $MailFolderId, [switch]$All) }
    }
    $global:ExoWriteLog = [System.Collections.Generic.List[object]]::new()
    $global:ExoWriteResult = @{}
    function global:Invoke-ExoTestWrite {
        param([string]$Name, [hashtable]$Bound)
        $copy = @{}; foreach ($k in $Bound.Keys) { $copy[$k] = $Bound[$k] }
        $global:ExoWriteLog.Add([pscustomobject]@{ Command = $Name; Params = $copy })
        $r = $global:ExoWriteResult[$Name]
        if ($r -is [scriptblock]) { & $r $copy } else { $r }
    }
    function global:New-MailContact { [CmdletBinding(SupportsShouldProcess)] param($Name, $DisplayName, $ExternalEmailAddress) Invoke-ExoTestWrite 'New-MailContact' $PSBoundParameters }
    function global:Set-MailContact { [CmdletBinding(SupportsShouldProcess)] param($Identity, $HiddenFromAddressListsEnabled) Invoke-ExoTestWrite 'Set-MailContact' $PSBoundParameters }
    function global:New-DistributionGroup { [CmdletBinding(SupportsShouldProcess)] param($Name, $DisplayName, $PrimarySmtpAddress, $Type, $MemberJoinRestriction, $MemberDepartRestriction, $RequireSenderAuthenticationEnabled) Invoke-ExoTestWrite 'New-DistributionGroup' $PSBoundParameters }
    function global:Add-DistributionGroupMember { [CmdletBinding(SupportsShouldProcess)] param($Identity, $Member) Invoke-ExoTestWrite 'Add-DistributionGroupMember' $PSBoundParameters }
    function global:New-Mailbox { [CmdletBinding(SupportsShouldProcess)] param($Name, [switch]$Shared, $DisplayName, $PrimarySmtpAddress) Invoke-ExoTestWrite 'New-Mailbox' $PSBoundParameters }
    function global:Add-MailboxPermission { [CmdletBinding(SupportsShouldProcess)] param($Identity, $User, $AccessRights, $AutoMapping) Invoke-ExoTestWrite 'Add-MailboxPermission' $PSBoundParameters }
    function global:Add-RecipientPermission { [CmdletBinding(SupportsShouldProcess)] param($Identity, $Trustee, $AccessRights) Invoke-ExoTestWrite 'Add-RecipientPermission' $PSBoundParameters }
    function global:Set-Mailbox { [CmdletBinding(SupportsShouldProcess)] param($Identity, $Type, $EmailAddresses, $ForwardingAddress, $ForwardingSmtpAddress, $DeliverToMailboxAndForward) Invoke-ExoTestWrite 'Set-Mailbox' $PSBoundParameters }
    function global:New-InboxRule { [CmdletBinding(SupportsShouldProcess)] param($Mailbox, $Name, $SubjectOrBodyContainsWords, $SentTo, $MoveToFolder, $StopProcessingRules, [switch]$Force) Invoke-ExoTestWrite 'New-InboxRule' $PSBoundParameters }
    function global:Set-MailboxAutoReplyConfiguration { [CmdletBinding(SupportsShouldProcess)] param($Identity, $AutoReplyState, $InternalMessage, $ExternalMessage, $ExternalAudience) Invoke-ExoTestWrite 'Set-MailboxAutoReplyConfiguration' $PSBoundParameters }
    function global:Set-MailboxRegionalConfiguration { [CmdletBinding(SupportsShouldProcess)] param($Identity, $Language, $TimeZone, [switch]$LocalizeDefaultFolderName) Invoke-ExoTestWrite 'Set-MailboxRegionalConfiguration' $PSBoundParameters }
    function global:New-DkimSigningConfig { [CmdletBinding(SupportsShouldProcess)] param($DomainName, $Enabled, $KeySize) Invoke-ExoTestWrite 'New-DkimSigningConfig' $PSBoundParameters }
    function global:Set-DkimSigningConfig { [CmdletBinding(SupportsShouldProcess)] param($Identity, $Enabled) Invoke-ExoTestWrite 'Set-DkimSigningConfig' $PSBoundParameters }
    function global:New-MgUserMailFolderChildFolder { [CmdletBinding(SupportsShouldProcess)] param($UserId, $MailFolderId, $BodyParameter) Invoke-ExoTestWrite 'New-MgUserMailFolderChildFolder' $PSBoundParameters }
    function global:Send-MgUserMail { [CmdletBinding(SupportsShouldProcess)] param($UserId, $BodyParameter) Invoke-ExoTestWrite 'Send-MgUserMail' $PSBoundParameters }
    $script:Writes = 'New-MailContact', 'Set-MailContact', 'New-DistributionGroup', 'Add-DistributionGroupMember', 'New-Mailbox', 'Add-MailboxPermission',
    'Add-RecipientPermission', 'Set-Mailbox', 'New-InboxRule', 'Set-MailboxAutoReplyConfiguration', 'Set-MailboxRegionalConfiguration',
    'New-DkimSigningConfig', 'Set-DkimSigningConfig', 'New-MgUserMailFolderChildFolder', 'Send-MgUserMail'
    function Get-Write([string]$Name) { @($global:ExoWriteLog | Where-Object Command -eq $Name) }
}
AfterAll {
    Remove-Item env:M365_TOOLKIT_LOG_PATH -ErrorAction SilentlyContinue
    foreach ($w in $script:Writes + 'Invoke-ExoTestWrite') { Remove-Item "Function:\$w" -ErrorAction SilentlyContinue }
    Remove-Variable -Name ExoWriteLog, ExoWriteResult -Scope Global -ErrorAction SilentlyContinue
}

Describe 'ExchangeHelpers module' {
    BeforeEach {
        Mock Test-M365ReadOnly -ModuleName M365Helpers { $false }
    }

    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }
    It 'exports the expected functions' {
        $expected = 'Get-SpfAnalysis', 'Get-DmarcAnalysis', 'Get-M365DkimStatus', 'Enable-M365Dkim', 'New-M365MailContact',
        'New-M365DistributionList', 'Add-M365DistributionListMember', 'New-M365SharedMailbox', 'Add-M365MailboxAlias',
        'New-M365MailboxFolder', 'New-M365InboxRule', 'Format-M365Template', 'Send-M365TemplateMail',
        'Test-M365ExternalAddress', 'Get-M365ForwardingAudit', 'Get-M365MailboxPermissionAudit',
        'ConvertTo-M365SharedMailbox', 'Set-M365MailboxForwarding', 'Add-M365MailboxPermission', 'Set-M365MailboxAutoReply',
        'Set-M365MailboxRegionalConfig', 'Get-M365ExactRecipient'
        $actual = (Get-Command -Module ExchangeHelpers).Name
        foreach ($f in $expected) { $actual | Should -Contain $f }
    }
    It 'makes no tenant write outside Invoke-M365Change' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..' 'scripts' 'powershell' 'modules' 'ExchangeHelpers' 'ExchangeHelpers.psm1'), [ref]$null, [ref]$null)
        $direct = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $script:Writes -contains $n.GetCommandName() }, $true)
        @($direct | ForEach-Object { "$($_.GetCommandName()) at line $($_.Extent.StartLineNumber)" }) | Should -BeNullOrEmpty
    }

    Context 'Get-SpfAnalysis' {
        It 'passes a clean EXO record' {
            $r = Get-SpfAnalysis -Domain pass.example -Resolver $script:Resolver
            $r.Status | Should -Be 'Pass'
            $r.IncludesExchangeOnline | Should -BeTrue
            $r.AllMechanism | Should -Be '-all'
            $r.LookupCount | Should -Be 1
            $r.Findings.Count | Should -Be 0
        }
        It 'fails when the Exchange Online include is missing' {
            $r = Get-SpfAnalysis -Domain noexo.example -Resolver $script:Resolver
            $r.Status | Should -Be 'Fail'
            $r.Findings | Should -Contain 'include:spf.protection.outlook.com is missing. Mail sent from Exchange Online will fail SPF.'
        }
        It 'fails on +all' {
            (Get-SpfAnalysis -Domain plusall.example -Resolver $script:Resolver).Status | Should -Be 'Fail'
        }
        It 'fails on two SPF records' {
            $r = Get-SpfAnalysis -Domain two.example -Resolver $script:Resolver
            $r.Status | Should -Be 'Fail'
            $r.RecordCount | Should -Be 2
        }
        It 'fails when there is no SPF record' {
            $r = Get-SpfAnalysis -Domain none.example -Resolver $script:Resolver
            $r.Status | Should -Be 'Fail'
            $r.Record | Should -BeNullOrEmpty
        }
        It 'counts nested include lookups and fails past 10' {
            # top: 3 includes + mx + a = 5; l1 and l2 each add 3 nested = 11
            $r = Get-SpfAnalysis -Domain deep.example -Resolver $script:Resolver
            $r.LookupCount | Should -Be 11
            $r.Status | Should -Be 'Fail'
            $r.Findings | Should -Match 'limit is 10'
        }
        It 'follows a top-level redirect= and counts its lookups' {
            # redirect (1) + include (1) + mx (1)
            $r = Get-SpfAnalysis -Domain redir.example -Resolver $script:Resolver
            $r.Redirect | Should -Be @('_spf.redir.example')
            $r.IncludesExchangeOnline | Should -BeTrue
            $r.AllMechanism | Should -Be '-all'
            $r.LookupCount | Should -Be 3
            $r.Status | Should -Be 'Pass'
        }
        It 'fails when the redirect target has no SPF record' {
            $r = Get-SpfAnalysis -Domain redirbad.example -Resolver $script:Resolver
            $r.Status | Should -Be 'Fail'
            ($r.Findings -join ' ') | Should -Match 'redirect=_spf\.nothing\.example'
        }
    }

    Context 'Get-DmarcAnalysis' {
        It 'passes an enforcing record with rua' {
            $r = Get-DmarcAnalysis -Domain pass.example -Resolver $script:Resolver
            $r.Status | Should -Be 'Pass'
            $r.Policy | Should -Be 'quarantine'
        }
        It 'warns on monitoring mode' {
            (Get-DmarcAnalysis -Domain monitor.example -Resolver $script:Resolver).Status | Should -Be 'Warn'
        }
        It 'fails without a p= tag' {
            (Get-DmarcAnalysis -Domain broken.example -Resolver $script:Resolver).Status | Should -Be 'Fail'
        }
        It 'suggests the SOP monitoring record when nothing is published' {
            $r = Get-DmarcAnalysis -Domain none.example -Resolver $script:Resolver
            $r.Status | Should -Be 'Fail'
            $r.SuggestedHost | Should -Be '_dmarc.none.example'
            $r.SuggestedRecord | Should -Be 'v=DMARC1; p=none; rua=mailto:dmarc@none.example; ruf=mailto:dmarc@none.example; fo=1'
        }
    }

    Context 'Format-M365Template' {
        It 'fills tokens case-insensitively and tolerates spaces' {
            Format-M365Template -Template 'Hi {{Name}} from {{ msp }}' -Tokens @{ name = 'Jane'; MSP = 'MSP' } | Should -Be 'Hi Jane from MSP'
        }
        It 'throws on unfilled tokens' {
            { Format-M365Template -Template 'Hi {{Name}} {{Missing}}' -Tokens @{ Name = 'Jane' } } | Should -Throw '*Missing*'
        }
        It 'inserts values literally: $ and $$ survive, and a value is never expanded again' {
            Format-M365Template -Template 'Price {{P}} {{Q}}' -Tokens @{ P = 'USD $$50 ($1)'; Q = '{{P}}' } | Should -Be 'Price USD $$50 ($1) {{P}}'
        }
        It 'HTML-encodes values for an HTML template' {
            Format-M365Template -Template '<p>{{Name}}</p><a href="mailto:{{Mail}}">' -Tokens @{ Name = 'Smith & <Sons>'; Mail = 'a"b@x.example' } -HtmlEncode |
                Should -Be '<p>Smith &amp; &lt;Sons&gt;</p><a href="mailto:a&quot;b@x.example">'
        }
        It 'renders the shipped welcome letter with the documented tokens' {
            $template = Get-Content (Join-Path $PSScriptRoot '..' 'templates' 'welcome-letter.html') -Raw
            $tokens = @{ ClientName = 'Contoso'; MspName = 'MSP'; SupportEmail = 's@msp.example'; SupportPhone = '555'; SupportPhone24x7 = '556'; Address = '1 Main St'; ItAlias = 'IT@contoso.example' }
            { Format-M365Template -Template $template -Tokens $tokens -HtmlEncode } | Should -Not -Throw
        }
    }

    Context 'Test-M365ExternalAddress' {
        It 'flags addresses outside the accepted domains, ignoring case and smtp: prefixes' {
            Test-M365ExternalAddress -Address 'x@gmail.example' -AcceptedDomains 'contoso.com', 'contoso.onmicrosoft.com' | Should -BeTrue
            Test-M365ExternalAddress -Address 'SMTP:Jane@Contoso.COM' -AcceptedDomains 'contoso.com' | Should -BeFalse
            Test-M365ExternalAddress -Address 'not-an-address' -AcceptedDomains 'contoso.com' | Should -BeFalse
            Test-M365ExternalAddress -Address 'x@contoso.com' -AcceptedDomains @() | Should -BeTrue
        }
    }
}

Describe 'ExchangeHelpers changes (exact targets, plan and run)' {

    BeforeEach {
        Mock Test-M365ReadOnly -ModuleName M365Helpers { $false }
        Set-M365ChangeTarget -Service Exchange -Label 'test.onmicrosoft.com'
        Set-M365ChangeTarget -Service Graph -Label 'test.onmicrosoft.com'
        $global:ExoWriteLog.Clear()
        $global:ExoWriteResult = @{}
        Mock -ModuleName ExchangeHelpers Get-AcceptedDomain { @([pscustomobject]@{ DomainName = 'contoso.com' }, [pscustomobject]@{ DomainName = 'contoso.onmicrosoft.com' }) }
        Mock -ModuleName ExchangeHelpers Get-Recipient { throw $script:NotFound }
        Mock -ModuleName ExchangeHelpers Get-Mailbox { throw $script:NotFound }
        Mock -ModuleName ExchangeHelpers Get-MailboxPermission { }
        Mock -ModuleName ExchangeHelpers Get-RecipientPermission { }
    }

    Context 'Get-M365ExactRecipient (M13)' {
        It 'refuses wildcards before reading anything' {
            { Get-M365ExactRecipient -Kind Mailbox -Identity 'j*' } | Should -Throw '*wildcard*'
            { Get-M365ExactRecipient -Kind Recipient -Identity 'j?ne@contoso.com' } | Should -Throw '*wildcard*'
            Should -Invoke -ModuleName ExchangeHelpers Get-Mailbox -Times 0 -Exactly
        }
        It 'returns $null only for Exchange''s not-found answer' {
            Get-M365ExactRecipient -Kind Recipient -Identity 'nobody@contoso.com' | Should -BeNullOrEmpty
        }
        It 'throws when the read fails (could not read is not "does not exist")' {
            Mock -ModuleName ExchangeHelpers Get-Recipient { throw $script:ReadFails }
            { Get-M365ExactRecipient -Kind Recipient -Identity 'jane@contoso.com' } | Should -Throw '*Could not read*429*'
        }
        It 'throws when more than one object matches' {
            Mock -ModuleName ExchangeHelpers Get-Mailbox { New-TestRecipient UserMailbox 'Jane A' 'jane.a@contoso.com'; New-TestRecipient UserMailbox 'Jane B' 'jane.b@contoso.com' }
            { Get-M365ExactRecipient -Kind Mailbox -Identity 'Jane' } | Should -Throw '*matches 2 objects*jane.a@contoso.com*jane.b@contoso.com*'
        }
    }

    Context 'New-M365SharedMailbox (C3, M8)' {
        It 'refuses when the address is an alias on someone''s personal mailbox, and grants nothing' {
            Mock -ModuleName ExchangeHelpers Get-Recipient { if ($Identity -eq '911@contoso.com') { New-TestRecipient UserMailbox 'Jane Doe' 'jane@contoso.com' } else { New-TestRecipient UserMailbox 'Bob' 'bob@contoso.com' } }
            { New-M365SharedMailbox -Name 911 -PrimarySmtpAddress 911@contoso.com -FullAccess bob@contoso.com 6>$null } | Should -Throw "*UserMailbox 'Jane Doe' (jane@contoso.com)*"
            (Get-Write 'New-Mailbox').Count | Should -Be 0
            (Get-Write 'Add-MailboxPermission').Count | Should -Be 0
        }
        It 'refuses a user mailbox that has the address as its primary' {
            Mock -ModuleName ExchangeHelpers Get-Recipient { New-TestRecipient UserMailbox '911' '911@contoso.com' }
            { New-M365SharedMailbox -Name 911 -PrimarySmtpAddress 911@contoso.com 6>$null } | Should -Throw '*not a shared mailbox*'
            (Get-Write 'Set-Mailbox').Count | Should -Be 0
        }
        It 'keeps an existing shared mailbox with exactly that primary address and grants Full Access on it' {
            Mock -ModuleName ExchangeHelpers Get-Recipient { if ($Identity -eq '911@contoso.com') { New-TestRecipient SharedMailbox '911' '911@contoso.com' } else { New-TestRecipient UserMailbox 'Bob' 'bob@contoso.com' } }
            $r = New-M365SharedMailbox -Name 911 -PrimarySmtpAddress 911@contoso.com -FullAccess bob 6>$null
            $r.Created | Should -BeFalse
            $r.FullAccessGranted | Should -Be @('bob')
            @(Get-Write 'Add-MailboxPermission' | Where-Object { $_.Params.Identity -eq '911@contoso.com' -and $_.Params.User -eq 'bob@contoso.com' -and $_.Params.AutoMapping -eq $false }).Count | Should -Be 1
        }
        It 'plans the mailbox AND the Full Access grants in a dry run, writing nothing' {
            Mock -ModuleName ExchangeHelpers Get-Recipient { if ($Identity -eq 'bob') { New-TestRecipient UserMailbox 'Bob' 'bob@contoso.com' } else { throw $script:NotFound } }
            Start-M365ChangeRecording
            $r = New-M365SharedMailbox -Name 911 -PrimarySmtpAddress 911@contoso.com -FullAccess bob -WhatIf
            $plan = Stop-M365ChangeRecording
            @($plan.Text) | Should -Be @(
                "[test.onmicrosoft.com] New-Mailbox -Name '911' -Shared -DisplayName '911' -PrimarySmtpAddress '911@contoso.com'",
                "[test.onmicrosoft.com] Add-MailboxPermission -Identity '911@contoso.com' -User 'bob@contoso.com' -AccessRights 'FullAccess' -AutoMapping:`$false")
            $r.WhatIf | Should -BeTrue
            $r.Created | Should -BeFalse
            $r.FullAccessPlanned | Should -Be @('bob')
            $global:ExoWriteLog.Count | Should -Be 0
        }
        It 'runs exactly the approved plan' {
            Mock -ModuleName ExchangeHelpers Get-Recipient { if ($Identity -eq 'bob') { New-TestRecipient UserMailbox 'Bob' 'bob@contoso.com' } else { throw $script:NotFound } }
            $global:ExoWriteResult['New-Mailbox'] = New-TestRecipient SharedMailbox '911' '911@contoso.com'
            Start-M365ChangeRecording; $null = New-M365SharedMailbox -Name 911 -PrimarySmtpAddress 911@contoso.com -FullAccess bob -WhatIf; $plan = Stop-M365ChangeRecording
            Start-M365ChangeRecording -ApprovedPlan $plan
            $r = New-M365SharedMailbox -Name 911 -PrimarySmtpAddress 911@contoso.com -FullAccess bob 6>$null
            @((Stop-M365ChangeRecording).Status) | Should -Be @('Done', 'Done')
            $r.Created | Should -BeTrue
            $r.WhatIf | Should -BeFalse
        }
    }

    Context 'New-M365DistributionList (H7)' {
        It 'refuses when the address is a secondary on another list, and adds nobody' {
            Mock -ModuleName ExchangeHelpers Get-Recipient { New-TestRecipient MailUniversalDistributionGroup 'Helpdesk' 'helpdesk@contoso.com' }
            { New-M365DistributionList -Name IT -PrimarySmtpAddress IT@contoso.com -Members contoso@msp.example 6>$null } | Should -Throw "*'Helpdesk' (helpdesk@contoso.com)*"
            (Get-Write 'Add-DistributionGroupMember').Count | Should -Be 0
            (Get-Write 'New-DistributionGroup').Count | Should -Be 0
        }
        It 'refuses a mail-enabled security group holding the address' {
            Mock -ModuleName ExchangeHelpers Get-Recipient { New-TestRecipient MailUniversalSecurityGroup 'IT' 'IT@contoso.com' }
            { New-M365DistributionList -Name IT -PrimarySmtpAddress IT@contoso.com 6>$null } | Should -Throw '*not a distribution list*'
        }
        It 'keeps an exact existing list and warns in the output when sender authentication differs' {
            Mock -ModuleName ExchangeHelpers Get-Recipient {
                if ($Identity -eq 'IT@contoso.com') { New-TestRecipient MailUniversalDistributionGroup 'IT' 'IT@contoso.com' } else { New-TestRecipient MailContact 'MSP' 'contoso@msp.example' }
            }
            Mock -ModuleName ExchangeHelpers Get-DistributionGroup { New-TestRecipient MailUniversalDistributionGroup 'IT' 'IT@contoso.com' @{ RequireSenderAuthenticationEnabled = $true } }
            Mock -ModuleName ExchangeHelpers Get-DistributionGroupMember { }
            $r = New-M365DistributionList -Name IT -PrimarySmtpAddress IT@contoso.com -Members contoso@msp.example 6>$null 3>$null
            $r.Created | Should -BeFalse
            $r.Warnings | Should -Match 'RequireSenderAuthenticationEnabled=True'
            $r.MembersAdded | Should -Be @('contoso@msp.example')
            @(Get-Write 'Add-DistributionGroupMember' | Where-Object { $_.Params.Identity -eq 'IT@contoso.com' -and $_.Params.Member -eq 'contoso@msp.example' }).Count | Should -Be 1
        }
        It 'stops before creating anything when a member does not exist (real run)' {
            { New-M365DistributionList -Name IT -PrimarySmtpAddress IT@contoso.com -Members support@msp.example 6>$null } | Should -Throw '*not found in this tenant: support@msp.example*'
            $global:ExoWriteLog.Count | Should -Be 0
        }
        It 'plans a new list and a member that does not exist yet (placeholder), writing nothing' {
            Start-M365ChangeRecording
            $r = New-M365DistributionList -Name IT -PrimarySmtpAddress IT@contoso.com -Members support@msp.example -WhatIf 3>$null
            $plan = Stop-M365ChangeRecording
            $plan.Count | Should -Be 2
            $plan[0].Text | Should -BeLike "*New-DistributionGroup -Name 'IT' -DisplayName 'IT' -PrimarySmtpAddress 'IT@contoso.com' -Type 'Distribution'*-RequireSenderAuthenticationEnabled:`$false"
            $plan[1].Text | Should -Be '[test.onmicrosoft.com] Add-DistributionGroupMember -Identity ''IT@contoso.com'' -Member <support@msp.example (must exist by the real run)>'
            $r.WhatIf | Should -BeTrue
            $r.MembersPlanned | Should -Be @('support@msp.example')
            $global:ExoWriteLog.Count | Should -Be 0
        }
    }

    Context 'Set-M365MailboxForwarding (H3, M8)' {
        BeforeEach {
            Mock -ModuleName ExchangeHelpers Get-Mailbox { New-TestRecipient UserMailbox 'Jane' 'jane@contoso.com' @{ ForwardingAddress = $null; ForwardingSmtpAddress = $null; DeliverToMailboxAndForward = $false } }
        }
        It 'refuses a target that is not in the tenant (a typo) unless -AllowExternal' {
            { Set-M365MailboxForwarding -Identity jane@contoso.com -ForwardTo manager@cotnoso.example 6>$null } | Should -Throw '*not found in this tenant; pass -AllowExternal to forward outside*'
            (Get-Write 'Set-Mailbox').Count | Should -Be 0
        }
        It 'forwards outside only with -AllowExternal, as SMTP forwarding' {
            $r = Set-M365MailboxForwarding -Identity jane@contoso.com -ForwardTo archive@partner.example -AllowExternal 6>$null 3>$null
            $r.External | Should -BeTrue
            $r.Changed | Should -BeTrue
            @(Get-Write 'Set-Mailbox' | Where-Object { $_.Params.Identity -eq 'jane@contoso.com' -and $_.Params.ForwardingSmtpAddress -eq 'smtp:archive@partner.example' -and $null -eq $_.Params.ForwardingAddress }).Count | Should -Be 1
        }
        It 'never treats a failed read as "not found"' {
            Mock -ModuleName ExchangeHelpers Get-Recipient { throw $script:ReadFails }
            { Set-M365MailboxForwarding -Identity jane@contoso.com -ForwardTo manager@contoso.com -AllowExternal 6>$null } | Should -Throw '*Could not read*'
            (Get-Write 'Set-Mailbox').Count | Should -Be 0
        }
        It 'counts a mail contact with an outside address as external' {
            Mock -ModuleName ExchangeHelpers Get-Recipient { New-TestRecipient MailContact 'Jane Gmail' 'jane@gmail.example' @{ ExternalEmailAddress = 'SMTP:jane@gmail.example' } }
            { Set-M365MailboxForwarding -Identity jane@contoso.com -ForwardTo 'Jane Gmail' 6>$null } | Should -Throw '*delivers outside*-AllowExternal*'
            (Get-Write 'Set-Mailbox').Count | Should -Be 0
        }
        It 'refuses an unknown address in one of the tenant''s own domains even with -AllowExternal' {
            { Set-M365MailboxForwarding -Identity jane@contoso.com -ForwardTo manger@contoso.com -AllowExternal 6>$null } | Should -Throw "*own domains*"
        }
        It 'forwards internally to the verified recipient, by primary address, with a plain-English plan' {
            Mock -ModuleName ExchangeHelpers Get-Recipient { New-TestRecipient UserMailbox 'Manager' 'manager@contoso.com' }
            Start-M365ChangeRecording
            $r = Set-M365MailboxForwarding -Identity jane@contoso.com -ForwardTo manager@contoso.com -WhatIf
            $plan = Stop-M365ChangeRecording
            $plan[0].Action | Should -Be 'Forward mailbox jane@contoso.com to manager@contoso.com (internal), keep a copy'
            $plan[0].Text | Should -Be "[test.onmicrosoft.com] Set-Mailbox -Identity 'jane@contoso.com' -ForwardingAddress 'manager@contoso.com' -ForwardingSmtpAddress `$null -DeliverToMailboxAndForward:`$true"
            $r.Changed | Should -BeFalse
            $r.WhatIf | Should -BeTrue
            (Get-Write 'Set-Mailbox').Count | Should -Be 0
        }
        It '-Clear under -WhatIf reports Changed=$false' {
            Mock -ModuleName ExchangeHelpers Get-Mailbox { New-TestRecipient UserMailbox 'Jane' 'jane@contoso.com' @{ ForwardingAddress = 'Manager'; ForwardingSmtpAddress = $null; DeliverToMailboxAndForward = $true } }
            $r = Set-M365MailboxForwarding -Identity jane@contoso.com -Clear -WhatIf
            $r.Changed | Should -BeFalse
            $r.WhatIf | Should -BeTrue
            (Get-Write 'Set-Mailbox').Count | Should -Be 0
        }
    }

    Context 'ConvertTo-M365SharedMailbox' {
        It 'refuses a wildcard identity without reading or writing' {
            { ConvertTo-M365SharedMailbox -Identity 'j*' 6>$null } | Should -Throw '*wildcard*'
            Should -Invoke -ModuleName ExchangeHelpers Get-Mailbox -Times 0 -Exactly
            (Get-Write 'Set-Mailbox').Count | Should -Be 0
        }
        It 'converts by primary address and reports IsShared only after reading it back' {
            $global:converted = $false
            Mock -ModuleName ExchangeHelpers Get-Mailbox { New-TestRecipient $(if ($global:converted) { 'SharedMailbox' } else { 'UserMailbox' }) 'Jane' 'jane@contoso.com' }
            $global:ExoWriteResult['Set-Mailbox'] = { $global:converted = $true }
            Mock -ModuleName ExchangeHelpers Get-MailboxStatistics { [pscustomobject]@{ TotalItemSize = '1.2 GB (1,288,490,188 bytes)' } }
            $r = ConvertTo-M365SharedMailbox -Identity Jane 6>$null
            $r.IsShared | Should -BeTrue
            $r.Converted | Should -BeTrue
            @(Get-Write 'Set-Mailbox' | Where-Object { $_.Params.Identity -eq 'jane@contoso.com' -and $_.Params.Type -eq 'Shared' }).Count | Should -Be 1
        }
        It 'reports IsShared=$false (and warns) when the mailbox does not read back as shared' {
            Mock -ModuleName ExchangeHelpers Get-Mailbox { New-TestRecipient UserMailbox 'Jane' 'jane@contoso.com' }
            Mock -ModuleName ExchangeHelpers Get-MailboxStatistics { $null }
            $r = ConvertTo-M365SharedMailbox -Identity jane@contoso.com -WarningVariable warned 6>$null 3>$null
            $r.IsShared | Should -BeFalse
            ($warned -join ' ') | Should -Match 'Do NOT remove its license'
        }
        It 'under -WhatIf reports the current state honestly' {
            Mock -ModuleName ExchangeHelpers Get-Mailbox { New-TestRecipient UserMailbox 'Jane' 'jane@contoso.com' }
            Mock -ModuleName ExchangeHelpers Get-MailboxStatistics { $null }
            $r = ConvertTo-M365SharedMailbox -Identity jane@contoso.com -WhatIf
            $r.IsShared | Should -BeFalse
            $r.Type | Should -Be 'UserMailbox'
            $r.WhatIf | Should -BeTrue
            (Get-Write 'Set-Mailbox').Count | Should -Be 0
        }
        It 'refuses a room mailbox' {
            Mock -ModuleName ExchangeHelpers Get-Mailbox { New-TestRecipient RoomMailbox 'Board room' 'board@contoso.com' }
            { ConvertTo-M365SharedMailbox -Identity board@contoso.com 6>$null } | Should -Throw '*not a user mailbox*'
        }
    }

    Context 'New-M365MailContact (M8)' {
        It 'does not create when the contact exists, but still hides it (by its address)' {
            Mock -ModuleName ExchangeHelpers Get-Recipient { New-TestRecipient MailContact 'Existing' 'x@ext.example' }
            Mock -ModuleName ExchangeHelpers Get-MailContact { New-TestRecipient MailContact 'Existing' 'x@ext.example' @{ ExternalEmailAddress = 'SMTP:x@ext.example'; HiddenFromAddressListsEnabled = $false } }
            $r = New-M365MailContact -Name 'X' -ExternalEmailAddress x@ext.example -HiddenFromAddressLists 6>$null
            $r.Created | Should -BeFalse
            $r.HiddenFromAddressLists | Should -BeTrue
            (Get-Write 'New-MailContact').Count | Should -Be 0
            @(Get-Write 'Set-MailContact' | Where-Object { $_.Params.Identity -eq 'x@ext.example' -and $_.Params.HiddenFromAddressListsEnabled -eq $true }).Count | Should -Be 1
        }
        It 'creates when missing' {
            $global:ExoWriteResult['New-MailContact'] = { param($p) [pscustomobject]@{ Name = $p.Name; PrimarySmtpAddress = 'x@ext.example'; RecipientTypeDetails = 'MailContact'; HiddenFromAddressListsEnabled = $false } }
            $r = New-M365MailContact -Name 'X' -ExternalEmailAddress x@ext.example 6>$null
            $r.Created | Should -BeTrue
            (Get-Write 'New-MailContact').Count | Should -Be 1
            (Get-Write 'Set-MailContact').Count | Should -Be 0
        }
        It 'plans create and hide under -WhatIf without claiming it is hidden' {
            Start-M365ChangeRecording
            $r = New-M365MailContact -Name 'X' -ExternalEmailAddress x@ext.example -HiddenFromAddressLists -WhatIf
            $plan = Stop-M365ChangeRecording
            $plan.Count | Should -Be 2
            $plan[1].Text | Should -Be '[test.onmicrosoft.com] Set-MailContact -Identity <the mail contact created above (x@ext.example)> -HiddenFromAddressListsEnabled:$true'
            $r.WhatIf | Should -BeTrue
            $r.HiddenFromAddressLists | Should -BeFalse
            (Get-Write 'New-MailContact').Count | Should -Be 0
        }
        It 'hides nothing and says so when the address belongs to a mailbox' {
            Mock -ModuleName ExchangeHelpers Get-Recipient { New-TestRecipient UserMailbox 'Jane' 'jane@contoso.com' }
            $r = New-M365MailContact -Name 'X' -ExternalEmailAddress jane@contoso.com -HiddenFromAddressLists -WarningVariable warned 3>$null
            $r.HiddenFromAddressLists | Should -BeFalse
            $r.Created | Should -BeFalse
            $r.Note | Should -Match "UserMailbox 'Jane'"
            $warned.Count | Should -Be 1
            (Get-Write 'Set-MailContact').Count | Should -Be 0
        }
    }

    Context 'New-M365InboxRule (M6)' {
        BeforeEach {
            Mock -ModuleName ExchangeHelpers Get-Mailbox { New-TestRecipient SharedMailbox 'clients' 'clients@msp.example' }
            Mock -ModuleName ExchangeHelpers Get-InboxRule { }
        }
        It 'does not stop later rules unless asked, and shows that in the plan' {
            Start-M365ChangeRecording
            $null = New-M365InboxRule -Mailbox clients -Name 'Client - Contoso' -SubjectOrBodyContainsWords Contoso -MoveToFolder 'Inbox\Contoso' -WhatIf
            $plan = Stop-M365ChangeRecording
            $plan[0].Text | Should -Be "[test.onmicrosoft.com] New-InboxRule -Mailbox 'clients@msp.example' -Name 'Client - Contoso' -SubjectOrBodyContainsWords @('Contoso') -MoveToFolder 'clients@msp.example:\Inbox\Contoso' -StopProcessingRules:`$false -Force"
            $plan[0].Action | Should -Match 'removes any Outlook client-only rules'
        }
        It 'passes -StopProcessingRules only with the switch, and answers the client-rules prompt the same way every time (-Force, -Confirm:$false)' {
            $null = New-M365InboxRule -Mailbox clients -Name R -SentTo contoso@msp.example -MoveToFolder 'Inbox\Contoso' -StopProcessingRules 6>$null
            @(Get-Write 'New-InboxRule' | Where-Object { $_.Params.StopProcessingRules -eq $true -and $_.Params.Force -and $_.Params.ContainsKey('Confirm') -and -not $_.Params.Confirm }).Count | Should -Be 1
        }
        It 'says in the synopsis that PowerShell rules can remove Outlook client-only rules' {
            (Get-Help New-M365InboxRule).Synopsis | Should -Match 'client-only rules'
        }
    }

    Context 'Send-M365TemplateMail (one message per recipient)' {
        It 'sends each recipient their own message with the values HTML-encoded' {
            $tpl = Join-Path $TestDrive 't.html'
            Set-Content -Path $tpl -Value '<p>Hello {{Name}}, USD {{Price}}</p>' -NoNewline
            $r = @(Send-M365TemplateMail -From s@msp.example -To a@contoso.com, b@contoso.com -Subject 'Hi {{Name}}' -TemplatePath $tpl -Tokens @{ Name = 'A & B'; Price = '$$5' } 6>$null)
            $r.Count | Should -Be 2
            (Get-Write 'Send-MgUserMail').Count | Should -Be 2
            @(Get-Write 'Send-MgUserMail' | Where-Object {
                @($_.Params.BodyParameter.message.toRecipients).Count -eq 1 -and $_.Params.BodyParameter.message.toRecipients[0].emailAddress.address -eq 'b@contoso.com' -and
                $_.Params.BodyParameter.message.body.content -eq '<p>Hello A &amp; B, USD $$5</p>' -and $_.Params.BodyParameter.message.subject -eq 'Hi A & B'
            }).Count | Should -Be 1
        }
        It 'sends nothing under -WhatIf' {
            $tpl = Join-Path $TestDrive 't2.html'
            Set-Content -Path $tpl -Value '<p>Hello</p>' -NoNewline
            $r = @(Send-M365TemplateMail -From s@msp.example -To a@contoso.com -Subject 'Hi' -TemplatePath $tpl -WhatIf)
            $r[0].Sent | Should -BeFalse
            $r[0].WhatIf | Should -BeTrue
            (Get-Write 'Send-MgUserMail').Count | Should -Be 0
        }
    }

    Context 'Mailbox permissions, alias, auto-reply, regional settings' {
        BeforeEach {
            Mock -ModuleName ExchangeHelpers Get-Mailbox { New-TestRecipient UserMailbox 'Jane' 'jane@contoso.com' @{ EmailAddresses = @('SMTP:jane@contoso.com') } }
        }
        It 'Add-M365MailboxPermission grants on the verified mailbox to the verified user' {
            Mock -ModuleName ExchangeHelpers Get-Recipient { New-TestRecipient UserMailbox 'Manager' 'manager@contoso.com' }
            $r = Add-M365MailboxPermission -Identity Jane -User Manager -SendAs 6>$null
            $r.FullAccessGranted | Should -BeTrue
            $r.SendAsGranted | Should -BeTrue
            @(Get-Write 'Add-MailboxPermission' | Where-Object { $_.Params.Identity -eq 'jane@contoso.com' -and $_.Params.User -eq 'manager@contoso.com' }).Count | Should -Be 1
            @(Get-Write 'Add-RecipientPermission' | Where-Object { $_.Params.Identity -eq 'jane@contoso.com' -and $_.Params.Trustee -eq 'manager@contoso.com' }).Count | Should -Be 1
        }
        It 'Add-M365MailboxPermission stops when existing grants cannot be read' {
            Mock -ModuleName ExchangeHelpers Get-Recipient { New-TestRecipient UserMailbox 'Manager' 'manager@contoso.com' }
            Mock -ModuleName ExchangeHelpers Get-MailboxPermission { throw $script:ReadFails }
            { Add-M365MailboxPermission -Identity Jane -User Manager 6>$null } | Should -Throw '*429*'
            (Get-Write 'Add-MailboxPermission').Count | Should -Be 0
        }
        It 'Add-M365MailboxAlias refuses an address another recipient holds' {
            Mock -ModuleName ExchangeHelpers Get-Recipient { New-TestRecipient UserMailbox 'Bob' 'bob@contoso.com' }
            { Add-M365MailboxAlias -Mailbox jane@contoso.com -Alias bob.alias@contoso.com 6>$null } | Should -Throw "*UserMailbox 'Bob'*"
            (Get-Write 'Set-Mailbox').Count | Should -Be 0
        }
        It 'Add-M365MailboxAlias adds with @{ Add } on the verified mailbox' {
            $r = Add-M365MailboxAlias -Mailbox Jane -Alias jane.doe@contoso.com 6>$null
            $r.Added | Should -BeTrue
            @(Get-Write 'Set-Mailbox' | Where-Object { $_.Params.Identity -eq 'jane@contoso.com' -and $_.Params.EmailAddresses.Add -eq 'jane.doe@contoso.com' }).Count | Should -Be 1
        }
        It 'Set-M365MailboxAutoReply does not claim a State under -WhatIf' {
            $r = Set-M365MailboxAutoReply -Identity jane@contoso.com -Message 'Gone' -WhatIf
            $r.State | Should -BeNullOrEmpty
            $r.RequestedState | Should -Be 'Enabled'
            $r.WhatIf | Should -BeTrue
            (Get-Write 'Set-MailboxAutoReplyConfiguration').Count | Should -Be 0
        }
        It 'Set-M365MailboxRegionalConfig changes the verified mailbox only when different' {
            Mock -ModuleName ExchangeHelpers Get-MailboxRegionalConfiguration { [pscustomobject]@{ TimeZone = 'UTC'; Language = 'en-US' } }
            $r = Set-M365MailboxRegionalConfig -Identity jane@contoso.com -TimeZone 'Pacific Standard Time' -Language en-US 6>$null
            $r.Changed | Should -BeTrue
            @(Get-Write 'Set-MailboxRegionalConfiguration' | Where-Object { $_.Params.Identity -eq 'jane@contoso.com' -and $_.Params.LocalizeDefaultFolderName }).Count | Should -Be 1
        }
    }

    Context 'DKIM (could not read is not "no config")' {
        It 'reports no config as Fail when Exchange says not found' {
            Mock -ModuleName ExchangeHelpers Get-DkimSigningConfig { throw $script:NotFound }
            $r = Get-M365DkimStatus -Domain contoso.com -Resolver $script:Resolver
            $r.ConfigExists | Should -BeFalse
            $r.Status | Should -Be 'Fail'
        }
        It 'reports Unknown when the read fails, and Enable-M365Dkim then creates nothing' {
            Mock -ModuleName ExchangeHelpers Get-DkimSigningConfig { throw $script:ReadFails }
            (Get-M365DkimStatus -Domain contoso.com -Resolver $script:Resolver).Status | Should -Be 'Unknown'
            Mock -ModuleName ExchangeHelpers Resolve-DnsRecord { @() }
            { Enable-M365Dkim -Domain contoso.com 6>$null } | Should -Throw '*Could not read the DKIM signing config*'
            (Get-Write 'New-DkimSigningConfig').Count | Should -Be 0
        }
        It 'Enable-M365Dkim plans the config creation under -WhatIf' {
            Mock -ModuleName ExchangeHelpers Get-DkimSigningConfig { throw $script:NotFound }
            Start-M365ChangeRecording
            $r = Enable-M365Dkim -Domain contoso.com -WhatIf
            $plan = Stop-M365ChangeRecording
            $plan[0].Text | Should -Be "[test.onmicrosoft.com] New-DkimSigningConfig -DomainName 'contoso.com' -Enabled:`$false -KeySize 2048"
            $r.WhatIf | Should -BeTrue
            (Get-Write 'New-DkimSigningConfig').Count | Should -Be 0
        }
    }

    Context 'Audits never skip a mailbox they could not read (M5)' {
        BeforeEach {
            Mock -ModuleName ExchangeHelpers Get-Mailbox {
                New-TestRecipient UserMailbox 'Jane' 'jane@contoso.com' @{ ForwardingAddress = 'Jane Gmail'; ForwardingSmtpAddress = $null; DeliverToMailboxAndForward = $true; GrantSendOnBehalfTo = @() }
                New-TestRecipient UserMailbox 'Bob' 'bob@contoso.com' @{ ForwardingAddress = $null; ForwardingSmtpAddress = $null; DeliverToMailboxAndForward = $false; GrantSendOnBehalfTo = @() }
            }
            Mock -ModuleName ExchangeHelpers Get-Recipient { New-TestRecipient MailContact 'Jane Gmail' 'jane@gmail.example' @{ ExternalEmailAddress = 'SMTP:jane@gmail.example' } }
        }
        It 'flags forwarding to an outside mail contact as External' {
            $rows = @(Get-M365ForwardingAudit)
            $rows.Count | Should -Be 1
            $rows[0].External | Should -BeTrue
            $rows[0].Target | Should -Be 'jane@gmail.example'
        }
        It 'returns an Error row (and a warning) for a mailbox whose inbox rules cannot be read' {
            Mock -ModuleName ExchangeHelpers Get-InboxRule { if ($Mailbox -eq 'bob@contoso.com') { throw $script:ReadFails } else { [pscustomobject]@{ Name = 'fw'; ForwardTo = @('Ext [SMTP:x@evil.example]'); ForwardAsAttachmentTo = $null; RedirectTo = $null } } }
            $rows = @(Get-M365ForwardingAudit -IncludeInboxRules -WarningVariable warned 3>$null)
            ($rows | Where-Object Mailbox -eq 'bob@contoso.com').Error | Should -Match 'Could not read inbox rules'
            ($rows | Where-Object Rule -eq 'fw').External | Should -BeTrue
            ($warned -join ' ') | Should -Match 'bob@contoso.com'
        }
        It 'returns an Error row for a mailbox whose permissions cannot be read' {
            Mock -ModuleName ExchangeHelpers Get-MailboxPermission { if ($Identity -eq 'bob@contoso.com') { throw $script:ReadFails } }
            $rows = @(Get-M365MailboxPermissionAudit 3>$null)
            ($rows | Where-Object { $_.Mailbox -eq 'bob@contoso.com' -and $_.Permission -eq 'FullAccess' }).Error | Should -Match 'Could not read Full Access'
        }
    }
}
