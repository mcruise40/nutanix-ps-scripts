#Requires -Version 7.0
<#
.SYNOPSIS
    Guided cleanup of Nutanix recovery points that are expired or whose VM / volume group
    no longer exists, across one or more Prism Central instances (Prism Central v4 API).
.DESCRIPTION
    Interactive terminal script in five steps:

      1. Connect  - asks how many Prism Centrals to check, their addresses and logins, and
                    checks every login before anything else happens.
      2. Collect  - reads VMs, volume groups and recovery points from all Prism Centrals.
      3. Review   - lists one row per VM / volume group with the reason, the Prism
                    Central(s), the number of recovery points and the space they hold.
                    The list can be exported to CSV.
      4. Select   - pick rows by number (1,4,7-12), by reason (expired / missing) or all.
                    "all" means every row of the list from step 3, nothing else.
      5. Delete   - shows the total, asks you to type the number of recovery points to
                    confirm, deletes them and writes a log file.

    The mode is shown at the start and in every step title: [DRY RUN] with -WhatIf
    (nothing is deleted), otherwise [LIVE]. Log files are named ..._DRYRUN / ..._LIVE.

    A recovery point is offered for deletion when one of these applies:
      - VM missing / VG missing: none of the VMs or volume groups it contains exist on any
        of the Prism Centrals checked. All its recovery points are listed, expired or not.
      - VM replaced: like VM missing, but an existing VM has the same name as the deleted
        one (for example restored or re-created). Check these before deleting.
      - Expired: its expiration time is in the past, but it still exists.
    Recovery points that have not expired and still have their VM are never listed, so
    this script cannot delete them. Recovery points that hold VM template versions
    (name VmTemplateRP_...) are never listed either.

    The script does not decide whether a recovery point is still needed. VM missing rows
    include recovery points that have not expired yet; once they are deleted, the VM can
    no longer be restored. Step 4 shows how many of the selected ones are not expired.

    Recommended order (each run starts with a dry run):
      1. -WhatIf -ExportCsv .\rp-list.csv, select "all", check the list.
      2. Live run, select "expired": recovery points past their expiry date that Nutanix
         did not remove.
      3. Live run, select "missing 30": recovery points of VMs / volume groups deleted at
         least 30 days ago (newest recovery point older than 30 days).
      4. Rows marked "VM replaced" and recently deleted VMs: only by row number, after
         checking with "d <row>".
.NOTES
    - The VM inventory is combined across all Prism Centrals. A recovery point replicated
      from another site only counts as "VM missing" if its VM exists on none of them, so
      always include every Prism Central that replicates with the ones you clean up.
    - Before a VM or volume group is reported missing, it is looked up by ID on every
      Prism Central. If a lookup fails for any reason other than "not found" (for example
      missing permissions), it counts as unverified and its recovery points are not offered
      as missing (expired ones still are). Use an account that can see all VMs.
    - Space: totalExclusiveUsageBytes (API v4.2 and later), documented as the space that
      could be reclaimed after deleting the recovery point. Totals are a lower bound: data
      shared only between several selected recovery points of the same VM is not counted
      for any single one. The space is freed once the cluster's background cleanup
      (Curator) has run, usually within several hours to a day.
    - VM names of deleted VMs are read from the VM configuration stored in the recovery
      point (vmm vm-recovery-points API). If that fails, the row shows the VM ID instead.
    - Secure recovery points (isSecure) need an approval to be deleted and are skipped.
    - VM templates store their data as recovery points. Their VM is not a normal VM, so
      they would look like "VM missing"; they are skipped and counted under "Not listed".
    - Observed in practice: the last recovery point of a deleted VM is not removed when it
      expires, so it stays until it is deleted manually.
    - Storage: every run reads the used storage of each cluster (clustermgmt stats API:
      storageUsageBytes, logicalStorageUsageBytes, storageCapacityBytes) and appends it to
      RecoveryPointCleanup_storage-history.csv in the log folder. Live runs also record how
      much they expected to free. Each run (and -StorageReport) compares the current usage
      with the usage before the live runs of the last 30 days. Other changes on the cluster
      (new snapshots, growing VMs) are part of the difference too.
    - Deletion is irreversible. Run with -WhatIf for a dry run.
    - Certificate validation is disabled (SkipCertificateCheck), like the other scripts in
      this folder.
.PARAMETER PrismCentral
    IP addresses or FQDNs of the Prism Central instances to check (without https:// or
    port). If omitted, the script asks how many there are and for each address.
.PARAMETER Credential
    Login used for all Prism Centrals. If omitted, the script asks for a login per Prism
    Central (with the option to reuse the previous one).
.PARAMETER ApiVersion
    Nutanix v4 API revision. Default: "v4.2". Space per recovery point needs v4.2 or later.
.PARAMETER ExportCsv
    Writes the list of recovery points found in step 3 to this CSV file (one line per
    recovery point). The list can also be exported interactively with the "csv" command.
.PARAMETER LogDirectory
    Folder for the log file, the results CSV and the storage history. Default: the current
    folder. Use the same folder for every run, so the storage history can be compared.
.PARAMETER StorageReport
    Only connects, reads the storage usage of the clusters and compares it with the usage
    before the last live runs, then exits. Nothing is deleted. Run it a day after a live
    run to see how much space was freed.
.PARAMETER TimeoutSeconds
    Maximum time to wait for one deletion task. Default: 600 seconds.
.PARAMETER BatchSize
    Number of deletions started at the same time. Default: 5. Lower it (for example 2)
    if Prism Central keeps reporting that its API rate limit was reached.
.EXAMPLE
    .\Invoke-NtnxRecoveryPointCleanup.ps1

    Fully guided: asks for the number of Prism Centrals, their addresses and logins.
.EXAMPLE
    .\Invoke-NtnxRecoveryPointCleanup.ps1 -PrismCentral pc-a.example.local, pc-b.example.local

    Checks both Prism Centrals; asks for the logins.
.EXAMPLE
    .\Invoke-NtnxRecoveryPointCleanup.ps1 -PrismCentral 10.0.20.10, 10.0.30.10 -ExportCsv .\rp.csv -WhatIf

    Dry run: goes through all steps and exports the list, but deletes nothing.
.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\Invoke-NtnxRecoveryPointCleanup.ps1 -WhatIf

    Starts a dry run from cmd.exe or Windows PowerShell 5.1 (the script needs PowerShell 7).
.EXAMPLE
    .\Invoke-NtnxRecoveryPointCleanup.ps1 -StorageReport

    A day after a live run: shows how much the used storage changed since before the
    deletion, next to the space the script expected to free.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string[]]$PrismCentral,
    [pscredential]$Credential,
    [string]$ApiVersion = 'v4.2',
    [string]$ExportCsv,
    [string]$LogDirectory = (Get-Location).Path,
    [ValidateRange(30, 7200)][int]$TimeoutSeconds = 600,
    [ValidateRange(1, 50)][int]$BatchSize = 5,
    [switch]$StorageReport
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $LogDirectory)) {
    $null = New-Item -ItemType Directory -Path $LogDirectory -WhatIf:$false -Confirm:$false
}
$script:DryRun = [bool]$WhatIfPreference
$script:Mode = if ($StorageReport) { 'STORAGE REPORT' } elseif ($script:DryRun) { 'DRY RUN' } else { 'LIVE' }
$script:TotalSteps = if ($StorageReport) { 2 } else { 5 }
$script:Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$modeSuffix = @{ 'STORAGE REPORT' = 'REPORT'; 'DRY RUN' = 'DRYRUN'; 'LIVE' = 'LIVE' }[$script:Mode]
$logFolder = (Resolve-Path -LiteralPath $LogDirectory).Path
$script:LogFile = Join-Path $logFolder "RecoveryPointCleanup_$($script:Stamp)_$modeSuffix.log"
$script:StorageFile = Join-Path $logFolder 'RecoveryPointCleanup_storage-history.csv'
$script:Results = [System.Collections.Generic.List[object]]::new()
$script:RateLimitWaits = 0

#region Output and prompts

function Write-CleanupLog {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding utf8 -WhatIf:$false -Confirm:$false
}

function Write-ModeTag {
    # DRY RUN / LIVE / STORAGE REPORT, so the mode is visible in every step.
    switch ($script:Mode) {
        'LIVE' { Write-Host ' LIVE ' -ForegroundColor White -BackgroundColor DarkRed -NoNewline }
        'DRY RUN' { Write-Host ' DRY RUN ' -ForegroundColor Black -BackgroundColor Yellow -NoNewline }
        default { Write-Host ' STORAGE REPORT ' -ForegroundColor Black -BackgroundColor Cyan -NoNewline }
    }
}

function Write-Step {
    param([int]$Number, [string]$Title)
    Write-Host ''
    Write-Host ("=== Step {0} of {1}: {2} " -f $Number, $script:TotalSteps, $Title) -ForegroundColor Cyan -NoNewline
    Write-ModeTag
    Write-Host ' ===' -ForegroundColor Cyan
    Write-CleanupLog ("Step {0}: {1}" -f $Number, $Title)
}

function Exit-Cleanup {
    # Only used before anything was deleted.
    param([string]$Reason = 'Cancelled.')
    Write-Host ''
    Write-Host "$Reason Nothing was deleted." -ForegroundColor Yellow
    Write-CleanupLog "$Reason Nothing was deleted." 'WARN'
    Write-Host "Log: $($script:LogFile)"
    exit 0
}

function Read-Text {
    param([string]$Prompt, [string]$Default)
    while ($true) {
        $shown = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
        $answer = "$(Read-Host $shown)".Trim()
        if ($answer) { return $answer }
        if ($Default) { return $Default }
    }
}

function Read-Number {
    param([string]$Prompt, [int]$Min, [int]$Max)
    while ($true) {
        $number = 0
        if ([int]::TryParse((Read-Text -Prompt $Prompt), [ref]$number) -and $number -ge $Min -and $number -le $Max) {
            return $number
        }
        Write-Host "  Please enter a number from $Min to $Max." -ForegroundColor Yellow
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $answer = "$(Read-Host "$Prompt [$hint]")".Trim()
        if (-not $answer) { return $Default }
        if ($answer -match '^(y|yes|j|ja)$') { return $true }
        if ($answer -match '^(n|no|nein)$') { return $false }
    }
}

function Read-Choice {
    param([string]$Prompt, [string[]]$Allowed)
    while ($true) {
        $answer = "$(Read-Host $Prompt)".Trim().ToUpperInvariant()
        if ($answer -and $Allowed -contains $answer.Substring(0, 1)) { return $answer.Substring(0, 1) }
    }
}

function Read-PcCredential {
    param([string]$Address)
    while ($true) {
        $cred = Get-Credential -Message "Login for Prism Central $Address"
        if ($cred -and $cred.UserName) { return $cred }
        Write-Host '  A user name is required.' -ForegroundColor Yellow
    }
}

function ConvertTo-PcAddress {
    param([string]$Value)
    (($Value.Trim() -replace '^https?://', '') -replace '/.*$', '') -replace ':9440$', ''
}

function ConvertTo-UtcDate {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
        return $Value.ToUniversalTime()
    }
    return [datetimeoffset]::Parse([string]$Value, [cultureinfo]::InvariantCulture).UtcDateTime
}

function Format-LocalDate {
    param($UtcDate, [string]$Empty = '')
    if ($null -eq $UtcDate) { return $Empty }
    $UtcDate.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
}

function Format-Size {
    param($Bytes)
    if ($null -eq $Bytes) { return 'n/a' }
    $units = 'B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'
    $value = [double]$Bytes
    $i = 0
    while ($value -ge 1024 -and $i -lt $units.Count - 1) { $value /= 1024; $i++ }
    if ($i -eq 0) { return '{0:N0} {1}' -f $value, $units[$i] }
    '{0:N1} {1}' -f $value, $units[$i]
}

function Format-Count {
    # "1 recovery point" / "3 recovery points"
    param([int]$Count, [string]$Singular, [string]$Plural = "$($Singular)s")
    if ($Count -eq 1) { return "1 $Singular" }
    "$Count $Plural"
}

function Format-Total {
    # "at least" because exclusive usage does not include data shared between deleted recovery points.
    param([object[]]$Items)
    $known = @($Items | Where-Object { $null -ne $_.SizeBytes })
    if (-not $known.Count) { return 'unknown (no size reported)' }
    $text = 'at least ' + (Format-Size ($known | Measure-Object -Property SizeBytes -Sum).Sum)
    $unknown = $Items.Count - $known.Count
    if ($unknown) { $text += " (plus $(Format-Count $unknown 'recovery point') without size)" }
    $text
}

function Get-ShortId {
    param([string]$Id)
    if (-not $Id) { return '?' }
    $Id.Substring(0, [Math]::Min(8, $Id.Length))
}

#endregion

#region Nutanix API

function Invoke-NtnxApi {
    param(
        [Parameter(Mandatory)]$Pc,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('GET', 'DELETE')][string]$Method = 'GET'
    )
    $params = @{
        Method               = $Method
        Uri                  = "https://$($Pc.Address):9440/api$Path"
        Authentication       = 'Basic'
        Credential           = $Pc.Credential
        SkipCertificateCheck = $true
        TimeoutSec           = 120
        ErrorAction          = 'Stop'
    }
    if ($Method -eq 'DELETE') {
        # Idempotency token, mandatory for v4 write operations. Retries reuse it.
        $params.Headers = @{ 'NTNX-Request-Id' = [guid]::NewGuid().Guid }
    }
    # Prism Central rate-limits its API. When the limit is hit, wait and try again
    # (Retry-After if the answer has one, otherwise 5, 10, 20, 40, 60 seconds).
    $waits = 5, 10, 20, 40, 60
    for ($attempt = 0; ; $attempt++) {
        try {
            return Invoke-RestMethod @params
        } catch {
            $err = Get-ApiError $_
            if (($err.StatusCode -ne 429 -and $err.Message -notmatch 'rate limit') -or $attempt -ge $waits.Count) { throw }
            $wait = $waits[$attempt]
            try {
                $retryAfter = $_.Exception.Response.Headers.RetryAfter.Delta
                if ($retryAfter) { $wait = [Math]::Min(120, [Math]::Max(1, [int]$retryAfter.TotalSeconds)) }
            } catch { Write-Verbose 'No Retry-After header.' }
            $script:RateLimitWaits++
            Write-CleanupLog ("API rate limit reached ({0} {1}), waiting {2} s before retry {3}" -f $Method, $Path, $wait, ($attempt + 1)) 'WARN'
            Write-Host ("  API rate limit reached, waiting {0} s and trying again..." -f $wait) -ForegroundColor DarkYellow
            Start-Sleep -Seconds $wait
        }
    }
}

function Get-ApiError {
    # Turns a failed API call into a status code (null = no HTTP answer) and a readable message.
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    $status = $null
    $response = $ErrorRecord.Exception.Response
    if ($response -and $response.StatusCode) { $status = [int]$response.StatusCode }
    $message = $null
    $body = $ErrorRecord.ErrorDetails.Message
    if ($body) {
        try {
            $message = @(($body | ConvertFrom-Json).data.error | ForEach-Object { $_.message } | Where-Object { $_ }) -join '; '
        } catch { Write-Verbose "Error body is not Nutanix JSON: $body" }
        if (-not $message) { $message = $body }
    }
    if (-not $message) { $message = $ErrorRecord.Exception.Message }
    $message = ($message -replace '\s+', ' ').Trim()
    if ($message.Length -gt 300) { $message = $message.Substring(0, 300) + '...' }
    [pscustomobject]@{ StatusCode = $status; Message = $message }
}

function Get-NtnxList {
    # Reads all pages of a v4 list call. Uses $page (zero-based) + $limit; $offset is ignored by the API.
    param([Parameter(Mandatory)]$Pc, [Parameter(Mandatory)][string]$Path, [string]$Activity)
    $items = [System.Collections.Generic.List[object]]::new()
    $limit = 100
    for ($page = 0; $page -lt 100000; $page++) {
        $response = Invoke-NtnxApi -Pc $Pc -Path ('{0}?$page={1}&$limit={2}' -f $Path, $page, $limit)
        $data = if ($null -eq $response.data) { @() } else { @($response.data) }
        foreach ($entry in $data) { $items.Add($entry) }
        $total = $response.metadata.totalAvailableResults
        if ($Activity) {
            $status = if ($total) { "$($items.Count) of $total" } else { "$($items.Count)" }
            Write-Progress -Activity $Activity -Status $status
        }
        if ($data.Count -lt $limit -or ($total -and $items.Count -ge $total)) { break }
    }
    if ($Activity) { Write-Progress -Activity $Activity -Completed }
    $items.ToArray()
}

function Test-PcLogin {
    # Returns $null if the login works and the user can read VMs and recovery points, otherwise the problem.
    param($Pc)
    try {
        $null = Invoke-NtnxApi -Pc $Pc -Path "/vmm/$ApiVersion/ahv/config/vms?`$limit=1"
        $null = Invoke-NtnxApi -Pc $Pc -Path "/dataprotection/$ApiVersion/config/recovery-points?`$limit=1"
        return $null
    } catch {
        $err = Get-ApiError $_
        if ($null -eq $err.StatusCode) { return "cannot connect to https://$($Pc.Address):9440 - $($err.Message)" }
        switch ($err.StatusCode) {
            401 { return 'login failed: wrong user name or password' }
            403 { return 'login works, but this user may not read VMs or recovery points' }
            404 { return "API version $ApiVersion is not available on this Prism Central (HTTP 404). Use -ApiVersion to change it." }
            default { return ('HTTP {0}: {1}' -f $err.StatusCode, $err.Message) }
        }
    }
}

function Get-LookupAnswer {
    # 'Exists', 'Missing' (HTTP 404) or 'Unverified' (any other error).
    param($Pc, [string]$Path)
    try {
        $null = Invoke-NtnxApi -Pc $Pc -Path $Path
        return 'Exists'
    } catch {
        if ((Get-ApiError $_).StatusCode -eq 404) { return 'Missing' }
        return 'Unverified'
    }
}

function Get-VmState {
    # A VM only counts as missing if every Prism Central answers "not found".
    param([object[]]$Pcs, [string]$VmExtId, [string]$HypervisorType)
    $answers = foreach ($pc in $Pcs) {
        Get-LookupAnswer -Pc $pc -Path "/vmm/$ApiVersion/ahv/config/vms/$VmExtId"
        if ($pc.EsxiListOk) { Get-LookupAnswer -Pc $pc -Path "/vmm/$ApiVersion/esxi/config/vms/$VmExtId" }
        elseif ($HypervisorType -ne 'AHV') { 'Unverified' }
    }
    if ($answers -contains 'Exists') { return 'Exists' }
    if ($answers -contains 'Unverified') { return 'Unverified' }
    'Missing'
}

function Get-VgState {
    param([object[]]$Pcs, [string]$VgExtId)
    $answers = foreach ($pc in $Pcs) { Get-LookupAnswer -Pc $pc -Path "/volumes/$ApiVersion/config/volume-groups/$VgExtId" }
    if ($answers -contains 'Exists') { return 'Exists' }
    if ($answers -contains 'Unverified') { return 'Unverified' }
    'Missing'
}

function Get-RpSize {
    param($Rp)
    if ($null -ne $Rp.totalExclusiveUsageBytes) { return [int64]$Rp.totalExclusiveUsageBytes }
    $parts = @(@($Rp.vmRecoveryPoints) + @($Rp.volumeGroupRecoveryPoints) |
        Where-Object { $_ -and $null -ne $_.totalExclusiveUsageBytes })
    if ($parts.Count) { return [int64]($parts | Measure-Object -Property totalExclusiveUsageBytes -Sum).Sum }
    $null
}

function Resolve-DeletedVmName {
    # The VM configuration stored in the recovery point still has the name of a deleted VM.
    param($Pc, $Rp, [string]$VmExtId)
    $vmRp = @($Rp.vmRecoveryPoints | Where-Object { $_ -and $_.vmExtId -eq $VmExtId })[0]
    foreach ($id in @($vmRp.extId, $Rp.extId) | Where-Object { $_ } | Select-Object -Unique) {
        try {
            $name = (Invoke-NtnxApi -Pc $Pc -Path "/vmm/$ApiVersion/ahv/config/vm-recovery-points/$id").data.vm.name
            if ($name) { return $name }
        } catch { Write-Verbose "No VM name from recovery point ${id}: $($_.Exception.Message)" }
    }
    "(name unknown, VM id $(Get-ShortId $VmExtId))"
}

#endregion

#region Storage

function Get-LatestStat {
    # Stats are lists of { timestamp, value }; returns the newest value or $null.
    param($Series)
    $points = @($Series | Where-Object { $null -ne $_ -and $null -ne $_.value } | Sort-Object { ConvertTo-UtcDate $_.timestamp })
    if ($points.Count) { return [int64]$points[-1].value }
    $null
}

function Get-ClusterStorage {
    # Used, logical used and capacity of every cluster of this Prism Central (not Prism Central itself).
    param($Pc)
    $clusters = $null
    foreach ($version in @($ApiVersion, 'v4.0') | Select-Object -Unique) {
        try {
            $clusters = @(Get-NtnxList -Pc $Pc -Path "/clustermgmt/$version/config/clusters")
            break
        } catch {
            if ((Get-ApiError $_).StatusCode -ne 404) { throw }
        }
    }
    if ($null -eq $clusters) { throw "clustermgmt API $ApiVersion and v4.0 not available" }
    $end = [datetime]::UtcNow
    $query = '?$startTime={0}&$endTime={1}&$samplingInterval=300&$statType=LAST' -f
        $end.AddHours(-2).ToString('yyyy-MM-ddTHH:mm:ssZ'), $end.ToString('yyyy-MM-ddTHH:mm:ssZ')
    foreach ($cluster in $clusters) {
        if (@($cluster.config.clusterFunction) -contains 'PRISM_CENTRAL') { continue }
        $stats = (Invoke-NtnxApi -Pc $Pc -Path "/clustermgmt/$version/stats/clusters/$($cluster.extId)$query").data
        [pscustomobject]@{
            Pc               = $Pc
            Cluster          = if ($cluster.name) { $cluster.name } else { Get-ShortId $cluster.extId }
            ClusterExtId     = $cluster.extId
            UsedBytes        = Get-LatestStat $stats.storageUsageBytes
            LogicalUsedBytes = Get-LatestStat $stats.logicalStorageUsageBytes
            CapacityBytes    = Get-LatestStat $stats.storageCapacityBytes
        }
    }
}

function ConvertTo-StorageRow {
    param([string]$EventName, [string]$PrismCentral, $Measurement, [int]$DeletedCount, $FreedAtLeastBytes)
    [pscustomobject]@{
        TimeUtc           = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        RunId             = $script:Stamp
        Mode              = $script:Mode
        Event             = $EventName
        PrismCentral      = $PrismCentral
        Cluster           = $Measurement.Cluster
        ClusterExtId      = $Measurement.ClusterExtId
        UsedBytes         = $Measurement.UsedBytes
        LogicalUsedBytes  = $Measurement.LogicalUsedBytes
        CapacityBytes     = $Measurement.CapacityBytes
        DeletedCount      = if ($EventName -eq 'Deleted') { $DeletedCount } else { $null }
        FreedAtLeastBytes = $FreedAtLeastBytes
    }
}

function Add-StorageHistory {
    param([object[]]$Rows)
    if (-not $Rows) { return }
    try {
        $Rows | Export-Csv -LiteralPath $script:StorageFile -Append -NoTypeInformation -UseCulture -Encoding utf8BOM -WhatIf:$false -Confirm:$false
    } catch {
        Write-Host "  Storage history could not be written: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-CleanupLog "Storage history could not be written: $($_.Exception.Message)" 'WARN'
    }
}

function Format-Change {
    param([int64]$Bytes)
    if ($Bytes -eq 0) { return 'unchanged' }
    if ($Bytes -lt 0) { return 'down by {0}' -f (Format-Size (-$Bytes)) }
    'up by {0}' -f (Format-Size $Bytes)
}

function Show-StorageComparison {
    # Compares with the usage measured at the start of the first live run (with deletions) of the last 30 days.
    param([object[]]$Current)
    if (-not (Test-Path -LiteralPath $script:StorageFile)) { return }
    try {
        $history = @(Import-Csv -LiteralPath $script:StorageFile -UseCulture)
    } catch {
        Write-Host "  Storage history could not be read: $($_.Exception.Message)" -ForegroundColor Yellow
        return
    }
    $sinceUtc = [datetime]::UtcNow.AddDays(-30)
    $deletions = @($history | Where-Object { $_.Event -eq 'Deleted' -and $_.RunId -ne $script:Stamp -and (ConvertTo-UtcDate $_.TimeUtc) -ge $sinceUtc })
    if (-not $deletions.Count) {
        Write-Host '  No live run with deletions in the last 30 days to compare with.'
        return
    }
    $firstRun = ($deletions | Sort-Object { ConvertTo-UtcDate $_.TimeUtc } | Select-Object -First 1).RunId
    $baseline = @($history | Where-Object { $_.Event -eq 'Measured' -and $_.RunId -eq $firstRun })
    if (-not $baseline.Count) {
        Write-Host '  The first live run of the last 30 days has no storage measurement to compare with.'
        return
    }
    $runCount = @($deletions | ForEach-Object { $_.RunId } | Select-Object -Unique).Count
    $baselineUtc = ConvertTo-UtcDate $baseline[0].TimeUtc
    $firstTime = Format-LocalDate $baselineUtc
    $anyDecrease = $false
    Write-Host ''
    if ($runCount -eq 1) { Write-Host "Compared with before the live run on ${firstTime}:" -ForegroundColor Cyan }
    else { Write-Host "Compared with before the first of $runCount live runs ($firstTime):" -ForegroundColor Cyan }
    foreach ($group in ($Current | Group-Object { $_.Pc.Address })) {
        $pcDeletions = @($deletions | Where-Object PrismCentral -EQ $group.Name)
        $deletedCount = ($pcDeletions | ForEach-Object { [int]$_.DeletedCount } | Measure-Object -Sum).Sum
        $expected = ($pcDeletions | Where-Object { $_.FreedAtLeastBytes } | ForEach-Object { [int64]$_.FreedAtLeastBytes } | Measure-Object -Sum).Sum
        $line = '  {0} {1}: {2} deleted' -f $group.Group[0].Pc.Label, $group.Name, (Format-Count ([int]$deletedCount) 'recovery point')
        if ($expected) { $line += ", expected to free at least $(Format-Size $expected)" }
        Write-Host $line
        foreach ($m in $group.Group) {
            $before = $baseline | Where-Object { $_.PrismCentral -eq $group.Name -and $_.ClusterExtId -eq $m.ClusterExtId } | Select-Object -First 1
            if (-not $before -or -not $before.UsedBytes -or $null -eq $m.UsedBytes) {
                Write-Host "    $($m.Cluster): no earlier value"
                continue
            }
            if ($m.UsedBytes -lt [int64]$before.UsedBytes) { $anyDecrease = $true }
            $text = '    {0}: used storage {1} (now {2})' -f $m.Cluster, (Format-Change ($m.UsedBytes - [int64]$before.UsedBytes)), (Format-Size $m.UsedBytes)
            if ($before.LogicalUsedBytes -and $null -ne $m.LogicalUsedBytes) {
                $text += ', logical {0}' -f (Format-Change ($m.LogicalUsedBytes - [int64]$before.LogicalUsedBytes))
            }
            Write-Host $text
            Write-CleanupLog ("Storage change {0} {1} since {2}: {3}" -f $group.Name, $m.Cluster, $firstRun, $text.Trim())
        }
    }
    # A deleted recovery point is gone from Prism at once, but its data is only freed by Curator scans later.
    $elapsed = [datetime]::UtcNow - $baselineUtc
    if ($elapsed.TotalHours -lt 24) {
        $since = if ($elapsed.TotalHours -lt 1) { Format-Count ([Math]::Max(1, [int]$elapsed.TotalMinutes)) 'minute' } else { Format-Count ([int][Math]::Floor($elapsed.TotalHours)) 'hour' }
        Write-Host "Only $since since the deletion. The cluster frees the space in its background cleanup (Curator)," -ForegroundColor DarkYellow
        Write-Host 'usually within several hours to a day. Until then, a small increase is normal: the clusters keep writing.' -ForegroundColor DarkYellow
    } else {
        Write-Host 'Space is freed by the cluster background cleanup (Curator). Other changes on the cluster count too.'
        if (-not $anyDecrease -and $elapsed.TotalHours -ge 36) {
            Write-Host 'No decrease after 36 hours: check the last Curator scans on a CVM (curator_cli get_last_successful_scans)' -ForegroundColor Yellow
            Write-Host 'and the recycle bin in Prism, or open a case with Nutanix support.' -ForegroundColor Yellow
        }
    }
}

function Invoke-StorageCheck {
    # Reads the storage of all clusters, shows it, appends it to the history and compares with earlier live runs.
    param([object[]]$Pcs)
    $measurements = foreach ($pc in $Pcs) {
        try {
            Get-ClusterStorage -Pc $pc
        } catch {
            $msg = '{0}: storage usage could not be read ({1}). The cleanup works without it.' -f $pc.Label, (Get-ApiError $_).Message
            Write-Host "  $msg" -ForegroundColor Yellow
            Write-CleanupLog $msg 'WARN'
        }
    }
    $measurements = @($measurements | Where-Object { $_ })
    if (-not $measurements.Count) { return }
    Write-Host 'Storage now:'
    foreach ($m in $measurements) {
        $text = '{0} {1}: used {2} of {3}, logical {4}' -f $m.Pc.Label, $m.Cluster, (Format-Size $m.UsedBytes), (Format-Size $m.CapacityBytes), (Format-Size $m.LogicalUsedBytes)
        Write-Host "  $text"
        Write-CleanupLog "Storage $($m.Pc.Address) $text"
    }
    Add-StorageHistory @($measurements | ForEach-Object { ConvertTo-StorageRow -EventName 'Measured' -PrismCentral $_.Pc.Address -Measurement $_ })
    Show-StorageComparison -Current $measurements
}

#endregion

#region Review helpers

function Show-RowTable {
    param([object[]]$Rows)
    $Rows | Format-Table -AutoSize -Property @(
        @{ Label = '#'; Expression = { $_.Row }; Align = 'Right' }
        @{ Label = 'Reason'; Expression = { $_.Reason } }
        @{ Label = 'VM / volume group'; Expression = { if ($_.Name.Length -gt 45) { $_.Name.Substring(0, 42) + '...' } else { $_.Name } } }
        @{ Label = 'PC'; Expression = { $_.Pcs } }
        @{ Label = 'RPs'; Expression = { $_.Count }; Align = 'Right' }
        @{ Label = 'Oldest'; Expression = { Format-LocalDate $_.OldestUtc } }
        @{ Label = 'Newest'; Expression = { Format-LocalDate $_.NewestUtc } }
        @{ Label = 'Overdue'; Expression = { if ($_.Reason -eq 'Expired') { "$($_.OverdueDays) d" } }; Align = 'Right' }
        @{ Label = 'Space'; Expression = {
                if ($_.UnknownSize -eq $_.Count) { 'n/a' }
                elseif ($_.UnknownSize) { (Format-Size $_.SizeBytes) + '*' }
                else { Format-Size $_.SizeBytes }
            }; Align = 'Right'
        }
    ) | Out-Host
}

function Show-RowDetail {
    param($Row)
    Write-Host ''
    Write-Host ("Row {0}: {1} ({2})" -f $Row.Row, $Row.Name, $Row.Reason) -ForegroundColor Cyan
    $ids = @($Row.Items[0].VmIds) + @($Row.Items[0].VgIds) | Where-Object { $_ }
    Write-Host ("IDs: {0}" -f ($ids -join ', '))
    $Row.Items | Sort-Object CreatedUtc | Format-Table -AutoSize -Property @(
        @{ Label = 'PC'; Expression = { $_.Pc.Label } }
        @{ Label = 'Recovery point'; Expression = { $_.RpName } }
        @{ Label = 'Created'; Expression = { Format-LocalDate $_.CreatedUtc } }
        @{ Label = 'Expires'; Expression = { Format-LocalDate $_.ExpiresUtc 'never' } }
        @{ Label = 'Space'; Expression = { Format-Size $_.SizeBytes }; Align = 'Right' }
        @{ Label = 'ExtId'; Expression = { $_.RpExtId } }
    ) | Out-Host
}

function Export-CandidateList {
    param([object[]]$Rows, [string]$Path)
    $lines = foreach ($row in $Rows) {
        foreach ($item in $row.Items) {
            [pscustomobject]@{
                Row                = $row.Row
                Reason             = $row.Reason
                Name               = $row.Name
                Type               = $item.Type
                PrismCentral       = $item.Pc.Address
                RecoveryPointName  = $item.RpName
                RecoveryPointExtId = $item.RpExtId
                LocationAgnosticId = $item.LocationAgnosticId
                Created            = Format-LocalDate $item.CreatedUtc
                Expires            = Format-LocalDate $item.ExpiresUtc 'never'
                SizeBytes          = $item.SizeBytes
                Size               = Format-Size $item.SizeBytes
                VmExtIds           = $item.VmIds -join ' '
                VolumeGroupExtIds  = $item.VgIds -join ' '
            }
        }
    }
    # -UseCulture: list separator of this machine, so Excel opens it directly.
    $lines | Export-Csv -LiteralPath $Path -NoTypeInformation -UseCulture -Encoding utf8BOM -WhatIf:$false -Confirm:$false
    Write-Host "Exported $(@($lines).Count) recovery points to $Path" -ForegroundColor Green
    Write-CleanupLog "Exported list to $Path"
}

function ConvertFrom-RowSelection {
    # "1,4,7-12" -> row numbers; nothing if the text is not a valid selection.
    param([string]$Text, [int]$Max)
    $set = [System.Collections.Generic.SortedSet[int]]::new()
    foreach ($token in ($Text -split '[,;\s]+' | Where-Object { $_ })) {
        if ($token -match '^(\d+)$') { $from = [int]$Matches[1]; $to = $from }
        elseif ($token -match '^(\d+)-(\d+)$') { $from = [int]$Matches[1]; $to = [int]$Matches[2] }
        else { return }
        if ($from -gt $to) { $from, $to = $to, $from }
        if ($from -lt 1 -or $to -gt $Max) { return }
        for ($n = $from; $n -le $to; $n++) { [void]$set.Add($n) }
    }
    @($set)
}

function Add-Result {
    param($Item, [string]$Status, [string]$Message)
    $script:Results.Add([pscustomobject]@{
            Time               = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            Status             = $Status
            Reason             = $Item.Reason
            Name               = $Item.Name
            PrismCentral       = $Item.Pc.Address
            RecoveryPointName  = $Item.RpName
            RecoveryPointExtId = $Item.RpExtId
            SizeBytes          = $Item.SizeBytes
            Message            = $Message
        })
    $text = '{0}: {1} / {2} on {3}' -f $Status, $Item.Name, $Item.RpName, $Item.Pc.Label
    if ($Message) { $text += " - $Message" }
    $ok = $Status -in 'Deleted', 'Already gone', 'Not deleted (dry run)'
    Write-Host "  $text" -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
    Write-CleanupLog ('{0} [{1}] on {2}' -f $text, $Item.RpExtId, $Item.Pc.Address) $(if ($ok) { 'INFO' } else { 'ERROR' })
}

#endregion

Write-Host ''
Write-Host 'Nutanix recovery point cleanup' -ForegroundColor Cyan
Write-Host 'Finds recovery points that are expired or whose VM / volume group no longer exists,'
Write-Host 'and deletes the ones you select.'
Write-Host ''
if ($StorageReport) {
    Write-Host ' STORAGE REPORT: only reads the storage usage of the clusters, nothing is deleted. ' -ForegroundColor Black -BackgroundColor Cyan
} elseif ($script:DryRun) {
    Write-Host ' DRY RUN (-WhatIf): nothing will be deleted. ' -ForegroundColor Black -BackgroundColor Yellow
    Write-Host 'All steps run as usual; step 5 only lists what would be deleted.'
} else {
    Write-Host ' LIVE RUN: the recovery points you select will be deleted permanently. ' -ForegroundColor White -BackgroundColor DarkRed
    Write-Host 'Nothing is deleted before you confirm in step 4. For a dry run, quit and start again with -WhatIf.'
}
Write-Host "Log: $($script:LogFile)"
Write-CleanupLog ("Started by {0} on {1}, API {2}, mode {3}" -f [Environment]::UserName, [Environment]::MachineName, $ApiVersion, $script:Mode)

#region Step 1: connect

Write-Step 1 'Connect to Prism Central'
if ($PrismCentral) {
    $addresses = @($PrismCentral | ForEach-Object { ConvertTo-PcAddress $_ } | Where-Object { $_ } | Select-Object -Unique)
} else {
    Write-Host 'Include every Prism Central that replicates recovery points with the others.'
    Write-Host 'Otherwise a replicated recovery point can wrongly look like its VM is missing.'
    $count = Read-Number -Prompt 'How many Prism Centrals do you want to check?' -Min 1 -Max 20
    $addresses = @(for ($i = 1; $i -le $count; $i++) {
            ConvertTo-PcAddress (Read-Text -Prompt "  Address of Prism Central $i (IP or FQDN)")
        }) | Select-Object -Unique
    $addresses = @($addresses)
}

$pcs = [System.Collections.Generic.List[object]]::new()
$previous = $null
foreach ($address in $addresses) {
    $cred = $Credential
    if (-not $cred) {
        if ($previous -and (Read-YesNo -Prompt "  Use the same login ($($previous.UserName)) for ${address}?")) {
            $cred = $previous
        } else {
            $cred = Read-PcCredential -Address $address
        }
    }
    $previous = $cred
    $pcs.Add([pscustomobject]@{ Label = "PC$($pcs.Count + 1)"; Address = $address; Credential = $cred; EsxiListOk = $false })
}

Write-Host ''
Write-Host 'Checking logins...'
$pending = @($pcs)
while ($pending.Count) {
    $failed = @()
    foreach ($pc in $pending) {
        $problem = Test-PcLogin -Pc $pc
        if ($problem) {
            Write-Host ("  [FAILED] {0} {1}: {2}" -f $pc.Label, $pc.Address, $problem) -ForegroundColor Red
            Write-CleanupLog ("Login check failed for {0} as {1}: {2}" -f $pc.Address, $pc.Credential.UserName, $problem) 'WARN'
            $failed += $pc
        } else {
            Write-Host ("  [OK]     {0} {1} (user {2})" -f $pc.Label, $pc.Address, $pc.Credential.UserName) -ForegroundColor Green
            Write-CleanupLog ("Login OK for {0} as {1}" -f $pc.Address, $pc.Credential.UserName)
        }
    }
    foreach ($pc in $failed) {
        switch (Read-Choice -Prompt "  $($pc.Label) $($pc.Address): [L]ogin again, change [A]ddress, or [Q]uit" -Allowed 'L', 'A', 'Q') {
            'Q' { Exit-Cleanup }
            'A' { $pc.Address = ConvertTo-PcAddress (Read-Text -Prompt '  New address') }
            'L' { $pc.Credential = Read-PcCredential -Address $pc.Address }
        }
    }
    $pending = $failed
}

if ($StorageReport) {
    Write-Step 2 'Storage'
    Invoke-StorageCheck -Pcs $pcs
    Write-Host ''
    Write-Host "Storage history: $($script:StorageFile)"
    Write-Host "Log: $($script:LogFile)"
    Write-CleanupLog 'Storage report finished.'
    exit 0
}

#endregion

#region Step 2: collect

Write-Step 2 'Collect VMs, volume groups and recovery points'
$vmIndex = @{}   # VM extId -> name, all Prism Centrals combined
$vgIndex = @{}
$rpEntries = [System.Collections.Generic.List[object]]::new()

foreach ($pc in $pcs) {
    try {
        $ahvVms = @(Get-NtnxList -Pc $pc -Path "/vmm/$ApiVersion/ahv/config/vms" -Activity "$($pc.Label): reading AHV VMs")
        $rps = @(Get-NtnxList -Pc $pc -Path "/dataprotection/$ApiVersion/config/recovery-points" -Activity "$($pc.Label): reading recovery points")
    } catch {
        Exit-Cleanup ("Could not read from {0}: {1}" -f $pc.Address, (Get-ApiError $_).Message)
    }
    foreach ($vm in $ahvVms) { if ($vm.extId) { $vmIndex[$vm.extId] = $vm.name } }

    $esxiVms = @()
    try {
        $esxiVms = @(Get-NtnxList -Pc $pc -Path "/vmm/$ApiVersion/esxi/config/vms" -Activity "$($pc.Label): reading ESXi VMs")
        $pc.EsxiListOk = $true
        foreach ($vm in $esxiVms) { if ($vm.extId) { $vmIndex[$vm.extId] = $vm.name } }
    } catch {
        $msg = "{0}: ESXi VMs could not be read ({1}). Recovery points of ESXi VMs are not offered as 'VM missing'." -f $pc.Label, (Get-ApiError $_).Message
        Write-Host "  $msg" -ForegroundColor Yellow
        Write-CleanupLog $msg 'WARN'
    }

    $vgs = @()
    try {
        $vgs = @(Get-NtnxList -Pc $pc -Path "/volumes/$ApiVersion/config/volume-groups" -Activity "$($pc.Label): reading volume groups")
        foreach ($vg in $vgs) { if ($vg.extId) { $vgIndex[$vg.extId] = $vg.name } }
    } catch {
        $msg = "{0}: volume groups could not be read ({1}). Their recovery points are only offered if expired." -f $pc.Label, (Get-ApiError $_).Message
        Write-Host "  $msg" -ForegroundColor Yellow
        Write-CleanupLog $msg 'WARN'
    }

    foreach ($rp in $rps) { $rpEntries.Add([pscustomobject]@{ Pc = $pc; Rp = $rp }) }
    $summary = '{0} {1}: {2}, {3}, {4}' -f $pc.Label, $pc.Address, (Format-Count ($ahvVms.Count + $esxiVms.Count) 'VM'),
        (Format-Count $vgs.Count 'volume group'), (Format-Count $rps.Count 'recovery point')
    Write-Host "  $summary"
    Write-CleanupLog $summary
}
Invoke-StorageCheck -Pcs $pcs

#endregion

#region Step 3: review

Write-Step 3 'Review'

# VMs / volume groups referenced by recovery points but not in any inventory: double-check each by ID.
$vmHypervisor = @{}
$unknownVmIds = [System.Collections.Generic.HashSet[string]]::new()
$unknownVgIds = [System.Collections.Generic.HashSet[string]]::new()
foreach ($entry in $rpEntries) {
    foreach ($vmRp in @($entry.Rp.vmRecoveryPoints)) {
        if (-not $vmRp.vmExtId) { continue }
        if ($vmRp.hypervisorType) { $vmHypervisor[$vmRp.vmExtId] = [string]$vmRp.hypervisorType }
        if (-not $vmIndex.ContainsKey($vmRp.vmExtId)) { [void]$unknownVmIds.Add($vmRp.vmExtId) }
    }
    foreach ($vgRp in @($entry.Rp.volumeGroupRecoveryPoints)) {
        if ($vgRp.volumeGroupExtId -and -not $vgIndex.ContainsKey($vgRp.volumeGroupExtId)) { [void]$unknownVgIds.Add($vgRp.volumeGroupExtId) }
    }
}
$entityState = @{}
$checked = 0
$toCheck = $unknownVmIds.Count + $unknownVgIds.Count
foreach ($id in $unknownVmIds) {
    $checked++
    Write-Progress -Activity 'Checking missing VMs and VGs' -Status "$checked of $toCheck" -PercentComplete (100 * $checked / $toCheck)
    $entityState[$id] = Get-VmState -Pcs $pcs -VmExtId $id -HypervisorType $vmHypervisor[$id]
}
foreach ($id in $unknownVgIds) {
    $checked++
    Write-Progress -Activity 'Checking missing VMs and VGs' -Status "$checked of $toCheck" -PercentComplete (100 * $checked / $toCheck)
    $entityState[$id] = Get-VgState -Pcs $pcs -VgExtId $id
}
Write-Progress -Activity 'Checking missing VMs and VGs' -Completed
foreach ($id in @($entityState.Keys)) {
    if ($entityState[$id] -eq 'Exists') { Write-CleanupLog "Found by ID but not in the list: $id" 'WARN' }
}

# Classify every recovery point.
$nowUtc = [datetime]::UtcNow
$candidates = [System.Collections.Generic.List[object]]::new()
$skipped = [ordered]@{ Secure = 0; Template = 0; Unverified = 0; PartlyMissing = 0; Empty = 0 }
foreach ($entry in $rpEntries) {
    $rp = $entry.Rp
    $vmIds = @(@($rp.vmRecoveryPoints) | ForEach-Object { $_.vmExtId } | Where-Object { $_ } | Select-Object -Unique)
    $vgIds = @(@($rp.volumeGroupRecoveryPoints) | ForEach-Object { $_.volumeGroupExtId } | Where-Object { $_ } | Select-Object -Unique)
    if (-not ($vmIds.Count + $vgIds.Count)) { $skipped.Empty++; continue }

    $states = @(
        foreach ($id in $vmIds) { if ($vmIndex.ContainsKey($id)) { 'Exists' } else { $entityState[$id] } }
        foreach ($id in $vgIds) { if ($vgIndex.ContainsKey($id)) { 'Exists' } else { $entityState[$id] } }
    )
    $expiresUtc = ConvertTo-UtcDate $rp.expirationTime
    $isExpired = $null -ne $expiresUtc -and $expiresUtc -lt $nowUtc

    if (-not ($states | Where-Object { $_ -ne 'Missing' })) {
        $reason = if ($vmIds.Count) { 'VM missing' } else { 'VG missing' }
    } elseif ($isExpired) {
        $reason = 'Expired'
    } else {
        if ($states -contains 'Unverified' -and $states -notcontains 'Exists') { $skipped.Unverified++ }
        elseif ($states -contains 'Missing') { $skipped.PartlyMissing++ }
        continue
    }
    if ("$($rp.name)" -like 'VmTemplateRP_*') {
        # Holds a VM template version; its "VM" is not a normal VM, so it always looks missing.
        $skipped.Template++
        Write-CleanupLog ("Skipped VM template recovery point {0} ({1}) on {2}" -f $rp.name, $rp.extId, $entry.Pc.Address) 'WARN'
        continue
    }
    if ($rp.isSecure) {
        $skipped.Secure++
        Write-CleanupLog ("Skipped secure recovery point {0} ({1}) on {2}" -f $rp.name, $rp.extId, $entry.Pc.Address) 'WARN'
        continue
    }

    $candidates.Add([pscustomobject]@{
            Reason             = $reason
            Type               = if ($vmIds.Count -and $vgIds.Count) { 'VM+VG' } elseif ($vmIds.Count) { 'VM' } else { 'VG' }
            GroupKey           = $reason + '|' + ((@($vmIds) + @($vgIds) | Sort-Object) -join ',')
            Name               = ''
            VmIds              = $vmIds
            VgIds              = $vgIds
            Pc                 = $entry.Pc
            Rp                 = $rp
            RpExtId            = $rp.extId
            RpName             = $rp.name
            LocationAgnosticId = $rp.locationAgnosticId
            CreatedUtc         = ConvertTo-UtcDate $rp.creationTime
            ExpiresUtc         = $expiresUtc
            SizeBytes          = Get-RpSize $rp
        })
}

if (-not $candidates.Count) {
    Write-Host 'Nothing to clean up: no expired recovery points and none without a VM or volume group.' -ForegroundColor Green
    Write-CleanupLog 'Nothing to clean up.'
    Write-Host "Log: $($script:LogFile)"
    exit 0
}

# Names: from the inventory, or for deleted VMs from the VM configuration in the recovery point.
$vmNames = @{}
$resolveFrom = [ordered]@{}
foreach ($c in $candidates) {
    foreach ($id in $c.VmIds) { if (-not $vmIndex.ContainsKey($id) -and -not $resolveFrom.Contains($id)) { $resolveFrom[$id] = $c } }
}
$n = 0
foreach ($id in @($resolveFrom.Keys)) {
    $n++
    Write-Progress -Activity 'Reading names of deleted VMs' -Status "$n of $($resolveFrom.Count)" -PercentComplete (100 * $n / $resolveFrom.Count)
    $vmNames[$id] = Resolve-DeletedVmName -Pc $resolveFrom[$id].Pc -Rp $resolveFrom[$id].Rp -VmExtId $id
}
Write-Progress -Activity 'Reading names of deleted VMs' -Completed
foreach ($c in $candidates) {
    $names = @(
        foreach ($id in $c.VmIds) { if ($vmIndex.ContainsKey($id)) { $vmIndex[$id] } else { $vmNames[$id] } }
        foreach ($id in $c.VgIds) { if ($vgIndex.ContainsKey($id) -and $vgIndex[$id]) { $vgIndex[$id] } else { "volume group $(Get-ShortId $id)" } }
    )
    $c.Name = $names -join ', '
}

# A deleted VM whose name is used by an existing VM was probably restored or re-created.
$liveVmNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in $vmIndex.Values) { if ($name) { [void]$liveVmNames.Add($name) } }
foreach ($c in $candidates) {
    if ($c.Reason -ne 'VM missing') { continue }
    if (@($c.VmIds | Where-Object { $liveVmNames.Contains("$($vmNames[$_])") }).Count) {
        $c.Reason = 'VM replaced'
        $c.GroupKey = 'VM replaced|' + ($c.GroupKey -replace '^[^|]*\|', '')
    }
}

# Sizes missing from the list response: try reading single recovery points (stop if the API never returns one).
$noSize = @($candidates | Where-Object { $null -eq $_.SizeBytes })
$tried = 0
$found = 0
foreach ($c in $noSize) {
    if ($tried -ge 3 -and $found -eq 0) { break }
    $tried++
    Write-Progress -Activity 'Reading sizes' -Status "$tried of $($noSize.Count)" -PercentComplete (100 * $tried / $noSize.Count)
    try {
        $size = Get-RpSize (Invoke-NtnxApi -Pc $c.Pc -Path "/dataprotection/$ApiVersion/config/recovery-points/$($c.RpExtId)").data
        if ($null -ne $size) { $c.SizeBytes = $size; $found++ }
    } catch { Write-Verbose "No size for recovery point $($c.RpExtId): $($_.Exception.Message)" }
}
Write-Progress -Activity 'Reading sizes' -Completed

# One row per VM / volume group and reason; missing VMs first.
$reasonOrder = @{ 'VM missing' = 0; 'VG missing' = 1; 'VM replaced' = 2; 'Expired' = 3 }
$rows = @($candidates | Group-Object GroupKey | ForEach-Object {
        $items = @($_.Group)
        $known = @($items | Where-Object { $null -ne $_.SizeBytes })
        $expiries = @($items | Where-Object { $_.ExpiresUtc } | ForEach-Object { $_.ExpiresUtc } | Sort-Object)
        $created = @($items | Where-Object { $_.CreatedUtc } | ForEach-Object { $_.CreatedUtc } | Sort-Object)
        [pscustomobject]@{
            Row         = 0
            Reason      = $items[0].Reason
            Name        = $items[0].Name
            Pcs         = (@($items | ForEach-Object { $_.Pc.Label } | Sort-Object -Unique) -join ',')
            Count       = $items.Count
            OldestUtc   = $created | Select-Object -First 1
            NewestUtc   = $created | Select-Object -Last 1
            OverdueDays = if ($expiries.Count) { [int][Math]::Floor(($nowUtc - $expiries[0]).TotalDays) } else { 0 }
            SizeBytes   = if ($known.Count) { [int64]($known | Measure-Object -Property SizeBytes -Sum).Sum } else { $null }
            UnknownSize = $items.Count - $known.Count
            Items       = $items
        }
    } | Sort-Object @{ Expression = { $reasonOrder[$_.Reason] } }, Name)
for ($i = 0; $i -lt $rows.Count; $i++) { $rows[$i].Row = $i + 1 }

function Show-Overview {
    Show-RowTable $rows
    Write-Host ('Prism Centrals: ' + (($pcs | ForEach-Object { '{0} = {1}' -f $_.Label, $_.Address }) -join ', '))
    if ($rows | Where-Object { $_.UnknownSize -and $_.UnknownSize -lt $_.Count }) {
        Write-Host '* some recovery points in this row report no size; the value shown is the known part.'
    }
    $byReason = $candidates | Group-Object Reason | ForEach-Object { '{0} {1}' -f $_.Count, $_.Name }
    Write-Host ("{0} in {1} ({2}), space: {3}" -f (Format-Count $candidates.Count 'recovery point'), (Format-Count $rows.Count 'row'),
            ($byReason -join ', '), (Format-Total $candidates))
    $legend = [ordered]@{
        'VM missing'  = 'the VM no longer exists on any Prism Central checked'
        'VG missing'  = 'the volume group no longer exists on any Prism Central checked'
        'VM replaced' = 'the VM no longer exists, but another VM has the same name (restored or re-created?) - check before deleting'
        'Expired'     = 'past its expiry date but still there; the VM / volume group still exists'
    }
    foreach ($reason in $legend.Keys) {
        if ($rows.Reason -contains $reason) { Write-Host ('  {0,-12} {1}' -f $reason, $legend[$reason]) }
    }
}

Show-Overview
$notListed = @(
    if ($skipped.Secure) { '{0} - deleting needs an approval in Prism Central' -f (Format-Count $skipped.Secure 'secure recovery point') }
    if ($skipped.Template) { '{0} with VM template data (VmTemplateRP_...) - deleting would break the template' -f (Format-Count $skipped.Template 'recovery point') }
    if ($skipped.Unverified) { '{0} whose VM / volume group could not be verified (for example missing permissions)' -f (Format-Count $skipped.Unverified 'recovery point') }
    if ($skipped.PartlyMissing) { '{0} with several VMs of which only some are missing' -f (Format-Count $skipped.PartlyMissing 'recovery point') }
    if ($skipped.Empty) { '{0} without VM or volume group' -f (Format-Count $skipped.Empty 'recovery point') }
)
if ($notListed.Count) {
    Write-Host 'Not listed:' -ForegroundColor Yellow
    $notListed | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}
Write-CleanupLog ("Found {0} recovery points in {1} rows; skipped: {2}" -f $candidates.Count, $rows.Count, (($skipped.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))

if ($ExportCsv) { Export-CandidateList -Rows $rows -Path $ExportCsv }

#endregion

#region Step 4: select

Write-Step 4 'Select'
function Show-SelectionHelp {
    Write-Host 'Which rows do you want to delete?'
    Write-Host '  1,4,7-12     rows by number'
    Write-Host '  all          every row in the list above (also not yet expired ones of deleted VMs)'
    Write-Host '  expired      all rows with reason Expired'
    Write-Host '  missing      all rows with reason VM missing or VG missing'
    Write-Host '  missing 30   the same, but only if the newest recovery point is older than 30 days'
    Write-Host '  d 5          show the recovery points of row 5'
    Write-Host '  list         show the table again'
    Write-Host '  csv          export the list to a CSV file'
    Write-Host '  q            quit without deleting'
    Write-Host 'Recommended: "expired" first, then "missing 30". Check "VM replaced" rows and recently'
    Write-Host 'deleted VMs with "d <row>" and select them by number only if nobody needs them back.'
}
Show-SelectionHelp

# "continue" inside a switch only leaves the switch, so the loop is labeled.
:selection while ($true) {
    $answer = "$(Read-Host 'Selection')".Trim()
    $selectedRows = $null
    switch -Regex ($answer) {
        '^(q|quit|exit)$' { Exit-Cleanup 'Cancelled.' }
        '^(l|list)$' { Show-Overview; continue selection }
        '^(h|help|\?)$' { Show-SelectionHelp; continue selection }
        '^csv$' {
            $path = Read-Text -Prompt 'CSV file' -Default ($script:LogFile -replace '\.log$', '_list.csv')
            try { Export-CandidateList -Rows $rows -Path $path } catch { Write-Host "Export failed: $($_.Exception.Message)" -ForegroundColor Red }
            continue selection
        }
        '^d\s*(\d+)$' {
            $number = [int]$Matches[1]
            if ($number -ge 1 -and $number -le $rows.Count) { Show-RowDetail $rows[$number - 1] }
            else { Write-Host "There is no row $number." -ForegroundColor Yellow }
            continue selection
        }
        '^all$' { $selectedRows = $rows }
        '^expired$' { $selectedRows = @($rows | Where-Object Reason -EQ 'Expired') }
        '^missing(?:\s+(\d+))?$' {
            # "missing 30": leave out VMs / volume groups that still had a recovery point in the last 30 days.
            $minDays = if ($Matches[1]) { [int]$Matches[1] } else { 0 }
            $selectedRows = @($rows | Where-Object {
                    $_.Reason -like '*missing' -and ($minDays -eq 0 -or ($_.NewestUtc -and ($nowUtc - $_.NewestUtc).TotalDays -ge $minDays))
                })
        }
        default {
            $numbers = @(ConvertFrom-RowSelection -Text $answer -Max $rows.Count)
            if ($numbers.Count) { $selectedRows = @($numbers | ForEach-Object { $rows[$_ - 1] }) }
        }
    }
    if ($null -eq $selectedRows) {
        if ($answer) { Write-Host "Not understood. Use for example 1,4,7-12 or all, or type help." -ForegroundColor Yellow }
        continue
    }
    $selectedRows = @($selectedRows)
    if (-not $selectedRows.Count) { Write-Host 'No rows match.' -ForegroundColor Yellow; continue }

    $selectedItems = @($selectedRows | ForEach-Object { $_.Items })
    Write-Host ''
    Write-Host 'Selected:' -ForegroundColor Cyan
    Show-RowTable $selectedRows
    foreach ($group in ($selectedItems | Group-Object { $_.Pc.Label } | Sort-Object Name)) {
        $pc = $group.Group[0].Pc
        Write-Host ("  {0} {1}: {2}, space {3}" -f $pc.Label, $pc.Address, (Format-Count $group.Count 'recovery point'), (Format-Total $group.Group))
    }
    Write-Host ("Total: {0}, space freed: {1}" -f (Format-Count $selectedItems.Count 'recovery point'), (Format-Total $selectedItems)) -ForegroundColor Cyan
    $notExpired = @($selectedItems | Where-Object { $null -eq $_.ExpiresUtc -or $_.ExpiresUtc -gt $nowUtc })
    if ($notExpired.Count) {
        Write-Host ("Not expired yet: {0}. Their VM / volume group no longer exists and cannot be restored after deleting them." -f
            (Format-Count $notExpired.Count 'recovery point')) -ForegroundColor Yellow
    }
    $replacedRows = @($selectedRows | Where-Object Reason -EQ 'VM replaced')
    if ($replacedRows.Count) {
        Write-Host ("Selected rows with reason VM replaced: {0}. Another VM has the same name; check with d <row> first." -f
            ($replacedRows.Row -join ', ')) -ForegroundColor Yellow
    }
    Write-Host 'The space shows up as free once the cluster background cleanup has run (usually several hours to a day).'
    Write-Host ''

    if ($script:DryRun) {
        if (Read-YesNo -Prompt 'DRY RUN: list what would be deleted (nothing is deleted)?') { break selection }
    } else {
        Write-ModeTag
        Write-Host ''
        $confirm = "$(Read-Host "Type $($selectedItems.Count) to delete $(Format-Count $selectedItems.Count 'recovery point') permanently, or press Enter to go back")".Trim()
        if ($confirm -eq "$($selectedItems.Count)") { break selection }
        Write-Host 'Not confirmed. Back to the selection.' -ForegroundColor Yellow
    }
}
Write-CleanupLog ("Selected rows: {0}" -f (($selectedRows | ForEach-Object { '{0} {1} ({2})' -f $_.Row, $_.Name, $_.Reason }) -join '; '))
Write-CleanupLog ("{0} {1} recovery points, space {2}" -f $(if ($script:DryRun) { 'Dry run for' } else { 'Confirmed deletion of' }), $selectedItems.Count, (Format-Total $selectedItems))

#endregion

#region Step 5: delete

Write-Step 5 $(if ($script:DryRun) { 'Delete (simulated, nothing is deleted)' } else { 'Delete' })
$queue = @($selectedItems | Sort-Object { $_.Pc.Label }, Name, CreatedUtc)
$finishedCount = 0
for ($start = 0; $start -lt $queue.Count; $start += $BatchSize) {
    $batch = $queue[$start..([Math]::Min($start + $BatchSize, $queue.Count) - 1)]
    $running = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $batch) {
        $target = '{0} / {1} on {2} ({3})' -f $item.Name, $item.RpName, $item.Pc.Address, $item.RpExtId
        if (-not $PSCmdlet.ShouldProcess($target, 'Delete recovery point')) {
            Add-Result $item 'Not deleted (dry run)' ''
            $finishedCount++
            continue
        }
        try {
            $response = Invoke-NtnxApi -Pc $item.Pc -Method DELETE -Path "/dataprotection/$ApiVersion/config/recovery-points/$($item.RpExtId)"
            $taskId = $response.data.extId
            if ($taskId) {
                $running.Add([pscustomobject]@{ Item = $item; TaskId = $taskId; Started = [datetime]::UtcNow })
            } else {
                Add-Result $item 'Failed' 'No task ID returned'
                $finishedCount++
            }
        } catch {
            $err = Get-ApiError $_
            if ($err.StatusCode -eq 404) { Add-Result $item 'Already gone' 'not found, deleted in the meantime' }
            else { Add-Result $item 'Failed' $err.Message }
            $finishedCount++
        }
        Start-Sleep -Milliseconds 500   # spread the deletions, Prism Central rate-limits its API
    }

    while ($running.Count) {
        Start-Sleep -Seconds 5
        foreach ($run in @($running)) {
            $elapsed = ([datetime]::UtcNow - $run.Started).TotalSeconds
            try {
                $task = (Invoke-NtnxApi -Pc $run.Item.Pc -Path "/prism/$ApiVersion/config/tasks/$($run.TaskId)").data
            } catch {
                $task = $null
            }
            if ($null -eq $task -or $task.status -in 'QUEUED', 'RUNNING', 'CANCELING') {
                if ($elapsed -ge $TimeoutSeconds) {
                    Add-Result $run.Item 'Timeout' "task $($run.TaskId) not finished after $TimeoutSeconds s, check it in Prism Central"
                    [void]$running.Remove($run)
                    $finishedCount++
                }
                continue
            }
            if ($task.status -eq 'SUCCEEDED') {
                Add-Result $run.Item 'Deleted' ''
            } else {
                $detail = @($task.errorMessages | ForEach-Object { $_.message } | Where-Object { $_ }) -join '; '
                if (-not $detail) { $detail = @($task.legacyErrorMessage) -join '; ' }
                Add-Result $run.Item 'Failed' ("task {0}: {1}" -f $task.status, $detail)
            }
            [void]$running.Remove($run)
            $finishedCount++
        }
        Write-Progress -Activity 'Deleting recovery points' -Status "$finishedCount of $($queue.Count) finished" -PercentComplete (100 * $finishedCount / $queue.Count)
    }
}
Write-Progress -Activity 'Deleting recovery points' -Completed

$resultsCsv = $script:LogFile -replace '\.log$', '_results.csv'
$script:Results | Export-Csv -LiteralPath $resultsCsv -NoTypeInformation -UseCulture -Encoding utf8BOM -WhatIf:$false -Confirm:$false

$deleted = @($script:Results | Where-Object Status -EQ 'Deleted')
$gone = @($script:Results | Where-Object Status -EQ 'Already gone')
$problems = @($script:Results | Where-Object Status -In 'Failed', 'Timeout')
Write-Host ''
if ($script:DryRun) {
    Write-Host ' DRY RUN finished: nothing was deleted. ' -ForegroundColor Black -BackgroundColor Yellow
    Write-Host "$(Format-Count $queue.Count 'recovery point') would have been deleted, space $(Format-Total $queue)." -ForegroundColor Cyan
} else {
    Write-Host ' LIVE RUN finished ' -ForegroundColor White -BackgroundColor DarkRed
    Write-Host ("Deleted {0} of {1}, space to be freed: {2}." -f $deleted.Count, (Format-Count $queue.Count 'recovery point'), (Format-Total $deleted)) -ForegroundColor Cyan
    if ($gone.Count) { Write-Host ("{0} already gone (for example deleted together with a copy)." -f (Format-Count $gone.Count 'was' 'were')) }
    if ($problems.Count) {
        Write-Host "$($problems.Count) could not be deleted:" -ForegroundColor Red
        $problems | Format-Table -AutoSize -Wrap Status, Name, RecoveryPointName, PrismCentral, Message | Out-Host
        Write-Host 'These still exist and are listed again in the next run, so you can simply run the script again.'
        if ($problems.Message -match 'rate limit') {
            Write-Host 'Some failed because of the API rate limit: run it again with -BatchSize 2.' -ForegroundColor Yellow
        }
        Write-Host 'If expired recovery points keep failing for other reasons, open a case with Nutanix support.'
    }
    if ($deleted.Count) {
        # Recorded so later runs can compare the storage with the state before this deletion.
        Add-StorageHistory @($deleted | Group-Object PrismCentral | ForEach-Object {
                $freed = ($_.Group | Where-Object { $null -ne $_.SizeBytes } | Measure-Object -Property SizeBytes -Sum).Sum
                ConvertTo-StorageRow -EventName 'Deleted' -PrismCentral $_.Name -DeletedCount $_.Count -FreedAtLeastBytes ([int64]$freed)
            })
        Write-Host 'To see how much space was actually freed, run this tomorrow from the same folder:' -ForegroundColor Cyan
        Write-Host '  .\Invoke-NtnxRecoveryPointCleanup.ps1 -StorageReport' -ForegroundColor Cyan
    }
}
if ($script:RateLimitWaits) {
    Write-Host ("The API rate limit was reached {0}; the script waited and tried again." -f (Format-Count $script:RateLimitWaits 'time')) -ForegroundColor DarkYellow
}
Write-CleanupLog ("Finished ({0}): deleted={1}, already gone={2}, failed={3}, rate limit waits={4}" -f $script:Mode, $deleted.Count, $gone.Count, $problems.Count, $script:RateLimitWaits)
Write-Host "Log:     $($script:LogFile)"
Write-Host "Results: $resultsCsv"

#endregion
