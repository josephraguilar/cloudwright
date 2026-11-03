@{
    RootModule        = 'ExchangeHelpers.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '8e4b2c71-5d3a-4f6e-9a0b-1c2d3e4f5a6b'
    Author            = 'Cloudwright contributors'
    Description       = 'Reusable Exchange Online and mail-authentication logic: mail contacts, distribution lists, shared mailboxes, aliases, folders, inbox rules, templated mail, SPF/DKIM/DMARC analysis.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Get-SpfAnalysis'
        'Get-DmarcAnalysis'
        'Get-M365DkimStatus'
        'Enable-M365Dkim'
        'New-M365MailContact'
        'New-M365DistributionList'
        'Add-M365DistributionListMember'
        'New-M365SharedMailbox'
        'Add-M365MailboxAlias'
        'New-M365MailboxFolder'
        'New-M365InboxRule'
        'Format-M365Template'
        'Send-M365TemplateMail'
        'Test-M365ExternalAddress'
        'Get-M365ForwardingAudit'
        'Get-M365MailboxPermissionAudit'
        'ConvertTo-M365SharedMailbox'
        'Set-M365MailboxForwarding'
        'Add-M365MailboxPermission'
        'Set-M365MailboxAutoReply'
        'Set-M365MailboxRegionalConfig'
        'Get-M365ExactRecipient'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('ExchangeOnline', 'SPF', 'DKIM', 'DMARC', 'MSP') } }
}
