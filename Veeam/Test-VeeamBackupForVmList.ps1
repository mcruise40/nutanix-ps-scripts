<#
.SYNOPSIS
    Checks whether Veeam Backup & Replication holds restore points for a list of VMs -
    including Nutanix AHV backups (Veeam Plug-in for Nutanix AHV).
.DESCRIPTION
    Typical use: before deleting a set of powered-off VMs, verify that every VM has a
    restore point and that the latest one was created after the shutdown.

    - Regular backups (VMware, Hyper-V, Agent) are read via Get-VBRRestorePoint -Backup.
    - Get-VBRRestorePoint -Backup rejects Nutanix AHV backups ("Cannot get restore points
      from backup ..., because it is encrypted or created by an enterprise application
      plug-in"). For those, the per-VM child backups are retrieved via the internal .NET
      method GetAllChildBackupsIncludingThis() and their restore points via GetOibs().
    - The script is read-only; it does not change anything in the Veeam configuration
      database.
.NOTES
    GetAllChildBackupsIncludingThis() and GetOibs() are internal methods of
    Veeam.Backup.Core.CBackup and are NOT officially documented. Tested with
    VBR 13.1.2.57 / Veeam Plug-in for Nutanix AHV 13.10.1.4 and PowerShell 7.6.
    They may change with future VBR releases - after an update, verify the result
    against a VM with a known backup.

    AHV backups are organized per VM: the policy backup (type "Nutanix AHV Backup") has
    one child backup per VM. GetObjects(), GetAllStorages() and GetOibs($true) on the
    parent returned nothing in testing; GetOibs() on the child backups works.

    The check is based on the Veeam configuration database only. It does not verify that
    the backup files are readable - use a health check / test restore for that.
.PARAMETER VmName
    VM names as an array. Alternatively use -VmListPath or -FromClipboard.
.PARAMETER VmListPath
    Text file with one VM name per line (empty lines and lines starting with # are ignored).
.PARAMETER FromClipboard
    Read the VM names from the clipboard (e.g. a column copied from Excel).
.PARAMETER NotBefore
    Optional cut-off (e.g. the time the VMs were shut down). If the latest restore point
    is older, the VM is flagged as "BACKUP TOO OLD".
.PARAMETER Server
    VBR server for Connect-VBRServer. Default: localhost. Only used if there is no
    existing VBR session.
.PARAMETER CsvPath
    Export the result to CSV (semicolon-delimited, UTF-8).
.PARAMETER PassThru
    Also return the result objects, e.g. $r = .\Test-VeeamBackupForVmList.ps1 ... -PassThru
.EXAMPLE
    .\Test-VeeamBackupForVmList.ps1 -FromClipboard -NotBefore "2026-01-31 14:00"
.EXAMPLE
    .\Test-VeeamBackupForVmList.ps1 -VmListPath C:\Temp\vms.txt -CsvPath C:\Temp\backupcheck.csv
.EXAMPLE
    .\Test-VeeamBackupForVmList.ps1 -VmName "VM01","VM02" -Server vbr01.example.local
#>
[CmdletBinding(DefaultParameterSetName = 'Names')]
param(
    [Parameter(ParameterSetName = 'Names', Mandatory)]
    [string[]]$VmName,

    [Parameter(ParameterSetName = 'File', Mandatory)]
    [string]$VmListPath,

    [Parameter(ParameterSetName = 'Clipboard', Mandatory)]
    [switch]$FromClipboard,

    [datetime]$NotBefore,

    [string]$Server = 'localhost',

    [string]$CsvPath,

    [switch]$PassThru
)

# --- Connection ------------------------------------------------------------
Import-Module Veeam.Backup.PowerShell -ErrorAction Stop -WarningAction SilentlyContinue
if (-not (Get-VBRServerSession -ErrorAction SilentlyContinue)) {
    Connect-VBRServer -Server $Server -ErrorAction Stop
}

# --- VM list ---------------------------------------------------------------
switch ($PSCmdlet.ParameterSetName) {
    'Names'     { $raw = $VmName }
    'File'      { $raw = Get-Content -Path $VmListPath }
    'Clipboard' { $raw = Get-Clipboard }
}
$vms = @($raw -split "`r?`n" |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith('#') } |
    Sort-Object -Unique)

if (-not $vms) { throw 'No VM names found.' }
Write-Host ("{0} VM names read." -f $vms.Count)

# --- Collect restore points of all backups ---------------------------------
$all        = New-Object System.Collections.Generic.List[object]
$unreadable = New-Object System.Collections.Generic.List[object]
$backups    = @(Get-VBRBackup)

foreach ($b in $backups) {
    try {
        # Regular backups (VMware, Hyper-V, Agent)
        Get-VBRRestorePoint -Backup $b -ErrorAction Stop | ForEach-Object {
            $all.Add([pscustomobject]@{
                Name         = $_.Name
                CreationTime = $_.CreationTime
                Backup       = $b.Name
                Source       = 'Get-VBRRestorePoint'
            })
        }
    }
    catch {
        # Plug-in backups, e.g. Nutanix AHV: read via the per-VM child backups
        try {
            foreach ($k in $b.GetAllChildBackupsIncludingThis()) {
                foreach ($oib in $k.GetOibs()) {
                    $all.Add([pscustomobject]@{
                        Name         = $oib.Name
                        CreationTime = $oib.CreationTime
                        Backup       = $b.Name
                        Source       = 'GetOibs (plug-in)'
                    })
                }
            }
        }
        catch {
            $unreadable.Add([pscustomobject]@{ Backup = $b.Name; Type = $b.TypeToString; Error = $_.Exception.Message })
        }
    }
}

# Remove duplicates (the parent backup is part of GetAllChildBackupsIncludingThis)
$all = @($all | Sort-Object Name, CreationTime, Backup -Unique)
Write-Host ("{0} restore points read from {1} backups." -f $all.Count, $backups.Count)

if ($unreadable.Count) {
    Write-Warning 'The following backups could not be read - VMs in them may wrongly show up as "NO BACKUP":'
    $unreadable | Format-Table -AutoSize | Out-Host
}

# --- Index by VM name (PowerShell hashtables are case-insensitive) ---------
$index = @{}
foreach ($rp in $all) {
    if (-not $index.ContainsKey($rp.Name)) { $index[$rp.Name] = New-Object System.Collections.Generic.List[object] }
    $index[$rp.Name].Add($rp)
}

# --- Compare ---------------------------------------------------------------
$result = foreach ($vm in $vms) {
    if ($index.ContainsKey($vm)) {
        $rps    = $index[$vm]
        $latest = $rps | Sort-Object CreationTime -Descending | Select-Object -First 1
        $status = 'OK'
        if ($PSBoundParameters.ContainsKey('NotBefore') -and $latest.CreationTime -lt $NotBefore) {
            $status = 'BACKUP TOO OLD'
        }
        [pscustomobject]@{
            VM                 = $vm
            Status             = $status
            RestorePoints      = $rps.Count
            LatestRestorePoint = $latest.CreationTime
            Backups            = (($rps.Backup | Sort-Object -Unique) -join ', ')
        }
    }
    else {
        [pscustomobject]@{
            VM                 = $vm
            Status             = 'NO BACKUP'
            RestorePoints      = 0
            LatestRestorePoint = $null
            Backups            = ''
        }
    }
}

$result | Sort-Object Status, VM | Format-Table -AutoSize | Out-Host

$problem = @($result | Where-Object Status -ne 'OK')
Write-Host ("{0} VMs checked, {1} OK, {2} need attention" -f $result.Count, ($result.Count - $problem.Count), $problem.Count) `
    -ForegroundColor $(if ($problem.Count) { 'Yellow' } else { 'Green' })

if ($CsvPath) {
    $result | Sort-Object VM | Export-Csv -Path $CsvPath -NoTypeInformation -Delimiter ';' -Encoding UTF8
    Write-Host "Exported to $CsvPath"
}

if ($PassThru) { $result }
