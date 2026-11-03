<#
.SYNOPSIS
    Regenerate the catalog table in README.md from the task files.
.DESCRIPTION
    Rewrites everything between the catalog:start and catalog:end markers. Run after adding
    or renaming a task. Pure text; nothing is executed.
.EXAMPLE
    ./tools/Update-ReadmeCatalog.ps1
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path (Join-Path (Join-Path $root 'src') 'MsScripter') 'MsScripter.psd1') -Force

$rows = foreach ($e in (Get-MsTaskCatalog -CatalogRoot (Join-Path $root 'catalog') -Strict | Sort-Object Section, Title)) {
    $status = if ($e.Kind -eq 'Path') { 'Path' } else { $e.Definition.Status }
    "| $($e.Section -replace '/', ' / ') | $($e.Title) | ``$($e.Id)`` | $status |"
}
$table = @('| Section | Task | Id | Status |', '| ------- | ---- | -- | ------ |') + $rows
$readme = Join-Path $root 'README.md'
$text = Get-Content $readme -Raw
$pattern = '(?s)(<!-- catalog:start[^>]*-->).*?(<!-- catalog:end -->)'
$new = [regex]::Replace($text, $pattern, { param($m) $m.Groups[1].Value + "`n" + ($table -join "`n") + "`n" + $m.Groups[2].Value })
Set-Content -Path $readme -Value $new -NoNewline -Encoding utf8
Write-Output "README catalog table: $($rows.Count) rows."
