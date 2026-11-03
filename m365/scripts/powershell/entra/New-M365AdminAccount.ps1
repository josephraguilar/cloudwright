<#
.SYNOPSIS
    Creates one of our named admin accounts in a client tenant, assigns its roles, stores the password in Hudu.
.DESCRIPTION
    Onboarding checklist 5.4. One script call per account; the orchestrator loops over
    settings.adminAccounts. Cloud-only, always on the tenant's <name>.onmicrosoft.com
    domain, password never expires. Every role name is checked before anything is created.

    Password: by default you type it (twice, hidden) and save it in Hudu yourself. With
    -GeneratePassword a random one is made; with -HuduCompanyId and the Hudu API key set it
    goes straight into that client's Hudu Passwords. A generated password that could not be
    saved in Hudu is shown once on screen ("SAVE THIS NOW") and returned once in the
    PasswordNotSaved property of the result; it is never written to the log.

    An account that already exists is refused (nothing changes) unless -AdoptExisting: then
    missing roles are assigned and its password is NOT changed.
.PARAMETER TenantId
    Client tenant (GUID or any verified domain).
.PARAMETER UpnPrefix
    Local part, e.g. msp-admin.
.PARAMETER DisplayName
    Display name.
.PARAMETER Roles
    Entra role display names. Prefer the least that does the job.
.PARAMETER Domain
    The tenant's <name>.onmicrosoft.com domain. Default: looked up.
.PARAMETER GeneratePassword
    Generate a random password instead of asking you to type one.
.PARAMETER HuduCompanyId
    Numeric Hudu company_id. Only used with -GeneratePassword and the Hudu API key set: the generated password is stored there. 0 = never.
.PARAMETER AdoptExisting
    The account already exists and is ours: assign missing roles instead of refusing. Its password is NOT changed.
.EXAMPLE
    ./New-M365AdminAccount.ps1 -TenantId contoso.onmicrosoft.com -UpnPrefix msp-admin -DisplayName 'Example MSP Admin' -Roles 'Global Administrator' -GeneratePassword -HuduCompanyId 42 -WhatIf
.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Identity.Governance, Microsoft.Graph.Identity.DirectoryManagement
    Graph scopes: User.ReadWrite.All, RoleManagement.ReadWrite.Directory, Domain.Read.All
    Interactive: yes (prompts for the password unless -GeneratePassword)
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'One-time password display for the operator at the terminal, never a log.')]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$UpnPrefix,

    [Parameter(Mandatory)]
    [string]$DisplayName,

    [Parameter(Mandatory)]
    [string[]]$Roles,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9-]+\.onmicrosoft\.com$')]
    [string]$Domain,

    [Parameter()]
    [switch]$GeneratePassword,

    [Parameter()]
    [int]$HuduCompanyId = 0,

    [Parameter()]
    [switch]$AdoptExisting
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '..' 'modules'
Import-Module (Join-Path $modules 'M365Helpers' 'M365Helpers.psd1') -Force
Assert-M365WriteAllowed   # Refuse legacy write tasks before sign-in, lookups, or prompts.
Import-Module (Join-Path $modules 'EntraHelpers' 'EntraHelpers.psd1') -Force

$settings = try { Get-M365Settings } catch { $null }
$null = Assert-M365Graph -TenantId $TenantId -Scopes 'User.ReadWrite.All', 'RoleManagement.ReadWrite.Directory', 'Domain.Read.All'
#endregion

#region 3. Check the account, then the password, then create ---------------------------
#   WHY    An existing account is refused unless -AdoptExisting, and an adopted one keeps its
#          password, so the password is asked for only when an account will be created.
if (-not $Domain) {
    $initial = @(Get-MgDomain -All -ErrorAction Stop | Where-Object { $_.IsInitial })
    if ($initial.Count -ne 1) { throw 'Could not find exactly one initial (.onmicrosoft.com) domain. Pass -Domain.' }
    $Domain = $initial[0].Id
}
$upn = "$UpnPrefix@$Domain"
$existing = @(Get-MgUser -Filter "userPrincipalName eq '$($upn.Replace("'", "''"))'" -Property id, displayName -ErrorAction Stop)
if ($existing.Count -gt 0 -and -not $AdoptExisting) {
    throw "$upn already exists (id $($existing[0].Id), '$($existing[0].DisplayName)'). Nothing was changed. If it really is our admin account, re-run with -AdoptExisting to assign missing roles; its password will NOT be changed."
}
$params = @{ UpnPrefix = $UpnPrefix; DisplayName = $DisplayName; Roles = $Roles; Domain = $Domain; AdoptExisting = $AdoptExisting }
$typed = $false
if ($existing.Count -eq 0 -and -not $GeneratePassword -and -not $WhatIfPreference) {
    $params.Password = Read-M365Password -Prompt "Admin account password for $upn" -MinimumLength 16
    $typed = $true
}
$result = New-M365AdminAccount @params -WhatIf:$WhatIfPreference
#endregion

#region 4. Store the secret -----------------------------------------------------
#   WHAT   Hudu if we can; if not (or the Hudu write fails), the screen AND the result's
#          PasswordNotSaved, once. Never the log. Under -WhatIf the Hudu save is planned too.
$envVar = if ($settings -and $settings.PSObject.Properties['hudu'] -and $settings.hudu.apiKeyEnvVar) { $settings.hudu.apiKeyEnvVar } else { 'HUDU_API_KEY' }
$useHudu = $HuduCompanyId -gt 0 -and [bool][Environment]::GetEnvironmentVariable($envVar)
$huduName = "Admin - $DisplayName (Entra ID)"
$description = "MSP admin account. Roles: $($Roles -join ', '). Created by 365-MGMT New-M365AdminAccount.ps1 on $(Get-Date -Format yyyy-MM-dd)."
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
        } catch { $notSavedWhy = "saving to Hudu failed: $($_.Exception.Message)" }
    } else { $notSavedWhy = 'no Hudu company id or API key, so it was not stored' }
    if (-not $stored) {
        $notSaved = $result.Password
        Write-Host ''
        Write-Host "  SAVE THIS NOW: password for $($result.UserPrincipalName) ($notSavedWhy)." -ForegroundColor Red
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
#   GOTCHA A failure after creation ends with an error, except when a password is waiting in
#          PasswordNotSaved (throwing would discard the result): then it warns, Completed=$false.
$result | Select-Object UserPrincipalName, Id, Created, Adopted, Note, RolesRequested, RolesAssigned, RolesAlreadyHeld, RolesPlanned, Errors, Completed, WhatIf,
    @{ n = 'PasswordStoredInHudu'; e = { $stored } }, @{ n = 'PasswordNotSaved'; e = { $notSaved } }
if (-not $result.Completed) {
    $summary = "Admin account $($result.UserPrincipalName) did not finish: $($result.Errors -join ' | ')"
    if ($notSaved) { Write-Warning "$summary. Save the password shown above first, then re-run with -AdoptExisting to finish." }
    else { throw "$summary. Re-run with -AdoptExisting to finish (the password is not changed)." }
}
#endregion
