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
| `MaxReadyAt` | Timestamp (local time) of the highest sample |

Results are sorted by `MaxReadyPct` descending. The summary objects have more than 4 properties, so PowerShell shows them as a list by default - pipe to `Format-Table` for a table view.

**Implementation notes:**
- Endpoint: `GET /vmm/<ApiVersion>/ahv/stats/vms/{extId}` with `$startTime`, `$endTime`, `$samplingInterval`, `$statType` - one call per VM. Field names (`hypervisorCpuReadyTimePpm`, `hypervisorCpuUsagePpm`) are taken from the official Nutanix VMM SDK (`ntnx-vmm-py-client`, model `vmm.v4.ahv.stats.VmStatsTuple`).
- **Unit:** the API returns ppm (parts per million). `10'000 ppm = 1 %` - the script converts to percent.
- The script first requests only the needed fields via `$select`. If the PC rejects that expression, it automatically falls back to the full response for all further calls (only slower, same result).
- Time window is sent in UTC (`...Z`) to avoid URL-encoding issues with `+` offsets. Returned timestamps (UTC) are converted to local time for output.
- Cluster names are resolved via `/clustermgmt/<ApiVersion>/config/clusters`, falling back to `v4.0` if that revision is not available there. If both fail, the cluster extId is shown instead (and `-ClusterNames` cannot be used).
- With `-StatType AVG` short spikes are smoothed over the sampling interval. For peaks use a smaller `-SamplingInterval` and/or `-StatType MAX`.
- Whether Nutanix normalizes the value per vCPU (unlike VMware's per-VM summation in vCenter) is not explicitly documented - keep this in mind when comparing with vCenter values.
- A failure on one VM or one Prism Central produces a warning; the remaining VMs/PCs are still processed.
- Certificate validation is disabled (`SkipCertificateCheck`), same as the other scripts. Requires PowerShell 7+.

## Get-NtnxClusterCpuPeak.ps1

Reads the **hypervisor CPU usage** of all (or selected) clusters and their hosts from one or more Prism Central instances, determines the **peak** in the evaluation window and projects the cluster peak onto **N-1 hosts** (one host in maintenance or failed). Intended as a pre-check before rolling upgrades.

The projection is `MaxCpuPct × Nodes / (Nodes - 1)`. It assumes homogeneous nodes and an even redistribution of the load; additional CVM load during an upgrade is not included. Read it together with CPU Ready (`Get-NtnxVmCpuReady.ps1`) - CPU usage alone does not show contention.

| Parameter | Description |
|---|---|
| `-PcIp` (mandatory) | One or more Prism Central IPs/FQDNs, without `https://` or port. All clusters of each PC are covered |
| `-Credential` (mandatory) | `PSCredential` for Prism Central (same credential for all PCs) |
| `-ClusterNames` | Only these cluster(s) (Prism Element cluster name, case-insensitive) |
| `-Hours` | Look-back window in hours, ending now. Default: `168` (7 days) |
| `-StartTime` / `-EndTime` | Explicit window (local time) instead of `-Hours` |
| `-SamplingInterval` | Seconds per data point. Default: `300` (5 min), minimum `30` |
| `-StatType` | Down-sampling per interval: `MAX` (default), `AVG`, `MIN`, `LAST` |
| `-ThresholdPercent` | Threshold for the projected N-1 peak (`WARN` status). Default: `80` - rule of thumb, not an official Nutanix value |
| `-ClusterOnly` | Skip the per-host queries, cluster rows only |
| `-ApiVersion` | Nutanix v4 API revision. Default: `v4.2`, falls back to `v4.0` |
| `-CsvPath` | Export to CSV (semicolon-delimited, UTF-8) |
| `-Raw` | One row per cluster/host and sample instead of the summary |

```powershell
$creds = Get-Credential
.\Get-NtnxClusterCpuPeak.ps1 -PcIp 10.0.20.10 -Credential $creds | Format-Table
.\Get-NtnxClusterCpuPeak.ps1 -PcIp 10.0.20.10,10.1.20.10 -Credential $creds -ClusterOnly -CsvPath .\cpupeak.csv
.\Get-NtnxClusterCpuPeak.ps1 -PcIp 10.0.20.10 -Credential $creds -ClusterNames "NTNX-CL01" -Hours 24 -SamplingInterval 30 | Format-Table
.\Get-NtnxClusterCpuPeak.ps1 -PcIp 10.0.20.10 -Credential $creds -ClusterNames "NTNX-CL01" -ClusterOnly -Raw | Format-Table
```

**Output columns (summary):**

| Column | Meaning |
|---|---|
| `Scope` | `Cluster` or `Host`. Each cluster row is followed by its hosts, sorted by peak |
| `Status` | Cluster rows: `WARN` = projected N-1 peak above `-ThresholdPercent`, `OK`, `SINGLE NODE` or `NO DATA` |
| `Nodes` | Number of hosts in the cluster |
| `MaxCpuPct` | Highest CPU usage (%) in the window |
| `ProjectedN1Pct` | Cluster rows only: peak projected onto N-1 hosts |
| `MaxCpuAt` | Timestamp (local time) of the peak - useful for choosing the maintenance window |
| `AvgCpuPct` | Mean of the samples. With `-StatType MAX` this is the mean of the per-interval peaks, not the true average |
| `Samples` | Number of data points |

**Implementation notes:**
- Endpoints: `GET /clustermgmt/<ApiVersion>/stats/clusters/{extId}` and `.../stats/clusters/{clusterExtId}/hosts/{hostExtId}` with `$startTime`, `$endTime`, `$samplingInterval`, `$statType`. Field name `hypervisorCpuUsagePpm` is taken from the official Nutanix clustermgmt SDK (`clustermgmt.v4.stats.ClusterStats` / `HostStats`, metrics as `TimeValuePair` arrays).
- Entity stats via the v4 API require Prism Central pc.2024.1 / AOS 6.8 or later.
- **Unit:** ppm, converted to percent (`10'000 ppm = 1 %`).
- The Prism Central self-registration (`clusterFunction` = `PRISM_CENTRAL`) is excluded automatically.
- `$select` fallback, UTC time window, error handling per cluster/host and PC: same behaviour as `Get-NtnxVmCpuReady.ps1`.
- Certificate validation is disabled (`SkipCertificateCheck`), same as the other scripts. Requires PowerShell 7+.
