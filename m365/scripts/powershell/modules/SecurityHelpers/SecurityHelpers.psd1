@{
    RootModule        = 'SecurityHelpers.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'f6b8c0d2-4e3a-4f7b-9c1d-0e2f3a4b5c6d'
    Author            = 'Cloudwright contributors'
    Description       = 'Tenant security baseline: collects facts from Graph and Exchange Online, compares them to a baseline file, and provides the idempotent remediations (audit logging, auto-forwarding, Security Defaults, external sender tag, SMTP AUTH).'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Get-M365SecurityBaseline'
        'Get-M365SecurityFact'
        'Compare-M365SecurityBaseline'
        'Enable-M365AuditLogging'
        'Set-M365AutoForwarding'
        'Set-M365SecurityDefault'
        'Set-M365ExternalSenderTag'
        'Set-M365SmtpAuth'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('Security', 'Baseline', 'MSP') } }
}
