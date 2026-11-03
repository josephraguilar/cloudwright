<#
.SYNOPSIS
    The one command. Sets up what is missing, then opens the GUI (or the console menu).
.DESCRIPTION
    Checks for the local settings file and the PowerShell modules. If anything is missing it
    runs Install-Toolkit.ps1 first (which asks for the two or three values it cannot know),
    then launches scripts/powershell/gui/Start-M365Gui.ps1 in an STA PowerShell, or the
    console menu with -Console.
.PARAMETER Console
    Open the text menu (Start-M365Console.ps1) instead of the GUI. Works on any OS.
.PARAMETER Setup
    Run the setup even if nothing looks missing (re-check modules, re-ask placeholders).
.EXAMPLE
    .\Start-Toolkit.ps1
.EXAMPLE
    .\Start-Toolkit.ps1 -Console
.NOTES
    Requires: PowerShell 7
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Launcher messages for the operator.')]
param(
    [Parameter()]
    [switch]$Console,

    [Parameter()]
    [switch]$Setup
)
#endregion

#region 2. Decide whether setup is needed ------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$settingsPath = Join-Path $repoRoot 'config' 'msp.settings.local.json'
$coreModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Identity.Partner', 'ExchangeOnlineManagement')
$missingModules = @($coreModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) })
#   WHAT   Setup is needed when modules are missing, or the settings file is absent or
#          still fails validation (a placeholder left from an older example).
Import-Module (Join-Path $repoRoot 'scripts' 'powershell' 'modules' 'M365Helpers' 'M365Helpers.psd1') -Force
$settingsProblem = $null
if (Test-Path $settingsPath) { try { $null = Get-M365Settings -Path $settingsPath -Force } catch { $settingsProblem = $_.Exception.Message } }
else { $settingsProblem = 'no settings file yet' }
$needSetup = $Setup -or $settingsProblem -or $missingModules.Count -gt 0
if ($needSetup) {
    Write-Host ''
    $why = @(); if ($missingModules.Count -gt 0) { $why += "missing modules: $($missingModules -join ', ')" }; if ($settingsProblem) { $why += "settings: $settingsProblem" }
    Write-Host "Setup needed$(if ($why) { " ($($why -join '; '))" })" -ForegroundColor White
    & (Join-Path $repoRoot 'Install-Toolkit.ps1')
    $null = Get-M365Settings -Path $settingsPath -Force
}
#endregion

#region 3. Launch -------------------------------------------------------------------------
#   GOTCHA WPF needs an STA thread. pwsh.exe is STA by default on Windows, but if this was
#          started with -MTA or from another host, relaunch the GUI in a fresh STA pwsh.
if ($Console -or -not $IsWindows) {
    if (-not $IsWindows -and -not $Console) { Write-Host 'GUI needs Windows; opening the console menu instead.' -ForegroundColor Yellow }
    & (Join-Path $repoRoot 'scripts' 'powershell' 'Start-M365Console.ps1')
} else {
    $gui = Join-Path $repoRoot 'scripts' 'powershell' 'gui' 'Start-M365Gui.ps1'
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') {
        & $gui
    } else {
        Start-Process pwsh -ArgumentList '-STA', '-NoLogo', '-File', "`"$gui`"" -Wait
    }
}
#endregion
