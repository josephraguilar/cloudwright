@('Microsoft.Compute', 'Microsoft.Network') | ForEach-Object { Register-AzResourceProvider -ProviderNamespace $_ }

New-AzResourceGroup -Name 'rg-avd-lab' -Location 'eastus2' -Tag @{ env = 'lab' }

New-AzVirtualNetwork -Name 'vnet-avd-lab' -ResourceGroupName 'rg-avd-lab' -Location 'eastus2' -AddressPrefix '10.10.0.0/16' -Subnet (New-AzVirtualNetworkSubnetConfig -Name 'snet-hosts' -AddressPrefix '10.10.1.0/24')

New-AzStorageAccount -Name 'stavdlabprof01' -ResourceGroupName 'rg-avd-lab' -Location 'eastus2' -SkuName 'Standard_LRS' -Kind 'StorageV2' -MinimumTlsVersion 'TLS1_2' -AllowBlobPublicAccess $false

New-AzRmStorageShare -ResourceGroupName 'rg-avd-lab' -StorageAccountName 'stavdlabprof01' -Name 'profiles' -QuotaGiB 100

Set-AzStorageAccount -ResourceGroupName 'rg-avd-lab' -Name 'stavdlabprof01' -EnableAzureActiveDirectoryKerberosForFile $true -DefaultSharePermission 'StorageFileDataSmbShareContributor'
Write-Host "Now: Entra admin center > Enterprise applications > '[Storage Account] stavdlabprof01.file.core.windows.net' > Permissions > Grant admin consent"

New-AzWvdHostPool -Name 'hp-lab' -ResourceGroupName 'rg-avd-lab' -Location 'eastus2' -HostPoolType 'Pooled' -LoadBalancerType 'BreadthFirst' -MaxSessionLimit 10 -PreferredAppGroupType 'Desktop' -CustomRdpProperty 'targetisaadjoined:i:1;enablerdsaadauth:i:1;' -StartVMOnConnect

New-AzWvdApplicationGroup -Name 'hp-lab-DAG' -ResourceGroupName 'rg-avd-lab' -Location 'eastus2' -ApplicationGroupType 'Desktop' -HostPoolArmPath (Get-AzWvdHostPool -Name 'hp-lab' -ResourceGroupName 'rg-avd-lab').Id

New-AzWvdWorkspace -Name 'ws-lab' -ResourceGroupName 'rg-avd-lab' -Location 'eastus2' -FriendlyName 'Contoso Lab Desktop' -ApplicationGroupReference (Get-AzWvdApplicationGroup -Name 'hp-lab-DAG' -ResourceGroupName 'rg-avd-lab').Id

New-AzRoleAssignment -ObjectId 'sample-groupobjectid' -RoleDefinitionName 'Desktop Virtualization User' -Scope (Get-AzWvdApplicationGroup -Name 'hp-lab-DAG' -ResourceGroupName 'rg-avd-lab').Id

(New-AzWvdRegistrationInfo -ResourceGroupName 'rg-avd-lab' -HostPoolName 'hp-lab' -ExpirationTime (Get-Date).AddHours(24)).Token

New-AzNetworkInterface -Name 'avd-lab-01-nic' -ResourceGroupName 'rg-avd-lab' -Location 'eastus2' -SubnetId ((Get-AzVirtualNetwork -Name 'vnet-avd-lab' -ResourceGroupName 'rg-avd-lab').Subnets | Where-Object Name -eq 'snet-hosts').Id
New-AzVM -ResourceGroupName 'rg-avd-lab' -Location 'eastus2' -VM (New-AzVMConfig -VMName 'avd-lab-01' -VMSize 'Standard_D4s_v5' -SecurityType 'TrustedLaunch' -IdentityType SystemAssigned -LicenseType 'Windows_Client' | Set-AzVMOperatingSystem -Windows -ComputerName 'avd-lab-01' -Credential (Get-Credential -Message 'Local administrator for the VM') -ProvisionVMAgent | Set-AzVMSourceImage -PublisherName 'MicrosoftWindowsDesktop' -Offer 'office-365' -Skus 'win11-24h2-avd-m365' -Version 'latest' | Add-AzVMNetworkInterface -Id (Get-AzNetworkInterface -Name 'avd-lab-01-nic' -ResourceGroupName 'rg-avd-lab').Id | Set-AzVMBootDiagnostic -Disable)
Set-AzVMExtension -ResourceGroupName 'rg-avd-lab' -VMName 'avd-lab-01' -Location 'eastus2' -Name 'AADLoginForWindows' -Publisher 'Microsoft.Azure.ActiveDirectory' -ExtensionType 'AADLoginForWindows' -TypeHandlerVersion '2.0'
Set-AzVMExtension -ResourceGroupName 'rg-avd-lab' -VMName 'avd-lab-01' -Location 'eastus2' -Name 'AvdAgentDsc' -Publisher 'Microsoft.Powershell' -ExtensionType 'DSC' -TypeHandlerVersion '2.73' -Settings @{ modulesUrl = 'https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration.zip'; configurationFunction = 'Configuration.ps1\AddSessionHost'; properties = @{ hostPoolName = 'hp-lab'; aadJoin = $true } } -ProtectedSettings @{ properties = @{ registrationInfoToken = (Read-Host -Prompt 'Host pool registration token (from the previous task)') } }
New-AzRoleAssignment -ObjectId 'sample-groupobjectid' -RoleDefinitionName 'Virtual Machine User Login' -Scope (Get-AzVM -Name 'avd-lab-01' -ResourceGroupName 'rg-avd-lab').Id
