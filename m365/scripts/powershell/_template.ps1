<#
.SYNOPSIS
    <One line: what this script does.>
.DESCRIPTION
    <A short paragraph. Which tenant it touches (ours or the client's), what it does NOT
    touch, any gotchas. One job per script: if you need two, write two scripts and let
    the onboarding orchestrator (or the console) call both.>
.PARAMETER TenantId
    Tenant to sign in to with Graph (GUID or any verified domain). Omit for Exchange-only scripts.
.PARAMETER Organization
    Client onmicrosoft.com domain for an Exchange Online delegated session. Omit for our tenant.
.PARAMETER Name
    <Describe every parameter.>
.EXAMPLE
    ./Verb-M365Noun.ps1 -TenantId contoso.onmicrosoft.com -Name example -WhatIf
    Shows what would happen without changing anything.
.NOTES
    Requires: Microsoft.Graph.<submodule>, ExchangeOnlineManagement (delete what you do not use)
    Graph scopes: <list>
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
#   WHAT   Declare every input up front. CmdletBinding turns on -Verbose, -WhatIf, etc.
#   WHY    No hard-coded names or addresses anywhere below. Everything client-specific
#          comes in through here or from Get-M365ClientConfig, so the same script works
#          in any tenant.
#   GOTCHA SupportsShouldProcess is only honest if the module function you call also
#          honors -WhatIf. Pass -WhatIf:$WhatIfPreference explicitly; preference
#          variables do not always cross a module boundary.
[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Organization', Justification = 'Template. Delete this attribute and the parameter you do not use.')]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter()]
    [string]$Organization,

    [Parameter(Mandatory)]
    [string]$Name
)
#endregion

#region 2. Setup --------------------------------------------------------------
#   WHAT   Strict mode, fail fast, load the modules, confirm the session.
#   WHY    Same opening as every script so behaviour is identical whether you
#          were already signed in or not. Assert-M365Graph / Assert-M365Exchange
#          reuse an open session when it matches and sign in when it does not.
#   GOTCHA M365Helpers must be imported before the others; they list it as a
#          RequiredModule and the repo is not on PSModulePath.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modules = Join-Path $PSScriptRoot '..' 'modules'
Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
Import-Module (Join-Path $modules 'ExchangeHelpers' 'ExchangeHelpers.psd1') -Force

$null = Assert-M365Graph -TenantId $TenantId -Scopes 'User.Read.All'
# $null = Assert-M365Exchange -DelegatedOrganization $Organization
#endregion

#region 3. Do the work --------------------------------------------------------
#   WHAT   One call into the module. The module function is idempotent and
#          returns an object.
#   WHY    Logic lives in modules so the orchestrator, the console and a future
#          web app all call the same code.
$result = $null
if ($PSCmdlet.ShouldProcess($Name, 'Describe the change in a few words')) {
    # $result = Verb-M365Noun -Name $Name -WhatIf:$WhatIfPreference
}
#endregion

#region 4. Output -------------------------------------------------------------
#   WHAT   Return objects, not formatted text, so the caller can pipe them.
#   WHY    The orchestrator reads .Created / .Updated to print the checklist line.
$result
#endregion
