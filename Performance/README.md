# Performance

Scripts for reading performance metrics of Nutanix AHV VMs via the Prism Central v4 REST API.

## Get-NtnxVmCpuReady.ps1

Reads the **CPU Ready Time** of all (or selected) AHV VMs from one or more Prism Central instances and summarizes it per VM. Covers every cluster registered to each Prism Central; can be narrowed to specific clusters, VM names or a Category.

CPU Ready is the share of time a VM was ready to run but had to wait for the hypervisor scheduler. Nutanix guidance (e.g. the SQL Server best practices) treats values **above 5 %** as cause for concern.

| Parameter | Description |
|---|---|
| `-PcIp` (mandatory) | One or more Prism Central IPs/FQDNs, without `https://` or port. All clusters of each PC are covered |
| `-Credential` (mandatory) | `PSCredential` for Prism Central (same credential for all PCs) |
| `-VmNames` | Only these VM(s), case-insensitive. Mutually exclusive with `-CategoryKey`/`-CategoryValue` |
| `-CategoryKey` / `-CategoryValue` | Only VMs tagged with this category key/value pair |
| `-ClusterNames` | Only VMs on these cluster(s) (Prism Element cluster name). Combinable with all of the above |
| `-Hours` | Look-back window in hours, ending now. Default: `24` |
| `-StartTime` / `-EndTime` | Explicit window (local time) instead of `-Hours` |
| `-SamplingInterval` | Seconds per data point. Default: `300` (5 min), minimum `30` |
| `-StatType` | Down-sampling per interval: `AVG` (default), `MAX`, `MIN`, `LAST` |
| `-ThresholdPercent` | Threshold for the `WARN` status. Default: `5` |
| `-IncludePoweredOff` | Also query VMs that are not powered on (normally skipped, they have no stats) |
| `-ApiVersion` | Nutanix v4 API revision. Default: `v4.2` |
| `-CsvPath` | Export to CSV (semicolon-delimited, UTF-8) |
| `-Raw` | One row per VM and sample instead of the per-VM summary |

```powershell
$creds = Get-Credential
.\Get-NtnxVmCpuReady.ps1 -PcIp 10.0.20.10 -Credential $creds | Format-Table
.\Get-NtnxVmCpuReady.ps1 -PcIp 10.0.20.10,10.1.20.10 -Credential $creds -Hours 168 -CsvPath .\cpuready.csv
.\Get-NtnxVmCpuReady.ps1 -PcIp 10.0.20.10 -Credential $creds -ClusterNames "NTNX-CL01" -Hours 2 -SamplingInterval 30 -StatType MAX | Format-Table
.\Get-NtnxVmCpuReady.ps1 -PcIp 10.0.20.10 -Credential $creds -CategoryKey "Workload" -CategoryValue "SQL" | Where-Object Status -eq 'WARN' | Format-Table
.\Get-NtnxVmCpuReady.ps1 -PcIp 10.0.20.10 -Credential $creds -VmNames "SQL01" -Raw | Format-Table
```

**Output columns (summary):**

| Column | Meaning |
|---|---|
| `Status` | `WARN` = at least one sample above `-ThresholdPercent`, `OK`, or `NO DATA` |
| `vCPUs` | Sockets × cores per socket × threads per core |
| `Samples` | Number of data points with a CPU Ready value |
| `AvgReadyPct` / `MaxReadyPct` | Average and highest CPU Ready (%) in the window |
| `AboveThreshold` | Number of samples above `-ThresholdPercent` |
| `AvgCpuUsagePct` | Average hypervisor CPU usage (%) - CPU Ready should always be read together with usage |
| `MaxReadyAt` | Timestamp (UTC) of the highest sample |

Results are sorted by `MaxReadyPct` descending. The summary objects have more than 4 properties, so PowerShell shows them as a list by default - pipe to `Format-Table` for a table view.

**Implementation notes:**
- Endpoint: `GET /vmm/<ApiVersion>/ahv/stats/vms/{extId}` with `$startTime`, `$endTime`, `$samplingInterval`, `$statType` - one call per VM. Field names (`hypervisorCpuReadyTimePpm`, `hypervisorCpuUsagePpm`) are taken from the official Nutanix VMM SDK (`ntnx-vmm-py-client`, model `vmm.v4.ahv.stats.VmStatsTuple`).
- **Unit:** the API returns ppm (parts per million). `10'000 ppm = 1 %` - the script converts to percent.
- The script first requests only the needed fields via `$select`. If the PC rejects that expression, it automatically falls back to the full response for all further calls (only slower, same result).
- Time window is sent in UTC (`...Z`) to avoid URL-encoding issues with `+` offsets.
- Cluster names are resolved via `/clustermgmt/<ApiVersion>/config/clusters`, falling back to `v4.0` if that revision is not available there. If both fail, the cluster extId is shown instead (and `-ClusterNames` cannot be used).
- With `-StatType AVG` short spikes are smoothed over the sampling interval. For peaks use a smaller `-SamplingInterval` and/or `-StatType MAX`.
- Whether Nutanix normalizes the value per vCPU (unlike VMware's per-VM summation in vCenter) is not explicitly documented - keep this in mind when comparing with vCenter values.
- A failure on one VM or one Prism Central produces a warning; the remaining VMs/PCs are still processed.
- Certificate validation is disabled (`SkipCertificateCheck`), same as the other scripts. Requires PowerShell 7+.
