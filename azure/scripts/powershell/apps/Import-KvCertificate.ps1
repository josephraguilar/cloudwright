<#
.SYNOPSIS
    Import a PFX into an Azure Key Vault as a certificate.
.DESCRIPTION
    An existing certificate name gets a new version; the old version stays.
.PARAMETER SubscriptionId
    Subscription of the vault.
.PARAMETER VaultName
    Key Vault name.
.PARAMETER Name
    Certificate name in the vault (letters, digits, hyphens).
.PARAMETER FilePath
    The .pfx file.
.PARAMETER Password
    The PFX password.
.EXAMPLE
    ./Import-KvCertificate.ps1 -SubscriptionId <sub> -VaultName kv-certs -Name wildcard-2026 -FilePath .\wildcard.pfx -Password (Read-Host -AsSecureString)
.NOTES
    Requires: Az.Accounts, Az.KeyVault
    Status:   Untested
    Roles:    Key Vault Certificates Officer on the vault.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$VaultName,
    [Parameter(Mandatory)] [string]$Name,
    [Parameter(Mandatory)] [string]$FilePath,
    [Parameter(Mandatory)] [securestring]$Password
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AzHelpers' 'AzHelpers.psd1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'AppDeploy' 'AppDeploy.psd1') -Force -Verbose:$false
Set-AzScriptDefault   # module functions do not inherit -WhatIf, -Verbose or -Confirm from a script; this hands them on
$null = Assert-AzContext -SubscriptionId $SubscriptionId
Import-KvCertificate -VaultName $VaultName -Name $Name -FilePath $FilePath -Password $Password
