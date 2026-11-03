function Get-MsSampleData {
    <#
    .SYNOPSIS
        Load catalog/_contoso.psd1 once and return it.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()] [string]$Path = (Join-Path $script:CatalogRoot '_contoso.psd1'))
    if (-not $script:SampleData) {
        $script:SampleData = Import-PowerShellDataFile -Path $Path -ErrorAction Stop
    }
    return $script:SampleData
}

function Get-MsSampleItem {
    <#
    .SYNOPSIS
        Sample rows for a lookup cmdlet, filtered by any parameters the row has a property for.
    .DESCRIPTION
        Get-AzVirtualNetwork with ResourceGroupName = rg-contoso-avd-lab returns only the VNets
        whose ResourceGroupName property matches. Rows without the property are kept, so
        unscoped tables (VM sizes, regions) work with any parameters. If the filter leaves
        nothing, the whole table is returned: a study-mode drop-down should never be empty.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Cmdlet,
        [Parameter()] [hashtable]$Parameters = @{},
        [Parameter(Mandatory)] [string]$Display,
        [Parameter(Mandatory)] [string]$Value
    )
    $data = Get-MsSampleData
    if (-not $data.ContainsKey($Cmdlet)) { return $null }
    $all  = @($data[$Cmdlet])
    $rows = @(foreach ($row in $all) {
        $keep = $true
        foreach ($k in $Parameters.Keys) {
            if ($row.ContainsKey($k) -and "$($row[$k])" -ne "$($Parameters[$k])") { $keep = $false; break }
        }
        if ($keep) { $row }
    })
    if ($rows.Count -eq 0) { $rows = $all }     # sample mode: a scoped list that matches nothing shows everything rather than an empty box
    return @($rows | ForEach-Object { [pscustomobject]@{ Display = "$($_[$Display])"; Value = "$($_[$Value])" } } | Sort-Object Display)
}
