<#
.SYNOPSIS
    Creates a server-side inbox rule that moves matching mail into a folder. Note: per Microsoft, creating rules from PowerShell can remove Outlook client-only rules in that mailbox.
.DESCRIPTION
    Onboarding checklist 1.7: file mail that mentions the client, or is sent to the client's
    alias, into their folder in clients@. Conditions inside one rule are ANDed by Exchange,
    so the orchestrator creates two rules (name match, alias match). The folder must exist
    first: New-M365MailboxFolder.ps1. Idempotent on rule name.

    Microsoft behaviour: creating or changing a rule with PowerShell (or Outlook on the web)
    can delete rules that exist only in the Outlook client, such as rules turned off in
    Outlook. Exchange normally asks first; the toolkit answers that prompt itself
    (-Confirm:$false) after you have reviewed and confirmed this exact change, so nothing
    waits on a hidden prompt. Later rules keep running unless -StopProcessingRules is given.
.PARAMETER Organization
    Tenant to change: its onmicrosoft.com domain or any verified domain. For our own tenant pass our domain (msp.homeTenantId in settings).
.PARAMETER Mailbox
    Mailbox the rule lives in.
.PARAMETER Name
    Rule name.
.PARAMETER SubjectOrBodyContainsWords
    Words to match.
.PARAMETER SentTo
    Recipient addresses to match.
.PARAMETER MoveToFolder
    Folder path from the mailbox root, e.g. 'Inbox\Contoso'.
.PARAMETER StopProcessingRules
    Stop evaluating later rules once this one matches. Off by default.
.PARAMETER SignInAs
    Partner account to sign in as. Defaults to msp.adminUpn from settings.
.EXAMPLE
    ./New-M365InboxRule.ps1 -Organization examplemsp.onmicrosoft.com -Mailbox clients@msp.example -Name 'Client - Contoso (name)' -SubjectOrBodyContainsWords Contoso -MoveToFolder 'Inbox\Contoso' -WhatIf
.NOTES
    Requires: ExchangeOnlineManagement
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$Organization,

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
    [switch]$StopProcessingRules,

    [Parameter()]
    [string]$SignInAs
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Sign in to exactly -Organization (verified live) before anything is read.
#   WHY    There is no "blank means our tenant": every run names the tenant it changes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
Assert-M365WriteAllowed   # Refuse legacy write tasks before sign-in, lookups, or prompts.
Import-Module (Join-Path $modules 'ExchangeHelpers' 'ExchangeHelpers.psd1') -Force

$settings = try { Get-M365Settings } catch { $null }
if (-not $SignInAs -and $settings -and $settings.msp.adminUpn -notmatch '^<') { $SignInAs = $settings.msp.adminUpn }
$null = Assert-M365Exchange -Organization $Organization -UserPrincipalName $SignInAs
#endregion

#region 3. Create -----------------------------------------------------------------
$params = @{ Mailbox = $Mailbox; Name = $Name; MoveToFolder = $MoveToFolder; StopProcessingRules = $StopProcessingRules }
if ($SubjectOrBodyContainsWords) { $params.SubjectOrBodyContainsWords = $SubjectOrBodyContainsWords }
if ($SentTo) { $params.SentTo = $SentTo }
New-M365InboxRule @params -WhatIf:$WhatIfPreference
#endregion
