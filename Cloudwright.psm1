#region 1. Locate the toolkit -------------------------------------------------
# WHAT The installed module records the checkout location as data.
# WHY Tenant settings and generated files stay with the checkout through updates.
Set-StrictMode -Version Latest
$script:ToolkitRoot = $PSScriptRoot
$locationFile = Join-Path $PSScriptRoot 'Cloudwright.location.json'
if (Test-Path -LiteralPath $locationFile) {
    $location = Get-Content -LiteralPath $locationFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($location.Tool -ne 'Cloudwright' -or $location.SchemaVersion -ne 1 -or
        -not [IO.Path]::IsPathRooted($location.RepositoryRoot)) {
        throw 'Invalid Cloudwright installation record. Run Install-Cloudwright.ps1 -Force from your checkout.'
    }
    $script:ToolkitRoot = $location.RepositoryRoot
}
$script:ToolkitVersion = (Import-PowerShellDataFile (Join-Path $PSScriptRoot 'Cloudwright.psd1')).ModuleVersion
#endregion

#region 2. Run an existing entry point -----------------------------------------
# WHAT Each area runs in a fresh PowerShell process with literal arguments.
# WHY Its module/session state and exit behavior cannot alter the caller's session.
function Invoke-CloudwrightProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ScriptPath,
        [Parameter()] [string[]]$ScriptArguments = @(),
        [Parameter()] [switch]$Sta
    )
    $executable = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    $processArguments = @('-NoLogo', '-NoProfile')
    if ($Sta) { $processArguments += '-STA' }
    $processArguments += @('-File', $ScriptPath)
    $processArguments += $ScriptArguments
    # Handle a failed native process ourselves, including on PowerShell 7.3+.
    $PSNativeCommandUseErrorActionPreference = $false
    & $executable @processArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Cloudwright's selected tool exited with code $LASTEXITCODE. See its error above."
    }
}
#endregion

#region 3. Public command ------------------------------------------------------
function Start-Cloudwright {
    <#
    .SYNOPSIS
        Open the Cloudwright menu or launch its Learn, Azure/AVD, or Microsoft 365 area.
    .DESCRIPTION
        Run cloudwright from any directory after installing with Install-Cloudwright.ps1.
        Each area starts in a separate PowerShell process. Windows uses the existing
        desktop interface by default; -Console and other platforms use a text menu.
        Learn builds commands for you to read and copy. It never runs generated commands.
        Azure/AVD opens a read-only console of reviewed inspections; its administration
        scripts stay disabled. Microsoft 365 permits reviewed reads only.
        Opening the top-level menu, help, or version does not sign in or install dependencies.
        -WhatIf previews which entry point would open; it does not run an area's tenant plan.
    .PARAMETER Area
        menu (default), learn, azure, m365, help, or version.
    .PARAMETER Console
        Use a text interface, including on Windows.
    .PARAMETER Contoso
        Learn only: use fictional offline data without any sign-in.
    .PARAMETER NoSignIn
        Learn only: skip optional sign-in prompts in its console interface.
    .PARAMETER Setup
        Microsoft 365 only: rerun its existing dependency and local-settings setup.
        The Microsoft 365 launcher also offers setup when dependencies/settings are missing.
    .PARAMETER TenantId
        Azure only: the tenant GUID to sign in to. Prompted for when omitted.
    .PARAMETER SubscriptionId
        Azure only: the subscription GUID to open. Choose one after sign-in when omitted.
    .PARAMETER DeviceCode
        Azure only: sign in with a device code instead of a browser window.
    .EXAMPLE
        cloudwright
    .EXAMPLE
        cloudwright learn -Contoso -Console
    .EXAMPLE
        cloudwright azure
    .EXAMPLE
        cloudwright m365 -Console
    .NOTES
        Requires: PowerShell 7. Desktop interfaces require Windows.
        Status: Local automated checks; live tenant operations retain their component status.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive launcher menu for the operator.')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [ValidateSet('menu', 'learn', 'azure', 'm365', 'help', 'version')]
        [string]$Area = 'menu',
        [Parameter()] [switch]$Console,
        [Parameter()] [switch]$Contoso,
        [Parameter()] [switch]$NoSignIn,
        [Parameter()] [switch]$Setup,
        [Parameter()]
        [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
        [string]$TenantId,
        [Parameter()]
        [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
        [string]$SubscriptionId,
        [Parameter()] [switch]$DeviceCode
    )

    # WHAT Reject flags for a different area before prompting, signing in, or launching.
    $allowed = switch ($Area) {
        'learn' { @('Console', 'Contoso', 'NoSignIn') }
        'azure' { @('Console', 'TenantId', 'SubscriptionId', 'DeviceCode') }
        'm365'  { @('Console', 'Setup') }
        'menu'  { @('Console') }
        default { @() }
    }
    foreach ($name in 'Console', 'Contoso', 'NoSignIn', 'Setup', 'TenantId', 'SubscriptionId', 'DeviceCode') {
        if ($PSBoundParameters.ContainsKey($name) -and $name -notin $allowed) {
            throw "-$name is not supported for '$Area'. Run cloudwright help for usage."
        }
    }
    if ($Area -eq 'help') { Get-Help Start-Cloudwright -Full; return }
    if ($Area -eq 'version') { $script:ToolkitVersion; return }

    if ($Area -eq 'menu') {
        Write-Host ''
        Write-Host 'Cloudwright' -ForegroundColor Cyan
        Write-Host '  1. Learn Microsoft commands'
        Write-Host '  2. Azure and AVD (SAFE MODE: read-only)'
        Write-Host '  3. Manage Microsoft 365 (SAFE MODE: read-only)'
        Write-Host '  Q. Quit'
        while ($Area -eq 'menu') {
            $choice = "$(Read-Host 'Choose an area')".Trim().ToLowerInvariant()
            switch ($choice) {
                { $_ -in '1', 'learn' } { $Area = 'learn'; break }
                { $_ -in '2', 'azure' } { $Area = 'azure'; break }
                { $_ -in '3', 'm365' }  { $Area = 'm365'; break }
                { $_ -in '', 'q', 'quit', 'exit' } { return }
                default { Write-Host 'Choose 1, 2, 3, or Q.' }
            }
        }
    }

    # WHAT Azure/AVD always uses the read-only console. Its legacy desktop interface
    #      and administration scripts stay blocked.
    $useConsole = $Console -or -not $IsWindows -or $Area -eq 'azure'
    $scriptArguments = @()
    switch ($Area) {
        'learn' {
            $relativePath = 'learn/Start-MsScripter.ps1'
            if ($useConsole) { $scriptArguments += '-Console' }
            if ($Contoso) { $scriptArguments += '-Contoso' }
            if ($NoSignIn) { $scriptArguments += '-NoSignIn' }
        }
        'azure' {
            $relativePath = 'azure/readonly/Start-AzureReadOnly.ps1'
            if ($TenantId) { $scriptArguments += @('-TenantId', $TenantId) }
            if ($SubscriptionId) { $scriptArguments += @('-SubscriptionId', $SubscriptionId) }
            if ($DeviceCode) { $scriptArguments += '-UseDeviceAuthentication' }
        }
        'm365' {
            $relativePath = 'm365/Start-Toolkit.ps1'
            if ($useConsole) { $scriptArguments += '-Console' }
            if ($Setup) { $scriptArguments += '-Setup' }
        }
    }
    $entryPoint = Join-Path $script:ToolkitRoot $relativePath
    if (-not (Test-Path -LiteralPath $entryPoint -PathType Leaf)) {
        throw "Cloudwright could not find '$entryPoint'. If the checkout moved, run Install-Cloudwright.ps1 -Force from its new location."
    }
    if ($PSCmdlet.ShouldProcess($entryPoint, "Open Cloudwright $Area in a separate PowerShell process")) {
        Invoke-CloudwrightProcess -ScriptPath $entryPoint -ScriptArguments $scriptArguments -Sta:($IsWindows -and -not $useConsole)
    }
}

Set-Alias -Name cloudwright -Value Start-Cloudwright
Export-ModuleMember -Function Start-Cloudwright -Alias cloudwright
#endregion
