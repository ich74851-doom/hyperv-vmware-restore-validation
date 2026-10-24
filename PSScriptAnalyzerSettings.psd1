@{
    # Fail CI on errors and warnings; informational findings are shown but do not fail.
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @()
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            # Scripts are written for Windows PowerShell 5.1 and PowerShell 7+.
            TargetVersions = @('5.1', '7.0')
        }
    }
}
