#Requires -Version 5.1
<#
.SYNOPSIS
    Runs a restore test plan against VMs restored onto this Hyper-V host and writes reports.

.DESCRIPTION
    Restore the VMs under test names with your backup product first (for example a restore
    to a new VM or an instant recovery), then run this script on the Hyper-V host as an
    administrator. It isolates each VM on the plan's Internal or Private switch, starts it,
    waits for the heartbeat, runs guest checks over PowerShell Direct and writes an HTML and
    JSON report.

    Exit codes: 0 all VMs passed, 1 a VM failed a check or exceeded the RTO, 2 error.

.PARAMETER PlanPath
    JSON test plan. See examples/restore-test-plan.json.

.PARAMETER Credential
    Guest account for PowerShell Direct. Prompted for if omitted.

.PARAMETER OutputFolder
    Where reports are written. Default: .\reports

.PARAMETER Cleanup
    None, Stop (default) or Remove. Remove deletes the restored VM from Hyper-V after the test.

.PARAMETER ValidateOnly
    Only check the plan file; do not touch any VM.

.EXAMPLE
    .\scripts\Invoke-RestoreValidation.ps1 -PlanPath .\plans\quarterly.local.json -Cleanup Stop

.EXAMPLE
    .\scripts\Invoke-RestoreValidation.ps1 -PlanPath .\examples\restore-test-plan.json -ValidateOnly
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $PlanPath,
    [pscredential] $Credential,
    [string] $OutputFolder = (Join-Path -Path (Get-Location) -ChildPath 'reports'),
    [ValidateSet('None', 'Stop', 'Remove')] [string] $Cleanup = 'Stop',
    [switch] $ValidateOnly
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\src\RestoreValidation.psm1') -Force

try {
    $plan = Read-RestoreTestPlan -Path $PlanPath
    Write-Output "Plan '$($plan.name)' is valid: $(@($plan.vms).Count) VM(s), isolated switch '$($plan.isolatedSwitch)'."
    if ($ValidateOnly) { exit 0 }

    if (-not (Get-Command -Name Get-VM -ErrorAction SilentlyContinue)) {
        throw 'The Hyper-V PowerShell module is not available. Run this on a Hyper-V host.'
    }
    if (-not $Credential) { $Credential = Get-Credential -Message 'Guest credential for PowerShell Direct checks' }

    $run = Invoke-RestoreValidation -Plan $plan -Credential $Credential -Cleanup $Cleanup -WhatIf:$WhatIfPreference
    if (-not (Test-Path -LiteralPath $OutputFolder)) { $null = New-Item -ItemType Directory -Path $OutputFolder }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $html = Join-Path -Path $OutputFolder -ChildPath "restore-validation-$stamp.html"
    $json = Join-Path -Path $OutputFolder -ChildPath "restore-validation-$stamp.json"
    ConvertTo-RestoreValidationHtml -Run $run | Set-Content -LiteralPath $html -Encoding UTF8
    ConvertTo-RestoreValidationJson -Run $run | Set-Content -LiteralPath $json -Encoding UTF8

    foreach ($r in $run.Results) { Write-Output ("{0,-20} {1,-12} {2} min" -f $r.VMName, $r.Outcome, $r.ElapsedMinutes) }
    $code = Get-RestoreValidationExitCode -Run $run
    Write-Output "Reports: $html, $json"
    exit $code
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 2
}
