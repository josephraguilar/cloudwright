function Get-MsTaskCatalog {
    <#
    .SYNOPSIS
        Load every task and build path under catalog/.
    .DESCRIPTION
        Returns objects with Id, Title, Section (folder path as 'Azure/Create'), Path, and
        Definition (the raw hashtable). Invalid tasks are skipped with a warning unless
        -Strict, which throws listing every problem. Tests use -Strict.
    .PARAMETER CatalogRoot
        Defaults to the repo's catalog/ folder.
    .PARAMETER Strict
        Throw on the first invalid task instead of warning and skipping.
    .EXAMPLE
        Get-MsTaskCatalog | Format-Table Id, Section, Title
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [string]$CatalogRoot = $script:CatalogRoot,
        [Parameter()] [switch]$Strict
    )
    $root = (Resolve-Path $CatalogRoot).Path
    $files = Get-ChildItem -Path $root -Filter '*.psd1' -Recurse -File | Where-Object { $_.Name -notlike '_*' } | Sort-Object FullName
    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($file in $files) {
        try {
            $def = Import-PowerShellDataFile -Path $file.FullName -ErrorAction Stop
        } catch {
            $errors.Add("$($file.FullName): does not load. $($_.Exception.Message)")
            continue
        }
        $isPath = $file.FullName -replace '\\', '/' -match '/catalog/paths/'
        $problems = @($(if ($isPath) { Test-MsPathDefinition -Path $def } else { Test-MsTaskDefinition -Task $def -Path $file.FullName }))
        if ($problems.Count -gt 0) {
            $errors.Add("$($file.FullName):`n  " + ($problems -join "`n  "))
            continue
        }
        $relDir = Split-Path ($file.FullName.Substring($root.Length).TrimStart('\', '/')) -Parent
        [pscustomobject]@{
            PSTypeName = 'MsScripter.Task'
            Id         = $def.Id
            Title      = $def.Title
            Kind       = if ($isPath) { 'Path' } else { 'Task' }
            Section    = (($relDir -replace '\\', '/') -split '/' | ForEach-Object { ConvertTo-MsTitleCase $_ }) -join '/'
            Path       = $file.FullName
            Definition = $def
        }
    }

    if ($errors.Count -gt 0) {
        $message = "Invalid catalog entries:`n" + ($errors -join "`n")
        if ($Strict) { throw $message } else { Write-Warning $message }
    }
}

function ConvertTo-MsTitleCase {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()] [AllowEmptyString()] [string]$Text)
    $known = @{ 'm365' = 'Microsoft 365'; 'entra' = 'Entra ID'; 'avd' = 'AVD'; 'vm' = 'Virtual machine'; 'paths' = 'Build paths' }
    if ($known.ContainsKey($Text)) { return $known[$Text] }
    if (-not $Text) { return $Text }
    return ($Text -replace '-', ' ').Substring(0, 1).ToUpperInvariant() + ($Text -replace '-', ' ').Substring(1)
}

function Test-MsPathDefinition {
    <#
    .SYNOPSIS
        Validate a build path file (catalog/paths/*.psd1).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [hashtable]$Path)
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($key in 'Id', 'Title', 'Summary', 'Tasks') {
        if (-not $Path.ContainsKey($key)) { $problems.Add("Missing required key '$key'.") }
    }
    if ($Path.ContainsKey('Id') -and $Path.Id -notmatch '^path\.[a-z0-9-]+(\.[a-z0-9-]+)+$') { $problems.Add("Path Id '$($Path.Id)' must start with 'path.'.") }
    if ($Path.ContainsKey('Tasks') -and @($Path.Tasks).Count -lt 2) { $problems.Add('A path needs at least two tasks.') }
    return $problems.ToArray()
}
