<#
.SYNOPSIS
    One-time setup: PowerShell modules, local config files, optional WebView2. Safe to re-run.
.DESCRIPTION
    Does everything a fresh clone needs before the first run:

      1. Checks PowerShell 7. If the CurrentUser execution policy is Restricted or Undefined it
         sets RemoteSigned; it never weakens AllSigned (it tells you instead).
      2. Installs the Microsoft Graph submodules the scripts use (not the whole SDK) and
         ExchangeOnlineManagement at or above the minimum versions, after you approve the list.
         It does not change the PSGallery trust setting, and Install-Module's publisher
         (Authenticode) checks stay on.
      3. Creates config/*.local.json from the examples when missing, then asks for every
         value that is still a <placeholder>. Enter to keep a placeholder for later.
      4. Optionally downloads one pinned version of the Microsoft.Web.WebView2 package, checks
         its SHA-512 against the value recorded here and the DLLs' Microsoft signature, and
         places the three files the GUI needs in scripts/powershell/gui/lib/webview2.

    With -WhatIf nothing is installed, created or downloaded, nothing is asked, and every
    line says what would happen.

    Start-Toolkit.ps1 calls this automatically when something is missing.
.PARAMETER SkipModules
    Do not install or check PowerShell modules.
.PARAMETER SkipWebView2
    Do not offer the WebView2 download.
.PARAMETER NonInteractive
    Never prompt. Placeholders are left as they are and WebView2 is skipped.
.EXAMPLE
    ./Install-Toolkit.ps1
.NOTES
    Requires: PowerShell 7, internet access to the PowerShell Gallery (and nuget.org for WebView2)
    Status:   Untested
#>

#region 1. Parameters ---------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive setup. Output is for the operator.')]
param(
    [Parameter()]
    [switch]$SkipModules,

    [Parameter()]
    [switch]$SkipWebView2,

    [Parameter()]
    [switch]$NonInteractive
)
#endregion

#region 2. Setup --------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
Import-Module (Join-Path $repoRoot 'scripts' 'powershell' 'modules' 'M365Helpers' 'M365Helpers.psd1') -Force
function Write-Head { param([string]$t) Write-Host ''; Write-Host $t -ForegroundColor White }
function Write-Ok { param([string]$t) Write-Host "  [ok]   $t" -ForegroundColor Green }
function Write-Do { param([string]$t) Write-Host "  [..]   $t" -ForegroundColor Cyan }
function Write-Skip { param([string]$t) Write-Host "  [skip] $t" -ForegroundColor DarkGray }
function Write-Would { param([string]$t) Write-Host "  [would] $t" -ForegroundColor Cyan }
#   WHY    -WhatIf must not ask questions or claim it did something.
$askable = -not $NonInteractive -and -not $WhatIfPreference
Write-Host ''
Write-Host '365-MGMT setup' -ForegroundColor White
#endregion

#region 3. PowerShell and policy -------------------------------------------------
Write-Head 'PowerShell'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw "PowerShell 7 is required (this is $($PSVersionTable.PSVersion)). Install with: winget install Microsoft.PowerShell" }
Write-Ok "PowerShell $($PSVersionTable.PSVersion)"
if ($IsWindows) {
    $policy = Get-ExecutionPolicy -Scope CurrentUser
    if ($policy -eq 'AllSigned') {
        Write-Skip 'Execution policy is AllSigned and is left as it is. These scripts are not signed: run them under a policy you choose (for example RemoteSigned) or sign them.'
    } elseif ($policy -in 'Restricted', 'Undefined') {
        if ($PSCmdlet.ShouldProcess('CurrentUser execution policy', 'Set to RemoteSigned')) { Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force; Write-Ok 'Execution policy set to RemoteSigned for your user' }
        else { Write-Would 'set the CurrentUser execution policy to RemoteSigned' }
    } else { Write-Ok "Execution policy $policy" }
}
#endregion

#region 4. Modules --------------------------------------------------------------------
#   WHY    The full Microsoft.Graph meta-module is hundreds of MB and takes a long time.
#          The scripts only use these submodules.
Write-Head 'PowerShell modules'
#   GOTCHA Minimum versions: Graph SDK 2.x (v1.0 cmdlets the scripts call) and
#          ExchangeOnlineManagement 3.x (REST cmdlets, Get-ConnectionInformation).
$required = [ordered]@{
    'Microsoft.Graph.Authentication' = '2.0.0'; 'Microsoft.Graph.Users' = '2.0.0'; 'Microsoft.Graph.Users.Actions' = '2.0.0'; 'Microsoft.Graph.Groups' = '2.0.0'
    'Microsoft.Graph.Mail' = '2.0.0'; 'Microsoft.Graph.Identity.DirectoryManagement' = '2.0.0'; 'Microsoft.Graph.Identity.Governance' = '2.0.0'
    'Microsoft.Graph.Identity.SignIns' = '2.0.0'; 'Microsoft.Graph.Identity.Partner' = '2.0.0'; 'ExchangeOnlineManagement' = '3.0.0'
}
if ($SkipModules) {
    Write-Skip 'Module check skipped'
} else {
    $missing = @($required.Keys | Where-Object { -not (Get-Module -ListAvailable -Name $_ | Where-Object { $_.Version -ge [version]$required[$_] }) })
    foreach ($name in $required.Keys | Where-Object { $missing -notcontains $_ }) { Write-Ok $name }
    if ($missing.Count -gt 0) {
        Write-Host "  To install from the PowerShell Gallery (publisher checks on, PSGallery trust setting unchanged):" -ForegroundColor Gray
        foreach ($name in $missing) { Write-Host "    $name  (>= $($required[$name]))" -ForegroundColor Gray }
        $go = if ($askable) { Read-Host '  Install these now? (y/n) [y]' } elseif ($NonInteractive -and -not $WhatIfPreference) { 'y' } else { 'n' }
        if ([string]::IsNullOrWhiteSpace($go) -or $go -eq 'y') {
            foreach ($name in $missing) {
                if ($PSCmdlet.ShouldProcess("$name (>= $($required[$name]))", 'Install-Module -Scope CurrentUser from PSGallery')) {
                    Write-Do "Installing $name"
                    Install-Module -Name $name -MinimumVersion $required[$name] -Repository PSGallery -Scope CurrentUser -Force -AllowClobber
                    Write-Ok $name
                } else { Write-Would "install $name (>= $($required[$name]))" }
            }
        } else { Write-Skip 'Modules not installed; the scripts that need them will say so.' }
    }
}
#endregion

#region 5. Config files -----------------------------------------------------------------
#   WHAT   Copy examples to *.local.json if missing; ask for each remaining placeholder.
#   WHY    The example files are tracked and hold <placeholders>; the local ones are
#          gitignored and hold the real values. Enter keeps a placeholder for later.
Write-Head 'Configuration'
$pairs = @(
    @{ Example = 'config/msp.settings.example.json'; Local = 'config/msp.settings.local.json'; Hints = @{
            'msp.adminUpn'     = 'Your partner account UPN (the one you sign in to Microsoft 365 with, e.g. you@msp.example)'
            'msp.supportEmail' = 'Support mailbox clients and alerts should reach (e.g. support@msp.example)'
        } }
    @{ Example = 'config/gdap-roles.example.json'; Local = 'config/gdap-roles.local.json'; Hints = @{
            'groups[0].id' = 'Object ID of the security group in our tenant that receives the GDAP roles (Admin Agents by default). Leave blank to fill later with entra/Get-M365Group.ps1'
            'groups[1].id' = 'Object ID of a second (lower-privilege) security group, if your template has one'
        } }
)
foreach ($pair in $pairs) {
    $local = Join-Path $repoRoot $pair.Local
    if (-not (Test-Path $local)) {
        if ($PSCmdlet.ShouldProcess($pair.Local, "Create from $($pair.Example)")) { Copy-Item (Join-Path $repoRoot $pair.Example) $local; Write-Ok "Created $($pair.Local)" }
        else { Write-Would "create $($pair.Local) from $($pair.Example)"; continue }
    } else { Write-Ok "$($pair.Local) exists" }
    #   WHAT   When the tracked example has grown a real default for a key the local file
    #          still has as a placeholder, take the default instead of asking.
    #   WHY    Defaults get added over time (support mailbox, partner tenant, GDAP group);
    #          a local file created earlier should pick them up without retyping.
    $example = Join-Path $repoRoot $pair.Example
    foreach ($key in @(Get-M365ConfigPlaceholder -Path $local)) {
        $default = Get-M365ConfigValue -Path $example -Key $key
        if ($null -ne $default -and "$default" -notmatch '^<.*>$' -and "$default" -ne '') {
            Set-M365ConfigValue -Path $local -Key $key -Value "$default" -WhatIf:$WhatIfPreference
            if ($WhatIfPreference) { Write-Would "set $key from the example default ($default)" } else { Write-Ok "$key set from the example default ($default)" }
        }
    }
    $placeholders = @(Get-M365ConfigPlaceholder -Path $local)
    if ($placeholders.Count -eq 0) { Write-Ok 'No placeholders left'; continue }
    if (-not $askable) { Write-Skip "$($placeholders.Count) placeholder(s) left in $($pair.Local): $($placeholders -join ', ')"; continue }
    foreach ($key in $placeholders) {
        $hint = if ($pair.Hints.ContainsKey($key)) { $pair.Hints[$key] } else { $key }
        Write-Host ''
        Write-Host "  $hint" -ForegroundColor Gray
        $answer = Read-Host "  $key"
        if ([string]::IsNullOrWhiteSpace($answer)) { Write-Skip "$key left as placeholder"; continue }
        Set-M365ConfigValue -Path $local -Key $key -Value $answer.Trim() -WhatIf:$WhatIfPreference
        Write-Ok "$key set"
    }
}
#endregion

#region 6. WebView2 (optional) ---------------------------------------------------------
#   WHAT   Download ONE pinned version of the NuGet package (a zip), check its SHA-512 against
#          the value nuget.org published for it (recorded below), check the DLLs carry a valid
#          Microsoft signature, then copy the three files the GUI needs.
#   WHY    These DLLs are loaded into the GUI process, which holds partner tokens. Nothing
#          unverified goes there. Without them the GUI uses a private browser window instead.
#   GOTCHA The .NET (Core) build lives in lib_manual/netcoreapp3.0; lib/ only has net462, the
#          .NET Framework build, which is not the one PowerShell 7 should load.
#          To move to a newer version: take the version's packageHash from
#          https://api.nuget.org/v3/registration5-semver1/microsoft.web.webview2/index.json
#          (catalog entry, SHA512, base64) and update both values together.
$webView2Version = '1.0.4191.47'
$webView2Sha512 = 'rfkb2hpx2GDAmM0OQmtaI44Yfqc8aUgy+P3jaAmpFl/aiET8nCufyKhwsNpTzZ65fsFA2aLxBKIoMB/66EHbjA=='
Write-Head 'WebView2 (in-app approval window, optional)'
$webView2Dir = Join-Path $repoRoot 'scripts' 'powershell' 'gui' 'lib' 'webview2'
$needed = @('Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.Wpf.dll', 'WebView2Loader.dll')
$have = @($needed | Where-Object { Test-Path (Join-Path $webView2Dir $_) })
if ($have.Count -eq $needed.Count) {
    Write-Ok 'WebView2 assemblies present'
} elseif ($SkipWebView2 -or -not $askable -or -not $IsWindows) {
    if ($WhatIfPreference -and $IsWindows -and -not $SkipWebView2) { Write-Would "offer to download Microsoft.Web.WebView2 $webView2Version (SHA-512 and signature checked)" }
    else { Write-Skip 'WebView2 download skipped; the GUI will use a private browser window' }
} else {
    $go = Read-Host "  Download Microsoft.Web.WebView2 $webView2Version from nuget.org now (checked against its published SHA-512)? (y/n) [y]"
    if (([string]::IsNullOrWhiteSpace($go) -or $go -eq 'y') -and $PSCmdlet.ShouldProcess("nuget.org Microsoft.Web.WebView2 $webView2Version", 'Download, verify and extract')) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "webview2-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $tmp -Force
        try {
            $nupkg = Join-Path $tmp 'webview2.zip'
            Write-Do 'Downloading'
            Invoke-WebRequest -Uri "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$webView2Version/microsoft.web.webview2.$webView2Version.nupkg" -OutFile $nupkg -UseBasicParsing
            $sha = [Convert]::ToBase64String([System.Security.Cryptography.SHA512]::HashData([IO.File]::ReadAllBytes($nupkg)))
            if ($sha -ne $webView2Sha512) { throw "WebView2 package hash does not match the published value; nothing was installed. Expected $webView2Sha512, got $sha." }
            Write-Ok 'Package SHA-512 matches the published value'
            Expand-Archive -Path $nupkg -DestinationPath (Join-Path $tmp 'pkg') -Force
            $files = @(
                (Join-Path $tmp 'pkg' 'lib_manual' 'netcoreapp3.0' 'Microsoft.Web.WebView2.Core.dll'),
                (Join-Path $tmp 'pkg' 'lib_manual' 'netcoreapp3.0' 'Microsoft.Web.WebView2.Wpf.dll'),
                (Join-Path $tmp 'pkg' 'runtimes' 'win-x64' 'native' 'WebView2Loader.dll')
            )
            foreach ($f in $files) {
                if (-not (Test-Path $f)) { throw "Expected file missing from the package: $f. Nothing was installed." }
                $sig = Get-AuthenticodeSignature -FilePath $f
                if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
                    throw "$(Split-Path $f -Leaf) is not validly signed by Microsoft (status $($sig.Status)); nothing was installed."
                }
            }
            Write-Ok 'DLL signatures valid (Microsoft Corporation)'
            $null = New-Item -ItemType Directory -Path $webView2Dir -Force
            foreach ($f in $files) { Copy-Item $f $webView2Dir -Force }
            $license = Get-ChildItem (Join-Path $tmp 'pkg') -Filter 'LICENSE*' -Recurse | Select-Object -First 1
            if ($license) { Copy-Item $license.FullName $webView2Dir -Force }
            Write-Ok "WebView2 $webView2Version assemblies placed in $webView2Dir"
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else { Write-Skip 'WebView2 skipped; the GUI will use a private browser window' }
}
#endregion

#region 7. Summary ------------------------------------------------------------------------
Write-Head 'Done'
$left = @()
foreach ($pair in $pairs) { $local = Join-Path $repoRoot $pair.Local; if (Test-Path $local) { $left += @(Get-M365ConfigPlaceholder -Path $local | ForEach-Object { "$($pair.Local): $_" }) } }
if ($left.Count -gt 0) {
    Write-Host '  Still placeholders (fill when you have them; read-only features work without):' -ForegroundColor Yellow
    foreach ($l in $left) { Write-Host "    $l" -ForegroundColor Yellow }
}
Write-Host '  Launch:  .\Start-Toolkit.ps1           (GUI)' -ForegroundColor Gray
Write-Host '           .\Start-Toolkit.ps1 -Console  (menu)' -ForegroundColor Gray
Write-Host ''
#endregion
