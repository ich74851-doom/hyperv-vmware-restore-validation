# Test plan format

A test plan is a JSON file. See [`examples/restore-test-plan.json`](../examples/restore-test-plan.json).

| Field | Required | Description |
| --- | --- | --- |
| `name` | yes | Plan name shown in the report |
| `isolatedSwitch` | yes | Hyper-V switch for the restored VMs. Must be `Internal` or `Private`; the run stops if it is `External` |
| `rtoMinutes` | no | Recovery time objective per VM, from the start of its test to the last check |
| `bootTimeoutSeconds` | no | How long to wait for the heartbeat (default 600) |
| `vms` | yes | List of VMs to test |

Each VM:

| Field | Required | Description |
| --- | --- | --- |
| `name` | yes | Name of the restored VM in Hyper-V, for example `DC01-RESTORE` |
| `role` | no | Free text shown in the report |
| `bootTimeoutSeconds` | no | Overrides the plan timeout for this VM |
| `checks` | no | Guest checks to run after the heartbeat is healthy |

Check types:

| `type` | Fields | Passes when |
| --- | --- | --- |
| `Service` | `name` | The Windows service exists and is running |
| `TcpPort` | `port` | Something in the guest listens on the TCP port |
| `Path` | `path` | The file or folder exists in the guest |

## Outcomes

- **Passed**: heartbeat healthy, all checks passed, within the RTO.
- **Failed**: no healthy heartbeat before the timeout, or a check failed.
- **RTO exceeded**: everything passed but took longer than `rtoMinutes`.
- **Error**: the VM was not found or the test could not run.

The runner exits with `0` when all VMs passed, `1` when any failed or exceeded the RTO, and
`2` on errors.

## Tips

- Keep real plans out of source control: name them `*.local.json` (ignored by `.gitignore`).
- Test the VMs a service depends on first, for example a domain controller before SQL Server.
- Use a guest account that exists in the restored image. For a domain controller restored
  in isolation, a domain account works once AD services are up.
