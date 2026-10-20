# RecoveryPoints

Scripts for managing Nutanix AHV recovery points via the Prism Central v4 REST API (`/dataprotection/v4.2/...`). Covers listing, creating (on-demand, per VM or per category), and deleting recovery points, plus a guided cleanup of expired recovery points and recovery points whose VM no longer exists.

## Shared implementation

`Get-`, `New-` and `Remove-` scripts implement the same `Invoke-NtnxApi` / `Get-AllNtnxVms` helper functions locally (not a shared module). `Invoke-NtnxRecoveryPointCleanup.ps1` has its own helpers, see its section below.

- **Auth:** Basic Auth header built from the supplied `PSCredential`.
- **`Ntnx-Request-Id` header:** automatically attached on every `POST`/`PUT`/`DELETE` call (mandatory idempotency token for v4 write operations).
- **Pagination:** `Get-AllNtnxVms` pages through `/vmm/v4.2/ahv/config/vms` using `$page` (zero-based) and `$limit` (capped at 100 by the API). Note: `$offset` is silently ignored by the API — using it causes an endless loop, which is why `$page` is used instead.
- **Certificate validation:** disabled by default (`SkipCertificateCheck`) — suited for lab environments with self-signed certificates; adjust for production.
- **Error handling:** API errors surface the actual response body (`$_.ErrorDetails.Message`) instead of just the generic HTTP status, and are re-thrown as terminating errors.

## Get-NtnxRecoveryPoints.ps1

Lists existing recovery points, optionally filtered.

| Parameter | Description |
|---|---|
| `-PcIp` (mandatory) | Prism Central IP/FQDN, without `https://` or port |
| `-Credential` (mandatory) | `PSCredential` for Prism Central |
| `-VmNames` | Filter to specific VM(s) by name. Mutually exclusive with `-CategoryKey`/`-CategoryValue` |
| `-CategoryKey` / `-CategoryValue` | Filter to all VMs tagged with this category key/value pair |
| `-ApiVersion` | Nutanix v4 API revision. Default: `v4.2` |
| `-Raw` | Output unmodified API objects instead of the simplified view |

```powershell
.\Get-NtnxRecoveryPoints.ps1 -PcIp 10.0.20.10 -Credential $creds
.\Get-NtnxRecoveryPoints.ps1 -PcIp 10.0.20.10 -Credential $creds -VmNames "VM01","VM02"
.\Get-NtnxRecoveryPoints.ps1 -PcIp 10.0.20.10 -Credential $creds -CategoryKey "Patching" -CategoryValue "Group01"
.\Get-NtnxRecoveryPoints.ps1 -PcIp 10.0.20.10 -Credential $creds -Raw | Select-Object -First 1 | ConvertTo-Json -Depth 10
```

**Implementation notes:**
- Field names for the recovery-points `GET` response are not fully confirmed against an official field list (no official schema found for this specific endpoint). `creationTime`/`expirationTime` are inferred from a related VMM SDK object description. Missing/renamed fields show up blank rather than erroring — use `-Raw` to inspect the actual response if something looks off.
- Recovery points with no `vmRecoveryPoints` (e.g. Volume-Group-only, or legacy entries not created via this API) are handled without throwing — their VM column is simply empty.
- Output is sorted by `Created` descending.

## New-NtnxGroupRecoveryPoint.ps1

Creates on-demand recovery points for a group of VMs — **one API call per VM**, always, for both crash-consistent and app-consistent. This avoids the API's 1-VM-per-request limit for app-consistent requests (error `DP-10100`) and keeps behavior uniform across both modes. A failure/timeout on one VM does not stop the others; see the summary line at the end.

| Parameter | Description |
|---|---|
| `-PcIp` / `-Credential` (mandatory) | See above |
| `-VmNames` | Explicit VM name list (case-insensitive matching). Mutually exclusive with `-CategoryKey`/`-CategoryValue` |
| `-CategoryKey` / `-CategoryValue` | Target all VMs tagged with this category |
| `-RecoveryPointName` | Name used as-is for every created recovery point (same name across all targeted VMs — no VM suffix, since Prism Central's Data Protection view is already organized per-VM). Default: `OnDemand-<timestamp>` |
| `-RetentionDays` | Days until the recovery point expires. Default: `1` |
| `-ApiVersion` | Default: `v4.2` |
| `-TimeoutSeconds` | Max wait per-VM task polling. Default: `600` |
| `-AppConsistent` | Requests `APPLICATION_CONSISTENT` instead of `CRASH_CONSISTENT`. Requires NGT on the guest (VSS on Windows, or `/usr/local/sbin/pre_freeze` + `/usr/local/sbin/post_thaw` on Linux) — without these, Nutanix silently falls back to crash-consistent, no error |
| `-ProjectExtId` | Optional; relevant mainly in project-scoped/multi-tenant setups (e.g. Nutanix Central). Omitted from the request entirely if not supplied |

Supports `-WhatIf` / `-Confirm` (`ConfirmImpact = 'Medium'`).

```powershell
.\New-NtnxGroupRecoveryPoint.ps1 -PcIp 10.0.0.10 -Credential $creds -VmNames "VM01" -WhatIf
.\New-NtnxGroupRecoveryPoint.ps1 -PcIp 10.0.0.10 -Credential $creds -VmNames "VM01","VM02"
.\New-NtnxGroupRecoveryPoint.ps1 -PcIp 10.0.0.10 -Credential $creds -CategoryKey "Patching" -CategoryValue "Group1" -WhatIf
.\New-NtnxGroupRecoveryPoint.ps1 -PcIp 10.0.0.10 -Credential $creds -CategoryKey "Patching" -CategoryValue "Group1" -RecoveryPointName "PrePatch" -RetentionDays 3 -TimeoutSeconds 900
.\New-NtnxGroupRecoveryPoint.ps1 -PcIp 10.0.0.10 -Credential $creds -CategoryKey "Patching" -CategoryValue "Group1" -AppConsistent
```

**Implementation notes:**
- The field schema for `-AppConsistent` is partially inferred, not fully confirmed — verify against the official API reference at developers.nutanix.com before production use (v4 endpoints are not published in Prism Central's local REST API Explorer).
- `v4.3`/`v4.4` were not supported in the lab PC this was tested against; v4 revisions are documented as backward-compatible within the v4 family, so `-ApiVersion` normally only needs changing to intentionally use a newer revision's features.
- For app-consistent requests, `writers` is omitted from `applicationConsistentProperties` — the API rejects an empty array (`minItems 1`).
- Each recovery point creation is polled individually (5s interval) until `SUCCEEDED`/failure or `-TimeoutSeconds` is reached; a timeout produces a warning, not a terminating error, so remaining VMs still get processed.

## Remove-NtnxRecoveryPoint.ps1

Deletes one or more recovery points by ExtId.

| Parameter | Description |
|---|---|
| `-PcIp` / `-Credential` (mandatory) | See above |
| `-RecoveryPointExtIds` (mandatory) | One or more ExtIds (e.g. from `Get-NtnxRecoveryPoints.ps1`'s `ExtId` column) |
| `-ApiVersion` | Default: `v4.2` |
| `-TimeoutSeconds` | Default: `600` |

```powershell
.\Remove-NtnxRecoveryPoint.ps1 -PcIp 10.0.20.10 -Credential $creds -RecoveryPointExtIds "1ffff90f-f11f-4613-88d6-ceadac77f16d" -WhatIf
.\Remove-NtnxRecoveryPoint.ps1 -PcIp 10.0.20.10 -Credential $creds -RecoveryPointExtIds "id1","id2","id3"
.\Remove-NtnxRecoveryPoint.ps1 -PcIp 10.0.20.10 -Credential $creds -RecoveryPointExtIds "id1","id2","id3" -Confirm:$false
```

**⚠️ Safety:** Deletion is irreversible. `ConfirmImpact` is `'High'`, matching the default `$ConfirmPreference` — so **without any extra parameter, the script prompts individually for each recovery point** (standard ShouldProcess prompt: Yes/No/Yes to All/No to All/Halt). Pass `-Confirm:$false` to skip all prompts and delete immediately. Note: a bare `-Confirm` (without `:$false`) does **not** skip prompting — by PowerShell design, `-Confirm` always means "force a prompt", so it has no effect here since prompting already happens by default. `-WhatIf` previews without deleting or prompting, as usual.

**Implementation notes:**
- Resolves and displays the associated VM name(s) for each recovery point where available (best-effort — falls back to just the ExtId if the lookup `GET` fails, e.g. already deleted or a transient error).
- Volume-Group-only recovery points have no associated VM — shown without a VM tag.


## Invoke-NtnxRecoveryPointCleanup.ps1

Guided, interactive cleanup of recovery points that are **expired** or whose **VM / volume group no longer exists**, across one or more Prism Centrals. Requires PowerShell 7.

The script walks through five steps in the terminal:

1. **Connect**: asks how many Prism Centrals to check, their addresses and logins, and checks every login before anything else happens (wrong password, missing permissions and unsupported API versions are reported per Prism Central, with the option to log in again or change the address).
2. **Collect**: reads VMs (AHV and ESXi), volume groups and recovery points from all Prism Centrals, and the storage usage of their clusters (see [Storage tracking](#storage-tracking)).
3. **Review**: lists one row per VM / volume group with reason, Prism Central(s), number of recovery points, oldest/newest, days overdue and space.
4. **Select**: pick the rows to delete (see commands below).
5. **Delete**: shows the total per Prism Central, asks you to type the number of recovery points to confirm, deletes them in batches, and writes a log file and a results CSV.

The mode is shown at the start and in every step title: **`DRY RUN`** (yellow) when started with `-WhatIf`, **`STORAGE REPORT`** with `-StorageReport`, otherwise **`LIVE`** (red). The log and CSV files carry the mode in their name.

### Recommended process

What most environments need, in this order. Start every round with a dry run and check the list before deleting anything.

| # | Command | At `Selection:` | What it does |
|---|---|---|---|
| 1 | `.\Invoke-NtnxRecoveryPointCleanup.ps1 -WhatIf -ExportCsv .\rp-list.csv` | `all`, then `y` | Dry run: nothing is deleted. Check `rp-list.csv` (Excel opens it directly). |
| 2 | `.\Invoke-NtnxRecoveryPointCleanup.ps1` | `expired`, then type the count | Deletes recovery points that are past their expiry date but were not removed by Nutanix. Their VM still exists. |
| 3 | `.\Invoke-NtnxRecoveryPointCleanup.ps1` | `missing 30`, then type the count | Deletes recovery points of VMs / volume groups that were deleted at least 30 days ago (newest recovery point older than 30 days). After this the deleted VMs cannot be restored anymore. |
| 4 | `.\Invoke-NtnxRecoveryPointCleanup.ps1` | `d <row>`, then row numbers | Rows marked `VM replaced` and VMs deleted less than 30 days ago: check each one, select by number only if nobody needs it back. |
| 5 | `.\Invoke-NtnxRecoveryPointCleanup.ps1 -StorageReport` (the next day) | - | Shows how much the used storage of each cluster changed since before the live runs, next to the space the script expected to free. Nothing is deleted. |

Afterwards, check the results CSV for `Failed` entries (open a Nutanix support case if expired recovery points cannot be deleted). The freed space shows up in Prism after the cluster's background cleanup (Curator), usually within several hours to a day (see [Storage tracking](#storage-tracking)). Run every step from the same folder, so the storage history is in one place.

### Storage tracking

Every run reads the used storage of each cluster (not Prism Central itself) in step 2 and appends it to `RecoveryPointCleanup_storage-history.csv` in the log folder. Live runs also record per Prism Central how many recovery points were deleted and how much space that was expected to free.

Each run, and `-StorageReport`, compares the current usage with the usage measured at the start of the first live run of the last 30 days, before anything was deleted:

```
Compared with before the first of 2 live runs (2026-10-20 14:05):
  PC1 pc-a.example.local: 86 recovery points deleted, expected to free at least 2.9 TiB
    cluster-a: used storage down by 5.6 TiB (now 41.2 TiB), logical down by 2.8 TiB
```

- **Used** is the cluster's `storageUsageBytes`, **logical** its `logicalStorageUsageBytes` (clustermgmt stats API). The expected value comes from the recovery points' exclusive usage. The API does not document whether these values include the extra data copies the cluster keeps for redundancy, so compare the trend rather than expecting the exact number.
- **Timing:** a deleted recovery point disappears from Prism at once, and its task shows as succeeded. The data itself is only freed by the cluster's background cleanup (Curator), usually within several hours to a day. Check with `-StorageReport` the next day. Directly after a live run, used storage can even be slightly higher, because the clusters keep writing (VM writes, new recovery points, replication). The report says so when it runs within 24 hours of the deletion.
- **No decrease after 36 hours:** check the last Curator scans on a CVM (`curator_cli get_last_successful_scans`) and the recycle bin in Prism, or open a case with Nutanix support. The report shows this hint as well.
- Other changes on the cluster at the same time (new snapshots, growing or deleted VMs) are part of the difference.
- If the storage cannot be read (no permission, older Prism Central), the script shows a warning and the cleanup works as before.

Started from `cmd.exe` or Windows PowerShell 5.1, `.\script.ps1` either opens the file in an editor or fails on `#Requires -Version 7.0`. Start PowerShell 7 first (`pwsh`), or in one line:

```
pwsh -ExecutionPolicy Bypass -File .\Invoke-NtnxRecoveryPointCleanup.ps1 -WhatIf -ExportCsv .\rp-list.csv
```

### Reference

| Parameter | Description |
|---|---|
| `-PrismCentral` | Prism Central IPs/FQDNs. If omitted, the script asks how many there are and for each address |
| `-Credential` | Login for all Prism Centrals. If omitted, asked per Prism Central (with the option to reuse the previous one) |
| `-ApiVersion` | Default: `v4.2`. Space per recovery point needs v4.2 or later |
| `-ExportCsv` | Writes the list from step 3 to this CSV (one line per recovery point) |
| `-LogDirectory` | Folder for the log file (`RecoveryPointCleanup_<time>_DRYRUN.log` / `_LIVE.log` / `_REPORT.log`), the results CSV (`..._results.csv`) and the storage history (`RecoveryPointCleanup_storage-history.csv`). Default: current folder |
| `-TimeoutSeconds` | Max wait per deletion task. Default: `600` |
| `-BatchSize` | Deletions started at the same time. Default: `5`. Use `2` if Prism Central keeps reporting its API rate limit |
| `-StorageReport` | Only connects, shows the storage usage per cluster and the change since before the last live runs, then exits. Nothing is deleted |

Supports `-WhatIf` (dry run: all steps, nothing deleted; log and CSVs are still written, status `Not deleted (dry run)`).

```powershell
.\Invoke-NtnxRecoveryPointCleanup.ps1
.\Invoke-NtnxRecoveryPointCleanup.ps1 -PrismCentral pc-a.example.local, pc-b.example.local
.\Invoke-NtnxRecoveryPointCleanup.ps1 -PrismCentral 10.0.20.10, 10.0.30.10 -ExportCsv .\rp.csv -WhatIf
.\Invoke-NtnxRecoveryPointCleanup.ps1 -PrismCentral 10.0.20.10, 10.0.30.10 -StorageReport
```

**Which recovery points are offered:**

| Reason | Rule |
|---|---|
| `VM missing` / `VG missing` | None of the VMs / volume groups in the recovery point exist on any of the Prism Centrals checked. All its recovery points are listed, expired or not. |
| `VM replaced` | Like `VM missing`, but an existing VM has the same name as the deleted one (for example restored from a recovery point or re-created). Not included in `missing`; check before deleting. |
| `Expired` | `expirationTime` is in the past, but the recovery point still exists. |

Never offered: recovery points that are not expired and still have their VM; secure recovery points (`isSecure`, deletion needs an approval); recovery points that hold VM template data (name `VmTemplateRP_...`, see below); recovery points whose VM / volume group could not be verified; recovery points with several VMs of which only some are missing. The review step shows how many were left out and why.

**What `all` deletes:** exactly the recovery points in the list, which means expired **or** VM/VG missing **or** VM replaced. It never touches anything that is not in the list. The script does not decide whether a recovery point is still needed:

- `VM missing` rows contain all recovery points of a deleted VM, including ones that have not expired yet. Once they are deleted, that VM can no longer be restored.
- `VM replaced` rows belong to a deleted VM whose name is now used by an existing VM, for example one restored from these recovery points.

Before you confirm, step 4 shows how many of the selected recovery points have not expired yet and which selected rows are `VM replaced`. For a live run, prefer `expired` and `missing 30` over `all`.

**Selection commands (step 4):**

| Input | Effect |
|---|---|
| `1,4,7-12` | Rows by number |
| `all` | Every row of the list from step 3, nothing else (see "What `all` deletes" below) |
| `expired` / `missing` | All `Expired` rows / all `VM missing` and `VG missing` rows |
| `missing 30` | `VM missing` and `VG missing` rows whose newest recovery point is older than 30 days (any number of days) |
| `d 5` | Show the individual recovery points of row 5 (PC, name, created, expires, space, ExtId) |
| `list` / `csv` / `q` | Show the table again / export it to CSV / quit without deleting |

**Implementation notes:**
- **Several Prism Centrals:** the VM inventory is combined across all of them, so a recovery point replicated from another site only counts as `VM missing` if its VM exists on none of them. Include every Prism Central that replicates with the ones you clean up.
- **Double check before "missing":** every VM / volume group that is not in the inventory is looked up by ID on every Prism Central. Only if all answer HTTP 404 does it count as missing; any other error makes it "unverified" (for example an account that cannot see all VMs).
- **Space:** `totalExclusiveUsageBytes` (dataprotection v4.2+), documented as the space that could be reclaimed after deleting the recovery point. If the list response has no size, single recovery points are read by ID. Totals are shown as "at least": data shared only between several deleted recovery points of the same VM is not counted for any single one. The space is freed after the cluster's background cleanup (Curator) has run.
- **Names of deleted VMs** come from the VM configuration stored in the recovery point (`GET /vmm/{version}/ahv/config/vm-recovery-points/{extId}`); if that fails, the row shows the VM ID. Older recovery points often have no VM configuration there, so they show the VM ID.
- **VM templates** store their data as recovery points ([Nutanix docs](https://portal.nutanix.com/page/documents/details?targetId=Prism-Central-Guide-vpc_2024_3_1%3Amul-vm-template-create-pc-t.html): "The template data is stored as a VM recovery point"). Their VM is not a normal VM, so they would look like `VM missing`. Recovery points named `VmTemplateRP_...` are therefore never offered; manage templates in Prism Central.
- **Last recovery point of a deleted VM:** in practice, Nutanix does not remove it when it expires, so one recovery point per deleted VM stays until it is deleted manually. These show up as `VM missing`.
- **Storage:** `GET /clustermgmt/{version}/config/clusters` (clusters with function `PRISM_CENTRAL` are skipped), then `GET /clustermgmt/{version}/stats/clusters/{extId}` for the last 2 hours (`$samplingInterval=300`, `$statType=LAST`), newest value. Uses `-ApiVersion` and falls back to `v4.0` if that version is not available.
- **API rate limit:** Prism Central limits how many API requests it accepts. When it answers with a rate-limit error (HTTP 429), the script waits (`Retry-After`, otherwise 5, 10, 20, 40, 60 s) and tries again. Deletions are spread out (0.5 s apart, task status every 5 s). Recovery points that still fail are reported as `Failed`, are not deleted, and are listed again in the next run.
- **Deletion:** `DELETE /dataprotection/{version}/config/recovery-points/{extId}` with an `NTNX-Request-Id`, then the task is polled. HTTP 404 on delete is reported as "already gone" (for example removed together with a copy).
- **Auth:** `Invoke-RestMethod -Authentication Basic -Credential` (the script itself never handles the password as plain text). Certificate validation is disabled, like the other scripts in this folder.
- Field names were checked against Nutanix's generated API clients (`ntnx-api-golang-clients`, dataprotection/vmm/volumes v4.2.1, clustermgmt v4.0.1 and v4.2.1). Run it with `-WhatIf` first in a new environment.
