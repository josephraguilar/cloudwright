using './main.bicep'

param environment = 'lab'
param addressPrefix = '10.10.0.0/16'
param subnetPrefix = '10.10.1.0/24'

// Profile storage for FSLogix. Change the account name: it must be globally unique.
param deployProfileStorage = true
param storageAccountName = 'stavdlabprofiles001'
param storageSkuName = 'Standard_LRS'
param profileShareName = 'profiles'

// Flip to true when you want to capture your own images.
param deployGallery = false
