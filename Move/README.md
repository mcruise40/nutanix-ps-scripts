# Move

Tooling for Nutanix Move VM migrations: checking VirtIO driver status on Windows guests, preparing individual VMs for migration, and distributing that preparation across multiple servers at once.

## Typical workflow

1. **Get-WindowsNutanixVirtIO.ps1** — check which target servers already have (or lack) the VirtIO driver, before migration.
2. **NutanixMove_VMPrep.ps1** — run on an individual VM to prepare it for Move (NGT, VirtIO, SAN policy, VMware Tools removal, IP retention) - based on Nutanix Move original preparation script.
3. **NutanixMove_MultiServerDeployment.ps1** — push and run step 2's script across many servers at once via WinRM, instead of doing it manually per server.

## Get-WindowsNutanixVirtIO.ps1

Checks a list of Windows servers via remote registry query for an installed Nutanix VirtIO driver, and exports the result to CSV.

**Configuration (edit directly in the script):**
- `$servers` — array of server names, or read from a file via `Get-Content -Path "C:\servers.txt"` (commented-out alternative already included in the script)
- CSV export path — currently hardcoded to `C:\NutanixVirtIO_Check.csv`

**How it works:**
- Uses `Invoke-Command -ComputerName $server` (requires WinRM/remoting access to each target)
- Queries both `HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*` and the `Wow6432Node` equivalent, filtered to `DisplayName -like "*Nutanix VirtIO*"`
- Per server, reports one of three states: `Installed` (with `DisplayName`, `DisplayVersion`, `Publisher`, `InstallDate`), `Not Found`, or `Error: <exception message>` (e.g. unreachable host, access denied)
- Results are printed via `Format-Table` and exported to CSV

**Limitations:** no built-in retry logic; a single unreachable server is caught and reported as an `Error` row rather than stopping the whole run for the remaining servers.

## NutanixMove_VMPrep.ps1

Downloads the official Nutanix Move preparation script (`esx_setup_uvm.ps1`) directly from the Move appliance's web server and runs it locally on the target VM with a fixed set of parameters.

**Configuration (edit directly in the script):**

| Variable | Purpose | Default in script |
|---|---|---|
| `$NutanixMoveIp` | IP of the Move appliance to download the prep script from | `10.0.0.1` — **must be changed per environment** |
| `$retainIP` | Keep the VM's existing IP configuration after migration | `$true` |
| `$installNgt` | Install Nutanix Guest Tools | `$true` |
| `$installVirtio` | Install the VirtIO driver | `$true` |
| `$setSanPolicy` | Set the Windows SAN policy (relevant for multi-disk visibility on AHV) | `$true` |
| `$uninstallVMwareTools` | Remove VMware Tools (relevant when migrating from ESXi) | `$true` |
| `$minPSVersion` | Minimum PowerShell version required by the downloaded prep script | `4.0.0` |
| `$virtIOVersion` | VirtIO driver version to install | `1.2.3.9` — **verify this matches the version bundled with your Move appliance** |

**How it works:**
- Sets `Set-ExecutionPolicy Bypass -Scope Process -Force` for the current process only
- Disables certificate validation for the download (`ServerCertificateValidationCallback`) and explicitly enables TLS 1.0–1.3 as allowed protocols, since Move appliances may present a self-signed certificate
- Downloads `esx_setup_uvm.ps1` as a string via `WebClient.DownloadString` and executes it in-process via `Invoke-Command -ScriptBlock ([scriptblock]::Create(...))`, passing all the configured parameters positionally

**⚠️ Note:** This script always downloads and executes the **current** `esx_setup_uvm.ps1` from the configured Move appliance at runtime — it is not a static/pinned copy. Behavior depends on whatever version of that script the appliance is currently serving.

## NutanixMove_MultiServerDeployment.ps1

Copies a local script (typically `NutanixMove_VMPrep.ps1`) to a list of remote Windows servers via PowerShell remoting (WinRM) and executes it there.

| Parameter | Description |
|---|---|
| `-Servers` (mandatory) | Array of server names/IPs to deploy to |
| `-LocalScript` (mandatory) | Full local path to the script to copy (e.g. `NutanixMove_VMPrep.ps1`) |
| `-RemoteScript` (mandatory) | Destination path on each remote server |

```powershell
.\NutanixMove_MultiServerDeployment.ps1 -Servers server01, server02 -LocalScript "C:\Scripts\NutanixMove_VMPrep.ps1" -RemoteScript "C:\Temp\NutanixMove_VMPrep.ps1"
```

**How it works:** for each server, opens a `New-PSSession`, copies the local script into the session via `Copy-Item -ToSession`, executes it remotely via `Invoke-Command -Session`, then closes the session. A failure on one server (caught via `try`/`catch`, logged with `Write-Warning`) does not stop deployment to the remaining servers.

**Requirements:** PowerShell 5.1 or PowerShell 7+, WinRM enabled on all target servers.
