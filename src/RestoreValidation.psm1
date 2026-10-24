#Requires -Version 5.1
<#
    RestoreValidation module

    Validates virtual machines that a backup product has already restored (or started with
    instant recovery) onto a Hyper-V host. For each VM in a JSON test plan it:

      1. confirms the VM's network adapters are on an isolated (Internal or Private) switch
      2. starts the VM and waits for the Hyper-V integration services heartbeat
      3. runs guest checks over PowerShell Direct (services, listening TCP ports, paths)
      4. records timings against the plan's RTO and builds an HTML/JSON report
      5. optionally stops or removes the restored VM

    The restore itself is out of scope: use your backup product to restore the VMs under
    test names first. Nothing here touches production VMs unless the plan names them, so
    always use dedicated restored-VM names in a plan.
#>

Set-StrictMode -Version Latest

$script:IsolatedSwitchTypes = @('Internal', 'Private')
$script:HealthyHeartbeat = @('OkApplicationsHealthy', 'OkApplicationsUnknown', 'Ok')
$script:CheckTypes = @('Service', 'TcpPort', 'Path')

function Test-RestoreTestPlan {
    <#
    .SYNOPSIS
        Validates a restore test plan object and returns a list of problems (empty if valid).
    .PARAMETER Plan
        Plan object, as returned by ConvertFrom-Json.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [object] $Plan
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $names = @($Plan.PSObject.Properties.Name)
    foreach ($required in 'name', 'isolatedSwitch', 'vms') {
        if ($names -notcontains $required -or $null -eq $Plan.$required -or "$($Plan.$required)" -eq '') {
            $problems.Add("Plan is missing '$required'.")
        }
    }
    if ($names -contains 'rtoMinutes' -and $null -ne $Plan.rtoMinutes -and [double]$Plan.rtoMinutes -le 0) {
        $problems.Add("'rtoMinutes' must be greater than zero.")
    }

    $i = 0
    $planVms = if ($names -contains 'vms') { @($Plan.vms | Where-Object { $null -ne $_ }) } else { @() }
    foreach ($vm in $planVms) {
        $i++
        $vmNames = @($vm.PSObject.Properties.Name)
        if ($vmNames -notcontains 'name' -or [string]::IsNullOrWhiteSpace($vm.name)) {
            $problems.Add("VM #$i is missing 'name'.")
            continue
        }
        $j = 0
        foreach ($check in @($(if ($vmNames -contains 'checks') { $vm.checks }) | Where-Object { $null -ne $_ })) {
            $j++
            $label = "VM '$($vm.name)' check #$j"
            if ($script:CheckTypes -notcontains $check.type) {
                $problems.Add("$label has unknown type '$($check.type)'. Use one of: $($script:CheckTypes -join ', ').")
                continue
            }
            $checkNames = @($check.PSObject.Properties.Name)
            switch ($check.type) {
                'Service' { if ($checkNames -notcontains 'name') { $problems.Add("$label (Service) needs 'name'.") } }
                'TcpPort' {
                    if ($checkNames -notcontains 'port' -or [int]$check.port -lt 1 -or [int]$check.port -gt 65535) {
                        $problems.Add("$label (TcpPort) needs a 'port' between 1 and 65535.")
                    }
                }
                'Path' { if ($checkNames -notcontains 'path') { $problems.Add("$label (Path) needs 'path'.") } }
            }
        }
    }
    if ($i -eq 0 -and $names -contains 'vms') { $problems.Add("Plan has no VMs.") }
    return $problems.ToArray()
}

function Read-RestoreTestPlan {
    <#
    .SYNOPSIS
        Reads and validates a JSON restore test plan. Throws if the plan is invalid.
    .PARAMETER Path
        Path to the JSON plan file.
    .EXAMPLE
        $plan = Read-RestoreTestPlan -Path .\examples\restore-test-plan.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "Test plan not found: $Path" }
    try {
        $plan = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Test plan '$Path' is not valid JSON: $($_.Exception.Message)"
    }
    $problems = @(Test-RestoreTestPlan -Plan $plan)
    if ($problems.Count -gt 0) {
        throw "Test plan '$Path' is invalid:`n - " + ($problems -join "`n - ")
    }
    return $plan
}

function Test-SwitchIsolation {
    <#
    .SYNOPSIS
        Returns $true when a Hyper-V virtual switch type is isolated from the physical network.
    .DESCRIPTION
        Internal and Private switches have no external uplink, so a restored VM cannot reach
        (and conflict with) the production machine it was restored from. External switches
        are rejected.
    .PARAMETER SwitchType
        The SwitchType value of a Hyper-V virtual switch.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $SwitchType
    )
    return ($script:IsolatedSwitchTypes -contains $SwitchType)
}

function Assert-IsolatedSwitch {
    <#
    .SYNOPSIS
        Throws unless the named Hyper-V switch exists and is Internal or Private.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SwitchName
    )
    $switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    if (-not $switch) { throw "Virtual switch '$SwitchName' was not found." }
    if (-not (Test-SwitchIsolation -SwitchType ([string]$switch.SwitchType))) {
        throw "Virtual switch '$SwitchName' is '$($switch.SwitchType)'. Restore tests must use an Internal or Private switch."
    }
}

function Connect-RestoredVMToIsolatedSwitch {
    <#
    .SYNOPSIS
        Connects every network adapter of a restored VM to the isolated switch.
    .OUTPUTS
        The number of adapters connected.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [string] $SwitchName
    )
    $count = 0
    foreach ($adapter in @(Get-VMNetworkAdapter -VMName $VMName)) {
        if ($adapter.SwitchName -eq $SwitchName) { continue }
        if ($PSCmdlet.ShouldProcess("$VMName adapter '$($adapter.Name)'", "Connect to isolated switch '$SwitchName'")) {
            Connect-VMNetworkAdapter -VMNetworkAdapter $adapter -SwitchName $SwitchName
            $count++
        }
    }
    return $count
}

function Wait-VMHeartbeat {
    <#
    .SYNOPSIS
        Waits until a VM reports a healthy integration services heartbeat, or times out.
    .OUTPUTS
        PSCustomObject with Healthy, Heartbeat and Seconds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [int] $TimeoutSeconds = 600,
        [int] $PollSeconds = 10
    )
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $heartbeat = 'Unknown'
    while ($true) {
        $vm = Get-VM -Name $VMName
        $heartbeat = [string]$vm.Heartbeat
        if ($script:HealthyHeartbeat -contains $heartbeat) {
            return [pscustomobject]@{ Healthy = $true; Heartbeat = $heartbeat; Seconds = [math]::Round($timer.Elapsed.TotalSeconds) }
        }
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
        Start-Sleep -Seconds $PollSeconds
    }
    return [pscustomobject]@{ Healthy = $false; Heartbeat = $heartbeat; Seconds = [math]::Round($timer.Elapsed.TotalSeconds) }
}

function Get-GuestCheckScriptBlock {
    <#
    .SYNOPSIS
        Returns the script block that runs one check inside the guest.
    .DESCRIPTION
        Each script block takes the check target as its only argument and returns a
        hashtable with Passed (bool) and Detail (string). They use only cmdlets available
        in Windows Server 2012 R2 and later guests.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param(
        [Parameter(Mandatory)] [ValidateSet('Service', 'TcpPort', 'Path')] [string] $Type
    )
    switch ($Type) {
        'Service' {
            return {
                param($Name)
                $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
                if (-not $svc) { return @{ Passed = $false; Detail = "Service '$Name' not found" } }
                @{ Passed = ([string]$svc.Status -eq 'Running'); Detail = "Service '$Name' is $($svc.Status)" }
            }
        }
        'TcpPort' {
            return {
                param($Port)
                $listening = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
                if ($listening.Count -gt 0) { @{ Passed = $true; Detail = "TCP $Port is listening" } }
                else { @{ Passed = $false; Detail = "Nothing is listening on TCP $Port" } }
            }
        }
        'Path' {
            return {
                param($Path)
                if (Test-Path -LiteralPath $Path) { @{ Passed = $true; Detail = "$Path exists" } }
                else { @{ Passed = $false; Detail = "$Path not found" } }
            }
        }
    }
}

function Get-CheckTarget {
    # Returns the argument passed to a check's script block and a readable label.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [object] $Check)
    switch ($Check.type) {
        'Service' { return @{ Target = [string]$Check.name; Label = "Service $($Check.name)" } }
        'TcpPort' { return @{ Target = [int]$Check.port; Label = "TCP $($Check.port)" } }
        'Path' { return @{ Target = [string]$Check.path; Label = "Path $($Check.path)" } }
    }
}

function Invoke-GuestCheck {
    <#
    .SYNOPSIS
        Runs one plan check inside a VM over PowerShell Direct and returns the result.
    .PARAMETER Credential
        A local or domain account in the restored guest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [object] $Check,
        [Parameter(Mandatory)] [pscredential] $Credential
    )
    $target = Get-CheckTarget -Check $Check
    try {
        $sb = Get-GuestCheckScriptBlock -Type $Check.type
        $r = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock $sb -ArgumentList $target.Target -ErrorAction Stop
        $passed = [bool]$r.Passed
        $detail = [string]$r.Detail
    }
    catch {
        $passed = $false
        $detail = "Check could not run: $($_.Exception.Message)"
    }
    [pscustomobject]@{ Check = $target.Label; Type = [string]$Check.type; Passed = $passed; Detail = $detail }
}

function Get-RestoreTestOutcome {
    <#
    .SYNOPSIS
        Works out the overall outcome of one VM test from its heartbeat, checks and timing.
    .OUTPUTS
        'Passed', 'Failed' or 'RTO exceeded'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [bool] $HeartbeatHealthy,
        [object[]] $CheckResults = @(),
        [double] $ElapsedMinutes = 0,
        [double] $RtoMinutes = 0
    )
    if (-not $HeartbeatHealthy) { return 'Failed' }
    if (@($CheckResults | Where-Object { -not $_.Passed }).Count -gt 0) { return 'Failed' }
    if ($RtoMinutes -gt 0 -and $ElapsedMinutes -gt $RtoMinutes) { return 'RTO exceeded' }
    return 'Passed'
}

function New-VMTestResult {
    # Builds a result object for one VM.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [string] $Role = '',
        [Parameter(Mandatory)] [object] $Heartbeat,
        [object[]] $CheckResults = @(),
        [double] $ElapsedMinutes = 0,
        [double] $RtoMinutes = 0,
        [string] $ErrorMessage = ''
    )
    $outcome = if ($ErrorMessage) { 'Error' } else {
        Get-RestoreTestOutcome -HeartbeatHealthy ([bool]$Heartbeat.Healthy) -CheckResults $CheckResults -ElapsedMinutes $ElapsedMinutes -RtoMinutes $RtoMinutes
    }
    [pscustomobject]@{
        VMName           = $VMName
        Role             = $Role
        Outcome          = $outcome
        Heartbeat        = [string]$Heartbeat.Heartbeat
        HeartbeatSeconds = [int]$Heartbeat.Seconds
        ElapsedMinutes   = [math]::Round($ElapsedMinutes, 1)
        RtoMinutes       = $RtoMinutes
        Checks           = @($CheckResults)
        Error            = $ErrorMessage
    }
}

function Stop-RestoredVM {
    <#
    .SYNOPSIS
        Turns off (and optionally deletes) a restored VM after testing.
    .DESCRIPTION
        Remove only deletes the VM's configuration from Hyper-V; the backup product or an
        administrator should remove restored disks according to its own clean-up process.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [switch] $Remove
    )
    if ($PSCmdlet.ShouldProcess($VMName, 'Turn off restored VM')) {
        Stop-VM -Name $VMName -TurnOff -Force
    }
    if ($Remove -and $PSCmdlet.ShouldProcess($VMName, 'Remove restored VM from Hyper-V')) {
        Remove-VM -Name $VMName -Force
    }
}

function Invoke-RestoreValidation {
    <#
    .SYNOPSIS
        Runs a restore test plan against restored VMs on this Hyper-V host.
    .PARAMETER Plan
        A plan from Read-RestoreTestPlan.
    .PARAMETER Credential
        Guest credential used for PowerShell Direct checks.
    .PARAMETER Cleanup
        None (leave VMs running), Stop (turn off) or Remove (turn off and remove from Hyper-V).
    .OUTPUTS
        PSCustomObject with plan details and one result per VM.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object] $Plan,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [ValidateSet('None', 'Stop', 'Remove')] [string] $Cleanup = 'Stop',
        [int] $PollSeconds = 10
    )
    $problems = @(Test-RestoreTestPlan -Plan $Plan)
    if ($problems.Count -gt 0) { throw "Plan is invalid: $($problems -join '; ')" }
    Assert-IsolatedSwitch -SwitchName $Plan.isolatedSwitch

    $planNames = @($Plan.PSObject.Properties.Name)
    $rto = if ($planNames -contains 'rtoMinutes') { [double]$Plan.rtoMinutes } else { 0 }
    $defaultTimeout = if ($planNames -contains 'bootTimeoutSeconds') { [int]$Plan.bootTimeoutSeconds } else { 600 }
    $started = Get-Date
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($vm in @($Plan.vms)) {
        $vmNames = @($vm.PSObject.Properties.Name)
        $role = if ($vmNames -contains 'role') { [string]$vm.role } else { '' }
        $timeout = if ($vmNames -contains 'bootTimeoutSeconds') { [int]$vm.bootTimeoutSeconds } else { $defaultTimeout }
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            if (-not (Get-VM -Name $vm.name -ErrorAction SilentlyContinue)) {
                throw "VM '$($vm.name)' was not found on this host. Restore it with your backup product first."
            }
            if (-not $PSCmdlet.ShouldProcess($vm.name, 'Isolate, start and test restored VM')) { continue }
            $null = Connect-RestoredVMToIsolatedSwitch -VMName $vm.name -SwitchName $Plan.isolatedSwitch -Confirm:$false
            Start-VM -Name $vm.name
            $hb = Wait-VMHeartbeat -VMName $vm.name -TimeoutSeconds $timeout -PollSeconds $PollSeconds
            $checks = @()
            if ($hb.Healthy -and $vmNames -contains 'checks') {
                $checks = @(foreach ($c in @($vm.checks)) { Invoke-GuestCheck -VMName $vm.name -Check $c -Credential $Credential })
            }
            $results.Add((New-VMTestResult -VMName $vm.name -Role $role -Heartbeat $hb -CheckResults $checks -ElapsedMinutes $timer.Elapsed.TotalMinutes -RtoMinutes $rto))
        }
        catch {
            $hb = [pscustomobject]@{ Healthy = $false; Heartbeat = 'n/a'; Seconds = 0 }
            $results.Add((New-VMTestResult -VMName $vm.name -Role $role -Heartbeat $hb -ElapsedMinutes $timer.Elapsed.TotalMinutes -RtoMinutes $rto -ErrorMessage $_.Exception.Message))
            continue
        }
        finally {
            if ($Cleanup -ne 'None' -and (Get-VM -Name $vm.name -ErrorAction SilentlyContinue)) {
                Stop-RestoredVM -VMName $vm.name -Remove:($Cleanup -eq 'Remove') -Confirm:$false
            }
        }
    }

    [pscustomobject]@{
        PlanName       = [string]$Plan.name
        IsolatedSwitch = [string]$Plan.isolatedSwitch
        HostName       = [System.Environment]::MachineName
        Started        = $started
        Finished       = Get-Date
        RtoMinutes     = $rto
        Cleanup        = $Cleanup
        Results        = $results.ToArray()
    }
}

function Get-RestoreValidationExitCode {
    <#
    .SYNOPSIS
        0 when every VM passed, 1 when any VM failed or exceeded the RTO, 2 when any VM errored.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)] [object] $Run)
    $outcomes = @($Run.Results | ForEach-Object { $_.Outcome })
    if ($outcomes -contains 'Error') { return 2 }
    if (@($outcomes | Where-Object { $_ -ne 'Passed' }).Count -gt 0) { return 1 }
    return 0
}

function ConvertTo-RestoreValidationHtml {
    <#
    .SYNOPSIS
        Renders a restore validation run as a self-contained HTML report.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [object] $Run,
        [string] $Note = ''
    )
    function Enc([object] $Value) { [System.Net.WebUtility]::HtmlEncode([string]$Value) }

    $passed = @($Run.Results | Where-Object Outcome -eq 'Passed').Count
    $total = @($Run.Results).Count
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append(@"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Restore validation: $(Enc $Run.PlanName)</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;max-width:1000px;margin:24px auto;padding:0 16px;color:#222}
h1{font-size:22px}h2{font-size:17px;margin-top:28px;border-bottom:1px solid #ddd;padding-bottom:4px}
.meta{color:#666;font-size:13px}.note{background:#fff8e1;border-left:4px solid #c77700;padding:8px 12px;font-size:13px}
table{border-collapse:collapse;width:100%;font-size:13px;margin-top:8px}th,td{border:1px solid #ddd;padding:5px 8px;text-align:left}
th{background:#f5f5f5}.Passed{color:#2e7d32;font-weight:600}.Failed,.Error{color:#c62828;font-weight:600}
.RTO{color:#c77700;font-weight:600}
</style></head><body>
<h1>Restore validation: $(Enc $Run.PlanName)</h1>
<p class="meta">Host $(Enc $Run.HostName) &middot; isolated switch $(Enc $Run.IsolatedSwitch) &middot; started $(Enc ($Run.Started.ToString('yyyy-MM-dd HH:mm'))) &middot; RTO target $(Enc $Run.RtoMinutes) min &middot; clean-up $(Enc $Run.Cleanup)</p>
"@)
    if ($Note) { $null = $sb.Append("<p class=`"note`">$(Enc $Note)</p>") }
    $null = $sb.Append("<p><strong>$passed of $total VM(s) passed.</strong></p><h2>Summary</h2><table><tr><th>VM</th><th>Role</th><th>Outcome</th><th>Heartbeat</th><th>Boot to heartbeat (s)</th><th>Elapsed (min)</th><th>Checks passed</th></tr>")
    foreach ($r in @($Run.Results)) {
        $cls = ($r.Outcome -split ' ')[0]
        $okChecks = @($r.Checks | Where-Object Passed).Count
        $null = $sb.Append("<tr><td>$(Enc $r.VMName)</td><td>$(Enc $r.Role)</td><td class=`"$cls`">$(Enc $r.Outcome)</td><td>$(Enc $r.Heartbeat)</td><td>$($r.HeartbeatSeconds)</td><td>$($r.ElapsedMinutes)</td><td>$okChecks / $(@($r.Checks).Count)</td></tr>")
    }
    $null = $sb.Append('</table>')
    foreach ($r in @($Run.Results)) {
        $null = $sb.Append("<h2>$(Enc $r.VMName)</h2>")
        if ($r.Error) { $null = $sb.Append("<p class=`"Error`">$(Enc $r.Error)</p>") }
        if (@($r.Checks).Count -gt 0) {
            $null = $sb.Append('<table><tr><th>Check</th><th>Result</th><th>Detail</th></tr>')
            foreach ($c in @($r.Checks)) {
                $res = if ($c.Passed) { 'Passed' } else { 'Failed' }
                $null = $sb.Append("<tr><td>$(Enc $c.Check)</td><td class=`"$res`">$res</td><td>$(Enc $c.Detail)</td></tr>")
            }
            $null = $sb.Append('</table>')
        }
        elseif (-not $r.Error) { $null = $sb.Append('<p>No guest checks ran.</p>') }
    }
    $null = $sb.Append("<p class=`"meta`">Generated by hyperv-vmware-restore-validation.</p></body></html>")
    return $sb.ToString()
}

function ConvertTo-RestoreValidationJson {
    <#
    .SYNOPSIS
        Serialises a run to JSON for ticketing or automation tools.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [object] $Run)
    $copy = [ordered]@{
        planName       = $Run.PlanName
        isolatedSwitch = $Run.IsolatedSwitch
        hostName       = $Run.HostName
        started        = $Run.Started.ToString('s')
        finished       = $Run.Finished.ToString('s')
        rtoMinutes     = $Run.RtoMinutes
        exitCode       = Get-RestoreValidationExitCode -Run $Run
        results        = @($Run.Results | ForEach-Object {
                [ordered]@{
                    vm = $_.VMName; role = $_.Role; outcome = $_.Outcome; heartbeat = $_.Heartbeat
                    heartbeatSeconds = $_.HeartbeatSeconds; elapsedMinutes = $_.ElapsedMinutes; error = $_.Error
                    checks = @($_.Checks | ForEach-Object { [ordered]@{ check = $_.Check; passed = $_.Passed; detail = $_.Detail } })
                }
            })
    }
    return ($copy | ConvertTo-Json -Depth 6)
}

Export-ModuleMember -Function Test-RestoreTestPlan, Read-RestoreTestPlan, Test-SwitchIsolation, Assert-IsolatedSwitch,
    Connect-RestoredVMToIsolatedSwitch, Wait-VMHeartbeat, Get-GuestCheckScriptBlock, Invoke-GuestCheck,
    Get-RestoreTestOutcome, New-VMTestResult, Stop-RestoredVM, Invoke-RestoreValidation,
    Get-RestoreValidationExitCode, ConvertTo-RestoreValidationHtml, ConvertTo-RestoreValidationJson
