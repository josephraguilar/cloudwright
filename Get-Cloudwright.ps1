#Requires -Version 7.0
<#
.SYNOPSIS
    Download Cloudwright, install its command, and open the menu.
.DESCRIPTION
    Designed to run as downloaded text, including Invoke-RestMethod | Invoke-Expression.
    Downloads a complete snapshot on first use without Git or administrator rights.
    Later runs reuse that snapshot so local settings and output remain in place.
    The public download needs no GitHub account or token.
.PARAMETER InstallPath
    Persistent toolkit directory. Defaults to Cloudwright/toolkit in your user data directory.
.PARAMETER ModulePath
    Optional parent module directory, forwarded to Install-Cloudwright.ps1.
.PARAMETER NoLaunch
    Install the command without opening the menu.
.PARAMETER Console
    Prefer the text interface when opening a tool from the menu.
.EXAMPLE
    ./Get-Cloudwright.ps1 -NoLaunch
.EXAMPLE
    ./Get-Cloudwright.ps1 -WhatIf
.NOTES
    Requires: PowerShell 7. Status: Local automated checks; no tenant access.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Download and installation progress for the operator.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parameters are used inside the child scope that isolates IEX preferences.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()] [string]$InstallPath,
    [Parameter()] [string]$ModulePath,
    [Parameter()] [switch]$NoLaunch,
    [Parameter()] [switch]$Console
)

# Keep preferences and working variables out of the caller's IEX scope.
& {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw 'Cloudwright requires PowerShell 7. Open pwsh and run the command there.'
    }

    if (-not $InstallPath) {
        $dataRoot = if ($IsWindows) {
            [Environment]::GetFolderPath('LocalApplicationData')
        } elseif ($env:XDG_DATA_HOME) {
            $env:XDG_DATA_HOME
        } else {
            Join-Path $HOME '.local/share'
        }
        if (-not $dataRoot) { throw 'Could not locate your user data directory. Specify -InstallPath.' }
        $InstallPath = Join-Path $dataRoot 'Cloudwright/toolkit'
    }
    $destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallPath)
    $markerName = 'Cloudwright.download.json'
    $markerPath = Join-Path $destination $markerName
    $requiredFiles = @(
        'Cloudwright.psd1', 'Cloudwright.psm1', 'Install-Cloudwright.ps1',
        'learn/Start-MsScripter.ps1', 'azure/scripts/powershell/Start-AvdConsole.ps1',
        'm365/Start-Toolkit.ps1',
        'm365/scripts/powershell/modules/M365Helpers/Safety.ps1'
    )

    # Only reuse our own complete snapshot. Never overwrite a checkout or arbitrary folder.
    $reuse = Test-Path -LiteralPath $destination
    if ($reuse) {
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
            throw "'$destination' is not a Cloudwright download. Choose a new -InstallPath or run Install-Cloudwright.ps1 from your existing checkout."
        }
        $record = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        if ($record.Tool -ne 'Cloudwright' -or $record.SchemaVersion -ne 1 -or
            $record.Commit -notmatch '^[0-9a-f]{40}$') {
            throw "Unrecognized Cloudwright download record at '$markerPath'. Choose a new -InstallPath."
        }
        if (-not $record.PSObject.Properties['SafetyBaseline'] -or $record.SafetyBaseline -ne 3) {
            throw 'This cached Cloudwright snapshot predates mandatory Cloudwright safe mode. It will not be launched. Keep your local settings and install the reviewed release into a NEW -InstallPath.'
        }
        foreach ($file in $requiredFiles) {
            if (-not (Test-Path -LiteralPath (Join-Path $destination $file) -PathType Leaf)) {
                throw "Incomplete Cloudwright download: missing $file. Choose a new -InstallPath; keep this directory's local settings."
            }
        }
    }
    $action = if ($reuse) { 'Register the existing Cloudwright snapshot' } else { 'Download and install Cloudwright from GitHub' }
    if (-not $PSCmdlet.ShouldProcess($destination, $action)) { return }

    if (-not $reuse) {
        $request = @{
            Headers = @{ Accept = 'application/vnd.github+json' }
            UserAgent = 'Cloudwright-Bootstrap'
            ErrorAction = 'Stop'
        }

        # Stage beside the destination so moving the validated snapshot stays on one volume.
        $parent = Split-Path -Parent $destination
        $null = New-Item -ItemType Directory -Path $parent -Force
        $staging = Join-Path $parent ('.cloudwright-download-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $staging
        try {
            $api = 'https://api.github.com/repos/josephraguilar/cloudwright'
            try {
                $head = Invoke-RestMethod -Uri "$api/commits/main" @request
                if ($head.sha -notmatch '^[0-9a-f]{40}$') { throw 'Invalid commit response.' }
                $archive = Join-Path $staging 'cloudwright.zip'
                Write-Host "Downloading Cloudwright ($($head.sha.Substring(0, 7)))..."
                # Use the same immutable commit for the whole toolkit. GitHub supplies the archive redirect.
                Invoke-WebRequest -Uri "$api/zipball/$($head.sha)" -OutFile $archive @request
            } catch {
                throw 'Could not download Cloudwright from GitHub. Check your connection and try again later; anonymous GitHub requests are rate limited.'
            }
            $expanded = Join-Path $staging 'expanded'
            Expand-Archive -LiteralPath $archive -DestinationPath $expanded
            $roots = @(Get-ChildItem -LiteralPath $expanded -Force)
            if ($roots.Count -ne 1 -or -not $roots[0].PSIsContainer) { throw 'The Cloudwright archive has an unexpected layout.' }
            $source = $roots[0].FullName
            foreach ($file in $requiredFiles) {
                if (-not (Test-Path -LiteralPath (Join-Path $source $file) -PathType Leaf)) {
                    throw "Incomplete Cloudwright archive: missing $file."
                }
            }
            $manifest = Import-PowerShellDataFile (Join-Path $source 'Cloudwright.psd1')
            if ($manifest.PrivateData['CloudwrightSafetyBaseline'] -ne 3) {
                throw 'This archive predates mandatory Cloudwright safe mode. It will not be installed or launched.'
            }
            [ordered]@{
                Tool = 'Cloudwright'; SchemaVersion = 1; SafetyBaseline = 3
                Commit = $head.sha
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $source $markerName) -Encoding utf8
            # Directory.Move fails if another invocation created the destination in the meantime.
            [IO.Directory]::Move($source, $destination)
        } finally {
            Remove-Item -LiteralPath $staging -Recurse -Force
            $request.Clear()
        }
    } else {
        Write-Host "Using Cloudwright at $destination"
    }

    $installOptions = @{ Force = $true }
    if ($ModulePath) { $installOptions.ModulePath = $ModulePath }
    & (Join-Path $destination 'Install-Cloudwright.ps1') @installOptions
    if (-not $NoLaunch) { Cloudwright\Start-Cloudwright -Console:$Console }
}
