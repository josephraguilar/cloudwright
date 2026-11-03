<#
.SYNOPSIS
    Creates the emergency-access account in a client tenant and stores its password in Hudu.
.DESCRIPTION
    Onboarding checklist 5.3. Cloud-only user on the tenant's onmicrosoft.com domain (pass it
    with -Domain; the orchestrator takes it from the client config), Global
    Administrator, password never expires, excluded from every Conditional Access policy.

    Password: by default you type it (twice, hidden) and save it in Hudu yourself. With
    -GeneratePassword a random one is made; with -HuduCompanyId and the Hudu API key set it
    goes straight into that client's Hudu Passwords. A generated password that could not be
    saved in Hudu is shown once on screen ("SAVE THIS NOW") and returned once in the
    PasswordNotSaved property of the result; it is never written to the log.

    An account that already exists is refused (nothing changes) unless -AdoptExisting: then
    its Global Administrator role and CA exclusions are checked and added where missing, and
    its password is NOT changed (the plan and the result say so). -WhatIf plans the account,
    the role and every exclusion without changing anything.
.PARAMETER TenantId
    Client tenant (GUID or any verified domain).
.PARAMETER UpnPrefix
    Local part of the UPN. Default from settings.breakGlass.upnPrefix, else 'breakglass'.
.PARAMETER DisplayName
    Default from settings.breakGlass.displayName, else 'Emergency Access'.
.PARAMETER PasswordLength
    Default from settings, else 64.
.PARAMETER Domain
    The tenant's <name>.onmicrosoft.com domain. Looked up when omitted.
.PARAMETER GeneratePassword
    Generate a random password and show it once, instead of asking you to type one. Default
    is to prompt (typed twice, hidden) so you choose it and save it in Hudu yourself.
.PARAMETER HuduCompanyId
    Numeric Hudu company_id. Only used with -GeneratePassword and HUDU_API_KEY set: the generated password is stored there. 0 = never.
.PARAMETER SkipConditionalAccessExclusion
    Leave CA policies untouched.
.PARAMETER AdoptExisting
    The account already exists and is this tenant's break-glass account: check its role and CA exclusions instead of refusing. Its password is NOT changed.
.EXAMPLE
    ./New-M365BreakGlassAccount.ps1 -TenantId contoso.onmicrosoft.com -Domain contoso.onmicrosoft.com -HuduCompanyId 42 -GeneratePassword -WhatIf
.EXAMPLE
    ./New-M365BreakGlassAccount.ps1 -TenantId contoso.onmicrosoft.com -Domain contoso.onmicrosoft.com -AdoptExisting
.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Identity.Governance, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Identity.DirectoryManagement
    Graph scopes: User.ReadWrite.All, RoleManagement.ReadWrite.Directory, Policy.Read.All, Policy.ReadWrite.ConditionalAccess, Domain.Read.All
    Interactive: yes (prompts for the password unless -GeneratePassword)
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The one-time password display must reach the operator at the terminal, never a log.')]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter()]
    [string]$UpnPrefix,

    [Parameter()]
    [string]$DisplayName,

    [Parameter()]
    [int]$PasswordLength,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9-]+\.onmicrosoft\.com$')]
    [string]$Domain,

    [Parameter()]
    [switch]$GeneratePassword,

    [Parameter()]
    [int]$HuduCompanyId = 0,

    [Parameter()]
    [switch]$SkipConditionalAccessExclusion,

    [Parameter()]
    [switch]$AdoptExisting
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
Import-Module (Join-Path $modules 'EntraHelpers' 'EntraHelpers.psd1') -Force

$settings = try { Get-M365Settings } catch { $null }
$bg = if ($settings -and $settings.PSObject.Properties['breakGlass']) { $settings.breakGlass } else { $null }
if (-not $UpnPrefix) { $UpnPrefix = if ($bg -and $bg.upnPrefix) { $bg.upnPrefix } else { 'breakglass' } }
if (-not $DisplayName) { $DisplayName = if ($bg -and $bg.displayName) { $bg.displayName } else { 'Emergency Access' } }
if (-not $PasswordLength) { $PasswordLength = if ($bg -and $bg.passwordLength) { [int]$bg.passwordLength } else { 64 } }

$null = Assert-M365Graph -TenantId $TenantId -Scopes 'User.ReadWrite.All', 'RoleManagement.ReadWrite.Directory',
    'Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess', 'Domain.Read.All'
#endregion

#region 3. Check the account, then the password, then create ---------------------------
#   WHAT   Look the account up BEFORE asking for a password.
#   WHY    An existing account is refused unless -AdoptExisting, and an adopted account keeps
#          its password: asking for one would only produce a password nobody applied (the
#          "wrong password saved in Hudu" problem). Under -WhatIf nothing is asked.
if (-not $Domain) {
    $initial = @(Get-MgDomain -All -ErrorAction Stop | Where-Object { $_.IsInitial })
    if ($initial.Count -ne 1) { throw 'Could not find exactly one initial (.onmicrosoft.com) domain. Pass -Domain.' }
    $Domain = $initial[0].Id
}
$upn = "$UpnPrefix@$Domain"
$existing = @(Get-MgUser -Filter "userPrincipalName eq '$($upn.Replace("'", "''"))'" -Property id, displayName -ErrorAction Stop)
if ($existing.Count -gt 0 -and -not $AdoptExisting) {
    throw "$upn already exists (id $($existing[0].Id), '$($existing[0].DisplayName)'). Nothing was changed. If it really is this tenant's break-glass account, re-run with -AdoptExisting to check its role and Conditional Access exclusions; its password will NOT be changed."
}
$params = @{ UpnPrefix = $UpnPrefix; DisplayName = $DisplayName; PasswordLength = $PasswordLength; Domain = $Domain; SkipConditionalAccessExclusion = $SkipConditionalAccessExclusion; AdoptExisting = $AdoptExisting }
$typed = $false
if ($existing.Count -eq 0 -and -not $GeneratePassword -and -not $WhatIfPreference) {
    $params.Password = Read-M365Password -Prompt "Break-glass password for $upn" -MinimumLength 20
    $typed = $true
}
$result = New-M365BreakGlassAccount @params -WhatIf:$WhatIfPreference
#endregion

#region 4. Store the secret -----------------------------------------------------
#   WHAT   Hudu if we can; if not (or the Hudu write fails), the screen AND the result's
#          PasswordNotSaved, once. Never the log.
#   WHY    The password exists exactly once. The GUI does not show Write-Host, so the result
#          object is the only place a GUI operator can see it.
#   GOTCHA Under -WhatIf the Hudu save is planned too (the password shows as <hidden>), so the
#          real run of a reviewed plan is allowed to make it.
$envVar = if ($settings -and $settings.PSObject.Properties['hudu'] -and $settings.hudu.apiKeyEnvVar) { $settings.hudu.apiKeyEnvVar } else { 'HUDU_API_KEY' }
$useHudu = $HuduCompanyId -gt 0 -and [bool][Environment]::GetEnvironmentVariable($envVar)
$huduName = 'Break Glass - Entra ID (Global Admin)'
$description = "Emergency access (break-glass). Global Administrator. Excluded from Conditional Access. Created by 365-MGMT New-M365BreakGlassAccount.ps1 on $(Get-Date -Format yyyy-MM-dd). Do not use for daily work; review sign-ins monthly."
$stored = $false
$notSaved = $null
$notSavedWhy = $null
if ($result.Password -and $typed) {
    Write-Host "  Created $($result.UserPrincipalName) with the password you typed. Save it in the client's Hudu Passwords now." -ForegroundColor Yellow
} elseif ($result.Password) {
    if ($useHudu) {
        try {
            $null = Add-HuduPassword -CompanyId $HuduCompanyId -Name $huduName -Username $result.UserPrincipalName -Password $result.Password -Description $description -Settings $settings
            $stored = $true
            Write-Verbose "Stored in Hudu company $HuduCompanyId."
        } catch { $notSavedWhy = "saving to Hudu failed: $($_.Exception.Message)" }
    } else { $notSavedWhy = 'no Hudu company id or API key, so it was not stored' }
    if (-not $stored) {
        $notSaved = $result.Password
        Write-Host ''
        Write-Host "  SAVE THIS NOW: break-glass password for $($result.UserPrincipalName) ($notSavedWhy)." -ForegroundColor Red
        Write-Host "  It is shown once and is not in any log. Put it in the client's Hudu Passwords now." -ForegroundColor Red
        Write-Host "  $($result.Password)" -ForegroundColor Yellow
        Write-Host ''
    }
} elseif ($WhatIfPreference -and $GeneratePassword -and $useHudu -and -not $result.Adopted) {
    $null = Add-HuduPassword -CompanyId $HuduCompanyId -Name $huduName -Username $result.UserPrincipalName -Password 'generated-at-run-time' -Description $description -Settings $settings -WhatIf
}
if ($result.Adopted) { Write-Warning "$($result.UserPrincipalName): existing account - password NOT changed." }
#endregion

#region 5. Result ---------------------------------------------------------------------
#   GOTCHA When something failed after the account was created, the run ends with an error,
#          EXCEPT when a password is waiting in PasswordNotSaved: throwing would discard the
#          result (callers that capture output lose it), so it warns instead and Completed
#          is $false.
$result | Select-Object UserPrincipalName, Id, Created, Adopted, Note, GlobalAdmin, GlobalAdminAssigned, PoliciesUpdated, PoliciesPlanned,
    PoliciesAlreadyExcluding, PoliciesSkipped, PoliciesFailed, Errors, Completed, WhatIf,
    @{ n = 'PasswordStoredInHudu'; e = { $stored } }, @{ n = 'PasswordNotSaved'; e = { $notSaved } }
if (-not $result.Completed) {
    $summary = "Break-glass setup for $($result.UserPrincipalName) did not finish: $($result.Errors -join ' | ')"
    if ($notSaved) { Write-Warning "$summary. Save the password shown above first, then re-run with -AdoptExisting to finish." }
    else { throw "$summary. Re-run with -AdoptExisting to finish (the password is not changed)." }
}
#endregion
