<#
.SYNOPSIS
    Import a .ps1 (for example from the repo's runbooks/ folder) into an Azure
    Automation account as a new, published PowerShell 7.2 runbook.
.DESCRIPTION
    A runbook with the same name is refused rather than overwritten.
.PARAMETER SubscriptionId
    Subscription of the Automation account.
.PARAMETER AccountId
    Resource ID of the Automation account.
.PARAMETER Path
    The .ps1 file.
.PARAMETER Name
    Runbook name. Defaults to the file name.
.PARAMETER Description
    What it does.
.EXAMPLE
    ./Import-ToolboxRunbook.ps1 -SubscriptionId <sub> -AccountId <account-id> -Path ../../../runbooks/Test-AvdHostHealth.ps1
.NOTES
    Requires: Az.Accounts, Az.Automation
    Status:   Untested
    Roles:    Automation Contributor on the account.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$AccountId,
    [Parameter(Mandatory)] [string]$Path,
    [Parameter()] [string]$Name,
    [Parameter()] [string]$Description
)
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AutomationAdmin' 'AutomationAdmin.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
$p = @{ AccountId = $AccountId; Path = $Path }
if ($Name) { $p.Name = $Name }
if ($Description) { $p.Description = $Description }
Import-RunbookFile @p
