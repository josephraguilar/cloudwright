#region Module setup ----------------------------------------------------------
#   WHAT   Dot-source every function file, export the public ones.
#   WHY    One function per file keeps diffs small and lets a worker own one file.
#   GOTCHA Nothing in this module may execute generated text. See docs/architecture.md
#          "The one rule" and tests/ReadOnly.Tests.ps1, which greps this tree.
Set-StrictMode -Version Latest

$script:ModuleRoot  = $PSScriptRoot
$script:CatalogRoot = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') '..') 'catalog'
$script:SourceCache = @{}       # Resolve-MsSource results, keyed by cmdlet + parameters
$script:Remembered  = @{}       # answers typed this session, keyed by field Name
$script:ContosoMode = $false    # when on, pick lists come from catalog/_contoso.psd1 instead of live lookups
$script:SampleData  = $null     # the loaded sample file, see Get-MsSampleData

foreach ($folder in 'Private', 'Public') {
    foreach ($file in Get-ChildItem -Path (Join-Path $PSScriptRoot $folder) -Filter '*.ps1' -ErrorAction SilentlyContinue) {
        . $file.FullName
    }
}

Export-ModuleMember -Function 'Get-MsTaskCatalog', 'Get-MsTask', 'Test-MsTaskDefinition', 'New-MsScript', 'Show-MsScripter', 'Show-MsScripterWindow', 'Set-MsContosoMode', 'Get-MsContosoMode'
#endregion
