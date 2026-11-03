function Select-MsItem {
    <#
    .SYNOPSIS
        Pick one item from a list. The "drop-down" of the console UI.
    .DESCRIPTION
        Best available picker, in order:
          1. Out-ConsoleGridView (Microsoft.PowerShell.ConsoleGuiTools, PS 7.2+, cross-platform)
          2. Out-GridView (Windows only) when the list is long
          3. Numbered list with type-to-filter (works everywhere, adapted from azure/Start-AvdConsole Select-Item)
        Returns the chosen item, or $null when the user backs out (-AllowNone) or the list is empty.
    .PARAMETER Title
        Shown above the list.
    .PARAMETER Items
        Objects to pick from.
    .PARAMETER Label
        Property name or scriptblock producing the text for each item. Defaults to Display.
    .PARAMETER AllowNone
        Enter on an empty line returns $null instead of re-asking.
    .PARAMETER PageSize
        Numbered-list fallback shows this many rows before asking you to filter.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive picker. Output is for the operator.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Label', Justification = 'Used inside the $text scriptblock; the analyzer cannot see into it.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Title,
        [Parameter()] [AllowNull()] [AllowEmptyCollection()] [object[]]$Items,
        [Parameter()] [object]$Label = 'Display',
        [Parameter()] [switch]$AllowNone,
        [Parameter()] [int]$PageSize = 25
    )
    if (-not $Items -or $Items.Count -eq 0) {
        Write-Host '  (nothing to choose from)' -ForegroundColor Yellow
        return $null
    }
    $text = { param($item) if ($Label -is [scriptblock]) { $item | ForEach-Object $Label } else { "$($item.$Label)" } }

    # 1. ConsoleGuiTools
    if ($Items.Count -gt 8 -and (Get-Command Out-ConsoleGridView -ErrorAction SilentlyContinue)) {
        $rows = $Items | ForEach-Object { [pscustomobject]@{ Choice = (& $text $_); Item = $_ } }
        $picked = $rows | Select-Object Choice | Out-ConsoleGridView -Title $Title -OutputMode Single
        if (-not $picked) { return $null }
        return ($rows | Where-Object Choice -eq $picked.Choice | Select-Object -First 1).Item
    }
    # 2. Out-GridView (Windows)
    if ($Items.Count -gt $PageSize -and (Get-Command Out-GridView -ErrorAction SilentlyContinue)) {
        $rows = $Items | ForEach-Object { [pscustomobject]@{ Choice = (& $text $_); Item = $_ } }
        $picked = $rows | Select-Object Choice | Out-GridView -Title $Title -OutputMode Single
        if (-not $picked) { return $null }
        return ($rows | Where-Object Choice -eq $picked.Choice | Select-Object -First 1).Item
    }
    # 3. Numbered list with filter
    $filtered = @($Items)
    while ($true) {
        Write-Host "  $Title" -ForegroundColor Cyan
        $shown = @($filtered | Select-Object -First $PageSize)
        for ($i = 0; $i -lt $shown.Count; $i++) {
            Write-Host ('  {0,3}. {1}' -f ($i + 1), (& $text $shown[$i]))
        }
        if ($filtered.Count -gt $PageSize) { Write-Host "  ... $($filtered.Count - $PageSize) more. Type part of a name to filter." -ForegroundColor DarkGray }
        $hint = if ($AllowNone) { 'Number, text to filter, or Enter to type a value' } else { 'Number, or text to filter' }
        $answer = "$(Read-Host "  $hint")".Trim()
        if (-not $answer) {
            if ($AllowNone) { return $null }
            continue
        }
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $shown.Count) { return $shown[[int]$answer - 1] }
        $filtered = @($Items | Where-Object { (& $text $_) -like "*$answer*" })
        if ($filtered.Count -eq 0) {
            Write-Host "  Nothing matches '$answer'." -ForegroundColor Yellow
            $filtered = @($Items)
        }
    }
}
