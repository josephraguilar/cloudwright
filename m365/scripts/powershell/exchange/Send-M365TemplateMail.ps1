<#
.SYNOPSIS
    Sends an HTML email built from a {{token}} template, as a mailbox in our tenant, one separate message per recipient.
.DESCRIPTION
    Generic templated notice (a future welcome letter, a maintenance notice, a password
    policy reminder). Tokens come from -Tokens plus defaults from settings: MspName,
    SupportEmail, SupportPhone, SupportPhone24x7, Address. Token values are inserted
    literally and HTML-encoded. Unfilled tokens are an error, so nothing goes out
    half-merged. Every address in -To gets its own message, so recipients never see each
    other's addresses. Always try -WhatIf first: it renders and validates the template and
    lists every message without sending. A dry run still signs in to Graph with the send
    scopes below (so the real run needs no second sign-in); it sends nothing. Not wired into
    the onboarding checklist yet (5.14 is manual until the welcome letter text is approved).
.PARAMETER TenantId
    Tenant that owns the From mailbox (ours).
.PARAMETER From
    Mailbox to send as (ours). You must have Send As on it.
.PARAMETER To
    Recipients. Each one gets a separate message.
.PARAMETER Subject
    Subject line (token-expanded).
.PARAMETER TemplatePath
    HTML template with {{tokens}}. Relative paths resolve from the repo root.
.PARAMETER Tokens
    Hashtable of token values; overrides the defaults.
.PARAMETER Bcc
    Blind copies on every message, e.g. our clients@ mailbox for the record.
.EXAMPLE
    ./Send-M365TemplateMail.ps1 -TenantId examplemsp.onmicrosoft.com -From support@msp.example -To jane@contoso.com -Subject 'Welcome' -TemplatePath templates/welcome-letter.html -Tokens @{ ClientName = 'Contoso'; ItAlias = 'IT@contoso.com' } -WhatIf
.NOTES
    Requires: Microsoft.Graph.Users.Actions
    Graph scopes: Mail.Send, Mail.Send.Shared
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

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
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
Import-Module (Join-Path $modules 'ExchangeHelpers' 'ExchangeHelpers.psd1') -Force

$settings = try { Get-M365Settings } catch { $null }
if (-not [IO.Path]::IsPathRooted($TemplatePath)) { $TemplatePath = Join-Path $PSScriptRoot '..' '..' '..' $TemplatePath }

#   WHAT   Settings supply the tokens that are the same for every client.
#   WHY    The caller only has to pass what is client-specific.
$merged = @{}
if ($settings) {
    $merged.MspName = $settings.msp.name
    $merged.SupportEmail = $settings.msp.supportEmail
    foreach ($pair in @(@('SupportPhone', 'supportPhone'), @('SupportPhone24x7', 'supportPhone24x7'), @('Address', 'address'))) {
        if ($settings.msp.PSObject.Properties.Name -contains $pair[1]) { $merged[$pair[0]] = $settings.msp.($pair[1]) }
    }
}
foreach ($k in $Tokens.Keys) { $merged[$k] = $Tokens[$k] }

$null = Assert-M365Graph -TenantId $TenantId -Scopes 'Mail.Send', 'Mail.Send.Shared'
#endregion

#region 3. Send -------------------------------------------------------------------------
Send-M365TemplateMail -From $From -To $To -Subject $Subject -TemplatePath $TemplatePath -Tokens $merged -Bcc $Bcc -WhatIf:$WhatIfPreference
#endregion
