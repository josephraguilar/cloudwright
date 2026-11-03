#region Module setup ----------------------------------------------------------
#   WHAT   Strict mode for the whole module.
#   WHY    Modules are imported by every script. A typo here breaks everything,
#          so catch it at import time.
Set-StrictMode -Version Latest
#endregion

function Assert-AzContext {
    <#
    .SYNOPSIS
        Ensures an Az PowerShell session exists and targets the expected subscription.
    .DESCRIPTION
        Checks Get-AzContext. If there is no context, connects: interactively by default,
        or as a managed identity when -Identity is set (for Azure Automation runbooks).
        If -SubscriptionId is supplied and the current context is on a different
        subscription, switches with Set-AzContext. Returns the resulting context.

        Call this at the top of every script and runbook so they behave the same whether
        you are already logged in or starting fresh.
    .PARAMETER SubscriptionId
        Subscription to target. Omit to accept whatever the current context uses.
    .PARAMETER TenantId
        Tenant to sign in to, or to switch an existing context to. Pass this when your
        account can see more than one tenant (MSP accounts, guest access): without it,
        Connect-AzAccount enumerates every tenant and trips over the ones that demand
        MFA or conditional access.
    .PARAMETER Identity
        Authenticate as the managed identity of the host (Azure Automation, a VM, etc.).
        Never prompts. Use this in runbooks.
    .EXAMPLE
        Assert-AzContext -SubscriptionId '00000000-0000-0000-0000-000000000000'
    .EXAMPLE
        # Inside an Azure Automation runbook
        Assert-AzContext -Identity -SubscriptionId $SubscriptionId
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$SubscriptionId,

        [Parameter()]
        [string]$TenantId,

        [Parameter()]
        [switch]$Identity
    )

    #region 1. Preflight ------------------------------------------------------
    #   WHAT   Fail fast inside this function, and make sure Az.Accounts exists.
    #   WHY    A module function does NOT inherit the caller's $ErrorActionPreference.
    #          Without setting it here, a failed Connect-AzAccount is a
    #          non-terminating error, the function carries on with no context, and
    #          the caller dies later on a confusing "property not found".
    #   GOTCHA Az.Accounts is checked at call time, not import time, so the module
    #          (and its tests) load on a machine without Az installed.
    $ErrorActionPreference = 'Stop'
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        throw 'The Az.Accounts module is not installed. Run: Install-Module Az -Scope CurrentUser'
    }
    #endregion

    #region 2. Connect if needed ----------------------------------------------
    #   WHAT   Reuse an existing login. Only connect when there is no context at all.
    #   WHY    Interactive login is slow and pops a browser. Reusing the session
    #          means you log in once per terminal, not once per script.
    #          -Identity swaps the browser login for the host's managed identity,
    #          which is the only option inside Azure Automation.
    #   GOTCHA Get-AzContext throws on some Az versions when nothing is cached, so
    #          -ErrorAction SilentlyContinue is required to get a clean $null.
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) {
        $connectParams = @{}
        if ($Identity) {
            Write-Verbose 'No Azure context found. Connecting as managed identity.'
            $connectParams.Identity = $true
        } else {
            Write-Verbose 'No Azure context found. Connecting interactively.'
            if ($TenantId) { $connectParams.Tenant = $TenantId }
        }
        if ($SubscriptionId) { $connectParams.Subscription = $SubscriptionId }
        $null = Connect-AzAccount @connectParams -ErrorAction Stop
        $context = Get-AzContext
    }

    if (-not $context -or -not $context.Subscription -or -not $context.Subscription.Id) {
        throw @'
Signed in, but Azure did not return a subscription context.
Usual cause: your account spans several tenants and Az tried to enumerate all of them.
Fix: sign in to the one tenant that holds your subscription and re-run.
    Get-AzTenant                                    # list tenants you can see
    Connect-AzAccount -TenantId <tenant-id>         # MFA prompt is expected
If Connect-AzAccount fails with "SharedTokenCacheCredential", disable the Windows token broker for Az:
    Update-AzConfig -EnableLoginByWam $false
    Connect-AzAccount -TenantId <tenant-id>
'@
    }
    #endregion

    #region 3. Point at the right tenant and subscription ---------------------
    #   WHAT   Switch tenant and/or subscription only if the caller asked for a
    #          specific one and the current context is somewhere else.
    #   WHY    Running a destructive script against the wrong subscription is the
    #          classic Azure mistake. This makes the target explicit every time.
    if ($TenantId -and $context.Tenant.Id -ne $TenantId) {
        Write-Verbose "Switching context to tenant $TenantId."
        $switch = @{ Tenant = $TenantId }
        if ($SubscriptionId) { $switch.Subscription = $SubscriptionId }
        $context = Set-AzContext @switch
    }
    if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
        Write-Verbose "Switching context to subscription $SubscriptionId."
        $context = Set-AzContext -Subscription $SubscriptionId
    }
    #endregion

    Write-Verbose "Using subscription '$($context.Subscription.Name)' ($($context.Subscription.Id))."
    return $context
}

function Assert-AzResourceProvider {
    <#
    .SYNOPSIS
        Registers Azure resource providers in the current subscription and waits for them.
    .DESCRIPTION
        A resource provider is the ARM back-end for a family of resource types
        (Microsoft.Compute = VMs and disks, Microsoft.DesktopVirtualization = AVD).
        Each one must be registered once per subscription before ARM accepts its types.
        Registration is free and idempotent. Unregistered providers fail with a
        confusing error at deploy time, so register everything you will need up front.
    .PARAMETER Namespace
        One or more provider namespaces. Already-registered ones are skipped.
    .PARAMETER TimeoutMinutes
        How long to wait for all of them to reach Registered. Default 10.
    .EXAMPLE
        Assert-AzResourceProvider -Namespace 'Microsoft.DesktopVirtualization', 'Microsoft.Compute'
    .NOTES
        Needs Contributor (or the */register/action permission) at subscription scope.
        Resource-group-scoped Contributor is not enough.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string[]]$Namespace,

        [Parameter()]
        [int]$TimeoutMinutes = 10
    )

    #region 1. Find what is missing ------------------------------------------
    #   WHAT   One call per namespace. Get-AzResourceProvider returns one row per
    #          resource type, all sharing the same RegistrationState.
    #   WHY    Only register what needs it, so re-running is instant.
    $pending = @()
    foreach ($ns in $Namespace) {
        $state = (Get-AzResourceProvider -ProviderNamespace $ns | Select-Object -First 1).RegistrationState
        if ($state -eq 'Registered') {
            Write-Verbose "$ns already registered."
        } else {
            $pending += $ns
        }
    }
    if ($pending.Count -eq 0) { return }
    #endregion

    #region 2. Register and wait ---------------------------------------------
    #   WHAT   Fire all registrations, then poll until every one is Registered.
    #   WHY    Register-AzResourceProvider returns immediately; the real work is
    #          async and takes anywhere from seconds to a few minutes. Registering
    #          all first and then waiting is faster than doing them one by one.
    foreach ($ns in $pending) {
        if ($PSCmdlet.ShouldProcess($ns, 'Register resource provider')) {
            Write-Verbose "Registering $ns."
            $null = Register-AzResourceProvider -ProviderNamespace $ns
        }
    }
    if ($WhatIfPreference) { return }

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds 10
        $pending = @($pending | Where-Object {
            $state = (Get-AzResourceProvider -ProviderNamespace $_ | Select-Object -First 1).RegistrationState
            Write-Verbose "  $_ is $state"
            $state -ne 'Registered'
        })
    } until ($pending.Count -eq 0 -or (Get-Date) -gt $deadline)

    if ($pending.Count -gt 0) {
        throw "Resource provider(s) not Registered after $TimeoutMinutes minutes: $($pending -join ', '). Re-run once they are."
    }
    #endregion
}

function Find-AzSubscriptionAcrossTenant {
    <#
    .SYNOPSIS
        Lists every enabled subscription the signed-in account can reach, across all
        tenants it can see.
    .DESCRIPTION
        Connect-AzAccount for a personal Microsoft account (or a guest in several
        tenants) often lands in a directory that holds no subscriptions. This walks
        Get-AzTenant and asks each tenant for its subscriptions. Tenants that refuse
        (MFA required, no access) are skipped with a verbose note, not an error, so one
        locked-down client tenant cannot break discovery of the lab.
    .OUTPUTS
        Objects with TenantId, TenantName, SubscriptionId, SubscriptionName.
    #>
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Stop'
    $tenants = @(Get-AzTenant -ErrorAction SilentlyContinue)
    foreach ($t in $tenants) {
        $tenantName = if ($t.Name) { $t.Name } else { $t.Id }
        try {
            $subs = @(Get-AzSubscription -TenantId $t.Id -WarningAction SilentlyContinue -ErrorAction Stop | Where-Object State -eq 'Enabled')
        } catch {
            Write-Verbose "Skipping tenant $tenantName ($($t.Id)): $($_.Exception.Message)"
            continue
        }
        foreach ($s in $subs) {
            [pscustomobject]@{
                TenantId         = $t.Id
                TenantName       = $tenantName
                SubscriptionId   = $s.Id
                SubscriptionName = $s.Name
            }
        }
    }
}

function Get-AzEffectivePermission {
    <#
    .SYNOPSIS
        The ARM actions the signed-in account can perform at a scope, including rights
        inherited through group membership and parent scopes.
    .DESCRIPTION
        Calls the Microsoft.Authorization/permissions endpoint, which is what the
        portal's "Check access" uses. Returns the raw permission sets: each has
        actions and notActions (wildcards allowed, e.g. "*" for Owner/Contributor).
    .PARAMETER Scope
        /subscriptions/<id> or /subscriptions/<id>/resourceGroups/<name>.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Scope)
    $ErrorActionPreference = 'Stop'
    $resp = Invoke-AzRestMethod -Method GET -Path "$Scope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
    if ($resp.StatusCode -ne 200) { throw "Permissions lookup at $Scope returned HTTP $($resp.StatusCode): $($resp.Content)" }
    return @(($resp.Content | ConvertFrom-Json).value)
}

function Test-AzActionAllowed {
    <#
    .SYNOPSIS
        True if an ARM action is allowed by a set of permissions from Get-AzEffectivePermission.
    .DESCRIPTION
        RBAC rule: an action is allowed if any permission set has an actions entry
        matching it and no notActions entry in that same set matching it. Wildcards
        use PowerShell -like semantics, which is what Azure's patterns mean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$Action,
        [Parameter(Mandatory)] [object[]]$Permissions
    )
    foreach ($p in $Permissions) {
        $allowed = @($p.actions    | Where-Object { $Action -like $_ })
        $denied  = @($p.notActions | Where-Object { $Action -like $_ })
        if ($allowed.Count -gt 0 -and $denied.Count -eq 0) { return $true }
    }
    return $false
}

function Get-AzDirectoryRoleMembership {
    <#
    .SYNOPSIS
        Entra ID directory roles the signed-in user holds (Global Administrator,
        Cloud Device Administrator, ...), via Microsoft Graph.
    .OUTPUTS
        Role display names. Empty if none; throws if Graph refuses the lookup.
    #>
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Stop'
    $resp = Invoke-AzRestMethod -Method GET -Uri 'https://graph.microsoft.com/v1.0/me/memberOf/microsoft.graph.directoryRole?$select=displayName,roleTemplateId'
    if ($resp.StatusCode -ne 200) { throw "Graph directory role lookup returned HTTP $($resp.StatusCode): $($resp.Content)" }
    return @(($resp.Content | ConvertFrom-Json).value | ForEach-Object displayName)
}


function Set-AzScriptDefault {
    <#
    .SYNOPSIS
        Hand a script's -WhatIf, -Confirm:$false and -Verbose on to the functions
        of this repo's modules. Call it right after the Import-Module lines.
    .DESCRIPTION
        Preference variables stop at a module boundary: a script run with -WhatIf
        calls a module function, and the function sees $WhatIfPreference = $false
        and makes the change. Same for -Verbose (the log stays quiet) and
        -Confirm:$false (a ConfirmImpact High function still prompts). This sets
        $PSDefaultParameterValues in the calling script for every function the
        repo's loaded modules export, so each call carries the switches without
        anyone remembering to pass them. Az cmdlets are left alone.
    .EXAMPLE
        Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'NetworkBuild' 'NetworkBuild.psd1') -Force
        Set-AzScriptDefault
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Sets parameter defaults in the caller; changes nothing outside the session.')]
    [CmdletBinding()]
    param()
    # $PSCmdlet.SessionState is the caller's (the script's), not this module's.
    $caller = $PSCmdlet.SessionState
    $whatIf  = [bool]$caller.PSVariable.GetValue('WhatIfPreference')
    $verbose = "$($caller.PSVariable.GetValue('VerbosePreference'))" -eq 'Continue'
    $noConfirm = "$($caller.PSVariable.GetValue('ConfirmPreference'))" -eq 'None'
    $existing = $caller.PSVariable.GetValue('PSDefaultParameterValues')
    $defaults = [System.Management.Automation.DefaultParameterDictionary]::new()
    if ($existing) { foreach ($k in @($existing.Keys)) { $defaults[$k] = $existing[$k] } }
    $modulesDir = Split-Path $PSScriptRoot -Parent
    foreach ($m in Get-Module | Where-Object { $_.ModuleBase -like "$modulesDir*" }) {
        foreach ($f in $m.ExportedFunctions.Keys) {
            $defaults["${f}:WhatIf"] = $whatIf
            $defaults["${f}:Verbose"] = $verbose
            if ($noConfirm) { $defaults["${f}:Confirm"] = $false }
        }
    }
    $caller.PSVariable.Set('PSDefaultParameterValues', $defaults)
}

Export-ModuleMember -Function Assert-AzContext, Assert-AzResourceProvider, Find-AzSubscriptionAcrossTenant, Get-AzEffectivePermission, Test-AzActionAllowed, Get-AzDirectoryRoleMembership, Set-AzScriptDefault
