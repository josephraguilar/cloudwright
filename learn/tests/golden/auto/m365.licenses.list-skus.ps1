Get-MgSubscribedSku | Select-Object SkuPartNumber, SkuId, ConsumedUnits, @{ n = 'Enabled'; e = { $_.PrepaidUnits.Enabled } } | Sort-Object SkuPartNumber | Format-Table -AutoSize
