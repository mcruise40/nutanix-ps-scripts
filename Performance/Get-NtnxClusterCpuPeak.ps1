<#
.SYNOPSIS
    Reads the hypervisor CPU usage of all (or selected) clusters and their hosts from one
    or more Prism Central instances via the Nutanix v4 API, determines the peak in the
    evaluation window and projects the cluster peak onto N-1 hosts (one host in
    maintenance or failed).
.DESCRIPTION
    Intended as a pre-check before rolling upgrades: shows whether the remaining hosts can
    absorb the load of the busiest period while one host is unavailable. Covers every
    cluster registered to the given Prism Central(s); can be narrowed to specific clusters.

    The N-1 projection is calculated as: MaxCpuPct x Nodes / (Nodes - 1). It assumes
    homogeneous nodes and an even redistribution of the load. Additional CVM load during an
    upgrade is not included. Use it together with CPU Ready (Get-NtnxVmCpuReady.ps1) - CPU
    usage alone does not show contention.
.NOTES
    Reuses Invoke-NtnxApi from the RecoveryPoints scripts (same auth pattern). Stats are
    fetched via
      GET /clustermgmt/<ApiVersion>/stats/clusters/{clusterExtId}
      GET /clustermgmt/<ApiVersion>/stats/clusters/{clusterExtId}/hosts/{hostExtId}
    The field name hypervisorCpuUsagePpm is taken from the official Nutanix clustermgmt SDK
    (model clustermgmt.v4.stats.ClusterStats / HostStats, metrics as TimeValuePair arrays).

    Unit: the API returns ppm (parts per million). 10'000 ppm = 1 %. The script converts
    to percent.

    With -StatType MAX (default) each sample is the highest value within one sampling
    interval, so short peaks are preserved even with a coarse interval. AvgCpuPct is the
    mean of the returned samples - with MAX that is the mean of the per-interval peaks,
    not the true average. Use -StatType AVG for a real average.

    Entity stats via the v4 API require Prism Central pc.2024.1 / AOS 6.8 or later.
    Requires PowerShell 7+ (uses -SkipCertificateCheck / -SkipHeaderValidation).
.PARAMETER PcIp
    IP address(es) or FQDN(s) of one or more Prism Central instances (without https:// or
    port). All clusters registered to each Prism Central are covered.
.PARAMETER Credential
    Prism Central credentials (PSCredential object), e.g. via Get-Credential. The same
    credential is used for every Prism Central in -PcIp.
.PARAMETER ClusterNames
    Only evaluate these cluster(s) (by Prism Element cluster name, case-insensitive).
.PARAMETER Hours
    Look-back window in hours, ending now. Default: 168 (7 days). Ignored if -StartTime is
    given.
.PARAMETER StartTime
    Explicit start of the evaluation window (local time). Use together with -EndTime.
.PARAMETER EndTime
    Explicit end of the evaluation window (local time). Default: now.
.PARAMETER SamplingInterval
    Sampling interval in seconds for the returned data points. Default: 300 (5 min).
    Smaller values give more detail but larger responses.
.PARAMETER StatType
    Down-sampling operator applied per sampling interval: MAX (default), AVG, MIN, LAST.
.PARAMETER ThresholdPercent
    Threshold for the projected N-1 peak in percent. Clusters above it are flagged
    (Status = WARN). Default: 80. This is a rule of thumb, not an official Nutanix value.
.PARAMETER ClusterOnly
    Skip the per-host queries and only report cluster rows (faster on large environments).
.PARAMETER ApiVersion
    Nutanix v4 API revision to target. Default: "v4.2". The script falls back to "v4.0" if
    this revision is rejected by the clustermgmt namespace.
.PARAMETER CsvPath
    Optional path for a CSV export (semicolon-delimited, UTF-8) of the summary, or of the
    per-sample rows when -Raw is used.
.PARAMETER Raw
    Output one row per cluster/host and sample (timestamp + value) instead of the summary -
    useful for charting or for checking individual peaks.
.EXAMPLE
    .\Get-NtnxClusterCpuPeak.ps1 -PcIp 10.0.20.10 -Credential $creds | Format-Table

    Peak CPU usage of all clusters and hosts of this Prism Central over the last 7 days,
    including the N-1 projection per cluster.
.EXAMPLE
    .\Get-NtnxClusterCpuPeak.ps1 -PcIp 10.0.20.10,10.1.20.10 -Credential $creds -ClusterOnly -CsvPath .\cpupeak.csv

    Cluster rows only, across two Prism Central instances, exported to CSV.
.EXAMPLE
    .\Get-NtnxClusterCpuPeak.ps1 -PcIp 10.0.20.10 -Credential $creds -ClusterNames "NTNX-CL01" -Hours 24 -SamplingInterval 30 |
        Format-Table

    Peaks in 30-second resolution for the last 24 hours on one cluster, right before an
    upgrade.
.EXAMPLE
    .\Get-NtnxClusterCpuPeak.ps1 -PcIp 10.0.20.10 -Credential $creds -ClusterNames "NTNX-CL01" -ClusterOnly -Raw |
        Format-Table

    Individual samples of one cluster.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$PcIp,
    [Parameter(Mandatory)][pscredential]$Credential,

    [string[]]$ClusterNames,

    [ValidateRange(1, 8760)]
    [int]$Hours = 168,

    [datetime]$StartTime,
    [datetime]$EndTime = (Get-Date),

    [ValidateRange(30, 86400)]
    [int]$SamplingInterval = 300,

    [ValidateSet('MAX', 'AVG', 'MIN', 'LAST')]
    [string]$StatType = 'MAX',

    [ValidateRange(0, 100)]
    [double]$ThresholdPercent = 80,

    [switch]$ClusterOnly,

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

# --- Reused from Get-NtnxVmCpuReady.ps1 ---

function ConvertTo-LocalTime {
    # API timestamps are UTC (ISO-8601). PowerShell's JSON parser turns them into
    # DateTime objects of kind Utc, which display without a zone marker - convert to
    # local time so they match the evaluation window and the Prism UI.
    param($Timestamp)
    if ($null -eq $Timestamp) { return $null }
    if ($Timestamp -is [datetime]) {
        if ($Timestamp.Kind -eq [DateTimeKind]::Unspecified) {
            $Timestamp = [datetime]::SpecifyKind($Timestamp, [DateTimeKind]::Utc)
        }
        return $Timestamp.ToLocalTime()
    }
    return ([datetimeoffset]::Parse([string]$Timestamp, [cultureinfo]::InvariantCulture)).LocalDateTime
}

function ConvertTo-Percent {
    # ppm -> percent (10'000 ppm = 1 %), $null stays $null
    param($Ppm)
    if ($null -eq $Ppm) { return $null }
    [math]::Round([double]$Ppm / 10000, 2)
}

# --- New for this script ---

function Get-NtnxPaged {
    # Generic pager for v4 list endpoints. Page size capped at 100 (API limit). Uses $page
    # (zero-based), NOT $offset - $offset is silently ignored, causing an endless loop.
    param([string]$Path, [int]$PageSize = 100)

    $sep  = if ($Path.Contains('?')) { '&' } else { '?' }
    $all  = @()
    $page = 0
    do {
        $result = Invoke-NtnxApi -Method GET -Path "$Path$($sep)`$page=$page&`$limit=$PageSize"
        if ($result.data) { $all += $result.data }
        $page++
    } while ($result.data -and $result.data.Count -eq $PageSize)

    return $all
}

function Get-NtnxClusters {
    # Returns the cluster list and remembers the clustermgmt revision that worked
    # ($script:cmVersion), trying -ApiVersion first, then v4.0. The Prism Central
    # self-registration (clusterFunction PRISM_CENTRAL) is excluded - the host list API
    # rejects it. Clusters without a readable clusterFunction are treated as AOS clusters.
    foreach ($ver in (@($ApiVersion, 'v4.0') | Select-Object -Unique)) {
        try {
            $clusters = Get-NtnxPaged -Path "/clustermgmt/$ver/config/clusters"
            $script:cmVersion = $ver
            return @($clusters | Where-Object { @($_.config.clusterFunction) -notcontains 'PRISM_CENTRAL' })
        } catch {
            Write-Verbose "Cluster list via clustermgmt/$ver failed: $($_.Exception.Message)"
        }
    }
    throw "Could not read the cluster list on $($script:currentPc) (tried $ApiVersion and v4.0)."
}

function Get-NtnxCpuSamples {
    # Returns the hypervisorCpuUsagePpm samples (timestamp/value) for a cluster or host
    # stats path. First attempt uses $select to keep the response small; if the PC rejects
    # the $select expression, the script falls back to the unfiltered response for all
    # following calls ($script:useSelect).
    param([string]$StatsPath)

    $query = "`$startTime=$([uri]::EscapeDataString($startIso))" +
             "&`$endTime=$([uri]::EscapeDataString($endIso))" +
             "&`$samplingInterval=$SamplingInterval" +
             "&`$statType=$StatType"

    $result = $null
    if ($script:useSelect) {
        try {
            $result = Invoke-NtnxApi -Method GET -Path "$($StatsPath)?$query&`$select=hypervisorCpuUsagePpm"
        } catch {
            Write-Verbose "`$select rejected, retrying without it: $($_.Exception.Message)"
            $script:useSelect = $false
        }
    }
    if (-not $result) {
        $result = Invoke-NtnxApi -Method GET -Path "$($StatsPath)?$query"
    }

    # Expected shape: data.hypervisorCpuUsagePpm = [ { timestamp, value }, ... ].
    # Fallback for a tuple-style response: data.stats = [ { timestamp, hypervisorCpuUsagePpm }, ... ].
    $series = @($result.data.hypervisorCpuUsagePpm | Where-Object { $null -ne $_ })
    if (-not $series -and $result.data.stats) {
        $series = @($result.data.stats | Where-Object { $null -ne $_.hypervisorCpuUsagePpm } | ForEach-Object {
            [pscustomobject]@{ timestamp = $_.timestamp; value = $_.hypervisorCpuUsagePpm }
        })
    }

    return @($series | Where-Object { $null -ne $_.value })
}

function New-CpuSummaryRow {
    # Builds one summary row (cluster or host) from a sample series.
    param($Pc, $ClusterName, $Scope, $Name, $Nodes, $Samples)

    if (-not $Samples) {
        return [pscustomobject][ordered]@{
            PrismCentral   = $Pc
            Cluster        = $ClusterName
            Scope          = $Scope
            Name           = $Name
            Status         = 'NO DATA'
            Nodes          = $Nodes
            MaxCpuPct      = $null
            ProjectedN1Pct = $null
            MaxCpuAt       = $null
            AvgCpuPct      = $null
            Samples        = 0
        }
    }

    $stats = $Samples.value | Measure-Object -Average -Maximum
    $peak  = $Samples | Sort-Object value -Descending | Select-Object -First 1
    $maxPct = ConvertTo-Percent $stats.Maximum

    $projected = $null
    $status    = 'OK'
    if ($Scope -eq 'Cluster') {
        if ($Nodes -gt 1) {
            $projected = [math]::Round($maxPct * $Nodes / ($Nodes - 1), 2)
            if ($projected -gt $ThresholdPercent) { $status = 'WARN' }
        } else {
            $status = 'SINGLE NODE'
        }
    }

    [pscustomobject][ordered]@{
        PrismCentral   = $Pc
        Cluster        = $ClusterName
        Scope          = $Scope
        Name           = $Name
        Status         = $status
        Nodes          = $Nodes
        MaxCpuPct      = $maxPct
        ProjectedN1Pct = $projected
        MaxCpuAt       = ConvertTo-LocalTime $peak.timestamp
        AvgCpuPct      = ConvertTo-Percent $stats.Average
        Samples        = $Samples.Count
    }
}

# --- Main loop over all Prism Central instances ---
$script:useSelect = $true
$summary = [System.Collections.Generic.List[object]]::new()
$rawRows = [System.Collections.Generic.List[object]]::new()

foreach ($pc in $PcIp) {

    $script:currentPc = $pc
    $baseUri = "https://$($pc):9440/api"
    Write-Host "Prism Central $pc - window $($StartTime.ToString('yyyy-MM-dd HH:mm')) to $($EndTime.ToString('yyyy-MM-dd HH:mm')), interval $($SamplingInterval)s, $StatType" -ForegroundColor Cyan

    try {
        $clusters = Get-NtnxClusters
    } catch {
        Write-Warning "Skipping Prism Central $pc - $($_.Exception.Message)"
        continue
    }

    # --- Optional cluster filter ---
    if ($ClusterNames) {
        $clusters = @($clusters | Where-Object { $ClusterNames -contains $_.name })   # -contains is case-insensitive
        foreach ($name in $ClusterNames) {
            if (-not ($clusters | Where-Object { $_.name -eq $name })) {
                Write-Verbose "Cluster '$name' not found on $pc."
            }
        }
    }

    if (-not $clusters) {
        Write-Warning "No matching clusters on $pc."
        continue
    }

    # --- Fetch stats per cluster (and per host) ---
    $i = 0
    foreach ($cl in $clusters) {
        $i++
        Write-Progress -Activity "CPU peak on $pc" -Status "$($cl.name) ($i/$($clusters.Count))" -PercentComplete ($i / $clusters.Count * 100)

        try {
            $hosts = @(Get-NtnxPaged -Path "/clustermgmt/$script:cmVersion/config/clusters/$($cl.extId)/hosts")
        } catch {
            Write-Warning "Host list for cluster '$($cl.name)' on $pc failed: $($_.Exception.Message)"
            continue
        }
        $nodes = $hosts.Count

        # Cluster level
        try {
            $clSamples = Get-NtnxCpuSamples -StatsPath "/clustermgmt/$script:cmVersion/stats/clusters/$($cl.extId)"
        } catch {
            Write-Warning "Stats for cluster '$($cl.name)' on $pc failed: $($_.Exception.Message)"
            $clSamples = @()
        }

        if ($Raw) {
            foreach ($s in $clSamples) {
                $rawRows.Add([pscustomobject][ordered]@{
                    PrismCentral = $pc
                    Cluster      = $cl.name
                    Scope        = 'Cluster'
                    Name         = $cl.name
                    Timestamp    = ConvertTo-LocalTime $s.timestamp
                    CpuUsagePct  = ConvertTo-Percent $s.value
                })
            }
        } else {
            $summary.Add((New-CpuSummaryRow -Pc $pc -ClusterName $cl.name -Scope 'Cluster' -Name $cl.name -Nodes $nodes -Samples $clSamples))
        }

        if ($ClusterOnly) { continue }

        # Host level
        foreach ($h in $hosts) {
            $hostName = if ($h.hostName) { $h.hostName } else { $h.extId }
            try {
                $hSamples = Get-NtnxCpuSamples -StatsPath "/clustermgmt/$script:cmVersion/stats/clusters/$($cl.extId)/hosts/$($h.extId)"
            } catch {
                Write-Warning "Stats for host '$hostName' on $pc failed: $($_.Exception.Message)"
                $hSamples = @()
            }

            if ($Raw) {
                foreach ($s in $hSamples) {
                    $rawRows.Add([pscustomobject][ordered]@{
                        PrismCentral = $pc
                        Cluster      = $cl.name
                        Scope        = 'Host'
                        Name         = $hostName
                        Timestamp    = ConvertTo-LocalTime $s.timestamp
                        CpuUsagePct  = ConvertTo-Percent $s.value
                    })
                }
            } else {
                $summary.Add((New-CpuSummaryRow -Pc $pc -ClusterName $cl.name -Scope 'Host' -Name $hostName -Nodes $nodes -Samples $hSamples))
            }
        }
    }

    Write-Progress -Activity "CPU peak on $pc" -Completed
}

# --- Output ---
$output = if ($Raw) {
    $rawRows | Sort-Object PrismCentral, Cluster, Scope, Name, Timestamp
} else {
    # Cluster row first, then its hosts by peak descending
    $summary | Sort-Object PrismCentral, Cluster,
        @{ Expression = { if ($_.Scope -eq 'Cluster') { 0 } else { 1 } } },
        @{ Expression = { if ($null -eq $_.MaxCpuPct) { -1 } else { $_.MaxCpuPct } }; Descending = $true }
}

if (-not $output) {
    Write-Host "No CPU usage data found." -ForegroundColor Yellow
    return
}

if (-not $Raw) {
    $clusterRows = @($summary | Where-Object Scope -eq 'Cluster')
    $warnCount   = @($clusterRows | Where-Object Status -eq 'WARN').Count
    $color = if ($warnCount) { 'Yellow' } else { 'Green' }
    Write-Host "$($clusterRows.Count) cluster(s) evaluated, $warnCount with a projected N-1 peak above $ThresholdPercent %." -ForegroundColor $color
}

if ($CsvPath) {
    $output | Export-Csv -Path $CsvPath -Delimiter ';' -NoTypeInformation -Encoding utf8
    Write-Host "Exported to $CsvPath" -ForegroundColor Green
}

$output
