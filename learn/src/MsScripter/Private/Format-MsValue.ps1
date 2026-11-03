function Format-MsValue {
    <#
    .SYNOPSIS
        Turn an answer into a PowerShell literal for the generated script.
    .DESCRIPTION
        Returns $null for "nothing to emit" (empty string, $null, $false, empty collection)
        so the caller can drop the parameter. Strings are single-quoted with embedded
        quotes doubled, which is the only quoting that is safe for arbitrary input.
    .PARAMETER Value
        The answer as typed or picked.
    .PARAMETER Type
        The field Type from the task definition. Decides how the value is rendered.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()] [AllowNull()] [object]$Value,
        [Parameter()] [string]$Type = 'String'
    )

    if ($null -eq $Value) { return $null }

    switch ($Type) {
        'Bool' {
            if ($Value -is [string]) { $Value = $Value -match '^(y|yes|true|1)$' }
            if ($Value) { return '$true' }
            return $null
        }
        'TrueFalse' {
            if ($Value -is [string]) { $Value = $Value -match '^(y|yes|true|1)$' }
            if ($Value) { return '$true' }
            return '$false'
        }
        'Int' {
            if ("$Value" -eq '') { return $null }
            return "$([int]$Value)"
        }
        'Hashtable' {
            if ($Value -is [string]) { $Value = ConvertFrom-MsFieldText -Text $Value -Type Hashtable }
            if (-not $Value -or $Value.Count -eq 0) { return $null }
            $pairs = foreach ($k in ($Value.Keys | Sort-Object)) {
                $key = if ($k -match '^[A-Za-z_][A-Za-z0-9_]*$') { $k } else { "'$([System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent("$k"))'" }
                "$key = '$([System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent("$($Value[$k])"))'"
            }
            return "@{ $($pairs -join '; ') }"
        }
        'MultiChoice' {
            if ($Value -is [string]) { $Value = ConvertFrom-MsFieldText -Text $Value -Type MultiChoice }
            $items = @($Value | Where-Object { "$_" -ne '' })
            if ($items.Count -eq 0) { return $null }
            return "@($(($items | ForEach-Object { "'$([System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent("$_"))'" }) -join ', '))"
        }
        default {
            $text = "$Value"
            if ($text -eq '') { return $null }
            return "'$([System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($text))'"
        }
    }
}
