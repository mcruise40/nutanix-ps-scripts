<#
.SYNOPSIS
    Pre-upgrade readiness check for Nutanix AHV clusters. Verifies via the Prism Central v4
    API that one host can be taken out of operation (maintenance mode for LCM updates) without
    resource shortages, records open alerts with the engineer's justification and writes an
    HTML report per cluster that can be attached to the change.
.DESCRIPTION
    Checks per cluster:
      1. Cluster and host state      - no upgrade running, no host already in maintenance
      2. Data resiliency             - current fault tolerance >= configured fault tolerance
      3. Storage                     - usage in percent of the resilient capacity
      4. HA reservation              - memory reserved for a host failure (Guarantee mode)
      5. Memory with N-1             - memory allotted to running VMs vs. capacity without
                                       the largest host
      6. CPU with N-1                - cluster CPU peak in the window projected onto N-1 hosts
                                       (main CPU criterion)
      7. CPU Ready                   - highest CPU Ready per VM in the window (warning only)
      8. GPU with N-1                - GPU profiles in use vs. capacity without the GPU host
                                       with the most cards
      9. Non-migratable VMs          - VMs that cannot be live-migrated (affinity, GPU
                                       passthrough, PCIe devices, ...)
     10. NCC health checks           - started by the script, result recorded
     11. Open alerts                 - Critical and Warning; acknowledged alerts are listed
                                       for information only

    Rating:
      FAIL  -> NO-GO                 (resource shortage or blocking state)
      WARN  -> GO WITH RESERVATIONS  (the engineer enters a justification per finding)
      else  -> GO
    The upgrade itself is not started by this script.
.NOTES
    Reuses the auth pattern of the RecoveryPoints/Performance scripts. Field names are taken
    from the official Nutanix v4 SDKs (ntnx-clustermgmt/vmm/monitoring/prism-py-client 4.3):
      clustermgmt  config/clusters (config.faultToleranceState, config.buildInfo),
                   config/clusters/{id}/hosts (maintenanceState, nodeStatus, hostType, gpuList),
                   stats/clusters/{id} and .../hosts/{id} (hypervisorCpuUsagePpm,
                   storageCapacityBytes, storageUsageBytes, memoryCapacityBytes,
                   totalMemoryAllottedToVmBytes, haMemoryReservedBytes, cpuOvercommitRatioPpm,
                   memoryOvercommitRatioPpm),
                   config/clusters/{id}/$actions/compute-non-migratable-vms,
                   config/clusters/{id}/physical-gpu-profiles, virtual-gpu-profiles
      vmm          ahv/config/vms (isLiveMigrateCapable, isMemoryOvercommitEnabled, gpus,
                   pcieDevices), ahv/stats/vms (hypervisorCpuReadyTimePpm)
      monitoring   serviceability/alerts, serviceability/clusters/{id}/$actions/
                   run-system-defined-checks (NCC)
      prism        config/tasks/{id}

    Approximations (see README):
    - Resilient capacity = storage capacity minus the capacity of the largest host(s)
      (one host for FT1, two for FT2). Prism's own value may differ slightly.
    - Memory N-1 compares the memory allotted to running VMs with the capacity without the
      largest host. CVM memory is included on both sides, so the result is conservative.
    - GPU N-1 assumes that the profile capacity (allocated + assignable) is spread evenly
      across all GPU cards in the cluster.

    The API revision is negotiated per namespace: -ApiVersion first, then v4.2, v4.1, v4.0.
    Requires PowerShell 7+ (uses -SkipCertificateCheck / -SkipHeaderValidation).
.PARAMETER PcIp
    IP address(es) or FQDN(s) of one or more Prism Central instances (without https:// or
    port). All clusters registered to each Prism Central are covered.
.PARAMETER Credential
    Prism Central credentials (PSCredential object), e.g. via Get-Credential.
.PARAMETER ClusterNames
    Only check these cluster(s) (Prism Element cluster name, case-insensitive). Recommended,
    as a change normally covers one cluster.
.PARAMETER ChangeId
    Optional change or ticket number, printed in the report and used in the file name.
.PARAMETER Engineer
    Name of the engineer running the check. Default: the current Windows user.
.PARAMETER Hours
    Look-back window for CPU peak and CPU Ready in hours. Default: 168 (7 days).
.PARAMETER CpuThresholdPercent
    Maximum projected N-1 CPU peak. Above -> FAIL. Default: 80.
.PARAMETER MemoryThresholdPercent
    Maximum memory allotted to running VMs in percent of the N-1 capacity. Above -> FAIL.
    Default: 95.
.PARAMETER StorageThresholdPercent
    Maximum storage usage in percent of the resilient capacity. Above -> FAIL. Default: 75
    (default warning threshold of the Prism storage summary).
.PARAMETER CpuReadyThresholdPercent
    CPU Ready threshold per VM. VMs above it -> WARN. Default: 5.
.PARAMETER SkipNcc
    Do not start the NCC health checks.
.PARAMETER NccTimeoutMinutes
    Maximum time to wait for the NCC run per cluster. Default: 60.
.PARAMETER SkipCpuReady
    Skip the CPU Ready evaluation (faster on large environments).
.PARAMETER NonInteractive
    Do not prompt for justifications. Warnings are reported as "no justification provided".
.PARAMETER ReportFolder
    Folder for the HTML reports. Default: current directory.
.PARAMETER CsvPath
    Optional CSV export (semicolon-delimited, UTF-8) of all check results.
.PARAMETER ApiVersion
    Preferred Nutanix v4 API revision. Default: "v4.2".
.EXAMPLE
    .\Test-NtnxUpgradeReadiness.ps1 -PcIp 10.0.20.10 -Credential $creds -ClusterNames "NTNX-CL01" -ChangeId "CHG0012345"

    Full check of one cluster including NCC, with an HTML report for the change.
.EXAMPLE
    .\Test-NtnxUpgradeReadiness.ps1 -PcIp 10.0.20.10 -Credential $creds -SkipNcc -NonInteractive | Format-Table

    Quick check of all clusters without NCC and without prompts.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$PcIp,
    [Parameter(Mandatory)][pscredential]$Credential,

    [string[]]$ClusterNames,
    [string]$ChangeId,
    [string]$Engineer = $(if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USER }),

    [ValidateRange(1, 8760)]
    [int]$Hours = 168,

    [ValidateRange(1, 100)][double]$CpuThresholdPercent = 80,
    [ValidateRange(1, 100)][double]$MemoryThresholdPercent = 95,
    [ValidateRange(1, 100)][double]$StorageThresholdPercent = 75,
    [ValidateRange(0, 100)][double]$CpuReadyThresholdPercent = 5,

    [switch]$SkipNcc,
    [ValidateRange(1, 480)][int]$NccTimeoutMinutes = 60,
    [switch]$SkipCpuReady,
    [switch]$NonInteractive,

    [string]$ReportFolder = (Get-Location).Path,
    [string]$CsvPath,

    [string]$ApiVersion = "v4.2"
)

$PSDefaultParameterValues = @{ 'Invoke-RestMethod:SkipCertificateCheck' = $true }

$authHeader = @{
    Authorization = "Basic " + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("$($Credential.UserName):$($Credential.GetNetworkCredential().Password)")
    )
}

$runStart = Get-Date
$endTime  = $runStart
$startTime = $endTime.AddHours(-$Hours)
$startIso = $startTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$endIso   = $endTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
# Short window for "current" values (capacities, usage) - the latest sample is used
$recentIso = $endTime.AddHours(-6).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

if (-not (Test-Path $ReportFolder)) { New-Item -ItemType Directory -Path $ReportFolder | Out-Null }

# ---------------------------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------------------------

function Invoke-NtnxApi {
    # Same as in the other scripts, except that the original exception is kept as
    # InnerException, so Invoke-NtnxV4 can read the HTTP status code for version fallback.
    param($Method, $Path, $Body)

    $headers = $authHeader.Clone()
    if ($Method -in @('POST', 'PUT', 'DELETE')) {
        $headers['Ntnx-Request-Id'] = (New-Guid).Guid
    }

    $params = @{ Method = $Method; Uri = "$baseUri$Path"; Headers = $headers; SkipHeaderValidation = $true }
    if ($Body) {
        $params.Body        = ($Body | ConvertTo-Json -Depth 10)
        $params.ContentType = "application/json"
    }

    try {
        Invoke-RestMethod @params -ErrorAction Stop
    } catch {
        $errorDetail = $_.ErrorDetails.Message
        $msg = if ($errorDetail) { "Nutanix API call failed ($Method $Path):`n$errorDetail" } else { "Nutanix API call failed ($Method $Path): $($_.Exception.Message)" }
        throw [System.Exception]::new($msg, $_.Exception)
    }
}

function Get-NtnxResponseCode {
    param($Exception)
    $e = $Exception
    while ($e) {
        if ($e.PSObject.Properties['Response'] -and $e.Response -and $e.Response.StatusCode) {
            return [int]$e.Response.StatusCode
        }
        $e = $e.InnerException
    }
    return $null
}

function Invoke-NtnxV4 {
    # Calls /<Namespace>/<version><Path>. Tries the cached revision of the namespace first;
    # on 404/501 the next candidate revision is tried and cached on success.
    param([string]$Namespace, [string]$Method = 'GET', [string]$Path, $Body)

    $candidates = if ($script:nsVersion[$Namespace]) { @($script:nsVersion[$Namespace]) }
                  else { @($ApiVersion, 'v4.2', 'v4.1', 'v4.0') | Select-Object -Unique }
    $lastError = $null
    foreach ($ver in $candidates) {
        try {
            $r = Invoke-NtnxApi -Method $Method -Path "/$Namespace/$ver$Path" -Body $Body
            $script:nsVersion[$Namespace] = $ver
            return $r
        } catch {
            $lastError = $_
            $code = Get-NtnxResponseCode $_.Exception
            if ($code -notin @(404, 501)) { throw }
            Write-Verbose "$Namespace/$ver$Path -> HTTP $code, trying next revision"
        }
    }
    throw $lastError
}

function Get-NtnxPagedV4 {
    # Page size capped at 100 (API limit). Uses $page (zero-based), NOT $offset - $offset is
    # silently ignored, causing an endless loop.
    param([string]$Namespace, [string]$Path, [string]$Query, [int]$PageSize = 100)

    $all  = [System.Collections.Generic.List[object]]::new()
    $page = 0
    do {
        $q = "`$page=$page&`$limit=$PageSize"
        if ($Query) { $q = "$Query&$q" }
        $result = Invoke-NtnxV4 -Namespace $Namespace -Path "$($Path)?$q"
        foreach ($d in @($result.data)) { if ($null -ne $d) { $all.Add($d) } }
        $page++
    } while ($result.data -and @($result.data).Count -eq $PageSize)
    return $all
}

function Get-NtnxStats {
    # Returns a hashtable metric -> array of {timestamp, value} for a clustermgmt stats path.
    param([string]$Path, [string[]]$Fields, [string]$StatType, [string]$From, [string]$To, [int]$Interval)

    $query = "`$startTime=$([uri]::EscapeDataString($From))" +
             "&`$endTime=$([uri]::EscapeDataString($To))" +
             "&`$samplingInterval=$Interval&`$statType=$StatType"
    $result = $null
    if ($script:useSelect) {
        try {
            $result = Invoke-NtnxV4 -Namespace clustermgmt -Path "$($Path)?$query&`$select=$([uri]::EscapeDataString($Fields -join ','))"
        } catch {
            Write-Verbose "`$select rejected, retrying without it: $($_.Exception.Message)"
            $script:useSelect = $false
        }
    }
    if (-not $result) { $result = Invoke-NtnxV4 -Namespace clustermgmt -Path "$($Path)?$query" }

    $out = @{}
    foreach ($f in $Fields) {
        $series = @($result.data.$f | Where-Object { $null -ne $_ -and $null -ne $_.value })
        if (-not $series -and $result.data.stats) {
            $series = @($result.data.stats | Where-Object { $null -ne $_.$f } |
                ForEach-Object { [pscustomobject]@{ timestamp = $_.timestamp; value = $_.$f } })
        }
        $out[$f] = $series
    }
    return $out
}

function Get-Latest { param($Series) ($Series | Sort-Object { ConvertTo-LocalTime $_.timestamp } | Select-Object -Last 1).value }
function Get-Peak   { param($Series) $Series | Sort-Object value -Descending | Select-Object -First 1 }

function Wait-NtnxTask {
    param([string]$TaskExtId, [int]$TimeoutMinutes, [string]$Activity)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        $t = (Invoke-NtnxV4 -Namespace prism -Path "/config/tasks/$TaskExtId").data
        if ($t.status -in @('SUCCEEDED', 'FAILED', 'CANCELED')) { return $t }
        if ($Activity) { Write-Progress -Activity $Activity -Status "$($t.status) $($t.progressPercentage) %" -PercentComplete ([int]$t.progressPercentage) }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    return $t
}

# ---------------------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------------------

function ConvertTo-LocalTime {
    param($Timestamp)
    if ($null -eq $Timestamp) { return $null }
    if ($Timestamp -is [datetime]) {
        if ($Timestamp.Kind -eq [DateTimeKind]::Unspecified) { $Timestamp = [datetime]::SpecifyKind($Timestamp, [DateTimeKind]::Utc) }
        return $Timestamp.ToLocalTime()
    }
    return ([datetimeoffset]::Parse([string]$Timestamp, [cultureinfo]::InvariantCulture)).LocalDateTime
}

function ConvertTo-Percent { param($Ppm) if ($null -eq $Ppm) { $null } else { [math]::Round([double]$Ppm / 10000, 2) } }
function Format-Bytes { param($Bytes) if ($null -eq $Bytes) { 'n/a' } else { '{0:N2} TiB' -f ([double]$Bytes / 1TB) } }
function Format-GiB  { param($Bytes) if ($null -eq $Bytes) { 'n/a' } else { '{0:N0} GiB' -f ([double]$Bytes / 1GB) } }
function HtmlEnc { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }

function Add-Check {
    param($List, [string]$Check, [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO', 'SKIPPED')][string]$Result,
          [string]$Value, [string]$Threshold, [string]$Detail)
    $List.Add([pscustomobject][ordered]@{
        Check         = $Check
        Result        = $Result
        Value         = $Value
        Threshold     = $Threshold
        Detail        = $Detail
        Justification = $null
    })
}

# ---------------------------------------------------------------------------------------
# Main loop over all Prism Central instances
# ---------------------------------------------------------------------------------------

$allRows = [System.Collections.Generic.List[object]]::new()

foreach ($pc in $PcIp) {

    $baseUri = "https://$($pc):9440/api"
    $script:nsVersion = @{}
    $script:useSelect = $true
    Write-Host "Prism Central $pc - CPU window $($startTime.ToString('yyyy-MM-dd HH:mm')) to $($endTime.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Cyan

    # --- Clusters ---
    try {
        $clusters = @(Get-NtnxPagedV4 -Namespace clustermgmt -Path "/config/clusters" |
                      Where-Object { @($_.config.clusterFunction) -notcontains 'PRISM_CENTRAL' })
    } catch {
        Write-Warning "Skipping Prism Central $pc - cluster list failed: $($_.Exception.Message)"
        continue
    }
    if ($ClusterNames) {
        $clusters = @($clusters | Where-Object { $ClusterNames -contains $_.name })
    }
    if (-not $clusters) { Write-Warning "No matching clusters on $pc."; continue }

    # --- Start NCC on all target clusters first (runs in parallel while we collect data) ---
    $nccTasks = @{}
    if (-not $SkipNcc) {
        foreach ($cl in $clusters) {
            try {
                $body = @{ shouldRunAllChecks = $true; shouldSendReportToConfiguredRecipients = $false; shouldAnonymize = $false }
                $r = Invoke-NtnxV4 -Namespace monitoring -Method POST -Path "/serviceability/clusters/$($cl.extId)/`$actions/run-system-defined-checks" -Body $body
                $nccTasks[$cl.extId] = @{ TaskId = $r.data.extId; Started = Get-Date; Error = $null }
                Write-Host "  NCC started on $($cl.name)" -ForegroundColor DarkGray
            } catch {
                $nccTasks[$cl.extId] = @{ TaskId = $null; Started = Get-Date; Error = $_.Exception.Message }
                Write-Warning "NCC could not be started on $($cl.name): $($_.Exception.Message)"
            }
        }
    }

    # --- VMs (once per PC) ---
    try {
        $allVms = @(Get-NtnxPagedV4 -Namespace vmm -Path "/ahv/config/vms")
    } catch {
        Write-Warning "VM list on $pc failed: $($_.Exception.Message)"
        $allVms = @()
    }

    # --- CPU Ready (once per PC, list endpoint, per-interval maximum) ---
    $cpuReadyByVm = @{}
    $cpuReadyError = $null
    if (-not $SkipCpuReady) {
        try {
            $q = "`$startTime=$([uri]::EscapeDataString($startIso))&`$endTime=$([uri]::EscapeDataString($endIso))" +
                 "&`$samplingInterval=3600&`$statType=MAX&`$select=$([uri]::EscapeDataString('stats/timestamp,stats/hypervisorCpuReadyTimePpm'))"
            $vmStats = Get-NtnxPagedV4 -Namespace vmm -Path "/ahv/stats/vms" -Query $q
            foreach ($s in $vmStats) {
                $vals = @($s.stats | Where-Object { $null -ne $_.hypervisorCpuReadyTimePpm })
                if ($vals) {
                    $peak = $vals | Sort-Object hypervisorCpuReadyTimePpm -Descending | Select-Object -First 1
                    $cpuReadyByVm[$s.extId] = [pscustomobject]@{ Ppm = $peak.hypervisorCpuReadyTimePpm; At = ConvertTo-LocalTime $peak.timestamp }
                }
            }
        } catch {
            $cpuReadyError = $_.Exception.Message
            Write-Warning "CPU Ready stats on $pc failed: $cpuReadyError"
        }
    }

    foreach ($cl in $clusters) {

        Write-Host "Checking cluster $($cl.name)" -ForegroundColor Cyan
        $checks  = [System.Collections.Generic.List[object]]::new()
        $extra   = @{ Alerts = @(); AckAlerts = @(); NonMigratable = @(); CpuReady = @(); Hosts = @(); Info = [ordered]@{} }
        $clVms   = @($allVms | Where-Object { $_.cluster.extId -eq $cl.extId })
        $onVms   = @($clVms | Where-Object { $_.powerState -eq 'ON' })
        $ft      = $cl.config.faultToleranceState

        $extra.Info['AOS version'] = $cl.config.buildInfo.version
        $extra.Info['Redundancy factor'] = $cl.config.redundancyFactor
        $extra.Info['VMs (running / total)'] = "$($onVms.Count) / $($clVms.Count)"

        # --- Hosts ---
        try {
            $hosts = @(Get-NtnxPagedV4 -Namespace clustermgmt -Path "/config/clusters/$($cl.extId)/hosts")
        } catch {
            Write-Warning "Host list for $($cl.name) failed: $($_.Exception.Message)"
            $hosts = @()
        }
        $vmHosts      = @($hosts | Where-Object { $_.hostType -ne 'STORAGE_ONLY' })
        $storageHosts = @($hosts | Where-Object { $_.hostType -ne 'COMPUTE_ONLY' })

        # --- Cluster stats ---
        $cpuSeries = @(); $now = @{}
        try {
            $cpuSeries = (Get-NtnxStats -Path "/stats/clusters/$($cl.extId)" -Fields @('hypervisorCpuUsagePpm') -StatType MAX -From $startIso -To $endIso -Interval 300)['hypervisorCpuUsagePpm']
            $nowFields = @('storageCapacityBytes', 'storageUsageBytes', 'memoryCapacityBytes', 'totalMemoryAllottedToVmBytes',
                           'haMemoryReservedBytes', 'cpuOvercommitRatioPpm', 'memoryOvercommitRatioPpm', 'aggregateVmConfiguredVcpus')
            $s = Get-NtnxStats -Path "/stats/clusters/$($cl.extId)" -Fields $nowFields -StatType LAST -From $recentIso -To $endIso -Interval 300
            foreach ($f in $nowFields) { $now[$f] = Get-Latest $s[$f] }
        } catch {
            Write-Warning "Cluster stats for $($cl.name) failed: $($_.Exception.Message)"
        }

        # --- Host stats ---
        $hostRows = foreach ($h in $hosts) {
            $hs = @{}
            $hPeak = $null
            try {
                $f = @('memoryCapacityBytes', 'storageCapacityBytes', 'totalMemoryAllottedToVmBytes')
                $r = Get-NtnxStats -Path "/stats/clusters/$($cl.extId)/hosts/$($h.extId)" -Fields $f -StatType LAST -From $recentIso -To $endIso -Interval 300
                foreach ($x in $f) { $hs[$x] = Get-Latest $r[$x] }
                $c = Get-NtnxStats -Path "/stats/clusters/$($cl.extId)/hosts/$($h.extId)" -Fields @('hypervisorCpuUsagePpm') -StatType MAX -From $startIso -To $endIso -Interval 300
                $hPeak = Get-Peak $c['hypervisorCpuUsagePpm']
            } catch {
                Write-Warning "Host stats for $($h.hostName) failed: $($_.Exception.Message)"
            }
            [pscustomobject][ordered]@{
                Host             = $h.hostName
                Type             = $h.hostType
                NodeStatus       = $h.nodeStatus
                Maintenance      = $h.maintenanceState
                RebootPending    = $h.isRebootPending
                MemoryBytes      = if ($hs.memoryCapacityBytes) { $hs.memoryCapacityBytes } else { $h.memorySizeBytes }
                StorageBytes     = $hs.storageCapacityBytes
                AllottedVmBytes  = $hs.totalMemoryAllottedToVmBytes
                MaxCpuPct        = if ($hPeak) { ConvertTo-Percent $hPeak.value } else { $null }
                MaxCpuAt         = if ($hPeak) { ConvertTo-LocalTime $hPeak.timestamp } else { $null }
                Gpus             = @($h.gpuList).Count
            }
        }
        $hostRows = @($hostRows)
        $extra.Hosts = $hostRows

        # ===== 1. Cluster and host state =====
        $inMaint = @($hostRows | Where-Object { $_.Maintenance -and $_.Maintenance -notmatch '^(normal|none)$' })
        $badNode = @($hostRows | Where-Object { $_.NodeStatus -and $_.NodeStatus -ne 'NORMAL' })
        $upg     = $cl.upgradeStatus
        if ($upg -in @('PENDING', 'DOWNLOADING', 'QUEUED', 'PREUPGRADE', 'UPGRADING', 'SCHEDULED')) {
            Add-Check $checks 'Cluster and host state' FAIL "Upgrade status $upg" 'No upgrade in progress' 'An upgrade is already running or scheduled on this cluster.'
        } elseif ($inMaint -or $badNode) {
            $names = (@($inMaint) + @($badNode) | Select-Object -ExpandProperty Host -Unique) -join ', '
            Add-Check $checks 'Cluster and host state' FAIL "Not normal: $names" 'All hosts in normal operation' 'At least one host is already in maintenance or not in NORMAL state - the cluster has no N-1 headroom left.'
        } else {
            $reboot = @($hostRows | Where-Object RebootPending) | Select-Object -ExpandProperty Host
            $detail = if ($reboot) { "Reboot pending on: $($reboot -join ', ')" } else { 'All hosts in normal operation.' }
            Add-Check $checks 'Cluster and host state' PASS "$($hosts.Count) host(s)" 'All hosts in normal operation' $detail
        }

        # ===== 2. Data resiliency =====
        if ($ft -and $null -ne $ft.currentMaxFaultTolerance) {
            $desired = if ($null -ne $ft.desiredMaxFaultTolerance) { $ft.desiredMaxFaultTolerance } else { 1 }
            $res = if ($ft.currentMaxFaultTolerance -ge $desired -and $ft.currentMaxFaultTolerance -ge 1) { 'PASS' } else { 'FAIL' }
            Add-Check $checks 'Data resiliency' $res "FT $($ft.currentMaxFaultTolerance) (desired FT $desired)" "Current FT >= desired FT" "Domain awareness: $($ft.domainAwarenessLevel)"
        } else {
            Add-Check $checks 'Data resiliency' WARN 'n/a' 'Current FT >= desired FT' 'Fault tolerance state not returned by the API - check the Data Resiliency widget in Prism manually.'
        }

        # ===== 3. Storage vs. resilient capacity =====
        $ftLevel = if ($ft -and $ft.desiredMaxFaultTolerance) { [int]$ft.desiredMaxFaultTolerance } else { 1 }
        $hostStorage = @($hostRows | Where-Object { $_.Type -ne 'COMPUTE_ONLY' -and $_.StorageBytes } | Sort-Object StorageBytes -Descending)
        if ($now.storageCapacityBytes -and $null -ne $now.storageUsageBytes -and $hostStorage.Count -gt $ftLevel) {
            $lost      = ($hostStorage | Select-Object -First $ftLevel | Measure-Object StorageBytes -Sum).Sum
            $resilient = [double]$now.storageCapacityBytes - $lost
            $pct       = [math]::Round([double]$now.storageUsageBytes / $resilient * 100, 1)
            $res       = if ($pct -gt $StorageThresholdPercent) { 'FAIL' } else { 'PASS' }
            Add-Check $checks 'Storage (resilient capacity)' $res "$pct %" "<= $StorageThresholdPercent %" ("Used {0} of {1} resilient capacity (total {2}, FT{3})" -f (Format-Bytes $now.storageUsageBytes), (Format-Bytes $resilient), (Format-Bytes $now.storageCapacityBytes), $ftLevel)
        } else {
            Add-Check $checks 'Storage (resilient capacity)' WARN 'n/a' "<= $StorageThresholdPercent %" 'Storage capacity could not be determined - check the storage summary in Prism manually.'
        }

        # ===== 4. HA reservation =====
        if ($null -ne $now.haMemoryReservedBytes) {
            if ([double]$now.haMemoryReservedBytes -gt 0) {
                Add-Check $checks 'HA reservation' PASS ("{0} reserved" -f (Format-GiB $now.haMemoryReservedBytes)) 'Enabled' 'Memory is reserved to restart the VMs of a failed host (Guarantee mode).'
            } else {
                Add-Check $checks 'HA reservation' WARN 'Not enabled' 'Enabled' 'No memory is reserved for a host failure (best effort). The memory check below shows whether the VMs still fit on N-1.'
            }
        } else {
            Add-Check $checks 'HA reservation' SKIPPED 'n/a' 'Enabled' 'haMemoryReservedBytes not returned by the API.'
        }

        # ===== 5. Memory with N-1 =====
        $memHosts = @($hostRows | Where-Object { $_.Type -ne 'STORAGE_ONLY' -and $_.MemoryBytes })
        $allotted = if ($null -ne $now.totalMemoryAllottedToVmBytes) { [double]$now.totalMemoryAllottedToVmBytes }
                    else { ($memHosts | Measure-Object AllottedVmBytes -Sum).Sum }
        if ($memHosts.Count -gt 1 -and $allotted) {
            $capTotal = ($memHosts | Measure-Object MemoryBytes -Sum).Sum
            $capN1    = $capTotal - ($memHosts | Measure-Object MemoryBytes -Maximum).Maximum
            $pct      = [math]::Round($allotted / $capN1 * 100, 1)
            $res      = if ($pct -gt $MemoryThresholdPercent) { 'FAIL' } else { 'PASS' }
            $oc       = @($onVms | Where-Object isMemoryOvercommitEnabled).Count
            $detail   = "{0} allotted to running VMs, N-1 capacity {1} (total {2}). VMs with memory overcommit: {3}" -f (Format-GiB $allotted), (Format-GiB $capN1), (Format-GiB $capTotal), $oc
            Add-Check $checks 'Memory with N-1' $res "$pct %" "<= $MemoryThresholdPercent %" $detail
        } elseif ($memHosts.Count -le 1) {
            Add-Check $checks 'Memory with N-1' FAIL 'Single host' 'At least 2 hosts' 'Single-node cluster - VMs must be shut down for the upgrade.'
        } else {
            Add-Check $checks 'Memory with N-1' WARN 'n/a' "<= $MemoryThresholdPercent %" 'Memory values could not be determined.'
        }
        if ($null -ne $now.memoryOvercommitRatioPpm) { $extra.Info['Memory overcommit ratio'] = '{0:N2} : 1' -f ($now.memoryOvercommitRatioPpm / 1e6) }

        # ===== 6. CPU with N-1 =====
        $n = $vmHosts.Count
        $peak = Get-Peak $cpuSeries
        if ($peak -and $n -gt 1) {
            $maxPct = ConvertTo-Percent $peak.value
            $proj   = [math]::Round($maxPct * $n / ($n - 1), 1)
            $res    = if ($proj -gt $CpuThresholdPercent) { 'FAIL' } else { 'PASS' }
            Add-Check $checks 'CPU peak with N-1' $res "$proj %" "<= $CpuThresholdPercent %" ("Cluster peak {0} % at {1:yyyy-MM-dd HH:mm}, {2} hosts -> projected onto {3}" -f $maxPct, (ConvertTo-LocalTime $peak.timestamp), $n, ($n - 1))
        } elseif ($n -le 1) {
            Add-Check $checks 'CPU peak with N-1' FAIL 'Single host' 'At least 2 hosts' 'Single-node cluster - VMs must be shut down for the upgrade.'
        } else {
            Add-Check $checks 'CPU peak with N-1' WARN 'n/a' "<= $CpuThresholdPercent %" 'No CPU usage data in the window.'
        }
        if ($null -ne $now.cpuOvercommitRatioPpm) { $extra.Info['vCPU : pCPU ratio (current)'] = '{0:N2} : 1' -f ($now.cpuOvercommitRatioPpm / 1e6) }
        if ($null -ne $now.aggregateVmConfiguredVcpus) { $extra.Info['Configured vCPUs'] = $now.aggregateVmConfiguredVcpus }

        # ===== 7. CPU Ready =====
        if ($SkipCpuReady) {
            Add-Check $checks 'CPU Ready' SKIPPED '-' "<= $CpuReadyThresholdPercent %" 'Skipped (-SkipCpuReady).'
        } elseif ($cpuReadyError) {
            Add-Check $checks 'CPU Ready' SKIPPED 'n/a' "<= $CpuReadyThresholdPercent %" "CPU Ready stats could not be read: $cpuReadyError"
        } else {
            $ready = foreach ($vm in $onVms) {
                $cr = $cpuReadyByVm[$vm.extId]
                if ($cr) { [pscustomobject]@{ VM = $vm.name; MaxReadyPct = ConvertTo-Percent $cr.Ppm; At = $cr.At } }
            }
            $ready = @($ready | Sort-Object MaxReadyPct -Descending)
            $extra.CpuReady = @($ready | Select-Object -First 10)
            $above = @($ready | Where-Object { $_.MaxReadyPct -gt $CpuReadyThresholdPercent })
            $top   = if ($ready) { $ready[0].MaxReadyPct } else { 0 }
            if ($above) {
                Add-Check $checks 'CPU Ready' WARN "$($above.Count) VM(s), max $top %" "<= $CpuReadyThresholdPercent %" ("Above threshold: " + (($above | Select-Object -First 5 | ForEach-Object { "$($_.VM) ($($_.MaxReadyPct) %)" }) -join ', '))
            } else {
                Add-Check $checks 'CPU Ready' PASS "max $top %" "<= $CpuReadyThresholdPercent %" "$($ready.Count) running VM(s) with CPU Ready data, none above the threshold (contention already present would get worse with N-1)."
            }
        }

        # ===== 8. GPU with N-1 =====
        $gpuVms = @($onVms | Where-Object { @($_.gpus).Count -gt 0 })
        if (-not $gpuVms) {
            Add-Check $checks 'GPU with N-1' PASS 'No GPU VMs' '-' 'No running VM uses a GPU.'
        } else {
            try {
                $cards     = @($hostRows | Where-Object Gpus)
                $totCards  = ($cards | Measure-Object Gpus -Sum).Sum
                $maxCards  = ($cards | Measure-Object Gpus -Maximum).Maximum
                $profiles  = @()
                $profiles += @(Get-NtnxPagedV4 -Namespace clustermgmt -Path "/config/clusters/$($cl.extId)/virtual-gpu-profiles"  | ForEach-Object { [pscustomobject]@{ Kind = 'vGPU';        Cfg = $_.virtualGpuConfig;  Alloc = @($_.allocatedVmExtIds).Count } })
                $profiles += @(Get-NtnxPagedV4 -Namespace clustermgmt -Path "/config/clusters/$($cl.extId)/physical-gpu-profiles" | ForEach-Object { [pscustomobject]@{ Kind = 'Passthrough'; Cfg = $_.physicalGpuConfig; Alloc = @($_.allocatedVmExtIds).Count } })
                $profiles  = @($profiles | Where-Object { $_.Alloc -gt 0 })
                if (-not $totCards) { throw "no GPU cards reported on the hosts (gpuList)" }
                $share   = $maxCards / $totCards
                $short   = @(); $lines = @()
                foreach ($p in $profiles) {
                    $cap   = $p.Alloc + [int]$p.Cfg.assignable
                    $capN1 = [math]::Floor($cap * (1 - $share))
                    $lines += "$($p.Kind) $($p.Cfg.deviceName): $($p.Alloc) in use, capacity $cap, N-1 approx. $capN1"
                    if ($p.Alloc -gt $capN1) { $short += "$($p.Cfg.deviceName)" }
                }
                $res = if ($short) { 'FAIL' } else { 'PASS' }
                Add-Check $checks 'GPU with N-1' $res "$($gpuVms.Count) GPU VM(s)" 'GPU profiles in use fit on N-1' ("$totCards card(s), max $maxCards per host. " + ($lines -join '; '))
            } catch {
                Add-Check $checks 'GPU with N-1' WARN "$($gpuVms.Count) GPU VM(s)" 'GPU profiles in use fit on N-1' "GPU capacity could not be determined ($($_.Exception.Message)) - check manually."
            }
        }

        # ===== 9. Non-migratable VMs =====
        $nonMig = $null; $nonMigSource = $null
        try {
            $body = @{ hosts = @($hosts.extId) }
            $r    = Invoke-NtnxV4 -Namespace clustermgmt -Method POST -Path "/config/clusters/$($cl.extId)/`$actions/compute-non-migratable-vms" -Body $body
            $task = Wait-NtnxTask -TaskExtId $r.data.extId -TimeoutMinutes 5
            if ($task.status -ne 'SUCCEEDED') { throw "task status $($task.status)" }
            # The result extId is not documented explicitly - try the affected entities and
            # completion details of the task.
            $candidates = @($task.entitiesAffected.extId) + @($task.completionDetails.value) |
                          Where-Object { $_ -match '^[0-9a-f]{8}-[0-9a-f]{4}-' } | Select-Object -Unique
            foreach ($id in $candidates) {
                try {
                    $res = Invoke-NtnxV4 -Namespace clustermgmt -Path "/config/clusters/$($cl.extId)/non-migratable-vms-result/$id"
                    $nonMig = @($res.data.vms | ForEach-Object { [pscustomobject]@{ VM = $_.vmName; Reason = $_.nonMigratableVmReason; Host = $_.hostIp.ipv4.value } })
                    $nonMigSource = 'AOS compute-non-migratable-vms'
                    break
                } catch { Write-Verbose "Result $id not readable: $($_.Exception.Message)" }
            }
            if ($null -eq $nonMig) { throw "result not found in task details" }
        } catch {
            Write-Verbose "compute-non-migratable-vms not usable on $($cl.name): $($_.Exception.Message) - using VM properties"
            $nonMigSource = 'VM properties (isLiveMigrateCapable, GPU passthrough, PCIe devices) - affinity rules not covered'
            $nonMig = @(foreach ($vm in $onVms) {
                $reasons = @()
                if ($vm.isLiveMigrateCapable -eq $false) { $reasons += 'not live-migrate capable' }
                if (@($vm.gpus | Where-Object { $_.mode -like 'PASSTHROUGH*' }).Count) { $reasons += 'GPU passthrough' }
                if (@($vm.pcieDevices).Count) { $reasons += 'PCIe device' }
                $hName = ($hosts | Where-Object { $_.extId -eq $vm.host.extId } | Select-Object -First 1).hostName
                if ($reasons) { [pscustomobject]@{ VM = $vm.name; Reason = $reasons -join ', '; Host = $(if ($hName) { $hName } else { $vm.host.extId }) } }
            })
        }
        $extra.NonMigratable = $nonMig
        $agentVms = @($onVms | Where-Object isAgentVm).Count
        if ($nonMig) {
            Add-Check $checks 'Non-migratable VMs' WARN "$($nonMig.Count) VM(s)" 'None' ("Must be shut down or handled manually during maintenance. Source: $nonMigSource. " + (($nonMig | Select-Object -First 5 | ForEach-Object { "$($_.VM) ($($_.Reason))" }) -join ', '))
        } else {
            $d = "Source: $nonMigSource."
            if ($agentVms) { $d += " $agentVms agent VM(s) - these are powered off automatically with the host." }
            Add-Check $checks 'Non-migratable VMs' PASS 'None' 'None' $d
        }

        # ===== 10. NCC =====
        if ($SkipNcc) {
            Add-Check $checks 'NCC health checks' SKIPPED '-' 'Run before upgrade' 'Skipped (-SkipNcc).'
        } else {
            $nt = $nccTasks[$cl.extId]
            if ($nt.Error -or -not $nt.TaskId) {
                Add-Check $checks 'NCC health checks' WARN 'Not started' 'Run before upgrade' "NCC could not be started via the API: $($nt.Error)"
            } else {
                $remaining = [math]::Max(1, [int]($NccTimeoutMinutes - ((Get-Date) - $nt.Started).TotalMinutes))
                $t = Wait-NtnxTask -TaskExtId $nt.TaskId -TimeoutMinutes $remaining -Activity "NCC on $($cl.name)"
                Write-Progress -Activity "NCC on $($cl.name)" -Completed
                $done = ConvertTo-LocalTime $t.completedTime
                $msgs = (@($t.errorMessages.message) + @($t.warnings.message) | Where-Object { $_ }) -join ' '
                switch ($t.status) {
                    'SUCCEEDED' { Add-Check $checks 'NCC health checks' PASS 'Completed' 'Run before upgrade' ("Run {0:yyyy-MM-dd HH:mm} - {1:HH:mm}. Findings are raised as alerts and evaluated below. {2}" -f $nt.Started, $done, $msgs) }
                    'FAILED'    { Add-Check $checks 'NCC health checks' WARN 'Failed' 'Run before upgrade' "NCC task failed: $msgs" }
                    default     { Add-Check $checks 'NCC health checks' WARN "$($t.status)" 'Run before upgrade' "NCC did not finish within $NccTimeoutMinutes min (task $($nt.TaskId))." }
                }
            }
        }

        # ===== 11. Open alerts (read after NCC so new findings are included) =====
        try {
            $alerts = @()
            try {
                $alerts = @(Get-NtnxPagedV4 -Namespace monitoring -Path "/serviceability/alerts" -Query "`$filter=$([uri]::EscapeDataString('isResolved eq false'))")
            } catch {
                Write-Verbose "Alert filter rejected, reading all alerts: $($_.Exception.Message)"
                $alerts = @(Get-NtnxPagedV4 -Namespace monitoring -Path "/serviceability/alerts" | Where-Object { -not $_.isResolved })
            }
            $alerts = @($alerts | Where-Object {
                ($_.clusterUUID -eq $cl.extId -or $_.originatingClusterUUID -eq $cl.extId) -and $_.severity -in @('CRITICAL', 'WARNING')
            } | Sort-Object @{ Expression = { if ($_.severity -eq 'CRITICAL') { 0 } else { 1 } } }, creationTime)

            $open = @($alerts | Where-Object { -not $_.isAcknowledged })
            $ack  = @($alerts | Where-Object isAcknowledged)
            $extra.AckAlerts = @($ack | ForEach-Object { [pscustomobject]@{ Severity = $_.severity; Title = $_.title; Created = ConvertTo-LocalTime $_.creationTime; AcknowledgedBy = $_.acknowledgedByUsername } })

            foreach ($a in $open) {
                Add-Check $checks "Alert: $($a.title)" WARN $a.severity 'No open Critical/Warning alerts' ("{0} (raised {1:yyyy-MM-dd HH:mm})" -f $a.message, (ConvertTo-LocalTime $a.creationTime))
            }
            if (-not $open) {
                Add-Check $checks 'Open alerts' PASS '0 unacknowledged' 'No open Critical/Warning alerts' "$($ack.Count) acknowledged alert(s) listed for information."
            }
        } catch {
            Add-Check $checks 'Open alerts' WARN 'n/a' 'No open Critical/Warning alerts' "Alerts could not be read: $($_.Exception.Message) - check Prism manually."
        }

        # ===== Justifications for warnings =====
        $warns = @($checks | Where-Object Result -eq 'WARN')
        if ($warns -and -not $NonInteractive) {
            Write-Host ""
            Write-Host "$($warns.Count) finding(s) on $($cl.name) need a justification (why it does not affect the upgrade):" -ForegroundColor Yellow
            foreach ($w in $warns) {
                Write-Host ""
                Write-Host "  [$($w.Value)] $($w.Check)" -ForegroundColor Yellow
                Write-Host "  $($w.Detail)" -ForegroundColor DarkGray
                $j = ''
                while (-not $j.Trim()) { $j = Read-Host "  Justification" }
                $w.Justification = $j.Trim()
            }
        }
        foreach ($w in $warns) { if (-not $w.Justification) { $w.Justification = '(no justification provided)' } }

        # ===== Verdict =====
        $verdict = if ($checks.Result -contains 'FAIL') { 'NO-GO' }
                   elseif ($checks.Result -contains 'WARN') { 'GO WITH RESERVATIONS' }
                   else { 'GO' }
        $color = switch ($verdict) { 'GO' { 'Green' } 'NO-GO' { 'Red' } default { 'Yellow' } }
        Write-Host "  $($cl.name): $verdict" -ForegroundColor $color

        foreach ($c in $checks) {
            $allRows.Add([pscustomobject][ordered]@{
                PrismCentral  = $pc
                Cluster       = $cl.name
                Verdict       = $verdict
                Check         = $c.Check
                Result        = $c.Result
                Value         = $c.Value
                Threshold     = $c.Threshold
                Detail        = $c.Detail
                Justification = $c.Justification
            })
        }

        # ===== HTML report =====
        $badge = @{ PASS = 'pass'; WARN = 'warn'; FAIL = 'fail'; INFO = 'info'; SKIPPED = 'skip' }
        $vClass = switch ($verdict) { 'GO' { 'pass' } 'NO-GO' { 'fail' } default { 'warn' } }
        $sb = [System.Text.StringBuilder]::new()
        $title = "Upgrade readiness - $($cl.name)"
        [void]$sb.Append(@"
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>$(HtmlEnc $title)</title>
<style>
body{font-family:Segoe UI,Helvetica,Arial,sans-serif;color:#1f2933;margin:32px;max-width:1100px}
h1{font-size:22px;margin:0 0 4px} h2{font-size:16px;margin:28px 0 8px;border-bottom:1px solid #d9dee3;padding-bottom:4px}
.meta{color:#52606d;font-size:13px} table{border-collapse:collapse;width:100%;font-size:13px}
th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #e4e7eb;vertical-align:top} th{background:#f5f7fa}
.verdict{display:inline-block;margin:16px 0;padding:10px 18px;border-radius:6px;font-size:18px;font-weight:600}
.b{display:inline-block;padding:1px 8px;border-radius:10px;font-size:12px;font-weight:600}
.pass{background:#e3f6e8;color:#1b6b35}.warn{background:#fff3d6;color:#8a5a00}.fail{background:#fde2e1;color:#a61b1b}
.info{background:#e6eefc;color:#1f4fa3}.skip{background:#eceff1;color:#52606d}
.kv td:first-child{width:260px;color:#52606d} .just{font-style:italic}
footer{margin-top:32px;color:#7b8794;font-size:12px}
</style></head><body>
<h1>$(HtmlEnc $title)</h1>
<div class="meta">Pre-upgrade check via Prism Central v4 API</div>
<div class="verdict $vClass">$(HtmlEnc $verdict)</div>
<h2>Run</h2><table class="kv">
<tr><td>Cluster</td><td>$(HtmlEnc $cl.name) ($(HtmlEnc $cl.extId))</td></tr>
<tr><td>Prism Central</td><td>$(HtmlEnc $pc)</td></tr>
<tr><td>Change</td><td>$(HtmlEnc $(if ($ChangeId) { $ChangeId } else { '-' }))</td></tr>
<tr><td>Engineer</td><td>$(HtmlEnc $Engineer)</td></tr>
<tr><td>Executed</td><td>$(HtmlEnc (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))</td></tr>
<tr><td>CPU evaluation window</td><td>$(HtmlEnc ("{0:yyyy-MM-dd HH:mm} - {1:yyyy-MM-dd HH:mm} ({2} h)" -f $startTime, $endTime, $Hours))</td></tr>
"@)
        foreach ($k in $extra.Info.Keys) { [void]$sb.Append("<tr><td>$(HtmlEnc $k)</td><td>$(HtmlEnc $extra.Info[$k])</td></tr>") }
        [void]$sb.Append("</table><h2>Checks</h2><table><tr><th>Check</th><th>Result</th><th>Value</th><th>Threshold</th><th>Detail / justification</th></tr>")
        foreach ($c in $checks) {
            $j = if ($c.Justification) { "<div class='just'>Justification: $(HtmlEnc $c.Justification)</div>" } else { '' }
            [void]$sb.Append("<tr><td>$(HtmlEnc $c.Check)</td><td><span class='b $($badge[$c.Result])'>$($c.Result)</span></td><td>$(HtmlEnc $c.Value)</td><td>$(HtmlEnc $c.Threshold)</td><td>$(HtmlEnc $c.Detail)$j</td></tr>")
        }
        [void]$sb.Append("</table><h2>Hosts</h2><table><tr><th>Host</th><th>Type</th><th>Status</th><th>Memory</th><th>Storage</th><th>CPU peak</th><th>Peak at</th><th>GPUs</th></tr>")
        foreach ($h in $hostRows) {
            $st = if ($h.Maintenance) { "$($h.NodeStatus) / $($h.Maintenance)" } else { $h.NodeStatus }
            [void]$sb.Append("<tr><td>$(HtmlEnc $h.Host)</td><td>$(HtmlEnc $h.Type)</td><td>$(HtmlEnc $st)</td><td>$(Format-GiB $h.MemoryBytes)</td><td>$(Format-Bytes $h.StorageBytes)</td><td>$(HtmlEnc $(if ($null -ne $h.MaxCpuPct) { "$($h.MaxCpuPct) %" } else { 'n/a' }))</td><td>$(HtmlEnc $(if ($h.MaxCpuAt) { $h.MaxCpuAt.ToString('yyyy-MM-dd HH:mm') }))</td><td>$($h.Gpus)</td></tr>")
        }
        [void]$sb.Append("</table>")
        if ($extra.NonMigratable) {
            [void]$sb.Append("<h2>Non-migratable VMs</h2><table><tr><th>VM</th><th>Reason</th><th>Host</th></tr>")
            foreach ($v in $extra.NonMigratable) { [void]$sb.Append("<tr><td>$(HtmlEnc $v.VM)</td><td>$(HtmlEnc $v.Reason)</td><td>$(HtmlEnc $v.Host)</td></tr>") }
            [void]$sb.Append("</table>")
        }
        if ($extra.CpuReady) {
            [void]$sb.Append("<h2>Highest CPU Ready (top 10)</h2><table><tr><th>VM</th><th>Max CPU Ready</th><th>At</th></tr>")
            foreach ($v in $extra.CpuReady) { [void]$sb.Append("<tr><td>$(HtmlEnc $v.VM)</td><td>$($v.MaxReadyPct) %</td><td>$(HtmlEnc $(if ($v.At) { $v.At.ToString('yyyy-MM-dd HH:mm') }))</td></tr>") }
            [void]$sb.Append("</table>")
        }
        if ($extra.AckAlerts) {
            [void]$sb.Append("<h2>Acknowledged alerts (information)</h2><table><tr><th>Severity</th><th>Title</th><th>Raised</th><th>Acknowledged by</th></tr>")
            foreach ($a in $extra.AckAlerts) { [void]$sb.Append("<tr><td>$(HtmlEnc $a.Severity)</td><td>$(HtmlEnc $a.Title)</td><td>$(HtmlEnc $(if ($a.Created) { $a.Created.ToString('yyyy-MM-dd HH:mm') }))</td><td>$(HtmlEnc $a.AcknowledgedBy)</td></tr>") }
            [void]$sb.Append("</table>")
        }
        [void]$sb.Append(@"
<h2>Rating</h2><table class="kv">
<tr><td><span class="b pass">GO</span></td><td>All checks passed.</td></tr>
<tr><td><span class="b warn">GO WITH RESERVATIONS</span></td><td>No resource shortage; each warning carries the engineer's justification.</td></tr>
<tr><td><span class="b fail">NO-GO</span></td><td>Resource shortage or blocking state - do not start the upgrade.</td></tr>
</table>
<footer>Generated by Test-NtnxUpgradeReadiness.ps1 - nutanix-ps-scripts. Projections assume homogeneous hosts and an even redistribution of the load.</footer>
</body></html>
"@)
        $safe = ($cl.name -replace '[^\w\-]', '_')
        $chg  = if ($ChangeId) { "_$($ChangeId -replace '[^\w\-]', '_')" } else { '' }
        $file = Join-Path $ReportFolder ("UpgradeReadiness_{0}{1}_{2:yyyyMMdd-HHmm}.html" -f $safe, $chg, $runStart)
        Set-Content -Path $file -Value $sb.ToString() -Encoding utf8
        Write-Host "  Report: $file" -ForegroundColor Green
    }
}

# --- Output ---
if (-not $allRows.Count) {
    Write-Host "No clusters checked." -ForegroundColor Yellow
    return
}
if ($CsvPath) {
    $allRows | Export-Csv -Path $CsvPath -Delimiter ';' -NoTypeInformation -Encoding utf8
    Write-Host "Exported to $CsvPath" -ForegroundColor Green
}
$allRows
