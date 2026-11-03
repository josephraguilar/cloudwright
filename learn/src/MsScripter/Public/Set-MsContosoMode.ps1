function Set-MsContosoMode {
    <#
    .SYNOPSIS
        Turn Contoso mode on or off: pick lists filled from sample data instead of a live tenant.
    .DESCRIPTION
        Contoso mode is for review and study without signing in to anything. Every drop-down is
        served from catalog/_contoso.psd1 (a fictional tenant: contoso.com users, groups,
        subscriptions, resource groups, host pools, mailboxes, licence SKUs), fields pre-fill
        with their example values, and the script header names the Contoso subscription.
        Nothing about generation changes: the output is the same commands with sample names.
        Returns the sample Context hashtable when turning on, $null when turning off.
    .PARAMETER Off
        Turn Contoso mode off and go back to live lookups.
    .EXAMPLE
        Set-MsContosoMode
        Show-MsScripterWindow
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Flips an in-memory flag for this module. Changes nothing outside the process.')]
    [CmdletBinding()]
    param([Parameter()] [switch]$Off)
    $script:ContosoMode = -not $Off
    $script:SourceCache.Clear()
    if ($Off) { return $null }
    return @{} + (Get-MsSampleData).Context
}

function Get-MsContosoMode {
    <#
    .SYNOPSIS
        True when Contoso mode (sample data, no live lookups) is on.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return [bool]$script:ContosoMode
}
