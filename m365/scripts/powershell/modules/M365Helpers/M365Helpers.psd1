@{
    RootModule        = 'M365Helpers.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '3c1f8a6e-9b2d-4e7f-a1c5-7d0e2b4f9a63'
    Author            = 'Cloudwright contributors'
    Description       = 'Shared helpers for the Microsoft 365 administration scripts in this repo: settings, sign-in to a client tenant over GDAP, DNS lookups, passwords, Hudu.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Test-M365ReadOnly'
        'Assert-M365WriteAllowed'
        'Get-M365Settings'
        'Get-M365ClientConfig'
        'Resolve-M365TenantId'
        'Assert-M365Graph'
        'Assert-M365Exchange'
        'Disconnect-M365Tenant'
        'Resolve-DnsRecord'
        'New-StrongPassword'
        'Add-HuduPassword'
        'Write-M365Step'
        'Invoke-M365WithRetry'
        'New-M365CorrelationId'
        'Write-M365Log'
        'Get-M365ConfigPlaceholder'
        'Get-M365ConfigValue'
        'Set-M365ConfigValue'
        'Export-M365Csv'
        'Test-M365PasswordComplexity'
        'Read-M365Password'
        'Assert-M365SameTenant'
        'Get-M365ExchangeTenant'
        'New-M365Placeholder'
        'Format-M365Command'
        'Set-M365ChangeTarget'
        'Start-M365ChangeRecording'
        'Stop-M365ChangeRecording'
        'Invoke-M365Change'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('Microsoft365', 'Graph', 'ExchangeOnline', 'MSP')
        }
    }
}
