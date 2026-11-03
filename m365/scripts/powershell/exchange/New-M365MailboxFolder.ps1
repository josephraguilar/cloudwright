<#
.SYNOPSIS
    Creates a mail folder in a mailbox (yours or a shared one) through Microsoft Graph.
.DESCRIPTION
    Onboarding checklist 1.7a: the client's folder under Inbox in clients@. Exchange
    PowerShell cannot create folders in another mailbox, so this goes through Graph with
    Mail.ReadWrite.Shared; you need Full Access on the shared mailbox. Idempotent on name.
.PARAMETER TenantId
    Tenant that owns the mailbox (ours, for clients@).
.PARAMETER Mailbox
    UPN or address of the mailbox.
.PARAMETER Name
    Folder display name.
.PARAMETER ParentFolder
    Well-known folder name or id. Default inbox.
.EXAMPLE
    ./New-M365MailboxFolder.ps1 -TenantId examplemsp.onmicrosoft.com -Mailbox clients@msp.example -Name 'Contoso' -WhatIf
.NOTES
    Requires: Microsoft.Graph.Mail
    Graph scopes: Mail.ReadWrite.Shared
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$Mailbox,

    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter()]
    [string]$ParentFolder = 'inbox'
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
Import-Module (Join-Path $modules 'ExchangeHelpers' 'ExchangeHelpers.psd1') -Force
$null = Assert-M365Graph -TenantId $TenantId -Scopes 'Mail.ReadWrite.Shared'
#endregion

#region 3. Create -----------------------------------------------------------------
New-M365MailboxFolder -Mailbox $Mailbox -Name $Name -ParentFolder $ParentFolder -WhatIf:$WhatIfPreference
#endregion
