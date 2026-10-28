<#
.SYNOPSIS
    Exports an asset inventory of all (or selected) AHV VMs from one or more Prism Central
    instances via the Nutanix v4 API: sizing (vCPU, memory, disks), guest OS and Nutanix
    Guest Tools (NGT) status, boot/vTPM configuration, network (MAC, IP, subnet), DR
    protection, categories, cluster/host placement and lifecycle timestamps.
.NOTES
    Same auth/pagination pattern as the other scripts (Invoke-NtnxApi, Get-AllNtnxVms).
    Field paths verified against a vmm.v4.ahv.config.Vm response ($fv=v4.r2):
      name, description, powerState, numSockets, numCoresPerSocket, numThreadsPerCore,
      memorySizeBytes, guestTools.*, bootConfig.$objectType, vtpmConfig.isVtpmEnabled,
      machineType, protectionType, cluster/host/project.extId, categories[].extId,
      createTime, updateTime, extId.
    Not yet verified against a live response (taken from the v4 schema, with fallbacks):
      disks[].backingInfo.diskSizeBytes
      nics[].nicBackingInfo.macAddress           (fallback: legacy nics[].backingInfo)
      nics[].nicNetworkInfo.ipv4Config/ipv4Info  (fallback: legacy nics[].networkInfo)
      nics[].nicNetworkInfo.subnet.extId

    guestTools is missing entirely on VMs where NGT was never enabled - the NGT columns
    are then False/empty.

    Name lookups (cluster, host, category, subnet) are best-effort: if a lookup fails, the
    extId is shown instead and a warning is written.

    Requires PowerShell 7+ (uses -SkipCertificateCheck / -SkipHeaderValidation).
.PARAMETER PcIp
    IP address(es) or FQDN(s) of one or more Prism Central instances (without https:// or
    port). All clusters registered to each Prism Central are covered.
.PARAMETER Credential
    Prism Central credentials (PSCredential object), e.g. via Get-Credential. The same
    credential is used for every Prism Central in -PcIp.
.PARAMETER VmNames
    Only include these VM(s). Matching is case-insensitive; wildcards (*) are supported.
.PARAMETER ClusterNames
    Only include VMs on these cluster(s) (by Prism Element cluster name, case-insensitive).
.PARAMETER ExcludePoweredOff
    Skip VMs that are not powered on. By default all VMs are listed - an inventory should
    include powered-off VMs.
.PARAMETER ApiVersion
    Nutanix v4 API revision to target. Default: "v4.2". Lookups in other namespaces
    (clustermgmt, prism, networking) fall back to "v4.0" if this revision is rejected.
.PARAMETER CsvPath
    Optional path for a CSV export (semicolon-delimited, UTF-8).
.EXAMPLE
    .\Get-NtnxVmInventory.ps1 -PcIp 10.0.20.10 -Credential $creds -CsvPath .\VM-Inventory.csv

    Full inventory of all VMs on all clusters of this Prism Central, exported to CSV.
.EXAMPLE
    .\Get-NtnxVmInventory.ps1 -PcIp 10.0.20.10 -Credential $creds |
        Where-Object { -not $_.NGT_Installed -or $_.NGT_UpdateNeeded } | Format-Table VM, Cluster, NGT_Version, NGT_Available

    VMs without NGT or with an outdated NGT version.
.EXAMPLE
    .\Get-NtnxVmInventory.ps1 -PcIp 10.0.20.10,10.1.20.10 -Credential $creds -ClusterNames "NTNX-CL01" -ExcludePoweredOff | Format-Table

    Powered-on VMs of one cluster, across two Prism Central instances.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$PcIp,
    [Parameter(Mandatory)][pscredential]$Credential,

    [string[]]$VmNames,

    [string[]]$ClusterNames,

    [switch]$ExcludePoweredOff,

    [string]$ApiVersion = "v4.2",

    [string]$CsvPath
)

$PSDefaultParameterValues = @{ 'Invoke-RestMethod:SkipCertificateCheck' = $true }

$authHeader = @{
    Authorization = "Basic " + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("$($Credential.UserName):$($Credential.GetNetworkCredential().Password)")
    )
}

# --- Reused as-is from the other scripts ---
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

function Get-NtnxLookup {
    # Generic extId -> display name map for a paged v4 list endpoint. Tries the configured
    # API revision first, then v4.0. Best-effort: returns an empty map on failure.
    param(
        [string]$Namespace,         # e.g. clustermgmt
        [string]$Path,              # e.g. /config/clusters
        [scriptblock]$NameOf,       # item -> display name
        [string]$Label,             # used in the warning
        [int]$PageSize = 100
    )

    foreach ($ver in (@($ApiVersion, 'v4.0') | Select-Object -Unique)) {
        try {
            $map  = @{}
            $page = 0
            do {
                $result = Invoke-NtnxApi -Method GET -Path "/$Namespace/$ver$($Path)?`$page=$page&`$limit=$PageSize"
                foreach ($item in @($result.data)) {
                    if ($item.extId) { $map[$item.extId] = & $NameOf $item }
                }
                $page++
            } while ($result.data -and $result.data.Count -eq $PageSize)
            return $map
        } catch {
            Write-Verbose "$Label lookup via $Namespace/$ver failed: $($_.Exception.Message)"
        }
    }

    Write-Warning "Could not resolve $Label names on $($script:currentPc) - showing extIds instead."
    return @{}
}

function Resolve-Name {
    param([hashtable]$Map, $ExtId)
    if (-not $ExtId) { return $null }
    if ($Map.ContainsKey($ExtId)) { return $Map[$ExtId] }
    return $ExtId
}

function Join-Unique {
    param($Values)
    $v = @($Values | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
    if ($v) { $v -join ', ' } else { $null }
}

function Get-NicMacs {
    param($Vm)
    foreach ($nic in @($Vm.nics)) {
        if ($nic.nicBackingInfo.macAddress) { $nic.nicBackingInfo.macAddress }
        elseif ($nic.backingInfo.macAddress) { $nic.backingInfo.macAddress }
    }
}

function Get-NicIps {
    # Configured (IPAM) address plus addresses learned from the guest - for VMs on
    # non-IPAM networks only the learned ones are populated.
    param($Vm)
    foreach ($nic in @($Vm.nics)) {
        $net = if ($nic.nicNetworkInfo) { $nic.nicNetworkInfo } else { $nic.networkInfo }
        if (-not $net) { continue }
        $net.ipv4Config.ipAddress.value
        @($net.ipv4Config.secondaryIpAddressList).value
        @($net.ipv4Info.learnedIpAddresses).value
    }
}

function Get-NicSubnetIds {
    param($Vm)
    foreach ($nic in @($Vm.nics)) {
        $net = if ($nic.nicNetworkInfo) { $nic.nicNetworkInfo } else { $nic.networkInfo }
        if ($net.subnet.extId) { $net.subnet.extId }
    }
}

function Test-NgtUpdateNeeded {
    param($GuestTools)
    if (-not $GuestTools -or -not $GuestTools.version -or -not $GuestTools.availableVersion) { return $null }
    try {
        return ([version]$GuestTools.version -lt [version]$GuestTools.availableVersion)
    } catch {
        return ($GuestTools.version -ne $GuestTools.availableVersion)
    }
}

function ConvertTo-LocalTime {
    # API timestamps are UTC (ISO-8601). PowerShell's JSON parser turns them into
    # DateTime objects of kind Utc - convert to local time so they match the Prism UI.
    param($Timestamp)
    if ($null -eq $Timestamp) { return $null }
    if ($Timestamp -is [datetime]) {
        if ($Timestamp.Kind -eq [DateTimeKind]::Unspecified) {
            $Timestamp = [datetime]::SpecifyKind($Timestamp, [DateTimeKind]::Utc)
        }
        return $Timestamp.ToLocalTime()
    }
    return ([datetimeoffset]::Parse([string]$Timestamp)).LocalDateTime
}

# --- Main ---

$inventory = [System.Collections.Generic.List[object]]::new()

foreach ($pc in $PcIp) {

    $script:currentPc = $pc
    $baseUri = "https://$($pc):9440/api"
    Write-Host "Prism Central $pc - reading VM inventory" -ForegroundColor Cyan

    try {
        $allVms = @(Get-AllNtnxVms)
    } catch {
        Write-Warning "Skipping Prism Central $pc - VM list failed: $($_.Exception.Message)"
        continue
    }

    $clusterMap  = Get-NtnxLookup -Namespace clustermgmt -Path '/config/clusters' -Label 'cluster'  -NameOf { param($i) $i.name }
    $hostMap     = Get-NtnxLookup -Namespace clustermgmt -Path '/config/hosts'    -Label 'host'     -NameOf { param($i) $i.hostName }
    $categoryMap = Get-NtnxLookup -Namespace prism       -Path '/config/categories' -Label 'category' -NameOf { param($i) "$($i.key):$($i.value)" }
    $subnetMap   = Get-NtnxLookup -Namespace networking  -Path '/config/subnets'  -Label 'subnet'   -NameOf { param($i) $i.name }

    # --- Filters ---
    $targetVms = $allVms

    if ($VmNames) {
        $targetVms = $targetVms | Where-Object {
            $n = $_.name
            @($VmNames | Where-Object { $n -like $_ }).Count -gt 0   # -like is case-insensitive
        }
    }

    if ($ClusterNames) {
        if ($clusterMap.Count -eq 0) {
            throw "-ClusterNames was given, but cluster names could not be resolved on $pc."
        }
        $targetVms = $targetVms | Where-Object {
            $clName = $clusterMap[$_.cluster.extId]
            $clName -and ($ClusterNames -contains $clName)   # -contains is case-insensitive
        }
    }

    if ($ExcludePoweredOff) {
        $targetVms = $targetVms | Where-Object { $_.powerState -eq 'ON' }
    }

    $targetVms = @($targetVms)
    if (-not $targetVms) {
        Write-Warning "No matching VMs on $pc."
        continue
    }

    foreach ($vm in $targetVms) {
        $gt      = $vm.guestTools
        $threads = if ($vm.numThreadsPerCore) { [int]$vm.numThreadsPerCore } else { 1 }
        $diskSum = (@($vm.disks).backingInfo.diskSizeBytes | Where-Object { $_ } | Measure-Object -Sum).Sum
        $bootRaw = $vm.bootConfig.'$objectType'
        $bootTyp = if ($bootRaw) { $bootRaw -replace '^vmm\.v4\.ahv\.config\.' } else { $null }

        $inventory.Add([pscustomobject][ordered]@{
            PrismCentral     = $pc
            Cluster          = Resolve-Name $clusterMap $vm.cluster.extId
            Host             = Resolve-Name $hostMap $vm.host.extId
            VM               = $vm.name
            Description      = $vm.description
            PowerState       = $vm.powerState
            Sockets          = $vm.numSockets
            CoresPerSocket   = $vm.numCoresPerSocket
            vCPU             = [int]$vm.numSockets * [int]$vm.numCoresPerSocket * $threads
            MemoryGB         = if ($vm.memorySizeBytes) { [math]::Round([double]$vm.memorySizeBytes / 1GB, 2) } else { $null }
            DiskCount        = @($vm.disks).Count
            DiskTotalGB      = if ($diskSum) { [math]::Round([double]$diskSum / 1GB, 2) } else { $null }
            GuestOS          = $gt.guestOsVersion
            NGT_Installed    = [bool]$gt.isInstalled
            NGT_Enabled      = [bool]$gt.isEnabled
            NGT_Reachable    = [bool]$gt.isReachable
            NGT_Version      = $gt.version
            NGT_Available    = $gt.availableVersion
            NGT_UpdateNeeded = Test-NgtUpdateNeeded $gt
            BootType         = $bootTyp
            vTPM             = [bool]$vm.vtpmConfig.isVtpmEnabled
            MachineType      = $vm.machineType
            MAC              = Join-Unique (Get-NicMacs $vm)
            IP               = Join-Unique (Get-NicIps $vm)
            Subnet           = Join-Unique (Get-NicSubnetIds $vm | ForEach-Object { Resolve-Name $subnetMap $_ })
            Protection       = $vm.protectionType
            Categories       = Join-Unique (@($vm.categories).extId | ForEach-Object { Resolve-Name $categoryMap $_ })
            Created          = ConvertTo-LocalTime $vm.createTime
            Updated          = ConvertTo-LocalTime $vm.updateTime
            VmExtId          = $vm.extId
        })
    }

    Write-Host "$($targetVms.Count) VM(s) read from $pc." -ForegroundColor Green
}

# --- Output ---
$output = $inventory | Sort-Object PrismCentral, Cluster, VM

if (-not $output) {
    Write-Host "No VMs found." -ForegroundColor Yellow
    return
}

if ($CsvPath) {
    $output | Export-Csv -Path $CsvPath -Delimiter ';' -NoTypeInformation -Encoding utf8
    Write-Host "Exported to $CsvPath" -ForegroundColor Green
}

$output
