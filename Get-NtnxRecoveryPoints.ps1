<#
.SYNOPSIS
    Lists existing Recovery Points from Prism Central via the Nutanix v4 API. Optionally
    filtered to specific VMs (by name) or all VMs in a Category.
.NOTES
    Reuses Invoke-NtnxApi and Get-AllNtnxVms from New-NtnxGroupRecoveryPoint.ps1 (same
    pagination/auth pattern). Field names for the recovery-points GET response are not
    fully confirmed against an official field list (no official schema found for this
    specific endpoint) - "creationTime"/"expirationTime" are inferred from a related VMM
    SDK object description. Missing/renamed fields show up blank rather than erroring;
    use -Raw to inspect the actual API response if something looks off.
.PARAMETER PcIp
    IP address or FQDN of the Prism Central instance (without https:// or port).
.PARAMETER Credential
    Prism Central credentials (PSCredential object), e.g. via Get-Credential.
.PARAMETER VmNames
    Only show recovery points belonging to these VM(s). Mandatory for the 'ByName'
    parameter set; mutually exclusive with -CategoryKey/-CategoryValue.
.PARAMETER CategoryKey
    Category key (e.g. "Patching") used to select VMs. Mandatory for the 'ByCategory'
    parameter set; must be used together with -CategoryValue.
.PARAMETER CategoryValue
    Category value (e.g. "Group01") used together with -CategoryKey.
.PARAMETER ApiVersion
    Nutanix v4 API revision to target. Default: "v4.2".
.PARAMETER Raw
    If set, outputs the raw API recovery-point objects instead of the simplified view -
    useful for checking actual field names if something looks wrong or blank.
.EXAMPLE
    .\Get-NtnxRecoveryPoints.ps1 -PcIp 10.0.20.10 -Credential $creds

    Lists all recovery points in the environment.
.EXAMPLE
    .\Get-NtnxRecoveryPoints.ps1 -PcIp 10.0.20.10 -Credential $creds -VmNames "VM01","VM02"

    Lists only recovery points that include VM01 and/or VM02.
.EXAMPLE
    .\Get-NtnxRecoveryPoints.ps1 -PcIp 10.0.20.10 -Credential $creds -CategoryKey "Patching" -CategoryValue "Group01"

    Lists recovery points for all VMs currently tagged with category Patching:Group01.
.EXAMPLE
    .\Get-NtnxRecoveryPoints.ps1 -PcIp 10.0.20.10 -Credential $creds -Raw | Select-Object -First 1 | ConvertTo-Json -Depth 10

    Dumps the raw API object for the first recovery point, to inspect actual field names.
#>

[CmdletBinding(DefaultParameterSetName = 'All')]
param(
    [Parameter(Mandatory)][string]$PcIp,
    [Parameter(Mandatory)][pscredential]$Credential,

    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [string[]]$VmNames,

    [Parameter(Mandatory, ParameterSetName = 'ByCategory')]
    [string]$CategoryKey,

    [Parameter(Mandatory, ParameterSetName = 'ByCategory')]
    [string]$CategoryValue,

    [string]$ApiVersion = "v4.2",

    [switch]$Raw
)

$PSDefaultParameterValues = @{ 'Invoke-RestMethod:SkipCertificateCheck' = $true }

$baseUri = "https://$($PcIp):9440/api"
$authHeader = @{
    Authorization = "Basic " + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("$($Credential.UserName):$($Credential.GetNetworkCredential().Password)")
    )
}

# --- Reused as-is from New-NtnxGroupRecoveryPoint.ps1 ---

function Invoke-NtnxApi {
    # Ntnx-Request-Id is mandatory on v4 POST/PUT/DELETE requests (idempotency token).
    # Dormant for this read-only script (only GET calls are made), kept for consistency
    # and in case write operations (e.g. delete) are added later.
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

function Get-AllNtnxRecoveryPoints {
    # Same pagination pattern as Get-AllNtnxVms.
    param([int]$PageSize = 100)

    $all = @()
    $page = 0
    do {
        $result = Invoke-NtnxApi -Method GET -Path "/dataprotection/$ApiVersion/config/recovery-points?`$page=$page&`$limit=$PageSize"
        if ($result.data) { $all += $result.data }
        $page++
    } while ($result.data -and $result.data.Count -eq $PageSize)

    return $all
}

# --- Resolve an optional VM filter (extIds) depending on parameter set ---
$filterVmExtIds = $null

if ($PSCmdlet.ParameterSetName -eq 'ByName') {

    $allVms = Get-AllNtnxVms
    $filterVmExtIds = foreach ($name in $VmNames) {
        $match = $allVms | Where-Object { $_.name -eq $name }  # -eq is case-insensitive in PowerShell
        if (-not $match) {
            Write-Warning "VM '$name' not found - skipping"
            continue
        }
        $match.extId
    }
    if (-not $filterVmExtIds) { throw "No matching VMs found - aborting." }

} elseif ($PSCmdlet.ParameterSetName -eq 'ByCategory') {

    $catFilter  = "key eq '$CategoryKey' and value eq '$CategoryValue'"
    $catEncoded = [uri]::EscapeDataString($catFilter)
    $catResult  = Invoke-NtnxApi -Method GET -Path "/prism/$ApiVersion/config/categories?`$filter=$catEncoded"

    if (-not $catResult.data) {
        throw "No category found matching key '$CategoryKey' and value '$CategoryValue'. Check spelling/case in Prism Central."
    }
    $categoryExtId = $catResult.data[0].extId

    $allVms = Get-AllNtnxVms
    $filterVmExtIds = $allVms |
        Where-Object { $_.categories -and ($_.categories.extId -contains $categoryExtId) } |
        Select-Object -ExpandProperty extId

    if (-not $filterVmExtIds) {
        throw "No VMs found tagged with category '$CategoryKey`:$CategoryValue'."
    }
}

# --- Fetch recovery points, apply optional VM filter ---
$recoveryPoints = Get-AllNtnxRecoveryPoints

if ($filterVmExtIds) {
    $recoveryPoints = $recoveryPoints | Where-Object {
        $_.vmRecoveryPoints -and (
            @($_.vmRecoveryPoints.vmExtId) | Where-Object { $filterVmExtIds -contains $_ }
        )
    }
}

if (-not $recoveryPoints) {
    Write-Host "No recovery points found." -ForegroundColor Yellow
    return
}

if ($Raw) {
    $recoveryPoints
    return
}

# --- VM extId -> name lookup, so output shows names instead of raw extIds ---
if (-not $allVms) { $allVms = Get-AllNtnxVms }
$vmLookup = @{}
$allVms | ForEach-Object { $vmLookup[$_.extId] = $_.name }

$recoveryPoints |
    ForEach-Object {
        # Some recovery points have no vmRecoveryPoints (e.g. Volume-Group-only, or
        # legacy entries not created via this API) - filter out empty/null vmExtIds
        # before the lookup, otherwise $vmLookup.ContainsKey($null) throws.
        # NOTE: local variable deliberately NOT named $vmNames - PowerShell variable
        # names are case-insensitive, so $vmNames would collide with the script's
        # strongly-typed [string[]]$VmNames parameter and cause cast errors.
        $resolvedVmNames = @($_.vmRecoveryPoints | Where-Object { $_.vmExtId } | ForEach-Object {
            if ($vmLookup.ContainsKey($_.vmExtId)) { $vmLookup[$_.vmExtId] } else { $_.vmExtId }
        })
        [pscustomobject][ordered]@{
            Name     = $_.name
            ExtId    = $_.extId
            Status   = $_.status
            Type     = $_.recoveryPointType
            VMs      = ($resolvedVmNames -join ', ')
            Created  = $_.creationTime
            Expiry   = $_.expirationTime
        }
    } |
    Sort-Object Created -Descending
