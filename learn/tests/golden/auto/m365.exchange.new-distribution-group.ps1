New-DistributionGroup -Name 'All Sales' -Alias 'all-sales' -PrimarySmtpAddress 'all-sales@contoso.com' -Members @('sample-one', 'sample-two')
Set-DistributionGroup -Identity 'all-sales@contoso.com' -RequireSenderAuthenticationEnabled $false
