@('Microsoft.Compute', 'Microsoft.Network') | ForEach-Object { Register-AzResourceProvider -ProviderNamespace $_ }
