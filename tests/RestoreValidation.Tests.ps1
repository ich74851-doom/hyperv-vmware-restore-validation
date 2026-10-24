#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    # Hyper-V cmdlets do not exist on Linux CI runners: define stubs so Pester can mock them.
    function global:Get-VM { param($Name, $ErrorAction) $null = $Name, $ErrorAction }
    function global:Get-VMSwitch { param($Name, $ErrorAction) $null = $Name, $ErrorAction }
    function global:Start-VM { param($Name) $null = $Name }
    function global:Stop-VM { param($Name, [switch] $TurnOff, [switch] $Force) $null = $Name, $TurnOff, $Force }
    function global:Remove-VM { param($Name, [switch] $Force) $null = $Name, $Force }
    function global:Get-VMNetworkAdapter { param($VMName) $null = $VMName }
    function global:Connect-VMNetworkAdapter { param($VMNetworkAdapter, $SwitchName) $null = $VMNetworkAdapter, $SwitchName }

    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'src/RestoreValidation.psm1') -Force
    $script:ExamplePlan = Join-Path $repoRoot 'examples/restore-test-plan.json'

    $user = 'lab\tester'
    $secure = New-Object System.Security.SecureString
    foreach ($ch in 'test'.ToCharArray()) { $secure.AppendChar($ch) }
    $script:Cred = [pscredential]::new($user, $secure)

    function Get-TestPlan {
        param([object[]] $Vms, [double] $Rto = 60)
        [pscustomobject]@{ name = 'Test plan'; isolatedSwitch = 'DR-Isolated'; rtoMinutes = $Rto; vms = $Vms }
    }
}

Describe 'Test-RestoreTestPlan' {
    It 'accepts the example plan' {
        $plan = Get-Content $script:ExamplePlan -Raw | ConvertFrom-Json
        @(Test-RestoreTestPlan -Plan $plan).Count | Should -Be 0
    }
    It 'reports missing top-level fields' {
        $problems = @(Test-RestoreTestPlan -Plan ([pscustomobject]@{ name = 'x' }))
        $problems | Should -Contain "Plan is missing 'isolatedSwitch'."
        $problems | Should -Contain "Plan is missing 'vms'."
    }
    It 'reports bad checks' {
        $plan = Get-TestPlan -Vms @([pscustomobject]@{ name = 'VM1'; checks = @(
                    [pscustomobject]@{ type = 'Ping' },
                    [pscustomobject]@{ type = 'TcpPort'; port = 70000 },
                    [pscustomobject]@{ type = 'Service' }) })
        $problems = @(Test-RestoreTestPlan -Plan $plan)
        $problems.Count | Should -Be 3
        ($problems -join ' ') | Should -Match "unknown type 'Ping'"
    }
    It 'rejects a non-positive RTO and VMs without names' {
        $problems = @(Test-RestoreTestPlan -Plan (Get-TestPlan -Vms @([pscustomobject]@{ role = 'x' }) -Rto 0))
        $problems | Should -Contain "'rtoMinutes' must be greater than zero."
        $problems | Should -Contain "VM #1 is missing 'name'."
    }
}

Describe 'Read-RestoreTestPlan' {
    It 'reads the example plan' {
        (Read-RestoreTestPlan -Path $script:ExamplePlan).vms.Count | Should -Be 3
    }
    It 'throws on missing files and invalid JSON' {
        { Read-RestoreTestPlan -Path (Join-Path $TestDrive 'nope.json') } | Should -Throw '*not found*'
        $bad = Join-Path $TestDrive 'bad.json'
        Set-Content -Path $bad -Value '{ not json'
        { Read-RestoreTestPlan -Path $bad } | Should -Throw '*not valid JSON*'
    }
}

Describe 'Switch isolation' {
    It 'treats <Type> as isolated: <Expected>' -TestCases @(
        @{ Type = 'Internal'; Expected = $true }, @{ Type = 'Private'; Expected = $true }, @{ Type = 'External'; Expected = $false }
    ) {
        Test-SwitchIsolation -SwitchType $Type | Should -Be $Expected
    }
    It 'refuses an External switch' {
        Mock -ModuleName RestoreValidation Get-VMSwitch { [pscustomobject]@{ Name = 'LAN'; SwitchType = 'External' } }
        { Assert-IsolatedSwitch -SwitchName 'LAN' } | Should -Throw '*Internal or Private*'
    }
    It 'refuses a missing switch' {
        Mock -ModuleName RestoreValidation Get-VMSwitch { $null }
        { Assert-IsolatedSwitch -SwitchName 'Nope' } | Should -Throw '*not found*'
    }
    It 'connects only adapters not already on the isolated switch' {
        Mock -ModuleName RestoreValidation Get-VMNetworkAdapter {
            @([pscustomobject]@{ Name = 'NIC1'; SwitchName = 'LAN' }, [pscustomobject]@{ Name = 'NIC2'; SwitchName = 'DR-Isolated' })
        }
        Mock -ModuleName RestoreValidation Connect-VMNetworkAdapter { }
        Connect-RestoredVMToIsolatedSwitch -VMName 'VM1' -SwitchName 'DR-Isolated' | Should -Be 1
        Should -Invoke -ModuleName RestoreValidation Connect-VMNetworkAdapter -Times 1 -Exactly
    }
    It 'does nothing with -WhatIf' {
        Mock -ModuleName RestoreValidation Get-VMNetworkAdapter { [pscustomobject]@{ Name = 'NIC1'; SwitchName = 'LAN' } }
        Mock -ModuleName RestoreValidation Connect-VMNetworkAdapter { }
        Connect-RestoredVMToIsolatedSwitch -VMName 'VM1' -SwitchName 'DR-Isolated' -WhatIf | Should -Be 0
        Should -Invoke -ModuleName RestoreValidation Connect-VMNetworkAdapter -Times 0 -Exactly
    }
}

Describe 'Wait-VMHeartbeat' {
    BeforeEach { Mock -ModuleName RestoreValidation Start-Sleep { } }
    It 'returns healthy once the heartbeat is OK' {
        $script:calls = 0
        Mock -ModuleName RestoreValidation Get-VM {
            $script:calls++
            [pscustomobject]@{ Heartbeat = $(if ($script:calls -ge 3) { 'OkApplicationsHealthy' } else { 'NoContact' }) }
        }
        $r = Wait-VMHeartbeat -VMName 'VM1' -TimeoutSeconds 60 -PollSeconds 1
        $r.Healthy | Should -BeTrue
        $r.Heartbeat | Should -Be 'OkApplicationsHealthy'
        Should -Invoke -ModuleName RestoreValidation Start-Sleep -Times 2 -Exactly
    }
    It 'times out with the last heartbeat value' {
        Mock -ModuleName RestoreValidation Get-VM { [pscustomobject]@{ Heartbeat = 'NoContact' } }
        $r = Wait-VMHeartbeat -VMName 'VM1' -TimeoutSeconds 0
        $r.Healthy | Should -BeFalse
        $r.Heartbeat | Should -Be 'NoContact'
    }
}

Describe 'Guest checks' {
    It 'builds script blocks that run locally' {
        $r = & (Get-GuestCheckScriptBlock -Type Path) $TestDrive
        $r.Passed | Should -BeTrue
        $r = & (Get-GuestCheckScriptBlock -Type Path) (Join-Path $TestDrive 'missing')
        $r.Passed | Should -BeFalse
    }
    It 'passes the check target to Invoke-Command' {
        Mock -ModuleName RestoreValidation Invoke-Command { @{ Passed = $true; Detail = "TCP $($ArgumentList[0]) is listening" } }
        $r = Invoke-GuestCheck -VMName 'VM1' -Check ([pscustomobject]@{ type = 'TcpPort'; port = 445 }) -Credential $script:Cred
        $r.Check | Should -Be 'TCP 445'
        $r.Passed | Should -BeTrue
        Should -Invoke -ModuleName RestoreValidation Invoke-Command -ParameterFilter { $VMName -eq 'VM1' -and $ArgumentList[0] -eq 445 }
    }
    It 'records a failure when PowerShell Direct fails' {
        Mock -ModuleName RestoreValidation Invoke-Command { throw 'The credential is invalid.' }
        $r = Invoke-GuestCheck -VMName 'VM1' -Check ([pscustomobject]@{ type = 'Service'; name = 'NTDS' }) -Credential $script:Cred
        $r.Passed | Should -BeFalse
        $r.Detail | Should -Match 'credential is invalid'
    }
}

Describe 'Get-RestoreTestOutcome' {
    It 'returns <Expected>' -TestCases @(
        @{ Hb = $true; Checks = @([pscustomobject]@{ Passed = $true }); Elapsed = 10; Expected = 'Passed' }
        @{ Hb = $false; Checks = @(); Elapsed = 10; Expected = 'Failed' }
        @{ Hb = $true; Checks = @([pscustomobject]@{ Passed = $false }); Elapsed = 10; Expected = 'Failed' }
        @{ Hb = $true; Checks = @([pscustomobject]@{ Passed = $true }); Elapsed = 90; Expected = 'RTO exceeded' }
    ) {
        Get-RestoreTestOutcome -HeartbeatHealthy $Hb -CheckResults $Checks -ElapsedMinutes $Elapsed -RtoMinutes 60 | Should -Be $Expected
    }
}

Describe 'Invoke-RestoreValidation' {
    BeforeEach {
        Mock -ModuleName RestoreValidation Get-VMSwitch { [pscustomobject]@{ Name = 'DR-Isolated'; SwitchType = 'Private' } }
        Mock -ModuleName RestoreValidation Get-VMNetworkAdapter { [pscustomobject]@{ Name = 'NIC1'; SwitchName = 'LAN' } }
        Mock -ModuleName RestoreValidation Connect-VMNetworkAdapter { }
        Mock -ModuleName RestoreValidation Start-VM { }
        Mock -ModuleName RestoreValidation Stop-VM { }
        Mock -ModuleName RestoreValidation Remove-VM { }
        Mock -ModuleName RestoreValidation Start-Sleep { }
        Mock -ModuleName RestoreValidation Get-VM { [pscustomobject]@{ Name = $Name; Heartbeat = 'OkApplicationsHealthy' } }
        Mock -ModuleName RestoreValidation Invoke-Command { @{ Passed = $true; Detail = 'ok' } }
    }
    It 'isolates, starts, checks and stops each VM' {
        $plan = Read-RestoreTestPlan -Path $script:ExamplePlan
        $run = Invoke-RestoreValidation -Plan $plan -Credential $script:Cred -Cleanup Stop
        @($run.Results).Count | Should -Be 3
        @($run.Results | Where-Object Outcome -eq 'Passed').Count | Should -Be 3
        Should -Invoke -ModuleName RestoreValidation Connect-VMNetworkAdapter -Times 3 -Exactly
        Should -Invoke -ModuleName RestoreValidation Start-VM -Times 3 -Exactly
        Should -Invoke -ModuleName RestoreValidation Invoke-Command -Times 10 -Exactly
        Should -Invoke -ModuleName RestoreValidation Stop-VM -Times 3 -Exactly
        Should -Invoke -ModuleName RestoreValidation Remove-VM -Times 0 -Exactly
        Get-RestoreValidationExitCode -Run $run | Should -Be 0
    }
    It 'removes VMs only with -Cleanup Remove' {
        $plan = Get-TestPlan -Vms @([pscustomobject]@{ name = 'VM1' })
        $null = Invoke-RestoreValidation -Plan $plan -Credential $script:Cred -Cleanup Remove
        Should -Invoke -ModuleName RestoreValidation Remove-VM -Times 1 -Exactly
    }
    It 'refuses to run on an External switch before touching any VM' {
        Mock -ModuleName RestoreValidation Get-VMSwitch { [pscustomobject]@{ Name = 'DR-Isolated'; SwitchType = 'External' } }
        { Invoke-RestoreValidation -Plan (Get-TestPlan -Vms @([pscustomobject]@{ name = 'VM1' })) -Credential $script:Cred } | Should -Throw
        Should -Invoke -ModuleName RestoreValidation Start-VM -Times 0 -Exactly
    }
    It 'records an error for a VM that was not restored and carries on' {
        Mock -ModuleName RestoreValidation Get-VM { if ($Name -eq 'MISSING') { $null } else { [pscustomobject]@{ Name = $Name; Heartbeat = 'OkApplicationsHealthy' } } }
        $plan = Get-TestPlan -Vms @([pscustomobject]@{ name = 'MISSING' }, [pscustomobject]@{ name = 'VM2' })
        $run = Invoke-RestoreValidation -Plan $plan -Credential $script:Cred -Cleanup None
        $run.Results[0].Outcome | Should -Be 'Error'
        $run.Results[0].Error | Should -Match 'not found'
        $run.Results[1].Outcome | Should -Be 'Passed'
        Get-RestoreValidationExitCode -Run $run | Should -Be 2
        Should -Invoke -ModuleName RestoreValidation Stop-VM -Times 0 -Exactly
    }
    It 'skips guest checks when the heartbeat never arrives' {
        Mock -ModuleName RestoreValidation Get-VM { [pscustomobject]@{ Name = $Name; Heartbeat = 'NoContact' } }
        $plan = Get-TestPlan -Vms @([pscustomobject]@{ name = 'VM1'; bootTimeoutSeconds = 0; checks = @([pscustomobject]@{ type = 'Service'; name = 'DNS' }) })
        $run = Invoke-RestoreValidation -Plan $plan -Credential $script:Cred
        $run.Results[0].Outcome | Should -Be 'Failed'
        Should -Invoke -ModuleName RestoreValidation Invoke-Command -Times 0 -Exactly
        Get-RestoreValidationExitCode -Run $run | Should -Be 1
    }
}

Describe 'Reports' {
    BeforeAll {
        $hb = [pscustomobject]@{ Healthy = $true; Heartbeat = 'OkApplicationsHealthy'; Seconds = 120 }
        $check = [pscustomobject]@{ Check = 'Path <E:\x>'; Type = 'Path'; Passed = $false; Detail = 'E:\x & y not found' }
        $script:Run = [pscustomobject]@{
            PlanName = 'Plan <1>'; IsolatedSwitch = 'DR-Isolated'; HostName = 'HV-LAB01'
            Started = [datetime]'2026-10-17T09:00:00'; Finished = [datetime]'2026-10-17T09:20:00'; RtoMinutes = 60; Cleanup = 'Stop'
            Results = @(New-VMTestResult -VMName 'VM1' -Heartbeat $hb -CheckResults @($check) -ElapsedMinutes 5 -RtoMinutes 60)
        }
    }
    It 'encodes HTML and shows outcomes' {
        $html = ConvertTo-RestoreValidationHtml -Run $script:Run -Note 'fictional'
        $html | Should -Match 'Plan &lt;1&gt;'
        $html | Should -Match 'E:\\x &amp; y not found'
        $html | Should -Match '0 of 1 VM\(s\) passed'
        $html | Should -Match 'fictional'
    }
    It 'produces JSON with the exit code' {
        $json = ConvertTo-RestoreValidationJson -Run $script:Run | ConvertFrom-Json
        $json.exitCode | Should -Be 1
        $json.results[0].checks[0].passed | Should -BeFalse
    }
}

Describe 'Runner script' {
    It 'validates the example plan without touching VMs' {
        $script = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Invoke-RestoreValidation.ps1'
        $out = & pwsh -NoProfile -File $script -PlanPath $script:ExamplePlan -ValidateOnly
        $LASTEXITCODE | Should -Be 0
        ($out -join ' ') | Should -Match '3 VM\(s\)'
    }
}
