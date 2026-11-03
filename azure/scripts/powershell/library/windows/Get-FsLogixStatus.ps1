<#
.SYNOPSIS
    FSLogix on this host: installed version, service state, profile settings, and
    profile errors from the last day.
.NOTES
    Status: Untested
#>
param()
$svc = Get-Service frxsvc -ErrorAction SilentlyContinue
"Service: $(if ($svc) { $svc.Status } else { 'not installed' })"
$exe = Join-Path $env:ProgramFiles 'FSLogix\Apps\frx.exe'
if (Test-Path $exe) { "Version: $((Get-Item $exe).VersionInfo.ProductVersion)" }
$cfg = Get-ItemProperty 'HKLM:\SOFTWARE\FSLogix\Profiles' -ErrorAction SilentlyContinue
if ($cfg) {
    foreach ($n in 'Enabled', 'VHDLocations', 'VolumeType', 'SizeInMBs', 'DeleteLocalProfileWhenVHDShouldApply', 'FlipFlopProfileDirectoryName', 'IsDynamic') {
        if ($cfg.PSObject.Properties[$n]) { "$n = $(@($cfg.$n) -join '; ')" }
    }
} else { 'No FSLogix profile settings (HKLM\SOFTWARE\FSLogix\Profiles).' }
Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-FSLogix-Apps/Operational'; Level = 2; StartTime = (Get-Date).AddDays(-1) } -MaxEvents 20 -ErrorAction SilentlyContinue |
    ForEach-Object { '{0:yyyy-MM-dd HH:mm} {1}' -f $_.TimeCreated, (($_.Message -split "`n")[0]).Trim() }
