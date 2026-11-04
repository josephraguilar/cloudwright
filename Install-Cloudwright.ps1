#Requires -Version 7.0
<#
.SYNOPSIS
    Install the cloudwright PowerShell command for the current user.
.DESCRIPTION
    Copies the launcher module and a checkout-location record into your user module
    directory. The three tools remain in this checkout, including their local settings.
    No profile edits, administrator rights, tenant connections, or cloud modules are needed.
    Keep the checkout in a permanent location. Rerun with -Force after moving it or
    updating the launcher. Get-Help Start-Cloudwright explains the available areas.
.PARAMETER ModulePath
    Parent module directory. Defaults to the current user's PowerShell 7 module directory.
    A custom directory must be on PSModulePath for discovery in future sessions.
.PARAMETER Force
    Update a launcher previously installed by this script. Other files are preserved.
.EXAMPLE
    ./Install-Cloudwright.ps1
.EXAMPLE
    ./Install-Cloudwright.ps1 -Force
.EXAMPLE
    ./Install-Cloudwright.ps1 -WhatIf
.NOTES
    Requires: PowerShell 7.
    Status: Local automated checks; no tenant access.
#>

#region 1. Parameters and paths -----------------------------------------------
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Installation result and next command for the operator.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()] [string]$ModulePath,
    [Parameter()] [switch]$Force
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ModulePath) {
    if ($IsWindows) {
        $documents = [Environment]::GetFolderPath('MyDocuments')
        if (-not $documents) { throw 'Could not locate Documents. Pass -ModulePath with your user PowerShell module directory.' }
        $ModulePath = Join-Path $documents 'PowerShell/Modules'
    } else {
        $dataRoot = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $HOME '.local/share' }
        $ModulePath = Join-Path $dataRoot 'powershell/Modules'
    }
}
$moduleBase = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ModulePath)
$destination = Join-Path $moduleBase 'Cloudwright'
$markerPath = Join-Path $destination 'Cloudwright.location.json'
$sourceRoot = (Get-Item -LiteralPath $PSScriptRoot).FullName
if ($destination.TrimEnd([IO.Path]::DirectorySeparatorChar) -eq $sourceRoot.TrimEnd([IO.Path]::DirectorySeparatorChar)) {
    throw 'The installation directory must be different from the source checkout.'
}
foreach ($required in 'Cloudwright.psd1', 'Cloudwright.psm1', 'learn/Start-MsScripter.ps1', 'azure/readonly/Start-AzureReadOnly.ps1', 'm365/Start-Toolkit.ps1', 'm365/scripts/powershell/modules/M365Helpers/Safety.ps1') {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $required) -PathType Leaf)) {
        throw "Incomplete Cloudwright checkout: missing $required."
    }
}
$manifest = Import-PowerShellDataFile (Join-Path $sourceRoot 'Cloudwright.psd1')
if ($manifest.PrivateData['CloudwrightSafetyBaseline'] -ne 3) {
    throw 'This checkout predates mandatory Cloudwright safe mode. Use the reviewed release.'
}
#endregion

#region 2. Check ownership before updating ------------------------------------
# WHAT Only replace an installation carrying our own location record.
# WHY A module with the same name might belong to a different project.
if (Test-Path -LiteralPath $destination) {
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw "An existing directory at '$destination' is not a Cloudwright launcher installation. Choose another -ModulePath."
    }
    $previous = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    if ($previous.Tool -ne 'Cloudwright' -or $previous.SchemaVersion -ne 1) {
        throw "The existing installation record at '$markerPath' is not recognized."
    }
    if (-not $Force) { throw 'Cloudwright is already installed. Use -Force to update its launcher and checkout location.' }
}
#endregion

#region 3. Register the launcher ----------------------------------------------
# WHAT Install just the launcher; keep source, private settings, and output in place.
if ($PSCmdlet.ShouldProcess($destination, 'Install the Cloudwright launcher for this checkout')) {
    $null = New-Item -ItemType Directory -Path $destination -Force
    foreach ($file in 'Cloudwright.psd1', 'Cloudwright.psm1') {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $file) -Destination (Join-Path $destination $file) -Force
    }
    [ordered]@{ Tool = 'Cloudwright'; SchemaVersion = 1; RepositoryRoot = $sourceRoot } |
        ConvertTo-Json | Set-Content -LiteralPath $markerPath -Encoding utf8
    Import-Module (Join-Path $destination 'Cloudwright.psd1') -Global -Force
    Write-Host "Cloudwright installed. Run: cloudwright" -ForegroundColor Green
    if ($moduleBase -notin ($env:PSModulePath -split [IO.Path]::PathSeparator)) {
        Write-Warning "Add '$moduleBase' to PSModulePath to use this custom installation in new PowerShell sessions."
    }
}
#endregion
