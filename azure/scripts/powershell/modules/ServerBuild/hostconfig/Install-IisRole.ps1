<#
.SYNOPSIS
    Runs INSIDE a VM: installs IIS with the management console and ASP.NET 4.8,
    and puts a plain index page in place so the first browse proves the install.
.NOTES
    The Web-Server role enables the "World Wide Web Services" Windows Firewall
    rules itself. Nothing is opened on the NSG; that is a network decision.
#>
param(
    [string]$SiteTitle = 'IIS is running'
)
# Mandatory release block: no Azure initialization, authentication, or administration.
& { $ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }

$ErrorActionPreference = 'Stop'
$features = 'Web-Server', 'Web-Mgmt-Console', 'Web-Asp-Net45', 'Web-Http-Logging', 'Web-Static-Content', 'Web-Default-Doc', 'Web-Http-Errors', 'Web-Dir-Browsing'
$result = Install-WindowsFeature -Name $features -IncludeManagementTools
"Features: $($result.FeatureResult.Name -join ', ') (restart needed: $($result.RestartNeeded))"
$page = "<!doctype html><html><head><title>$SiteTitle</title></head><body style='font-family:sans-serif'><h1>$SiteTitle</h1><p>$env:COMPUTERNAME, $(Get-Date -Format u)</p></body></html>"
Set-Content -Path 'C:\inetpub\wwwroot\index.html' -Value $page -Encoding UTF8
Import-Module WebAdministration
$docs = Get-WebConfigurationProperty -Filter 'system.webServer/defaultDocument/files' -Name Collection -PSPath 'IIS:\' | Select-Object -ExpandProperty value
if ($docs -notcontains 'index.html') {
    Add-WebConfigurationProperty -Filter 'system.webServer/defaultDocument/files' -Name Collection -Value @{ value = 'index.html' } -AtIndex 0 -PSPath 'IIS:\'
}
Start-Service W3SVC -ErrorAction SilentlyContinue
"W3SVC: $((Get-Service W3SVC).Status). Browse to http://$env:COMPUTERNAME/ from inside the network."
