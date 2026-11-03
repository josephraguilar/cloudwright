@{
    RootModule        = 'OnboardingHelpers.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'c9e2f4a6-7b1d-4c3e-9f5a-2b4d6e8f0a1c'
    Author            = 'Cloudwright contributors'
    Description       = 'Turns a client config into the ordered onboarding checklist (which steps apply, which script runs each one, which stay manual) and records what a run did.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Get-OnboardingPlan'
        'Get-OnboardingGraphScopes'
        'Save-OnboardingRunRecord'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('Onboarding', 'MSP') } }
}
