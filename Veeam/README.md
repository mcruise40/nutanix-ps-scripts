# Veeam

Scripts for Veeam Backup & Replication in Nutanix environments.

## Test-VeeamBackupForVmList.ps1

Checks for a list of VMs whether Veeam Backup & Replication holds **restore points** for them, and optionally whether the latest restore point is newer than a cut-off. Typical use: before deleting a set of powered-off VMs, confirm that each one has a backup taken after the shutdown. Covers regular backups (VMware, Hyper-V, Agent) **and Nutanix AHV backups** (Veeam Plug-in for Nutanix AHV).

Run it on the VBR server (or a machine with the VBR console installed). The script only reads; it does not change the Veeam configuration.

| Parameter | Description |
|---|---|
| `-VmName` | VM names as an array. One of `-VmName`, `-VmListPath`, `-FromClipboard` is mandatory |
| `-VmListPath` | Text file with one VM name per line (empty lines and `#` comments are ignored) |
| `-FromClipboard` | Read VM names from the clipboard, e.g. a column copied from Excel |
| `-NotBefore` | Cut-off (e.g. shutdown time). VMs whose latest restore point is older are flagged `BACKUP TOO OLD` |
| `-Server` | VBR server for `Connect-VBRServer`. Default: `localhost`, only used if there is no existing session |
| `-CsvPath` | Export to CSV (semicolon-delimited, UTF-8) |
| `-PassThru` | Also return the result objects |

```powershell
.\Test-VeeamBackupForVmList.ps1 -FromClipboard -NotBefore "2026-01-31 14:00"
.\Test-VeeamBackupForVmList.ps1 -VmListPath C:\Temp\vms.txt -CsvPath C:\Temp\backupcheck.csv
.\Test-VeeamBackupForVmList.ps1 -VmName "VM01","VM02" -Server vbr01.example.local
$r = .\Test-VeeamBackupForVmList.ps1 -FromClipboard -PassThru
```

**Output columns:**

| Column | Meaning |
|---|---|
| `Status` | `OK`, `BACKUP TOO OLD` (latest restore point before `-NotBefore`) or `NO BACKUP` |
| `RestorePoints` | Number of restore points found for the VM (across all backups) |
| `LatestRestorePoint` | Creation time of the newest restore point |
| `Backups` | Backup / policy names the restore points belong to |

**Implementation notes:**
- Regular backups are read with the official pattern `Get-VBRBackup` -> `Get-VBRRestorePoint -Backup`.
- For Nutanix AHV backups `Get-VBRRestorePoint -Backup` fails with *"Cannot get restore points from backup ..., because it is encrypted or created by an enterprise application plug-in"*. There is no official cmdlet for AHV restore points. The script then falls back to the internal .NET methods `GetAllChildBackupsIncludingThis()` (AHV backups have one child backup per VM) and `GetOibs()` on each child backup.
- These internal methods are **not documented** by Veeam. Tested with VBR 13.1.2.57 / AHV Plug-in 13.10.1.4 and PowerShell 7.6. After a VBR update, verify the result against a VM with a known backup.
- In testing, `GetObjects()`, `GetAllStorages()` and `GetOibs($true)` on the parent AHV backup returned nothing; `GetLastOibs()` requires parameters.
- Backups that can be read neither way are listed in a warning - VMs in them would otherwise wrongly show up as `NO BACKUP`.
- VM name matching is case-insensitive but otherwise exact - names must match how Veeam knows the VM.
- The check relies on the Veeam configuration database only. It does not verify that the backup files are readable; use a health check or test restore for that.
