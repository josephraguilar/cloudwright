<#
.SYNOPSIS
    Build Microsoft admin scripts (Azure, Microsoft 365, Entra ID) to review and run elsewhere.
.DESCRIPTION
    Run it with no arguments. On Windows it opens a window: task tree on the left, a
    drop-down or text box per field on the right, Generate at the bottom. Output is plain
    one-liners by default; tick "Explain steps" for the long form with comments.

    Sign-in is optional. Signed in, drop-downs load real resource groups, regions, VNets,
    groups, users (read-only lookups). Signed out, you type the values.

    It never runs a generated command. Copy the output into a separate window and run it
    one line at a time.
.PARAMETER Console
    Use the text menu instead of the window (also the fallback on macOS/Linux).
.PARAMETER NoSignIn
    Console only: skip the sign-in questions.
.PARAMETER Contoso
    Start in Contoso mode: a fictional tenant fills every drop-down and fields pre-fill with
    examples, so you can review and study without connecting to anything. The window has a
    button for the same.
.EXAMPLE
    ./Start-MsScripter.ps1
.EXAMPLE
    ./Start-MsScripter.ps1 -Console -NoSignIn
.NOTES
    Requires: PowerShell 5.1 or 7. Optional: Az.Accounts (+ Az.* for lookups),
              Microsoft.Graph.Authentication, Microsoft.PowerShell.ConsoleGuiTools (console pickers)
    Status:   Untested
#>
[CmdletBinding()]
param(
    [Parameter()] [switch]$Console,
    [Parameter()] [switch]$NoSignIn,
    [Parameter()] [switch]$Contoso
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Join-Path (Join-Path $PSScriptRoot 'src') 'MsScripter') 'MsScripter.psd1') -Force

$onWindows = $env:OS -eq 'Windows_NT'
if ($Console -or -not $onWindows) {
    Show-MsScripter -NoSignIn:$NoSignIn -Contoso:$Contoso
} else {
    Show-MsScripterWindow -Contoso:$Contoso
}
