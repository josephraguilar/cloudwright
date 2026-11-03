<#
.SYNOPSIS
    Run winget as SYSTEM inside a VM: search, list, install or upgrade.
.DESCRIPTION
    Runs through a managed Run Command, so as SYSTEM, where winget is not on the
    PATH: the App Installer package folder is found and winget.exe called from
    there. Search and list print one line per package as Name|Id|Version|Source
    after a line reading "---ROWS---", for the caller to parse.
    Windows 11 and Windows 10 multi-session have winget; Windows Server 2022 does
    not unless App Installer was added. Exit code 2 means winget was not found.
.PARAMETER Action
    Search, List, Install or Upgrade.
.PARAMETER Query
    Search text.
.PARAMETER Id
    Package IDs (comma separated) for Install or Upgrade.
.NOTES
    Status: Untested
#>
param(
    [ValidateSet('Search', 'List', 'Install', 'Upgrade')] [string]$Action = 'Search',
    [string]$Query = '',
    [string]$Id = ''
)
$ErrorActionPreference = 'Stop'
$winget = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps" -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -Directory -ErrorAction SilentlyContinue |
    Sort-Object { [version](($_.Name -split '_')[1]) } -Descending | ForEach-Object { Join-Path $_.FullName 'winget.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $winget) { $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue; if ($cmd) { $winget = $cmd.Source } }
if (-not $winget) { Write-Output 'winget was not found on this VM (App Installer is missing).'; exit 2 }
$common = @('--accept-source-agreements', '--disable-interactivity')

function ConvertFrom-WingetTable {
    # winget prints a fixed-width table; the header line gives the column starts.
    param([string[]]$Lines)
    $Lines = @($Lines | ForEach-Object { ($_ -replace '^[^\x20-\x7E]*', '').TrimEnd() } | Where-Object { $_ })
    $h = [array]::FindIndex([string[]]$Lines, [Predicate[string]] { param($l) $l -match '^Name\s+Id\s+Version' })
    if ($h -lt 0) { return }
    $header = $Lines[$h]
    $cols = foreach ($n in 'Name', 'Id', 'Version', 'Match', 'Available', 'Source') { $i = $header.IndexOf($n); if ($i -ge 0) { [pscustomobject]@{ Name = $n; Start = $i } } }
    $cols = @($cols | Sort-Object Start)
    foreach ($l in $Lines[($h + 2)..($Lines.Count - 1)]) {
        if ($l -match '^-+$' -or $l.Length -lt $cols[1].Start) { continue }
        $row = @{}
        for ($c = 0; $c -lt $cols.Count; $c++) {
            $s = $cols[$c].Start; $e = if ($c + 1 -lt $cols.Count) { $cols[$c + 1].Start } else { $l.Length }
            $row[$cols[$c].Name] = if ($s -lt $l.Length) { $l.Substring($s, [Math]::Min($e, $l.Length) - $s).Trim() } else { '' }
        }
        '{0}|{1}|{2}|{3}' -f $row['Name'], $row['Id'], $row['Version'], $(if ($row.ContainsKey('Source')) { $row['Source'] } else { '' })
    }
}

switch ($Action) {
    'Search' {
        $out = & $winget search --query $Query --count 40 @common 2>&1 | ForEach-Object { "$_" }
        '---ROWS---'; ConvertFrom-WingetTable -Lines $out
    }
    'List' {
        $out = & $winget list @common 2>&1 | ForEach-Object { "$_" }
        '---ROWS---'; ConvertFrom-WingetTable -Lines $out
    }
    default {
        $failed = 0
        foreach ($pkg in @($Id -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            $verb = if ($Action -eq 'Install') { 'install' } else { 'upgrade' }
            $out = & $winget $verb --id $pkg --exact --silent --scope machine --accept-package-agreements @common 2>&1 | ForEach-Object { "$_" }
            $code = $LASTEXITCODE
            # 0 = done; -1978335189 = no applicable upgrade; -1978335135 = already installed
            $ok = $code -in 0, -1978335189, -1978335135
            "$pkg`: $(if ($ok) { 'OK' } else { "FAILED ($code)" })"
            if (-not $ok) { $failed++; ($out | Select-Object -Last 5) -join "`n" }
        }
        if ($failed -gt 0) { exit 1 }
    }
}
