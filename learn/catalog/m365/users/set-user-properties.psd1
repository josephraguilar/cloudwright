@{
    Id      = 'm365.users.set-user-properties'
    Title   = 'Update a user''s profile fields'
    Summary = 'Sets job title, department, office, and phone. Blank fields are left unchanged.'
    Learn   = @(
        'Update-MgUser is a PATCH: only the parameters you pass change.'
        'Synced users (from AD) reject most of these; change them in AD and let Entra Connect sync.'
    )
    Requires = @{ Auth = 'Graph'; Modules = @('Microsoft.Graph.Users'); Scopes = @('User.ReadWrite.All'); Roles = @('User Administrator') }
    Prerequisites = @('m365.context.connect-graph')
    Fields = @(
        @{ Name = 'UserId'; Label = 'User'; Help = 'The user, by sign-in name (UPN). The list comes from Get-MgUser when you are signed in to Graph.'; Type = 'Choice'; Required = $true
           Source = @{ Cmdlet = 'Get-MgUser'; Parameters = @{ All = '$true' }; Display = 'UserPrincipalName'; Value = 'UserPrincipalName'; Auth = 'Graph' } }
        @{ Name = 'JobTitle'; Label = 'Job title'; Help = 'The job title shown on the profile card and in the address book.'; Type = 'String'; Required = $false }
        @{ Name = 'Department'; Label = 'Department'; Help = 'The department shown on the profile and usable in dynamic group rules.'; Type = 'String'; Required = $false }
        @{ Name = 'OfficeLocation'; Label = 'Office'; Help = 'Office or desk location shown on the profile.'; Type = 'String'; Required = $false }
        @{ Name = 'MobilePhone'; Label = 'Mobile phone'; Help = 'Mobile number shown on the profile. Also used by SSPR if configured.'; Type = 'String'; Required = $false }
        @{ Name = 'CompanyName'; Label = 'Company'; Help = 'Company shown on the profile.'; Type = 'String'; Required = $false }
    )
    Steps = @(
        @{
            Title      = 'Update the user'
            What       = 'PATCH with the fields you filled in.'
            Why        = 'One call, only the changed fields.'
            Cmdlet     = 'Update-MgUser'
            Parameters = @{ UserId = '{{UserId}}'; JobTitle = '{{JobTitle}}'; Department = '{{Department}}'; OfficeLocation = '{{OfficeLocation}}'; MobilePhone = '{{MobilePhone}}'; CompanyName = '{{CompanyName}}' }
            ParameterOrder = @('UserId', 'JobTitle', 'Department', 'OfficeLocation', 'MobilePhone', 'CompanyName')
        }
    )
    Verify = @('Get-MgUser -UserId {{UserId}} -Property DisplayName, JobTitle, Department, OfficeLocation, MobilePhone, CompanyName | Format-List DisplayName, JobTitle, Department, OfficeLocation, MobilePhone, CompanyName')
    Docs   = @('https://learn.microsoft.com/powershell/module/microsoft.graph.users/update-mguser')
    Status = 'Untested'
}
