@{
    Id      = 'path.azure.avd-entra-lab'
    Title   = 'AVD lab, Entra-joined, from nothing'
    Summary = 'Providers, group, network, profile storage with Entra Kerberos, host pool, app group, workspace, user access, token, one session host. The azure repo''s environment-build-path as one script.'
    Tasks   = @(
        'azure.context.register-providers', 'azure.create.resource-group', 'azure.network.new-vnet',
        'azure.storage.new-storage-account', 'azure.storage.new-file-share', 'azure.storage.enable-entra-kerberos',
        'azure.avd.new-host-pool', 'azure.avd.new-application-group', 'azure.avd.new-workspace', 'azure.avd.grant-desktop-access',
        'azure.avd.new-registration-token', 'azure.avd.new-session-host'
    )
    Share   = @{ ResourceGroupName = 'Name' }
}
