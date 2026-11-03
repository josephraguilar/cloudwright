function Read-MsField {
    <#
    .SYNOPSIS
        Ask the operator for one field. Returns the typed or picked value.
    .DESCRIPTION
        Choice fields try the live lookup first (Resolve-MsSource) and always offer typing
        a value instead, so the tool works signed out. Answers are remembered under the
        field Name for the rest of the session (same idea as $script:Remembered in
        azure/Start-AvdConsole.ps1) and offered as the default next time.
    .PARAMETER Field
        The field hashtable.
    .PARAMETER Answers
        Answers so far, for lookups that depend on earlier fields.
    .PARAMETER Fields
        All fields of the task.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive prompt. Output is for the operator.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Field,
        [Parameter(Mandatory)] [hashtable]$Answers,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Fields
    )
    if ($Field.Type -in 'Secret', 'Reference') { return $null }   # never asked

    $default = $null
    if ($script:Remembered.ContainsKey($Field.Name)) { $default = $script:Remembered[$Field.Name] }
    elseif ($Field.ContainsKey('Default')) { $default = $Field.Default }
    elseif ($script:ContosoMode -and $Field.ContainsKey('Example')) { $default = $Field.Example }

    Write-Host ''
    Write-Host "  $($Field.Label)" -ForegroundColor White
    if ($Field.ContainsKey('Help'))    { Write-Host "  $($Field.Help)" -ForegroundColor DarkGray }
    if ($Field.ContainsKey('Example')) { Write-Host "  e.g. $($Field.Example)" -ForegroundColor DarkGray }

    while ($true) {
        $value = $null
        switch ($Field.Type) {
            { $_ -in 'Bool', 'TrueFalse' } {
                $d = if ($default -is [bool]) { $default } elseif ("$default" -match '^(y|yes|true|1)$') { $true } else { $false }
                $hint = if ($d) { '[Y/n]' } else { '[y/N]' }
                $a = "$(Read-Host "  Yes or no $hint")".Trim()
                $value = if (-not $a) { $d } else { $a -match '^[Yy]' }
            }
            { $_ -in 'Choice', 'MultiChoice' } {
                $items = $null
                if ($Field.ContainsKey('Options')) {
                    $items = @($Field.Options | ForEach-Object { if ($_ -is [hashtable]) { [pscustomobject]@{ Display = $_.Display; Value = $_.Value } } else { [pscustomobject]@{ Display = "$_"; Value = "$_" } } })
                } elseif ($Field.ContainsKey('Source')) {
                    $items = Resolve-MsSource -Source $Field.Source -Answers $Answers -Fields $Fields
                    if ($null -eq $items) { Write-Host '  (not signed in, or lookup unavailable: type the value)' -ForegroundColor DarkGray }
                }
                if ($items -and $null -eq $default -and $script:ContosoMode) { $default = @($items)[0].Value }   # study mode: Enter takes the first sample row
                if ($items) {
                    if ($Field.Type -eq 'MultiChoice') {
                        $chosen = @()
                        while ($true) {
                            $pick = Select-MsItem -Title "$($Field.Label) (Enter when done; chosen: $($chosen -join ', '))" -Items $items -AllowNone
                            if (-not $pick) { break }
                            $chosen += $pick.Value
                        }
                        if ($chosen.Count -gt 0) { $value = $chosen }
                    } else {
                        $pick = Select-MsItem -Title $Field.Label -Items $items -AllowNone
                        if ($pick) { $value = $pick.Value }
                    }
                }
                if ($null -eq $value) {
                    $label = if ($null -ne $default) { "  Value [$default]" } else { '  Value' }
                    $a = "$(Read-Host $label)".Trim()
                    $value = if ($a) { $a } else { $default }
                    if ($Field.Type -eq 'MultiChoice' -and $value -is [string]) { $value = ConvertFrom-MsFieldText -Text $value -Type MultiChoice }
                }
            }
            default {
                $label = if ($null -ne $default -and "$default" -ne '') { "  Value [$default]" } else { '  Value' }
                $a = "$(Read-Host $label)".Trim()
                $value = if ($a) { $a } else { $default }
                if ($Field.Type -eq 'Hashtable' -and $value -is [string]) {
                    try { $value = ConvertFrom-MsFieldText -Text $value -Type Hashtable } catch { Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow; continue }
                }
            }
        }

        $empty = $null -eq $value -or ($value -is [string] -and $value -eq '') -or ($value -is [hashtable] -and $value.Count -eq 0)
        if ($empty -and $Field.ContainsKey('Required') -and $Field.Required) { Write-Host '  Required.' -ForegroundColor Yellow; continue }
        if (-not $empty -and $Field.ContainsKey('Pattern') -and $value -is [string] -and $value -notmatch $Field.Pattern) {
            Write-Host "  Does not match the expected format ($($Field.Pattern))." -ForegroundColor Yellow; continue
        }
        if (-not $empty -and $Field.Type -eq 'Int' -and "$value" -notmatch '^-?\d+$') { Write-Host '  Whole number, please.' -ForegroundColor Yellow; continue }
        if (-not $empty) { $script:Remembered[$Field.Name] = $value }
        return $value
    }
}
