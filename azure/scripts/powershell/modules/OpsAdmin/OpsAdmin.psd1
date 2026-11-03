@{
    RootModule        = 'OpsAdmin.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '2d7a5e91-c43f-4b68-a0e2-8f1b6c3d9e54'
    Author            = 'Cloudwright contributors'
    Description       = 'Operations views: AVD across pools and from Log Analytics, diagnostic settings, Cost Management queries, estimate against actual, Activity Log, HTML reports. No deletes.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Get-OpsAvdSummary'
        'Get-OpsDiagnosticInfo'
        'Get-OpsLogWorkspaceInfo'
        'Get-OpsAvdInsight'
        'New-OpsLogWorkspace'
        'Set-OpsAvdDiagnostic'
        'Invoke-OpsCostQuery'
        'Get-OpsCost'
        'Get-OpsCostComparison'
        'Get-OpsActivityLog'
        'ConvertTo-OpsHtmlReport'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('Azure', 'AVD', 'LogAnalytics', 'CostManagement', 'ActivityLog', 'Reporting') } }
}
