<#
.SYNOPSIS
    Import a certificate into the local machine store inside a VM.
.DESCRIPTION
    The certificate arrives base64-encoded as a protected Run Command parameter,
    with its password (for a PFX) the same way; neither is logged. A .cer has no
    private key and no password.
.PARAMETER CertificateBase64
    The .pfx or .cer file content, base64.
.PARAMETER PfxPassword
    Password of a PFX. Empty for a .cer.
.PARAMETER StoreName
    My (Personal), Root (Trusted Root), CA (Intermediate) or TrustedPublisher.
.NOTES
    Status: Untested
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'PfxPassword', Justification = 'Run Command delivers protected parameters as strings; it never reaches a log.')]
param(
    [Parameter(Mandatory)] [string]$CertificateBase64,
    [string]$PfxPassword = '',
    [ValidateSet('My', 'Root', 'CA', 'TrustedPublisher')] [string]$StoreName = 'My'
)
# Mandatory release block: no Azure initialization, authentication, or administration.
throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.'

$ErrorActionPreference = 'Stop'
$bytes = [Convert]::FromBase64String($CertificateBase64)
$flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]'MachineKeySet, PersistKeySet'
$cert = if ($PfxPassword) { [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes, $PfxPassword, $flags) }
        else { [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes) }
$store = [System.Security.Cryptography.X509Certificates.X509Store]::new($StoreName, 'LocalMachine')
$store.Open('ReadWrite')
try {
    $already = @($store.Certificates | Where-Object Thumbprint -eq $cert.Thumbprint).Count -gt 0
    if (-not $already) { $store.Add($cert) }
} finally { $store.Close() }
"$(if ($already) { 'Already in' } else { 'Imported into' }) LocalMachine\$StoreName`: $($cert.Subject) (thumbprint $($cert.Thumbprint), expires $($cert.NotAfter.ToString('yyyy-MM-dd')))"
