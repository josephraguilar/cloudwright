function Expand-MsTemplate {
    <#
    .SYNOPSIS
        Replace {{Field}} tokens in a string with answers.
    .DESCRIPTION
        {{Field}}      -> the answer rendered as a PowerShell literal ('quoted', @{...}, 1, $true)
        {{Field:raw}}  -> the answer's text, unquoted. For use inside a string the author
                          already quoted, e.g. "'{{Prefix:raw}}-nic'".
        Unknown tokens throw: a typo in a task file must fail the catalog test, not
        land in someone's script.
    .PARAMETER Text
        The template.
    .PARAMETER Answers
        Field Name -> value.
    .PARAMETER Fields
        The task's Fields, used to find each field's Type for rendering.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Answers', Justification = 'Used inside the $evaluator scriptblock; the analyzer cannot see into it.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Text,
        [Parameter(Mandatory)] [hashtable]$Answers,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Fields
    )
    $byName = @{}
    foreach ($f in $Fields) { $byName[$f.Name] = $f }

    $evaluator = {
        param($match)
        $name = $match.Groups['name'].Value
        $raw  = $match.Groups['raw'].Success
        if (-not $byName.ContainsKey($name)) { throw "Template references unknown field '{{$name}}'." }
        $field = $byName[$name]
        $value = if ($Answers.ContainsKey($name)) { $Answers[$name] } else { $null }
        if ($field.Type -eq 'Secret') {
            return Format-MsSecret -Field $field
        }
        if ($match.Groups['filter'].Success) {
            $property = $match.Groups['property'].Value
            $escaped = "$value".Replace("'", "''")
            return Format-MsValue -Value "$property eq '$escaped'"
        }
        if ($raw) {
            # Raw templates can appear inside PowerShell and OData quotes or comments.
            # Until converted to structured literals, accept only simple name/path text.
            # Quotes, dollar expressions, control characters, and shell syntax fail closed.
            if ("$value" -notmatch '\A[A-Za-z0-9 ._@:/\\-]*\z') {
                throw "Field '$name' contains characters this raw template cannot safely render. Use a structured literal template."
            }
            return "$value"
        }
        $literal = Format-MsValue -Value $value -Type $field.Type
        if ($null -eq $literal) { return '' }
        return $literal
    }
    return [regex]::Replace($Text, '\{\{(?<name>[A-Za-z][A-Za-z0-9_]*)(?:(?<raw>:raw)|(?<filter>:filter:(?<property>displayName|mailNickname)))?\}\}', $evaluator)
}

function Format-MsSecret {
    <#
    .SYNOPSIS
        What a Secret field becomes in the script: a prompt at run time, never a value.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [hashtable]$Field)
    $label = [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Field.Label)
    $kind = if ($Field.ContainsKey('SecretKind')) { $Field.SecretKind } else { 'Credential' }
    switch ($kind) {
        'SecureString' { return "(Read-Host -Prompt '$label' -AsSecureString)" }
        'PlainText'    { return "(Read-Host -Prompt '$label')" }
        default        { return "(Get-Credential -Message '$label')" }
    }
}
