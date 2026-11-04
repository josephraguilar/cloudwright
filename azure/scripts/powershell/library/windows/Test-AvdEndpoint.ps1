<#
.SYNOPSIS
    Check that a session host can reach the AVD service endpoints on 443.
.DESCRIPTION
    A host that cannot reach these shows Unavailable or NeedsAssistance. Failures
    usually mean a firewall, proxy or NSG rule. Exit 1 when any check fails.
.NOTES
    Status: Untested
#>
param()
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

$targets = 'rdbroker.wvd.microsoft.com', 'rdweb.wvd.microsoft.com', 'catalogartifact.azureedge.net', 'login.microsoftonline.com', 'mrsglobalsteus2prod.blob.core.windows.net', 'wvdportalstorageblob.blob.core.windows.net', 'gcs.prod.monitoring.core.windows.net'
$failed = 0
foreach ($t in $targets) {
    $ok = $false
    try { $c = [System.Net.Sockets.TcpClient]::new(); $ok = $c.ConnectAsync($t, 443).Wait(5000); $c.Dispose() } catch { $ok = $false }
    if (-not $ok) { $failed++ }
    '{0,-45} {1}' -f $t, $(if ($ok) { 'reachable' } else { 'NOT reachable' })
}
if ($failed -gt 0) { exit 1 }
