# Upgrade

Scripts that support Nutanix upgrades via the Prism Central v4 REST API.

## Test-NtnxUpgradeReadiness.ps1

Pre-upgrade readiness check. Verifies per cluster that **one host can be taken out of operation** (maintenance mode for LCM updates) without resource shortages, starts the **NCC health checks**, records **open alerts with the engineer's justification** and writes an **HTML report per cluster** to attach to the change. The upgrade itself is still started manually in LCM.

### Checks

| # | Check | FAIL (No-Go) | WARN (justification required) |
|---|---|---|---|
| 1 | Cluster and host state | Upgrade running/scheduled, host already in maintenance or not `NORMAL` | - |
| 2 | Data resiliency | Current FT below desired FT | FT state not returned |
| 3 | Storage | Usage above `-StorageThresholdPercent` of the resilient capacity | Capacity not determinable |
| 4 | HA reservation | - | Not enabled (best effort) |
| 5 | Memory with N-1 | Memory of running VMs above `-MemoryThresholdPercent` of the capacity without the largest host | - |
| 6 | CPU peak with N-1 | Projected cluster peak above `-CpuThresholdPercent` | No data |
| 7 | CPU Ready | - | VMs above `-CpuReadyThresholdPercent` |
| 8 | GPU with N-1 | GPU profiles in use do not fit without the host with the most cards | Capacity not determinable |
| 9 | Non-migratable VMs | - | At least one VM cannot be live-migrated |
| 10 | NCC health checks | - | Not started, failed or timed out |
| 11 | Open alerts | - | Each unacknowledged Critical/Warning alert |

**Rating:** any `FAIL` -> **NO-GO**, otherwise any `WARN` -> **GO WITH RESERVATIONS**, otherwise **GO**. For every `WARN` the script prompts for a justification (e.g. "false positive, fixed in AOS x.y"), which is written to the report together with engineer and timestamp. **Acknowledged alerts** need no justification - acknowledge known alerts in Prism beforehand; they are listed in the report for information.

The report also contains the current **vCPU:pCPU ratio**, **memory overcommit ratio**, a host table (memory, storage, CPU peak and time of peak), the non-migratable VMs and the top 10 VMs by CPU Ready.

### Parameters

| Parameter | Description |
|---|---|
| `-PcIp` (mandatory) | One or more Prism Central IPs/FQDNs, without `https://` or port |
| `-Credential` (mandatory) | `PSCredential` for Prism Central |
| `-ClusterNames` | Only these cluster(s), case-insensitive. Recommended - a change normally covers one cluster |
| `-ChangeId` | Change/ticket number, shown in the report and used in the file name |
| `-Engineer` | Name in the report. Default: current Windows user (`DOMAIN\user`) |
| `-Hours` | Window for CPU peak and CPU Ready. Default: `168` (7 days) |
| `-CpuThresholdPercent` | Max. projected N-1 CPU peak. Default: `80` |
| `-MemoryThresholdPercent` | Max. memory of running VMs vs. N-1 capacity. Default: `95` |
| `-StorageThresholdPercent` | Max. usage of the resilient capacity. Default: `75` (Prism default warning threshold) |
| `-CpuReadyThresholdPercent` | CPU Ready threshold per VM (warning only). Default: `5` |
| `-SkipNcc` | Do not start NCC |
| `-NccTimeoutMinutes` | Max. wait for NCC per cluster. Default: `60` |
| `-SkipCpuReady` | Skip CPU Ready (faster on large environments) |
| `-NonInteractive` | No prompts; warnings are reported as "no justification provided" |
| `-ReportFolder` | Folder for the HTML reports. Default: current directory |
| `-CsvPath` | CSV export (semicolon-delimited, UTF-8) of all check results |
| `-ApiVersion` | Preferred v4 revision. Default: `v4.2` |

```powershell
$creds = Get-Credential
.\Test-NtnxUpgradeReadiness.ps1 -PcIp 10.0.20.10 -Credential $creds -ClusterNames "NTNX-CL01" -ChangeId "CHG0012345"
.\Test-NtnxUpgradeReadiness.ps1 -PcIp 10.0.20.10 -Credential $creds -SkipNcc -NonInteractive | Format-Table Cluster, Verdict, Check, Result, Value
```

Report file name: `UpgradeReadiness_<cluster>_<change>_<yyyyMMdd-HHmm>.html`. Print it to PDF from the browser if the change tool requires PDF.

### Implementation notes

- Field names are taken from the official Nutanix v4 SDKs (`ntnx-clustermgmt/vmm/monitoring/prism-py-client` 4.3). Endpoints:
  - `clustermgmt`: `config/clusters` (`config.faultToleranceState`), `config/clusters/{id}/hosts`, `stats/clusters/{id}` and `.../hosts/{id}`, `config/clusters/{id}/$actions/compute-non-migratable-vms`, `config/clusters/{id}/non-migratable-vms-result/{id}`, `config/clusters/{id}/virtual-gpu-profiles` / `physical-gpu-profiles`
  - `vmm`: `ahv/config/vms`, `ahv/stats/vms` (list endpoint, `$statType=MAX`, 1-hour intervals)
  - `monitoring`: `serviceability/alerts`, `serviceability/clusters/{id}/$actions/run-system-defined-checks` (NCC)
  - `prism`: `config/tasks/{id}`
- **API revision** is negotiated per namespace: `-ApiVersion`, then `v4.2`, `v4.1`, `v4.0`; the first one that does not return 404 is cached.
- The script sends two `POST` requests per cluster: the NCC run and `compute-non-migratable-vms`. Neither changes the configuration. NCC findings are raised as alerts, so alerts are read **after** NCC has finished.
- **Non-migratable VMs:** the AOS action also covers affinity rules. The result ID is not documented explicitly; the script reads it from the task's affected entities / completion details. If the action is not available, it falls back to VM properties (`isLiveMigrateCapable`, GPU passthrough, PCIe devices) - affinity rules are then **not** covered (stated in the report).
- **Approximations:**
  - Resilient capacity = storage capacity minus the capacity of the largest host (FT1) or the two largest hosts (FT2). Prism's own value may differ slightly.
  - Memory N-1 uses the memory allotted to running VMs vs. the capacity without the largest host; CVM memory is included on both sides (conservative).
  - CPU N-1 = cluster peak × N / (N - 1), using the peak of the whole cluster (host peaks usually occur at different times). Storage-only nodes are excluded.
  - GPU N-1 assumes the profile capacity (`allocated + assignable`) is spread evenly across all GPU cards.
- Requires Prism Central pc.2024.1 / AOS 6.8 or later for entity stats. Certificate validation is disabled (`SkipCertificateCheck`), same as the other scripts. Requires PowerShell 7+.
- Tested against a mock of the v4 API (version fallback, all checks, rating, prompts, report). Validate against your own Prism Central before relying on it.
