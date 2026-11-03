@{
    # Same bar as the azure repo: warnings and errors fail CI.
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The console UI talks to a human. Write-Host is correct there and is
        # suppressed per-file with an attribute; nothing else should use it.
    )
}
