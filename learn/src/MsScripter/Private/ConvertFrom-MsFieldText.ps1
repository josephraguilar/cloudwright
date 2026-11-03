function ConvertFrom-MsFieldText {
    <#
    .SYNOPSIS
        Parse what a person typed for a Hashtable or MultiChoice field.
    .DESCRIPTION
        Hashtable:   'env=lab, owner=jane'  ->  @{ env = 'lab'; owner = 'jane' }
        MultiChoice: 'a, b, c'              ->  @('a', 'b', 'c')
        Anything else is returned unchanged.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [AllowEmptyString()] [string]$Text,
        [Parameter(Mandatory)] [string]$Type
    )
    switch ($Type) {
        'Hashtable' {
            $result = @{}
            foreach ($pair in ($Text -split ',')) {
                $pair = $pair.Trim()
                if (-not $pair) { continue }
                $idx = $pair.IndexOf('=')
                if ($idx -lt 1) { throw "Tag '$pair' is not key=value." }
                $result[$pair.Substring(0, $idx).Trim()] = $pair.Substring($idx + 1).Trim()
            }
            return $result
        }
        'MultiChoice' {
            return @($Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        default { return $Text }
    }
}
