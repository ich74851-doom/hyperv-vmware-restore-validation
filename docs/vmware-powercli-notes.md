# Running the same validation on VMware vSphere

The module currently automates Hyper-V. The same steps map to VMware PowerCLI as below.
This is a reference for running the checks by hand or extending the module; the PowerCLI
path is not implemented or tested in this repository yet (see the roadmap).

| Step | Hyper-V (implemented) | VMware PowerCLI equivalent |
| --- | --- | --- |
| Connect | Run on the Hyper-V host | `Connect-VIServer -Server vcenter.corp.example.com` |
| Isolated network | Internal or Private `VMSwitch` | A port group on a standard or distributed switch with no physical uplinks |
| Move NICs | `Get-VMNetworkAdapter` / `Connect-VMNetworkAdapter` | `Get-NetworkAdapter -VM $vm \| Set-NetworkAdapter -Portgroup 'DR-Isolated' -Confirm:$false` |
| Start | `Start-VM` | `Start-VM -VM $vm` |
| Wait for guest | Heartbeat via `Get-VM` | `Wait-Tools -VM $vm -TimeoutSeconds 600` |
| Guest checks | PowerShell Direct (`Invoke-Command -VMName`) | `Invoke-VMScript -VM $vm -ScriptText ... -GuestCredential $cred` (VMware Tools must be running) |
| Clean up | `Stop-VM -TurnOff`, `Remove-VM` | `Stop-VM -Kill`, `Remove-VM -DeletePermanently` |

Example guest check with PowerCLI:

```powershell
$vm = Get-VM -Name 'DC01-RESTORE'
Get-NetworkAdapter -VM $vm | Set-NetworkAdapter -Portgroup 'DR-Isolated' -Confirm:$false
Start-VM -VM $vm | Out-Null
Wait-Tools -VM $vm -TimeoutSeconds 600 | Out-Null
$script = "(Get-Service -Name NTDS).Status"
Invoke-VMScript -VM $vm -ScriptText $script -ScriptType Powershell -GuestCredential $cred
```

Notes:

- Confirm the isolated port group really has no uplinks before powering on a restored
  domain controller or application server, to avoid duplicate names and IP addresses on
  the production network.
- Many backup products can also run their own isolated verification (for example sandbox
  or virtual lab features). This tool is meant for teams that want a product-neutral,
  scriptable check and a consistent report for DR test evidence.
