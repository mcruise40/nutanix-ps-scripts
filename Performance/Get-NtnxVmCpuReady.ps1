<#
.SYNOPSIS
    Reads the CPU Ready Time of all (or selected) AHV VMs from one or more Prism Central
    instances via the Nutanix v4 API and summarizes it per VM (average, peak, number of
    samples above a threshold). Covers every cluster registered to the given Prism
    Central(s); can be narrowed to specific clusters, VM names or a Category.
.NOTES
    Reuses Invoke-NtnxApi and Get-AllNtnxVms from the RecoveryPoints scripts (same
    auth/pagination pattern). Stats are fetched per VM via
    GET /vmm/<ApiVersion>/ahv/stats/vms/{extId} - field names (hypervisorCpuReadyTimePpm,
    hypervisorCpuUsagePpm) are taken from the official Nutanix VMM SDK (ntnx-vmm-py-client,
    model vmm.v4.ahv.stats.VmStatsTuple).

    Unit: the API returns ppm (parts per million). 10'000 ppm = 1 %. The script converts
    to percent. Whether Nutanix normalizes the value per vCPU (unlike VMware's per-VM
    summation) is not explicitly documented - the SDK describes it as "percentage of time
    that the VM was ready, but could not get scheduled to run".

    With -StatType AVG (default) each sample is the average over one sampling interval,
    so short spikes are smoothed out. Use a smaller -SamplingInterval or -StatType MAX
    to see peaks.

    Requires PowerShell 7+ (uses -SkipCertificateCheck / -SkipHeaderValidation).
.PARAMETER PcIp
    IP address(es) or FQDN(s) of one or more Prism Central instances (without https:// or
    port). All clusters registered to each Prism Central are covered.
.PARAMETER Credential
    Prism Central credentials (PSCredential object), e.g. via Get-Credential. The same
    credential is used for every Prism Central in -PcIp.
.PARAMETER VmNames
    Only evaluate these VM(s). Mandatory for the 'ByName' parameter set; mutually
    exclusive with -CategoryKey/-CategoryValue. Matching is case-insensitive.
.PARAMETER CategoryKey
    Category key (e.g. "Workload") used to select VMs. Mandatory for the 'ByCategory'
    parameter set; must be used together with -CategoryValue.
.PARAMETER CategoryValue
    Category value (e.g. "SQL") used together with -CategoryKey.
.PARAMETER ClusterNames
    Only evaluate VMs running on these cluster(s) (by Prism Element cluster name,
    case-insensitive). Can be combined with any parameter set.
.PARAMETER Hours
    Look-back window in hours, ending now. Default: 24. Ignored if -StartTime is given.
.PARAMETER StartTime
    Explicit start of the evaluation window (local time). Use together with -EndTime.
.PARAMETER EndTime
    Explicit end of the evaluation window (local time). Default: now.
.PARAMETER SamplingInterval
    Sampling interval in seconds for the returned data points. Default: 300 (5 min).
    Smaller values give more detail but larger responses.
.PARAMETER StatType
    Down-sampling operator applied per sampling interval: AVG (default), MAX, MIN, LAST.
.PARAMETER ThresholdPercent
    CPU Ready threshold in percent. VMs with at least one sample above it are flagged
    (Status = WARN). Default: 5 (Nutanix best-practice guidance for SQL Server).
.PARAMETER IncludePoweredOff
    Also query VMs that are not powered on (they normally return no stats).
.PARAMETER ApiVersion
    Nutanix v4 API revision to target. Default: "v4.2". For the cluster-name lookup
    (clustermgmt namespace) the script falls back to "v4.0" if this revision is rejected.
.PARAMETER CsvPath
    Optional path for a CSV export (semicolon-delimited, UTF-8) of the per-VM summary,
    or of the per-sample rows when -Raw is used.
.PARAMETER Raw
    Output one row per VM and sample (timestamp + values) instead of the per-VM summary -
    useful for charting or for checking individual spikes.
.EXAMPLE
    .\Get-NtnxVmCpuReady.ps1 -PcIp 10.0.20.10 -Credential $creds

    CPU Ready summary for all powered-on VMs on all clusters of this Prism Central,
    last 24 hours, 5-minute averages.
.EXAMPLE
    .\Get-NtnxVmCpuReady.ps1 -PcIp 10.0.20.10,10.1.20.10 -Credential $creds -Hours 168 -CsvPath .\cpuready.csv

    Last 7 days across two Prism Central instances, exported to CSV.
.EXAMPLE
    .\Get-NtnxVmCpuReady.ps1 -PcIp 10.0.20.10 -Credential $creds -ClusterNames "NTNX-CL01" -SamplingInterval 30 -Hours 2 -StatType MAX

    Peak values in 30-second resolution for the last 2 hours on one cluster only.
.EXAMPLE
    .\Get-NtnxVmCpuReady.ps1 -PcIp 10.0.20.10 -Credential $creds -CategoryKey "Workload" -CategoryValue "SQL" |
        Where-Object Status -eq 'WARN'

    Only SQL VMs (by category), showing just the ones above the threshold.
.EXAMPLE
    .\Get-NtnxVmCpuReady.ps1 -PcIp 10.0.20.10 -Credential $creds -VmNames "SQL01" -Raw | Format-Table

    Individual samples for one VM.
#>

[CmdletBinding(DefaultParameterSetName = 'All')]
param(
    [Parameter(Mandatory)][string[]]$PcIp,
    [Parameter(Mandatory)][pscredential]$Credential,

    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [string[]]$VmNames,

    [Parameter(Mandatory, ParameterSetName = 'ByCategory')]
    [string]$CategoryKey,

    [Parameter(Mandatory, ParameterSetName = 'ByCategory')]
    [string]$CategoryValue,

    [string[]]$ClusterNames,

    [ValidateRange(1, 8760)]
    [int]$Hours = 24,

    [datetime]$StartTime,
    [datetime]$EndTime = (Get-Date),

    [ValidateRange(30, 86400)]
    [int]$SamplingInterval = 300,

    [ValidateSet('AVG', 'MAX', 'MIN', 'LAST')]
    [string]$StatType = 'AVG',

    [ValidateRange(0, 100)]
    [double]$ThresholdPercent = 5,

    [switch]$IncludePoweredOff,

    [string]$ApiVersion = "v4.2",

    [string]$CsvPath,

    [switch]$Raw
)

$PSDefaultParameterValues = @{ 'Invoke-RestMethod:SkipCertificateCheck' = $true }

$authHeader = @{
    Authorization = "Basic " + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("$($Credential.UserName):$($Credential.GetNetworkCredential().Password)")
    )
}

# --- Evaluation window (API expects ISO-8601; UTC with 'Z' avoids '+' encoding issues) ---
if (-not $PSBoundParameters.ContainsKey('StartTime')) {
    $StartTime = $EndTime.AddHours(-$Hours)
}
if ($StartTime -ge $EndTime) { throw "-StartTime must be before -EndTime." }

$startIso = $StartTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$endIso   = $EndTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# --- Reused as-is from the RecoveryPoints scripts ---
# Note: $baseUri is set per Prism Central inside the main loop below (script scope, so
# these functions pick up the current value).

function Invoke-NtnxApi {
    # Ntnx-Request-Id is mandatory on v4 POST/PUT/DELETE requests (idempotency token).
    # Dormant for this read-only script (only GET calls are made), kept for consistency.
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
        if ($errorDetail) {
            Write-Error "Nutanix API call failed ($Method $Path):`n$errorDetail" -ErrorAction Stop
        } else {
            throw
        }
    }
}

function Get-AllNtnxVms {
    # Page size capped at 100 (API limit). Uses $page (zero-based), NOT $offset -
    # $offset is silently ignored, causing an endless loop.
    param([int]$PageSize = 100)

    $all = @()
    $page = 0
    do {
        $result = Invoke-NtnxApi -Method GET -Path "/vmm/$ApiVersion/ahv/config/vms?`$page=$page&`$limit=$PageSize"
        if ($result.data) { $all += $result.data }
        $page++
    } while ($result.data -and $result.data.Count -eq $PageSize)

    return $all
}

# --- New for this script ---

function Get-NtnxClusterLookup {
    # Cluster extId -> name. Tries the configured API revision first, then v4.0 (the
    # clustermgmt namespace may not expose every vmm revision). Best-effort: returns an
    # empty map on failure, output then shows the cluster extId instead of the name.
    param([int]$PageSize = 100)

    foreach ($ver in (@($ApiVersion, 'v4.0') | Select-Object -Unique)) {
        try {
            $map  = @{}
            $page = 0
            do {
                $result = Invoke-NtnxApi -Method GET -Path "/clustermgmt/$ver/config/clusters?`$page=$page&`$limit=$PageSize"
                foreach ($c in @($result.data)) {
                    if ($c.extId) { $map[$c.extId] = $c.name }
                }
                $page++
            } while ($result.data -and $result.data.Count -eq $PageSize)
            return $map
        } catch {
            Write-Verbose "Cluster lookup via clustermgmt/$ver failed: $($_.Exception.Message)"
        }
    }

    Write-Warning "Could not resolve cluster names on $($script:currentPc) - showing cluster extIds instead."
    return @{}
}

function Get-NtnxVmStatsSamples {
    # Returns the stats tuples for one VM. First attempt uses $select to keep the
    # response small; if the PC rejects the $select expression, the script falls back
    # to the unfiltered response for all following calls ($script:useSelect).
    param([string]$VmExtId)

    $query = "`$startTime=$([uri]::EscapeDataString($startIso))" +
             "&`$endTime=$([uri]::EscapeDataString($endIso))" +
             "&`$samplingInterval=$SamplingInterval" +
             "&`$statType=$StatType"

    if ($script:useSelect) {
        $select = [uri]::EscapeDataString("stats/timestamp,stats/hypervisorCpuReadyTimePpm,stats/hypervisorCpuUsagePpm")
        try {
            $result = Invoke-NtnxApi -Method GET -Path "/vmm/$ApiVersion/ahv/stats/vms/$($VmExtId)?$query&`$select=$select"
            return @($result.data.stats)
        } catch {
            Write-Verbose "`$select rejected, retrying without it: $($_.Exception.Message)"
            $script:useSelect = $false
        }
    }

    $result = Invoke-NtnxApi -Method GET -Path "/vmm/$ApiVersion/ahv/stats/vms/$($VmExtId)?$query"
    return @($result.data.stats)
}

function ConvertTo-Percent {
    # ppm -> percent (10'000 ppm = 1 %), $null stays $null
    param($Ppm)
    if ($null -eq $Ppm) { return $null }
    [math]::Round([double]$Ppm / 10000, 2)
}

# --- Main loop over all Prism Central instances ---
$script:useSelect = $true
$summary = [System.Collections.Generic.List[object]]::new()
$samples = [System.Collections.Generic.List[object]]::new()

foreach ($pc in $PcIp) {

    $script:currentPc = $pc
    $baseUri = "https://$($pc):9440/api"
    Write-Host "Prism Central $pc - window $($StartTime.ToString('yyyy-MM-dd HH:mm')) to $($EndTime.ToString('yyyy-MM-dd HH:mm')), interval $($SamplingInterval)s, $StatType" -ForegroundColor Cyan

    try {
        $allVms = Get-AllNtnxVms
    } catch {
        Write-Warning "Skipping Prism Central $pc - VM list failed: $($_.Exception.Message)"
        continue
    }

    $clusterLookup = Get-NtnxClusterLookup

    # --- Resolve target VMs depending on parameter set ---
    $targetVms = $allVms

    if ($PSCmdlet.ParameterSetName -eq 'ByName') {

        $targetVms = foreach ($name in $VmNames) {
            $match = $allVms | Where-Object { $_.name -eq $name }  # -eq is case-insensitive in PowerShell
            if (-not $match) {
                Write-Warning "VM '$name' not found on $pc - skipping"
                continue
            }
            $match
        }

    } elseif ($PSCmdlet.ParameterSetName -eq 'ByCategory') {

        $catFilter  = "key eq '$CategoryKey' and value eq '$CategoryValue'"
        $catEncoded = [uri]::EscapeDataString($catFilter)
        $catResult  = Invoke-NtnxApi -Method GET -Path "/prism/$ApiVersion/config/categories?`$filter=$catEncoded"

        if (-not $catResult.data) {
            Write-Warning "No category '$CategoryKey`:$CategoryValue' on $pc - skipping this Prism Central."
            continue
        }
        $categoryExtId = $catResult.data[0].extId

        $targetVms = $allVms | Where-Object { $_.categories -and ($_.categories.extId -contains $categoryExtId) }
    }

    # --- Optional cluster filter ---
    if ($ClusterNames) {
        if ($clusterLookup.Count -eq 0) {
            throw "-ClusterNames was given, but cluster names could not be resolved on $pc."
        }
        $targetVms = $targetVms | Where-Object {
            $clName = $clusterLookup[$_.cluster.extId]
            $clName -and ($ClusterNames -contains $clName)   # -contains is case-insensitive
        }
    }

    # --- Skip powered-off VMs unless requested ---
    $targetVms = @($targetVms)
    if (-not $IncludePoweredOff) {
        $offCount  = @($targetVms | Where-Object { $_.powerState -ne 'ON' }).Count
        $targetVms = @($targetVms | Where-Object { $_.powerState -eq 'ON' })
        if ($offCount) { Write-Verbose "$offCount VM(s) not powered on - skipped (use -IncludePoweredOff to include)." }
    }

    if (-not $targetVms) {
        Write-Warning "No matching VMs on $pc."
        continue
    }

    # --- Fetch stats per VM ---
    $i = 0
    foreach ($vm in $targetVms) {
        $i++
        Write-Progress -Activity "CPU Ready on $pc" -Status "$($vm.name) ($i/$($targetVms.Count))" -PercentComplete ($i / $targetVms.Count * 100)

        $clusterExtId = $vm.cluster.extId
        $clusterName  = if ($clusterExtId -and $clusterLookup.ContainsKey($clusterExtId)) { $clusterLookup[$clusterExtId] } else { $clusterExtId }
        $threads      = if ($vm.numThreadsPerCore) { $vm.numThreadsPerCore } else { 1 }
        $vCpus        = [int]$vm.numSockets * [int]$vm.numCoresPerSocket * [int]$threads

        try {
            $stats = Get-NtnxVmStatsSamples -VmExtId $vm.extId
        } catch {
            Write-Warning "Stats for VM '$($vm.name)' on $pc failed: $($_.Exception.Message)"
            continue
        }

        # Only samples that actually carry a CPU Ready value
        $valid = @($stats | Where-Object { $null -ne $_.hypervisorCpuReadyTimePpm })

        if ($Raw) {
            foreach ($s in $valid) {
                $samples.Add([pscustomobject][ordered]@{
                    PrismCentral  = $pc
                    Cluster       = $clusterName
                    VM            = $vm.name
                    vCPUs         = $vCpus
                    Timestamp     = $s.timestamp
                    CpuReadyPct   = ConvertTo-Percent $s.hypervisorCpuReadyTimePpm
                    CpuUsagePct   = ConvertTo-Percent $s.hypervisorCpuUsagePpm
                })
            }
            continue
        }

        if (-not $valid) {
            $summary.Add([pscustomobject][ordered]@{
                PrismCentral   = $pc
                Cluster        = $clusterName
                VM             = $vm.name
                Status         = 'NO DATA'
                vCPUs          = $vCpus
                Samples        = 0
                AvgReadyPct    = $null
                MaxReadyPct    = $null
                AboveThreshold = 0
                AvgCpuUsagePct = $null
                MaxReadyAt     = $null
            })
            continue
        }

        $readyStats = $valid.hypervisorCpuReadyTimePpm | Measure-Object -Average -Maximum
        $peak       = $valid | Sort-Object hypervisorCpuReadyTimePpm -Descending | Select-Object -First 1
        $usageVals  = @($valid | Where-Object { $null -ne $_.hypervisorCpuUsagePpm }).hypervisorCpuUsagePpm
        $usageAvg   = if ($usageVals) { ($usageVals | Measure-Object -Average).Average } else { $null }
        $thresholdPpm = $ThresholdPercent * 10000
        $aboveCount   = @($valid | Where-Object { $_.hypervisorCpuReadyTimePpm -gt $thresholdPpm }).Count

        $summary.Add([pscustomobject][ordered]@{
            PrismCentral   = $pc
            Cluster        = $clusterName
            VM             = $vm.name
            Status         = if ($aboveCount -gt 0) { 'WARN' } else { 'OK' }
            vCPUs          = $vCpus
            Samples        = $valid.Count
            AvgReadyPct    = ConvertTo-Percent $readyStats.Average
            MaxReadyPct    = ConvertTo-Percent $readyStats.Maximum
            AboveThreshold = $aboveCount
            AvgCpuUsagePct = ConvertTo-Percent $usageAvg
            MaxReadyAt     = $peak.timestamp
        })
    }

    Write-Progress -Activity "CPU Ready on $pc" -Completed
}

# --- Output ---
$output = if ($Raw) {
    $samples | Sort-Object PrismCentral, Cluster, VM, Timestamp
} else {
    $summary | Sort-Object @{ Expression = { if ($null -eq $_.MaxReadyPct) { -1 } else { $_.MaxReadyPct } }; Descending = $true }, VM
}

if (-not $output) {
    Write-Host "No CPU Ready data found." -ForegroundColor Yellow
    return
}

if (-not $Raw) {
    $warnCount = @($summary | Where-Object Status -eq 'WARN').Count
    $color = if ($warnCount) { 'Yellow' } else { 'Green' }
    Write-Host "$($summary.Count) VM(s) evaluated, $warnCount with CPU Ready above $ThresholdPercent % in at least one sample." -ForegroundColor $color
}

if ($CsvPath) {
    $output | Export-Csv -Path $CsvPath -Delimiter ';' -NoTypeInformation -Encoding utf8
    Write-Host "Exported to $CsvPath" -ForegroundColor Green
}

$output
