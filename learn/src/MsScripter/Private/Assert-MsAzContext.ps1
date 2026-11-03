function Assert-MsAzContext {
    <#
    .SYNOPSIS
        Ensure an Az session exists for pick-list lookups. Adapted from azure/AzHelpers Assert-AzContext.
    .DESCRIPTION
        Reuses an existing Get-AzContext. Connects interactively only when there is none.
        Returns the context, or $null (with a warning) when Az.Accounts is not installed,
        so the UI can fall back to typed values. This is the ONLY place the tool signs in
        to Azure, and it never changes anything.
    .PARAMETER SubscriptionId
        Optional subscription to switch to.
    .PARAMETER TenantId
        Optional tenant for a fresh sign-in.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [string]$SubscriptionId,
        [Parameter()] [string]$TenantId
    )
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-Warning 'Az.Accounts is not installed, so Azure pick lists are off. Install-Module Az -Scope CurrentUser to enable them. You can still type values.'
        return $null
    }
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) {
        $connectParams = @{}
        if ($TenantId)       { $connectParams.Tenant = $TenantId }
        if ($SubscriptionId) { $connectParams.Subscription = $SubscriptionId }
        $null = Connect-AzAccount @connectParams
        $context = Get-AzContext
    }
    if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
        $context = Set-AzContext -Subscription $SubscriptionId
    }
    return $context
}
