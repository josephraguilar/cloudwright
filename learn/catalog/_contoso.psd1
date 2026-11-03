@{
    # Contoso mode: sample data for every pick list, so the tool can be used offline for
    # review and study. Keyed by the lookup cmdlet named in a field's Source. Rows carry the
    # properties the catalog's Display/Value settings read, plus the properties lookups
    # filter on (ResourceGroupName, HostPoolName, Location) so scoped lists behave.
    # Everything here is fictional. Names follow Microsoft's own demo tenant (contoso.com).
    # Loaded by Get-MsSampleData; the catalog loader skips files starting with an underscore.

    Context = @{
        TenantId         = 'c0a70500-c0de-4c0d-8000-000000000000'
        TenantDomain     = 'contoso.onmicrosoft.com'
        SubscriptionName = 'Contoso Production'
        SubscriptionId   = 'c0a70500-5ab5-4000-8000-000000000001'
        Account          = 'admin@contoso.onmicrosoft.com'
    }

    'Get-AzSubscription' = @(
        @{ Name = 'Contoso Production'; Id = 'c0a70500-5ab5-4000-8000-000000000001'; TenantId = 'c0a70500-c0de-4c0d-8000-000000000000'; State = 'Enabled' }
        @{ Name = 'Contoso Dev-Test';   Id = 'c0a70500-5ab5-4000-8000-000000000002'; TenantId = 'c0a70500-c0de-4c0d-8000-000000000000'; State = 'Enabled' }
    )
    'Get-AzLocation' = @(
        @{ DisplayName = 'East US 2';      Location = 'eastus2' }
        @{ DisplayName = 'East US';        Location = 'eastus' }
        @{ DisplayName = 'Central US';     Location = 'centralus' }
        @{ DisplayName = 'West US 3';      Location = 'westus3' }
        @{ DisplayName = 'Canada Central'; Location = 'canadacentral' }
        @{ DisplayName = 'North Europe';   Location = 'northeurope' }
        @{ DisplayName = 'West Europe';    Location = 'westeurope' }
        @{ DisplayName = 'UK South';       Location = 'uksouth' }
        @{ DisplayName = 'Australia East'; Location = 'australiaeast' }
    )
    'Get-AzResourceGroup' = @(
        @{ ResourceGroupName = 'rg-contoso-avd-prod'; Location = 'eastus2'; ResourceId = '/subscriptions/c0a70500-5ab5-4000-8000-000000000001/resourceGroups/rg-contoso-avd-prod' }
        @{ ResourceGroupName = 'rg-contoso-avd-lab';  Location = 'eastus2'; ResourceId = '/subscriptions/c0a70500-5ab5-4000-8000-000000000001/resourceGroups/rg-contoso-avd-lab' }
        @{ ResourceGroupName = 'rg-contoso-network';  Location = 'eastus2'; ResourceId = '/subscriptions/c0a70500-5ab5-4000-8000-000000000001/resourceGroups/rg-contoso-network' }
        @{ ResourceGroupName = 'rg-contoso-shared';   Location = 'eastus2'; ResourceId = '/subscriptions/c0a70500-5ab5-4000-8000-000000000001/resourceGroups/rg-contoso-shared' }
        @{ ResourceGroupName = 'rg-contoso-mgmt';     Location = 'eastus2'; ResourceId = '/subscriptions/c0a70500-5ab5-4000-8000-000000000001/resourceGroups/rg-contoso-mgmt' }
    )
    'Get-AzVirtualNetwork' = @(
        @{ Name = 'vnet-contoso-hub';      ResourceGroupName = 'rg-contoso-network';  Location = 'eastus2' }
        @{ Name = 'vnet-contoso-avd-prod'; ResourceGroupName = 'rg-contoso-avd-prod'; Location = 'eastus2' }
        @{ Name = 'vnet-contoso-avd-lab';  ResourceGroupName = 'rg-contoso-avd-lab';  Location = 'eastus2' }
    )
    'Get-AzNetworkSecurityGroup' = @(
        @{ Name = 'nsg-avd-hosts'; ResourceGroupName = 'rg-contoso-avd-prod' }
        @{ Name = 'nsg-avd-lab';   ResourceGroupName = 'rg-contoso-avd-lab' }
        @{ Name = 'nsg-mgmt';      ResourceGroupName = 'rg-contoso-mgmt' }
    )
    'Get-AzPublicIpAddress' = @(
        @{ Name = 'pip-vm-jump-01'; ResourceGroupName = 'rg-contoso-mgmt' }
        @{ Name = 'pip-bastion';    ResourceGroupName = 'rg-contoso-network' }
    )
    'Get-AzNetworkInterface' = @(
        @{ Name = 'vm-jump-01-nic';  ResourceGroupName = 'rg-contoso-mgmt' }
        @{ Name = 'vm-dc-01-nic';    ResourceGroupName = 'rg-contoso-shared' }
        @{ Name = 'avd-prod-01-nic'; ResourceGroupName = 'rg-contoso-avd-prod' }
        @{ Name = 'avd-prod-02-nic'; ResourceGroupName = 'rg-contoso-avd-prod' }
        @{ Name = 'avd-lab-01-nic';  ResourceGroupName = 'rg-contoso-avd-lab' }
    )
    'Get-AzVM' = @(
        @{ Name = 'vm-jump-01';  ResourceGroupName = 'rg-contoso-mgmt';     Location = 'eastus2' }
        @{ Name = 'vm-dc-01';    ResourceGroupName = 'rg-contoso-shared';   Location = 'eastus2' }
        @{ Name = 'avd-prod-01'; ResourceGroupName = 'rg-contoso-avd-prod'; Location = 'eastus2' }
        @{ Name = 'avd-prod-02'; ResourceGroupName = 'rg-contoso-avd-prod'; Location = 'eastus2' }
        @{ Name = 'avd-lab-01';  ResourceGroupName = 'rg-contoso-avd-lab';  Location = 'eastus2' }
    )
    'Get-AzVMSize' = @(
        @{ Name = 'Standard_B2s' }
        @{ Name = 'Standard_B2ms' }
        @{ Name = 'Standard_D2s_v5' }
        @{ Name = 'Standard_D4s_v5' }
        @{ Name = 'Standard_D8s_v5' }
        @{ Name = 'Standard_D16s_v5' }
        @{ Name = 'Standard_E4s_v5' }
        @{ Name = 'Standard_F4s_v2' }
    )
    'Get-AzDisk' = @(
        @{ Name = 'vm-jump-01_OsDisk_1_6f1d2c3b';  ResourceGroupName = 'rg-contoso-mgmt' }
        @{ Name = 'vm-dc-01_OsDisk_1_9a8b7c6d';    ResourceGroupName = 'rg-contoso-shared' }
        @{ Name = 'vm-dc-01-data-01';              ResourceGroupName = 'rg-contoso-shared' }
        @{ Name = 'avd-prod-01_OsDisk_1_1a2b3c4d'; ResourceGroupName = 'rg-contoso-avd-prod' }
        @{ Name = 'avd-prod-02_OsDisk_1_5e6f7a8b'; ResourceGroupName = 'rg-contoso-avd-prod' }
        @{ Name = 'avd-lab-01_OsDisk_1_0c1d2e3f';  ResourceGroupName = 'rg-contoso-avd-lab' }
    )
    'Get-AzStorageAccount' = @(
        @{ StorageAccountName = 'stcontosoprofprod01'; ResourceGroupName = 'rg-contoso-avd-prod' }
        @{ StorageAccountName = 'stcontosoproflab01';  ResourceGroupName = 'rg-contoso-avd-lab' }
        @{ StorageAccountName = 'stcontososcripts';    ResourceGroupName = 'rg-contoso-shared' }
    )
    'Get-AzKeyVault' = @(
        @{ VaultName = 'kv-contoso-prod-01'; ResourceGroupName = 'rg-contoso-shared' }
        @{ VaultName = 'kv-contoso-lab-01';  ResourceGroupName = 'rg-contoso-avd-lab' }
    )
    'Get-AzRecoveryServicesVault' = @(
        @{ Name = 'rsv-contoso-prod'; ResourceGroupName = 'rg-contoso-mgmt' }
    )
    'Get-AzADGroup' = @(
        @{ DisplayName = 'AVD Users - Production'; Id = 'a7d00001-0000-4000-8000-000000000001' }
        @{ DisplayName = 'AVD Users - Lab';        Id = 'a7d00001-0000-4000-8000-000000000002' }
        @{ DisplayName = 'AVD Admins';             Id = 'a7d00001-0000-4000-8000-000000000003' }
        @{ DisplayName = 'IT Helpdesk';            Id = 'a7d00001-0000-4000-8000-000000000004' }
        @{ DisplayName = 'Sales';                  Id = 'a7d00001-0000-4000-8000-000000000005' }
        @{ DisplayName = 'Finance';                Id = 'a7d00001-0000-4000-8000-000000000006' }
        @{ DisplayName = 'Break Glass Accounts';   Id = 'a7d00001-0000-4000-8000-000000000007' }
    )
    'Get-AzRoleDefinition' = @(
        @{ Name = 'Reader' }
        @{ Name = 'Contributor' }
        @{ Name = 'Owner' }
        @{ Name = 'User Access Administrator' }
        @{ Name = 'Virtual Machine Contributor' }
        @{ Name = 'Network Contributor' }
        @{ Name = 'Storage Account Contributor' }
        @{ Name = 'Storage Blob Data Contributor' }
        @{ Name = 'Storage File Data SMB Share Contributor' }
        @{ Name = 'Key Vault Secrets User' }
        @{ Name = 'Key Vault Secrets Officer' }
        @{ Name = 'Backup Contributor' }
        @{ Name = 'Desktop Virtualization User' }
        @{ Name = 'Desktop Virtualization Contributor' }
        @{ Name = 'Virtual Machine User Login' }
        @{ Name = 'Virtual Machine Administrator Login' }
    )
    'Get-AzWvdHostPool' = @(
        @{ Name = 'hp-contoso-prod'; ResourceGroupName = 'rg-contoso-avd-prod'; HostPoolType = 'Pooled' }
        @{ Name = 'hp-contoso-lab';  ResourceGroupName = 'rg-contoso-avd-lab';  HostPoolType = 'Pooled' }
    )
    'Get-AzWvdApplicationGroup' = @(
        @{ Name = 'hp-contoso-prod-DAG'; ResourceGroupName = 'rg-contoso-avd-prod' }
        @{ Name = 'hp-contoso-lab-DAG';  ResourceGroupName = 'rg-contoso-avd-lab' }
    )
    'Get-AzWvdSessionHost' = @(
        @{ Name = 'hp-contoso-prod/avd-prod-01'; ResourceGroupName = 'rg-contoso-avd-prod'; HostPoolName = 'hp-contoso-prod'; Status = 'Available' }
        @{ Name = 'hp-contoso-prod/avd-prod-02'; ResourceGroupName = 'rg-contoso-avd-prod'; HostPoolName = 'hp-contoso-prod'; Status = 'Available' }
        @{ Name = 'hp-contoso-lab/avd-lab-01';   ResourceGroupName = 'rg-contoso-avd-lab';  HostPoolName = 'hp-contoso-lab';  Status = 'Available' }
    )

    'Get-MgUser' = @(
        @{ DisplayName = 'Adele Vance';      UserPrincipalName = 'adele.vance@contoso.com';      Id = 'a5e00001-0000-4000-8000-000000000001' }
        @{ DisplayName = 'Alex Wilber';      UserPrincipalName = 'alex.wilber@contoso.com';      Id = 'a5e00001-0000-4000-8000-000000000002' }
        @{ DisplayName = 'Diego Siciliani';  UserPrincipalName = 'diego.siciliani@contoso.com';  Id = 'a5e00001-0000-4000-8000-000000000003' }
        @{ DisplayName = 'Grady Archie';     UserPrincipalName = 'grady.archie@contoso.com';     Id = 'a5e00001-0000-4000-8000-000000000004' }
        @{ DisplayName = 'Isaiah Langer';    UserPrincipalName = 'isaiah.langer@contoso.com';    Id = 'a5e00001-0000-4000-8000-000000000005' }
        @{ DisplayName = 'Lee Gu';           UserPrincipalName = 'lee.gu@contoso.com';           Id = 'a5e00001-0000-4000-8000-000000000006' }
        @{ DisplayName = 'Lidia Holloway';   UserPrincipalName = 'lidia.holloway@contoso.com';   Id = 'a5e00001-0000-4000-8000-000000000007' }
        @{ DisplayName = 'Megan Bowen';      UserPrincipalName = 'megan.bowen@contoso.com';      Id = 'a5e00001-0000-4000-8000-000000000008' }
        @{ DisplayName = 'Nestor Wilke';     UserPrincipalName = 'nestor.wilke@contoso.com';     Id = 'a5e00001-0000-4000-8000-000000000009' }
        @{ DisplayName = 'Patti Fernandez';  UserPrincipalName = 'patti.fernandez@contoso.com';  Id = 'a5e00001-0000-4000-8000-000000000010' }
        @{ DisplayName = 'Pradeep Gupta';    UserPrincipalName = 'pradeep.gupta@contoso.com';    Id = 'a5e00001-0000-4000-8000-000000000011' }
        @{ DisplayName = 'MOD Administrator'; UserPrincipalName = 'admin@contoso.onmicrosoft.com'; Id = 'a5e00001-0000-4000-8000-000000000012' }
        @{ DisplayName = 'Break Glass 01';   UserPrincipalName = 'breakglass01@contoso.onmicrosoft.com'; Id = 'a5e00001-0000-4000-8000-000000000013' }
    )
    'Get-MgGroup' = @(
        @{ DisplayName = 'AVD Users - Production'; Id = 'a7d00001-0000-4000-8000-000000000001'; MailNickname = 'avd-users-prod' }
        @{ DisplayName = 'AVD Users - Lab';        Id = 'a7d00001-0000-4000-8000-000000000002'; MailNickname = 'avd-users-lab' }
        @{ DisplayName = 'AVD Admins';             Id = 'a7d00001-0000-4000-8000-000000000003'; MailNickname = 'avd-admins' }
        @{ DisplayName = 'IT Helpdesk';            Id = 'a7d00001-0000-4000-8000-000000000004'; MailNickname = 'it-helpdesk' }
        @{ DisplayName = 'Sales';                  Id = 'a7d00001-0000-4000-8000-000000000005'; MailNickname = 'sales' }
        @{ DisplayName = 'Finance';                Id = 'a7d00001-0000-4000-8000-000000000006'; MailNickname = 'finance' }
        @{ DisplayName = 'Break Glass Accounts';   Id = 'a7d00001-0000-4000-8000-000000000007'; MailNickname = 'break-glass' }
        @{ DisplayName = 'All Company';            Id = 'a7d00001-0000-4000-8000-000000000008'; MailNickname = 'allcompany' }
        @{ DisplayName = 'Project Falcon';         Id = 'a7d00001-0000-4000-8000-000000000009'; MailNickname = 'project-falcon' }
        @{ DisplayName = 'MFA Pilot';              Id = 'a7d00001-0000-4000-8000-000000000010'; MailNickname = 'mfa-pilot' }
    )
    'Get-MgSubscribedSku' = @(
        @{ SkuPartNumber = 'SPE_E3';                SkuId = '05e9a617-0261-4cee-bb44-138d3ef5d965'; ConsumedUnits = 184 }
        @{ SkuPartNumber = 'SPE_E5';                SkuId = '06ebc4ee-1bb5-47dd-8120-11324bc54e06'; ConsumedUnits = 12 }
        @{ SkuPartNumber = 'O365_BUSINESS_PREMIUM'; SkuId = 'f245ecc8-75af-4f8e-b61f-27d8114de5f3'; ConsumedUnits = 25 }
        @{ SkuPartNumber = 'SPB';                   SkuId = 'cbdc14ab-d96c-4c30-b9f4-6ada7cdc1d46'; ConsumedUnits = 40 }
        @{ SkuPartNumber = 'EXCHANGESTANDARD';      SkuId = '4b9405b0-7788-4568-add1-99614e613b69'; ConsumedUnits = 6 }
        @{ SkuPartNumber = 'AAD_PREMIUM';           SkuId = '078d2b04-f1bd-4111-bbd4-b4b1b354cef4'; ConsumedUnits = 200 }
        @{ SkuPartNumber = 'EMS';                   SkuId = 'efccb6f7-5641-4e0e-bd10-b4976e1bf68e'; ConsumedUnits = 50 }
    )
    'Get-MgDirectoryRoleTemplate' = @(
        @{ DisplayName = 'Global Administrator';            Id = '62e90394-69f5-4237-9190-012177145e10' }
        @{ DisplayName = 'Global Reader';                   Id = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451' }
        @{ DisplayName = 'User Administrator';              Id = 'fe930be7-5e62-47db-91af-98c3a49a38b1' }
        @{ DisplayName = 'Helpdesk Administrator';          Id = '729827e3-9c14-49f7-bb1b-9608f156bbb8' }
        @{ DisplayName = 'Password Administrator';          Id = '966707d0-3269-4727-9be2-8c3a10f19b9d' }
        @{ DisplayName = 'Groups Administrator';            Id = 'fdd7a751-b60b-444a-984c-02652fe8fa1c' }
        @{ DisplayName = 'License Administrator';           Id = '4d6ac14f-3453-41d0-bef9-a3e0c569773a' }
        @{ DisplayName = 'Exchange Administrator';          Id = '29232cdf-9323-42fd-ade2-1d097af3e4de' }
        @{ DisplayName = 'Intune Administrator';            Id = '3a2c62db-5318-420d-8d74-23affee5d9d5' }
        @{ DisplayName = 'Conditional Access Administrator'; Id = 'b1be1c3e-b65d-4f19-8427-f6fa0d97feb9' }
        @{ DisplayName = 'Security Reader';                 Id = '5d6b6bb7-de71-4623-b4af-96380a352509' }
        @{ DisplayName = 'Application Administrator';       Id = '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3' }
    )
    'Get-EXOMailbox' = @(
        @{ DisplayName = 'Adele Vance';     UserPrincipalName = 'adele.vance@contoso.com';     PrimarySmtpAddress = 'adele.vance@contoso.com';     RecipientTypeDetails = 'UserMailbox' }
        @{ DisplayName = 'Alex Wilber';     UserPrincipalName = 'alex.wilber@contoso.com';     PrimarySmtpAddress = 'alex.wilber@contoso.com';     RecipientTypeDetails = 'UserMailbox' }
        @{ DisplayName = 'Diego Siciliani'; UserPrincipalName = 'diego.siciliani@contoso.com'; PrimarySmtpAddress = 'diego.siciliani@contoso.com'; RecipientTypeDetails = 'UserMailbox' }
        @{ DisplayName = 'Grady Archie';    UserPrincipalName = 'grady.archie@contoso.com';    PrimarySmtpAddress = 'grady.archie@contoso.com';    RecipientTypeDetails = 'UserMailbox' }
        @{ DisplayName = 'Lidia Holloway';  UserPrincipalName = 'lidia.holloway@contoso.com';  PrimarySmtpAddress = 'lidia.holloway@contoso.com';  RecipientTypeDetails = 'UserMailbox' }
        @{ DisplayName = 'Megan Bowen';     UserPrincipalName = 'megan.bowen@contoso.com';     PrimarySmtpAddress = 'megan.bowen@contoso.com';     RecipientTypeDetails = 'UserMailbox' }
        @{ DisplayName = 'Patti Fernandez'; UserPrincipalName = 'patti.fernandez@contoso.com'; PrimarySmtpAddress = 'patti.fernandez@contoso.com'; RecipientTypeDetails = 'UserMailbox' }
        @{ DisplayName = 'Support';         UserPrincipalName = 'support@contoso.com';         PrimarySmtpAddress = 'support@contoso.com';         RecipientTypeDetails = 'SharedMailbox' }
        @{ DisplayName = 'Sales Inbox';     UserPrincipalName = 'sales@contoso.com';           PrimarySmtpAddress = 'sales@contoso.com';           RecipientTypeDetails = 'SharedMailbox' }
    )
}
