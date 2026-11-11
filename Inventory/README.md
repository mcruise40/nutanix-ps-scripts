# Inventory

Scripts for exporting asset/inventory data from Nutanix AHV environments via the Prism Central v4 REST API.

## Get-NtnxVmInventory.ps1

Exports an **asset inventory of all AHV VMs** from one or more Prism Central instances: sizing, guest OS, Nutanix Guest Tools (NGT) status, boot/vTPM configuration, network, DR protection, categories and placement. Covers every cluster registered to each Prism Central. Powered-off VMs are included by default.

| Parameter | Description |
|---|---|
| `-PcIp` (mandatory) | One or more Prism Central IPs/FQDNs, without `https://` or port. All clusters of each PC are covered |
| `-Credential` (mandatory) | `PSCredential` for Prism Central (same credential for all PCs) |
| `-VmNames` | Only these VM(s), case-insensitive, wildcards (`*`) supported |
| `-ClusterNames` | Only VMs on these cluster(s) (Prism Element cluster name) |
| `-ExcludePoweredOff` | Skip VMs that are not powered on |
| `-ApiVersion` | Nutanix v4 API revision. Default: `v4.2` |
| `-CsvPath` | Export to CSV (semicolon-delimited, UTF-8) |

```powershell
$creds = Get-Credential
.\Get-NtnxVmInventory.ps1 -PcIp 10.0.20.10 -Credential $creds -CsvPath .\VM-Inventory.csv
.\Get-NtnxVmInventory.ps1 -PcIp 10.0.20.10 -Credential $creds | Where-Object { -not $_.NGT_Installed -or $_.NGT_UpdateNeeded } | Format-Table VM, Cluster, NGT_Version, NGT_Available
.\Get-NtnxVmInventory.ps1 -PcIp 10.0.20.10,10.1.20.10 -Credential $creds -ClusterNames "NTNX-CL01" -ExcludePoweredOff | Format-Table
```

**Output columns:**

| Column | Meaning |
|---|---|
| `PrismCentral` / `Cluster` / `Host` | Where the VM is registered and currently running (names resolved via lookup) |
| `VM` / `Description` / `PowerState` | Basic identity and state |
| `Sockets` / `CoresPerSocket` / `vCPU` | vCPU = sockets × cores per socket × threads per core |
| `MemoryGB` | Configured memory in GiB (`memorySizeBytes / 1GB`) |
| `DiskCount` / `DiskTotalGB` | Number of virtual disks (CD-ROMs excluded) and their total provisioned size in GiB |
| `GuestOS` | Guest OS as reported by NGT (e.g. `windows:64:WindowsServer2019Standard`) - empty without NGT |
| `NGT_Installed` / `NGT_Enabled` / `NGT_Reachable` | NGT status. Installed but not reachable usually means the NGT service is stopped or its certificate expired |
| `NGT_Version` / `NGT_Available` / `NGT_UpdateNeeded` | Installed NGT version, version available on the cluster, and whether an upgrade is pending |
| `BootType` / `vTPM` / `MachineType` | `LegacyBoot` (BIOS) or `UefiBoot`, vTPM state, machine type (`PC`, `Q35`, ...) - relevant for Windows 11 / Server 2025 readiness |
| `MAC` / `IP` / `Subnet` | Per NIC, comma-separated. IPs include configured (IPAM) and guest-learned addresses |
| `Protection` | DR protection type (e.g. `UNPROTECTED`, `PD_PROTECTED`, `RULE_PROTECTED`) |
| `Categories` | Assigned categories as `key:value` |
| `Created` / `Updated` | Creation and last update time (local time) |
| `VmExtId` | Stable VM identifier (v4 extId) for matching against other tools |

The output objects have more than 4 properties, so PowerShell shows them as a list by default - pipe to `Format-Table` (with selected columns) for a table view.

**Implementation notes:**
- Endpoint: `GET /vmm/<ApiVersion>/ahv/config/vms` (paged with `$page`/`$limit`, 100 per page).
- Name lookups: clusters and hosts via `clustermgmt`, categories via `prism`, subnets via `networking` (`/config/...`). Each tries `-ApiVersion` first, then `v4.0`. If a lookup fails, the extId is shown instead and a warning is written; `-ClusterNames` then cannot be used.
- `guestTools` is missing entirely on VMs where NGT was never enabled - the NGT columns are then `False`/empty.
- NIC fields: the v4.2 response carries both the new (`nicBackingInfo`/`nicNetworkInfo`) and the legacy (`backingInfo`/`networkInfo`) structures; the script uses the new ones and falls back to the legacy ones.
- Field paths for disks and NICs come from the v4 schema and were not yet verified against a live response - if `DiskTotalGB`, `MAC` or `IP` stay empty, check with `$vm.disks | ConvertTo-Json -Depth 6` / `$vm.nics | ConvertTo-Json -Depth 6`.
- Certificate validation is disabled (`SkipCertificateCheck`), same as the other scripts. Requires PowerShell 7+.

## Get-NtnxFilesInventory.ps1

Exports an **inventory of Nutanix Files file servers and their shares** (SMB/NFS) from one or more Prism Central instances. One row per share; file servers without shares appear as a single row with empty share columns. Optionally enriched with file server details (AD, network, version, capacity) from the Prism Element clusters hosting Files.

| Parameter | Description |
|---|---|
| `-PcIp` (mandatory) | One or more Prism Central IPs/FQDNs, without `https://` or port |
| `-Credential` (mandatory) | `PSCredential` for Prism Central |
| `-FileServerNames` | Only these file server(s), case-insensitive, wildcards (`*`) supported |
| `-ShareNames` | Only these share(s), case-insensitive, wildcards (`*`) supported |
| `-ClusterIp` | Prism Element cluster VIP(s)/FQDN(s) hosting the file servers. Adds the `FS_*` details below |
| `-ClusterCredential` | Credentials for `-ClusterIp`. Defaults to `-Credential` |
| `-IncludeUsage` | Add per-share usage (`UsedGB`, `UsedPercent`, `SnapshotGB`, `Files`, `Connections`) and `FS_Files`. One extra API call per share |
| `-ApiVersion` | Files v4 API revision. Default: `v4.0` |
| `-CsvPath` | Export to CSV (semicolon-delimited, UTF-8) |

```powershell
$creds = Get-Credential
.\Get-NtnxFilesInventory.ps1 -PcIp 10.0.20.10 -Credential $creds -CsvPath .\Files-Inventory.csv
.\Get-NtnxFilesInventory.ps1 -PcIp 10.0.20.10 -Credential $creds -ClusterIp 10.0.20.20 -IncludeUsage | Format-Table FileServer, Share, Protocol, UsedGB, FS_AD_Domain
.\Get-NtnxFilesInventory.ps1 -PcIp 10.0.20.10 -Credential $creds -ShareNames "*backup*" | Format-Table FileServer, Share, State
```

**Share columns (v4 API):**

| Column | Meaning |
|---|---|
| `FileServer` / `Share` / `Description` | Identity. A share is a "mount target" in the v4 API |
| `Protocol` / `Type` / `State` / `Path` | `SMB`, `NFS` (plus secondary protocol), share type (`GENERAL`, `HOMES`, `DISTRIBUTED`, `STANDARD`), `ONLINE`/`OFFLINE`, path |
| `MaxSizeGB` | Configured share limit. `0` = no limit (then `UsedPercent` stays empty) |
| `UsedGB` / `UsedPercent` / `SnapshotGB` / `Files` / `Connections` | Latest sample of the last hour, only with `-IncludeUsage` |
| `WorkloadType` / `Compression` / `PreviousVersions` / `SnapshotsPaused` / `WORM` | Share settings |
| `SMB_Encryption` / `SMB_ABE` / `SMB_ContinuousAvailability` | SMB3 encryption, access-based enumeration, continuous availability |
| `NFS_Auth` / `NFS_Access` / `NFS_Squash` | NFS authentication, default access, squash type |
| `FileServerExtId` / `ShareExtId` | Stable v4 identifiers |

**File server columns (`FS_*`, only with `-ClusterIp`, repeated on every row of a file server):**
`FS_Cluster`, `FS_Version`, `FS_State`, `FS_UpgradeRunning`, `FS_FSVMs`, `FS_FSVM_vCPU`, `FS_FSVM_MemGiB`, `FS_AD_Joined`, `FS_AD_Domain`, `FS_AD_OU`, `FS_AD_PrefDC`, `FS_AD_Protocol`, `FS_AD_Rfc2307`, `FS_LDAP`, `FS_NfsVersion`, `FS_NfsV4Domain`, `FS_DnsDomain`, `FS_DnsServers`, `FS_NtpServers`, `FS_ClientNetwork`, `FS_ClientIPs`, `FS_ExternalIP`, `FS_Shares`, `FS_HomeShares`, `FS_NestedShares`, `FS_SizeGB`, `FS_UsedGB`, `FS_FreeGB`, `FS_SnapshotGB`, `FS_Files`, `FS_Connections`, `FS_Compression`, `FS_BlockedExt`, `FS_MetroRole`, `FS_ProtectionDomain`, `FS_Created`, `FS_Description`.

**Implementation notes:**
- Endpoints: `GET /files/v4.0/config/file-servers` and `.../file-servers/{id}/mount-targets` (paged with `$page`/`$limit`). Usage: `GET /files/v4.0/stats/file-servers/{id}` and `.../mount-targets/{id}`.
- The v4.0 `FileServer` object only carries `name` and `extId` - there is no AD, version, network or capacity information. Those come from the Prism Element v1 API `GET /PrismGateway/services/rest/v1/vfilers` on the hosting cluster (`-ClusterIp`), matched to the v4 list by UUID, then by name. The AD service account password in that response is never read.
- The stats endpoints require `$startTime` **and** `$endTime`; without `$endTime` they answer `40015: 2009`. A usage call that fails is reported as a warning and leaves the usage columns empty.
- Certificate validation is disabled (`SkipCertificateCheck`), same as the other scripts. Requires PowerShell 7+.

