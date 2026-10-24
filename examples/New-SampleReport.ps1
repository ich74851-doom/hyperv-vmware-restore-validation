<#
.SYNOPSIS
    Regenerates examples/sample-report.html and sample-report.json from fictional results.
.DESCRIPTION
    No Hyper-V host is needed: the results below are invented to show the report layout.
#>
[CmdletBinding()]
param()
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\src\RestoreValidation.psm1') -Force

function Get-SampleCheck([string] $Check, [string] $Type, [bool] $Passed, [string] $Detail) {
    [pscustomobject]@{ Check = $Check; Type = $Type; Passed = $Passed; Detail = $Detail }
}

$results = @(
    New-VMTestResult -VMName 'DC01-RESTORE' -Role 'Domain controller' -RtoMinutes 60 -ElapsedMinutes 6.4 `
        -Heartbeat ([pscustomobject]@{ Healthy = $true; Heartbeat = 'OkApplicationsHealthy'; Seconds = 142 }) `
        -CheckResults @(
            Get-SampleCheck 'Service NTDS' 'Service' $true "Service 'NTDS' is Running"
            Get-SampleCheck 'Service DNS' 'Service' $true "Service 'DNS' is Running"
            Get-SampleCheck 'TCP 389' 'TcpPort' $true 'TCP 389 is listening'
            Get-SampleCheck 'Path C:\Windows\SYSVOL\domain' 'Path' $true 'C:\Windows\SYSVOL\domain exists'
        )
    New-VMTestResult -VMName 'SQL01-RESTORE' -Role 'SQL Server' -RtoMinutes 60 -ElapsedMinutes 11.9 `
        -Heartbeat ([pscustomobject]@{ Healthy = $true; Heartbeat = 'OkApplicationsHealthy'; Seconds = 318 }) `
        -CheckResults @(
            Get-SampleCheck 'Service MSSQLSERVER' 'Service' $true "Service 'MSSQLSERVER' is Running"
            Get-SampleCheck 'TCP 1433' 'TcpPort' $true 'TCP 1433 is listening'
            Get-SampleCheck 'Path D:\SQLData' 'Path' $true 'D:\SQLData exists'
        )
    New-VMTestResult -VMName 'FS01-RESTORE' -Role 'File server' -RtoMinutes 60 -ElapsedMinutes 7.2 `
        -Heartbeat ([pscustomobject]@{ Healthy = $true; Heartbeat = 'OkApplicationsHealthy'; Seconds = 165 }) `
        -CheckResults @(
            Get-SampleCheck 'Service LanmanServer' 'Service' $true "Service 'LanmanServer' is Running"
            Get-SampleCheck 'TCP 445' 'TcpPort' $true 'TCP 445 is listening'
            Get-SampleCheck 'Path E:\Shares\Finance' 'Path' $false 'E:\Shares\Finance not found'
        )
)
$run = [pscustomobject]@{
    PlanName = 'Quarterly DR test - corp.example.com (fictional)'; IsolatedSwitch = 'DR-Isolated'
    HostName = 'HV-LAB01'; Started = [datetime]'2026-10-17T09:00:00'; Finished = [datetime]'2026-10-17T09:26:00'
    RtoMinutes = 60; Cleanup = 'Stop'; Results = $results
}
$note = 'Fictional sample: the host, VMs and results are invented to show the report layout.'
ConvertTo-RestoreValidationHtml -Run $run -Note $note | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'sample-report.html') -Encoding UTF8
ConvertTo-RestoreValidationJson -Run $run | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'sample-report.json') -Encoding UTF8
