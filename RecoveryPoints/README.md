# RecoveryPoints

Scripts for managing Nutanix AHV recovery points via the Prism Central v4 REST API (`/dataprotection/v4.2/...`). Covers listing, creating (on-demand, per VM or per category), and deleting recovery points.

## Shared implementation

All three scripts implement the same `Invoke-NtnxApi` / `Get-AllNtnxVms` helper functions locally (not a shared module):

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
