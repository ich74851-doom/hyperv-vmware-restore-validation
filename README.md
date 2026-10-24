# Hyper-V / VMware Restore Validation

[![CI](https://github.com/ich74851-doom/hyperv-vmware-restore-validation/actions/workflows/ci.yml/badge.svg)](https://github.com/ich74851-doom/hyperv-vmware-restore-validation/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![PowerShell 5.1 | 7+](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5391FE)

Prove that restored virtual machines actually work. After your backup product restores VMs
onto a Hyper-V host, this PowerShell module isolates them, boots them, checks services,
ports and data paths inside the guest, and writes an HTML/JSON report you can keep as DR
test evidence.

> The example plan and sample report are fictional (`corp.example.com`, invented VM names
> and results). They show the format only.

## Overview

A backup job that reports "Success" does not prove the data can be restored and used. A
restore test answers that, but done by hand it is slow and inconsistent. This tool turns a
restore test into a repeatable plan:

1. Restore the VMs with your backup product under test names (for example `DC01-RESTORE`).
2. Describe what "working" means for each VM in a JSON plan.
3. Run the plan. Each VM is checked the same way every time, and the timings are compared
   with the RTO.

## Features

- JSON test plan with validation and clear error messages
- Safety first: refuses to run unless the plan's switch is Internal or Private, and moves
  every restored NIC onto it before the VM is started
- Waits for the Hyper-V integration services heartbeat with a per-VM timeout
- Guest checks over PowerShell Direct (no guest network needed): service running, TCP port
  listening, file or folder present
- Outcome per VM: Passed, Failed, RTO exceeded or Error, with RMM- and scheduler-friendly
  exit codes
- Self-contained HTML report and JSON output
- Clean-up options: leave running, turn off, or remove from Hyper-V; `-WhatIf` supported
- Notes for running the same checks on VMware vSphere with PowerCLI

## Quick start

Requirements: Windows Server with the Hyper-V role and PowerShell module, run as an
administrator. Guests need Windows Server 2016 / Windows 10 or later for PowerShell Direct.

```powershell
git clone https://github.com/ich74851-doom/hyperv-vmware-restore-validation.git
cd hyperv-vmware-restore-validation

# 1. Check a plan without touching any VM
.\scripts\Invoke-RestoreValidation.ps1 -PlanPath .\examples\restore-test-plan.json -ValidateOnly

# 2. Copy the example, edit VM names, switch and checks
New-Item -ItemType Directory -Path .\plans -Force | Out-Null
Copy-Item .\examples\restore-test-plan.json .\plans\quarterly.local.json

# 3. Run it (prompts for the guest credential)
.\scripts\Invoke-RestoreValidation.ps1 -PlanPath .\plans\quarterly.local.json -Cleanup Stop
```

## Usage

```powershell
# Preview what would happen
.\scripts\Invoke-RestoreValidation.ps1 -PlanPath .\plans\quarterly.local.json -WhatIf

# Remove the restored VMs from Hyper-V afterwards and write reports to a share
.\scripts\Invoke-RestoreValidation.ps1 -PlanPath .\plans\quarterly.local.json -Cleanup Remove `
    -OutputFolder \\fileserver\dr-evidence\2026-Q4

# Use the module directly
Import-Module .\src\RestoreValidation.psm1
$plan = Read-RestoreTestPlan -Path .\plans\quarterly.local.json
$run  = Invoke-RestoreValidation -Plan $plan -Credential (Get-Credential) -Cleanup None
ConvertTo-RestoreValidationHtml -Run $run | Set-Content .\reports\restore.html
```

A minimal plan:

```json
{
  "name": "Quarterly DR test",
  "isolatedSwitch": "DR-Isolated",
  "rtoMinutes": 60,
  "vms": [
    {
      "name": "FS01-RESTORE",
      "checks": [
        { "type": "Service", "name": "LanmanServer" },
        { "type": "TcpPort", "port": 445 },
        { "type": "Path", "path": "E:\\Shares" }
      ]
    }
  ]
}
```

Exit codes: `0` all VMs passed, `1` a VM failed or exceeded the RTO, `2` error.

- [docs/test-plan-schema.md](docs/test-plan-schema.md): every plan field and outcome
- [docs/vmware-powercli-notes.md](docs/vmware-powercli-notes.md): the same steps on vSphere
- [examples/sample-report.html](examples/sample-report.html): fictional sample report

## Project structure

```text
src/RestoreValidation.psm1          module: plan validation, isolation, heartbeat, guest checks, reports
scripts/Invoke-RestoreValidation.ps1 runner with reports and exit codes
examples/                           fictional test plan, sample report and its generator
docs/                               plan schema and VMware PowerCLI notes
tests/RestoreValidation.Tests.ps1   Pester tests (Hyper-V cmdlets are stubbed)
```

## Testing

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path .\tests
```

The tests stub the Hyper-V cmdlets, so they run on any OS. CI runs both on every push.

## Roadmap

- VMware vSphere provider using PowerCLI (`Wait-Tools`, `Invoke-VMScript`)
- More guest checks: HTTP endpoint, SQL query, event log errors since boot
- Ordered start groups with dependencies (for example domain controllers first)
- Optional e-mail or webhook delivery of the report

## License

[MIT](LICENSE)
