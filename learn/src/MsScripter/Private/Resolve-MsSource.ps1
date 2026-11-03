function Resolve-MsSource {
    <#
    .SYNOPSIS
        Run a field's read-only lookup and return picker items.
    .DESCRIPTION
        Returns objects with Display and Value, or $null when the lookup is unavailable
        (not signed in, module missing, cmdlet failed). Results are cached for the session
        by cmdlet + parameters. The verb allow-list is enforced here AND in
        Test-MsTaskDefinition, so a hand-built task cannot slip a write through.
    .PARAMETER Source
        The Source hashtable from the field.
    .PARAMETER Answers
        Current answers, for {{Token}}s inside Source.Parameters.
    .PARAMETER Fields
        The task's Fields.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Source,
        [Parameter(Mandatory)] [hashtable]$Answers,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Fields
    )
    $verb = ($Source.Cmdlet -split '-')[0]
    if ($verb -notin 'Get', 'Find', 'Search', 'Resolve') { throw "Refusing to run '$($Source.Cmdlet)': lookups must be read-only." }

    #region Contoso mode: sample rows, no connection, nothing executed ---------
    if ($script:ContosoMode) {
        $sampleParams = @{}
        if ($Source.ContainsKey('Parameters')) {
            foreach ($k in $Source.Parameters.Keys) {
                $v = Expand-MsTemplate -Text "$($Source.Parameters[$k])" -Answers $Answers -Fields $Fields
                $v = $v -replace "^'(.*)'$", '$1' -replace "''", "'"
                if ($v -ne '' -and $v -notin '$true', '$false') { $sampleParams[$k] = $v }
            }
        }
        $items = Get-MsSampleItem -Cmdlet $Source.Cmdlet -Parameters $sampleParams -Display $Source.Display -Value $Source.Value
        if ($null -eq $items) { Write-Warning "No Contoso sample data for $($Source.Cmdlet). Add rows to catalog/_contoso.psd1." }
        return $items
    }
    #endregion

    $connected = switch ($Source.Auth) {
        'Azure'          { [bool](Get-Command Get-AzContext -ErrorAction SilentlyContinue) -and [bool](Get-AzContext -ErrorAction SilentlyContinue) }
        'Graph'          { [bool](Get-Command Get-MgContext -ErrorAction SilentlyContinue) -and [bool](Get-MgContext -ErrorAction SilentlyContinue) }
        'ExchangeOnline' { [bool](Get-Command Get-ConnectionInformation -ErrorAction SilentlyContinue) -and [bool](Get-ConnectionInformation -ErrorAction SilentlyContinue) }
        default          { $true }
    }
    if (-not $connected) { return $null }

    $params = @{}
    if ($Source.ContainsKey('Parameters')) {
        foreach ($k in $Source.Parameters.Keys) {
            $v = Expand-MsTemplate -Text "$($Source.Parameters[$k])" -Answers $Answers -Fields $Fields
            $v = $v -replace "^'(.*)'$", '$1' -replace "''", "'"     # lookups want the value, not a literal
            if ($v -eq '$true') { $params[$k] = $true } elseif ($v -eq '$false') { $params[$k] = $false }   # switches need real booleans
            elseif ($v -ne '') { $params[$k] = $v }
        }
    }
    $key = $Source.Cmdlet + '|' + (($params.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';')
    if ($script:SourceCache.ContainsKey($key)) { return $script:SourceCache[$key] }

    $command = Get-Command -Name $Source.Cmdlet -ErrorAction SilentlyContinue
    if (-not $command) { Write-Warning "$($Source.Cmdlet) is not available; type the value instead."; return $null }
    try {
        $items = @(& $command @params -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Display = "$($_.$($Source.Display))"; Value = "$($_.$($Source.Value))" }
        } | Sort-Object Display)
    } catch {
        Write-Warning "$($Source.Cmdlet) failed: $($_.Exception.Message). Type the value instead."
        return $null
    }
    $script:SourceCache[$key] = $items
    return $items
}
