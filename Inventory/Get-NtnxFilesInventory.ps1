<#
.SYNOPSIS
    Exports an inventory of Nutanix Files file servers and their shares (SMB/NFS) from one
    or more Prism Central instances via the Nutanix v4 Files API. One row per share; file
    servers without any share appear as a single row with empty share columns.
.NOTES
    Same auth/pagination pattern as the other scripts (Invoke-NtnxApi, paged list).
    Endpoints (files.v4.config, from the published v4.0 client):
      GET /files/v4.0/config/file-servers
      GET /files/v4.0/config/file-servers/{fileServerExtId}/mount-targets
    A Nutanix Files "share" / "export" is a "mount target" in the v4 API.

    Field paths taken from the v4 model definitions, NOT yet verified against a live
    response:
      file server : extId, name
      mount target: extId, name, description, protocol, secondaryProtocol[], type, state,
                    path, maxSizeGB, workloadType, isCompressionEnabled,
                    isPreviousVersionEnabled, isSnapshotPaused, smbProperties.*,
                    nfsProperties.*, wormSpec
    The v4.0 FileServer model only carries name/extId - version, size, networks or the
    hosting cluster are not available through this endpoint. maxSizeGB is the configured
    share limit; consumed capacity is not part of the config API (stats live in the
    files analytics namespace).

    Requires PowerShell 7+ (uses -SkipCertificateCheck / -SkipHeaderValidation).
.PARAMETER PcIp
    IP address(es) or FQDN(s) of one or more Prism Central instances (without https:// or
    port).
.PARAMETER Credential
    Prism Central credentials (PSCredential object), e.g. via Get-Credential.
.PARAMETER FileServerNames
    Only include these file server(s). Case-insensitive; wildcards (*) supported.
.PARAMETER ShareNames
    Only include these share(s). Case-insensitive; wildcards (*) supported.
.PARAMETER ClusterIp
    Optional: Virtual IP(s) / FQDN(s) of the Prism Element cluster(s) that host the file
    servers. Adds file server details that the v4 Files API does not expose: AD domain /
    OU / domain controller, version, state, FSVMs, networks, DNS, NTP, NFS version,
    capacity and snapshot usage (Prism Element v1 API /vfilers). File servers are matched
    to the v4 list by UUID, then by name.
.PARAMETER ClusterCredential
    Credentials for -ClusterIp. Defaults to -Credential.
.PARAMETER IncludeUsage
    Add current usage: used space, snapshot space, file count and connections per file
    server and per share (latest sample of the files analytics stats, last hour). Costs
    one extra API call per file server and per share.
.PARAMETER ApiVersion
    Nutanix v4 API revision for the Files namespace. Default: "v4.0".
.PARAMETER CsvPath
    Optional path for a CSV export (semicolon-delimited, UTF-8).
.EXAMPLE
    .\Get-NtnxFilesInventory.ps1 -PcIp 10.0.20.10 -Credential $creds -CsvPath .\Files-Inventory.csv
.EXAMPLE
    .\Get-NtnxFilesInventory.ps1 -PcIp 10.0.20.10 -Credential $creds -ShareNames "*backup*" |
        Format-Table FileServer, Share, Protocol, MaxSizeGB, State
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$PcIp,
    [Parameter(Mandatory)][pscredential]$Credential,

    [string[]]$FileServerNames,

    [string[]]$ShareNames,

    [string[]]$ClusterIp,

    [pscredential]$ClusterCredential,

    [switch]$IncludeUsage,

    [string]$ApiVersion = "v4.0",

    [string]$CsvPath
)

$PSDefaultParameterValues = @{ 'Invoke-RestMethod:SkipCertificateCheck' = $true }

$authHeader = @{
    Authorization = "Basic " + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("$($Credential.UserName):$($Credential.GetNetworkCredential().Password)")
    )
}

# --- Reused as-is from the other scripts ---

function Invoke-NtnxApi {
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

# --- New for this script ---

function Get-NtnxPaged {
    # Generic paged GET. Uses $page (zero-based), NOT $offset - $offset is silently
    # ignored, causing an endless loop. Page size capped at 100 (API limit).
    param([string]$Path, [int]$PageSize = 100)

    $all  = @()
    $page = 0
    do {
        $result = Invoke-NtnxApi -Method GET -Path "$($Path)?`$page=$page&`$limit=$PageSize"
        if ($result.data) { $all += $result.data }
        $page++
    } while ($result.data -and $result.data.Count -eq $PageSize)

    return $all
}

function Get-NtnxLatestStats {
    # Latest sample of each requested metric from a files stats endpoint. The stats API
    # returns time series ([{timestamp, value}, ...]); $startTime and $endTime are mandatory. Best-effort:
    # returns $null (with a warning) on failure so the inventory itself still completes.
    param([string]$Path, [string[]]$Metrics)

    # $endTime is mandatory in practice (without it the API answers "40015: 2009"), even
    # though the client library marks it optional.
    $fmt   = "yyyy-MM-dd'T'HH:mm:ss.fff'Z'"
    $start = [datetime]::UtcNow.AddHours(-1).ToString($fmt)
    $end   = [datetime]::UtcNow.ToString($fmt)
    $query = '$select=' + ($Metrics -join ',') + '&$startTime=' + $start + '&$endTime=' + $end
    try {
        $r = Invoke-NtnxApi -Method GET -Path "$($Path)?$query"
    } catch {
        Write-Warning "Stats call failed ($Path): $($_.Exception.Message)"
        return $null
    }

    $latest = @{}
    foreach ($m in $Metrics) {
        $series = @($r.data.$m)
        $point  = $series | Where-Object { $null -ne $_.value } | Sort-Object timestamp | Select-Object -Last 1
        $latest[$m] = if ($point) { $point.value } else { $null }
    }
    return $latest
}

function Get-NtnxVfilers {
    # Prism Element v1 API (not v4): the only source for AD/network/version details of a
    # file server. Best-effort: warns and returns an empty list on failure.
    param([string]$Cluster, [pscredential]$Cred)

    $pair = "$($Cred.UserName):$($Cred.GetNetworkCredential().Password)"
    $h = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair)) }
    try {
        $r = Invoke-RestMethod -Method GET -Uri "https://$($Cluster):9440/PrismGateway/services/rest/v1/vfilers" `
            -Headers $h -SkipHeaderValidation -ErrorAction Stop
        return @($r.entities)
    } catch {
        Write-Warning "Could not read file server details from cluster ${Cluster}: $($_.Exception.Message)"
        return @()
    }
}

function Get-FsDetails {
    # FS_* columns (same for every row of a file server). $Vf is a v1 vfiler (or $null),
    # $Stats the optional v4 stats. windowsAdPassword is deliberately never read.
    param($Vf, $Stats, [string]$Cluster)

    $ad    = if ($Vf.nameServicesDTO.adDetails) { $Vf.nameServicesDTO.adDetails } else { $Vf.domainDirectoryDTO }
    $nvms  = @($Vf.nvms)
    $net   = @($Vf.externalNetworks | Where-Object { $_ -and -not $_.isInternalNetwork })
    $us    = $Vf.usageStats
    $fsvm1 = $nvms | Select-Object -First 1

    $used = if ($null -ne $us.fs_used_space_bytes) { $us.fs_used_space_bytes } else { $Stats.datasetSpaceUsedBytes }
    $snap = if ($null -ne $us.fs_usedbysnapshots_bytes) { $us.fs_usedbysnapshots_bytes } else { $Stats.snapshotUsedBytes }
    $conn = if ($null -ne $Stats.numberOfConnections) { $Stats.numberOfConnections } else { $us.total_smb_connections }

    [ordered]@{
        FS_Cluster        = $Cluster
        FS_Version        = $Vf.version
        FS_State          = $Vf.fileServerState
        FS_UpgradeRunning = if ($Vf) { [bool]$Vf.upgradeInProgress } else { $null }
        FS_FSVMs          = if ($Vf) { $nvms.Count } else { $null }
        FS_FSVM_vCPU      = $fsvm1.numVcpus
        FS_FSVM_MemGiB    = $fsvm1.memoryGiB
        FS_AD_Joined      = if ($Vf) { [bool]$ad.windowsAdDomainName } else { $null }
        FS_AD_Domain      = $ad.windowsAdDomainName
        FS_AD_OU          = $ad.organizationalUnit
        FS_AD_PrefDC      = $ad.preferredDomainController
        FS_AD_Protocol    = $ad.protocolType
        FS_AD_Rfc2307     = if ($ad) { [bool]$ad.rfc2307Enabled } else { $null }
        FS_LDAP           = if ($Vf) { [bool]$Vf.nameServicesDTO.ldapDetails } else { $null }
        FS_NfsVersion     = $Vf.nameServicesDTO.nfsVersion
        FS_NfsV4Domain    = $Vf.nameServicesDTO.nfsv4Domain
        FS_DnsDomain      = $Vf.dnsDomainName
        FS_DnsServers     = Join-Unique $Vf.dnsServerIpAddresses
        FS_NtpServers     = Join-Unique $Vf.ntpServers
        FS_ClientNetwork  = Join-Unique ($net | ForEach-Object { "$($_.name) ($($_.networkAddress)/$($_.subnetMask), GW $($_.defaultGateway))" })
        FS_ClientIPs      = Join-Unique ($Vf.dnsEntries.dnsIpAddress)
        FS_ExternalIP     = $Vf.externalIpAddress
        FS_Shares         = $Vf.numShares
        FS_HomeShares     = $Vf.numHomeShares
        FS_NestedShares   = $Vf.numNestedShares
        FS_SizeGB         = ConvertTo-GB $us.fileserver_size_bytes
        FS_UsedGB         = ConvertTo-GB $used
        FS_FreeGB         = ConvertTo-GB $us.fs_free_space_bytes
        FS_SnapshotGB     = ConvertTo-GB $snap
        FS_Files          = $Stats.numberOfFiles
        FS_Connections    = $conn
        FS_Compression    = if ($Vf) { [bool]$Vf.fileServerCompression } else { $null }
        FS_BlockedExt     = Join-Unique $Vf.fileBlockingExtensions
        FS_MetroRole      = $Vf.fileServerMetroRole
        FS_ProtectionDomain = $Vf.protectionDomainName
        FS_Created        = if ($Vf.createdTimeStampInUsecs) { [datetimeoffset]::FromUnixTimeMilliseconds([long]($Vf.createdTimeStampInUsecs / 1000)).LocalDateTime } else { $null }
        FS_Description    = $Vf.description
    }
}

function ConvertTo-GB {
    param($Bytes)
    if ($null -eq $Bytes) { return $null }
    [math]::Round([double]$Bytes / 1GB, 2)
}

function Join-Unique {
    param($Values)
    $v = @($Values | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
    if ($v) { $v -join ', ' } else { $null }
}

function Test-NameFilter {
    param([string]$Name, [string[]]$Patterns)
    if (-not $Patterns) { return $true }
    @($Patterns | Where-Object { $Name -like $_ }).Count -gt 0   # -like is case-insensitive
}

# --- Main ---

$inventory = [System.Collections.Generic.List[object]]::new()

foreach ($pc in $PcIp) {

    $baseUri = "https://$($pc):9440/api"
    Write-Host "Prism Central $pc - reading Files inventory" -ForegroundColor Cyan

    try {
        $fileServers = @(Get-NtnxPaged -Path "/files/$ApiVersion/config/file-servers")
    } catch {
        Write-Warning "Skipping Prism Central $pc - file server list failed: $($_.Exception.Message)"
        continue
    }

    $fileServers = @($fileServers | Where-Object { Test-NameFilter $_.name $FileServerNames })
    if (-not $fileServers) {
        Write-Warning "No matching file servers on $pc."
        continue
    }

    # v1 details from the Prism Element clusters (optional)
    $vfilers = @()
    foreach ($ce in $ClusterIp) {
        $cred = if ($ClusterCredential) { $ClusterCredential } else { $Credential }
        foreach ($v in (Get-NtnxVfilers -Cluster $ce -Cred $cred)) {
            $v | Add-Member -NotePropertyName _cluster -NotePropertyValue $ce -Force
            $vfilers += $v
        }
    }

    $shareCount = 0
    foreach ($fs in $fileServers) {

        $vf = $vfilers | Where-Object { $_.uuid -eq $fs.extId } | Select-Object -First 1
        if (-not $vf) { $vf = $vfilers | Where-Object { $_.name -eq $fs.name } | Select-Object -First 1 }
        if ($ClusterIp -and -not $vf) { Write-Warning "No Prism Element details found for file server '$($fs.name)'." }

        $fsStats = $null
        if ($IncludeUsage) {
            $fsStats = Get-NtnxLatestStats -Path "/files/$ApiVersion/stats/file-servers/$($fs.extId)" `
                -Metrics datasetSpaceUsedBytes, snapshotUsedBytes, numberOfFiles, numberOfConnections
        }

        $fsDetails = Get-FsDetails -Vf $vf -Stats $fsStats -Cluster $vf._cluster

        try {
            $shares = @(Get-NtnxPaged -Path "/files/$ApiVersion/config/file-servers/$($fs.extId)/mount-targets")
        } catch {
            Write-Warning "Share list failed for file server '$($fs.name)' on ${pc}: $($_.Exception.Message)"
            $shares = @()
        }

        $shares = @($shares | Where-Object { Test-NameFilter $_.name $ShareNames })

        # Keep file servers without shares visible, unless the user filtered by share.
        if (-not $shares -and -not $ShareNames) {
            $row = [ordered]@{
                PrismCentral = $pc
                FileServer   = $fs.name
                Share        = $null
                Description  = $null
                Protocol     = $null
                Type         = $null
                State        = $null
                Path         = $null
                MaxSizeGB    = $null
                UsedGB       = $null
                UsedPercent  = $null
                SnapshotGB   = $null
                Files        = $null
                Connections  = $null
                WorkloadType = $null
                Compression  = $null
                PreviousVersions = $null
                SnapshotsPaused  = $null
                SMB_Encryption   = $null
                SMB_ABE          = $null
                SMB_ContinuousAvailability = $null
                NFS_Auth         = $null
                NFS_Access       = $null
                NFS_Squash       = $null
                WORM             = $null
                FileServerExtId  = $fs.extId
                ShareExtId       = $null
            }
            foreach ($k in $fsDetails.Keys) { $row[$k] = $fsDetails[$k] }
            $inventory.Add([pscustomobject]$row)
            continue
        }

        foreach ($s in $shares) {
            $protocols = Join-Unique (@($s.protocol) + @($s.secondaryProtocol))
            $st = $null
            if ($IncludeUsage) {
                $st = Get-NtnxLatestStats -Path "/files/$ApiVersion/stats/file-servers/$($fs.extId)/mount-targets/$($s.extId)" `
                    -Metrics usedBytes, snapshotUsedBytes, numberOfFiles, numberOfConnections
            }
            # maxSizeGB = 0 means no limit configured
            $usedPct = if ($st.usedBytes -and $s.maxSizeGB) { [math]::Round([double]$st.usedBytes / 1GB / $s.maxSizeGB * 100, 1) } else { $null }

            $smb = $s.smbProperties
            $nfs = $s.nfsProperties

            $row = [ordered]@{
                PrismCentral = $pc
                FileServer   = $fs.name
                Share        = $s.name
                Description  = $s.description
                Protocol     = $protocols
                Type         = $s.type
                State        = $s.state
                Path         = $s.path
                MaxSizeGB    = $s.maxSizeGB
                UsedGB       = ConvertTo-GB $st.usedBytes
                UsedPercent  = $usedPct
                SnapshotGB   = ConvertTo-GB $st.snapshotUsedBytes
                Files        = $st.numberOfFiles
                Connections  = $st.numberOfConnections
                WorkloadType = $s.workloadType
                Compression  = if ($null -ne $s.isCompressionEnabled) { [bool]$s.isCompressionEnabled } else { $null }
                PreviousVersions = if ($null -ne $s.isPreviousVersionEnabled) { [bool]$s.isPreviousVersionEnabled } else { $null }
                SnapshotsPaused  = if ($null -ne $s.isSnapshotPaused) { [bool]$s.isSnapshotPaused } else { $null }
                SMB_Encryption   = if ($smb) { [bool]$smb.isSmb3EncryptionEnabled } else { $null }
                SMB_ABE          = if ($smb) { [bool]$smb.isAccessBasedEnumerationEnabled } else { $null }
                SMB_ContinuousAvailability = if ($smb) { [bool]$smb.isCaEnabled } else { $null }
                NFS_Auth         = $nfs.authenticationType
                NFS_Access       = $nfs.accessType
                NFS_Squash       = $nfs.squashType
                WORM             = if ($s.wormSpec) { $true } else { $false }
                FileServerExtId  = $fs.extId
                ShareExtId       = $s.extId
            }
            foreach ($k in $fsDetails.Keys) { $row[$k] = $fsDetails[$k] }
            $inventory.Add([pscustomobject]$row)
            $shareCount++
        }
    }

    Write-Host "$($fileServers.Count) file server(s), $shareCount share(s) read from $pc." -ForegroundColor Green
}

# --- Output ---
$output = $inventory | Sort-Object PrismCentral, FileServer, Share

if (-not $output) {
    Write-Host "No file servers found." -ForegroundColor Yellow
    return
}

if ($CsvPath) {
    $output | Export-Csv -Path $CsvPath -Delimiter ';' -NoTypeInformation -Encoding utf8
    Write-Host "Exported to $CsvPath" -ForegroundColor Green
}

$output
