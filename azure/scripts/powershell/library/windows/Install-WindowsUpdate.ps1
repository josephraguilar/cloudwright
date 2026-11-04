<#
.SYNOPSIS
    Install pending Windows updates (software, not drivers) with the Windows Update
    agent; restart afterwards only when asked.
.PARAMETER Restart
    yes to restart when an update needs it. Default no.
.NOTES
    Status: Untested
    Can run for a long time. Drain AVD hosts first.
#>
param([string]$Restart = 'no')
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

$session = New-Object -ComObject Microsoft.Update.Session
$found = $session.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Software' and IsHidden=0").Updates
if ($found.Count -eq 0) { 'No updates pending.'; exit 0 }
$list = New-Object -ComObject Microsoft.Update.UpdateColl
foreach ($u in $found) { if (-not $u.EulaAccepted) { $u.AcceptEula() }; [void]$list.Add($u); "Pending: $($u.Title)" }
$dl = $session.CreateUpdateDownloader(); $dl.Updates = $list; [void]$dl.Download()
$inst = $session.CreateUpdateInstaller(); $inst.Updates = $list
$r = $inst.Install()
"Result code $($r.ResultCode) (2 = succeeded, 3 = succeeded with errors); reboot required: $($r.RebootRequired)"
if ($r.RebootRequired -and $Restart -eq 'yes') { 'Restarting in 60 seconds.'; shutdown.exe /r /t 60 /c 'Windows updates installed' }
if ($r.ResultCode -notin 2, 3) { exit 1 }
