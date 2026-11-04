function Get-MsTask {
    <#
    .SYNOPSIS
        One task (or build path) by Id.
    .EXAMPLE
        Get-MsTask -Id azure.create.resource-group
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string]$Id,
        [Parameter()] [string]$CatalogRoot = $script:CatalogRoot
    )
    $ErrorActionPreference = 'Stop'
    $task = Get-MsTaskCatalog -CatalogRoot $CatalogRoot | Where-Object Id -eq $Id
    if (-not $task) { throw "No task with Id '$Id' under $CatalogRoot." }
    return $task
}
