# Legacy algorithm tests run only on temporary, explicitly modified source copies.
# Release-policy tests must use the real source and never call this helper.
function New-LegacyAzureTestCopy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Destination)
    $testRoot = (Get-Variable TestDrive -ValueOnly -ErrorAction Stop)
    $full = [IO.Path]::GetFullPath($Destination)
    if (-not $full.StartsWith([IO.Path]::GetFullPath($testRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar)) {
        throw 'Legacy test copies must stay inside Pester TestDrive.'
    }
    $source = Join-Path $PSScriptRoot '../..'
    $null = New-Item -ItemType Directory -Path $full -Force
    foreach ($tree in 'scripts', 'runbooks') {
        Copy-Item (Join-Path $source $tree) -Destination $full -Recurse
    }
    $guard = "& { `$ErrorActionPreference = 'Stop'; throw 'Cloudwright safe release: Azure/AVD execution is disabled pending a reviewed read-only implementation.' }"
    foreach ($file in Get-ChildItem $full -Recurse -File | Where-Object Extension -in '.ps1', '.psm1') {
        $text = [IO.File]::ReadAllText($file.FullName)
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
        $first = $ast.EndBlock.Statements[0]
        if ($first.Extent.Text -cne $guard) { throw "Missing release block in test source: $($file.Name)" }
        [IO.File]::WriteAllText($file.FullName, $text.Remove($first.Extent.StartOffset, $first.Extent.EndOffset - $first.Extent.StartOffset))
    }
    return $full
}
