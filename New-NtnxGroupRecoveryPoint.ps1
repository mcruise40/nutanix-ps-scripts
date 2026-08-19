<#
.SYNOPSIS
    Creates on-demand Recovery Points for a group of AHV VMs via Prism Central v4 API.
    Target VMs are selected either by explicit name list, or by a Category key/value pair.
.NOTES
    IMPORTANT: Verify the recovery-points POST body schema in your PC's REST API Explorer
    (Settings -> REST API Explorer, or https://<pc-ip>:9440/api/dataprotection/v4.0/openapi)
    before running against production. Field names for the create body (vmRecoveryPointSpecs,
    entityExtId, expirationTime) are inferred from REST convention, not confirmed against the
    official schema (the relevant Nutanix Support Portal page required login and could not be
    fetched for verification).

    v4 API revisions (v4.0, v4.1, v4.2, ...) are documented as backward compatible within the
    v4 family (excluding EA releases), per official Nutanix.dev versioning docs. The ApiVersion
    parameter lets you target a newer revision without editing the script body.

    Name matching (ByName parameter set) is done case-insensitively via client-side comparison
    (PowerShell -eq is case-insensitive by default), since tolower()/case-insensitive support in
    the Nutanix v4 OData $filter is not confirmed in official docs - fetching all VMs and
    matching locally is the safer, documented-compatible approach. VMs are paginated in pages
    of 100 (the API's confirmed maximum $limit, observed directly from a live 400 error - not
    documented anywhere) via Get-AllNtnxVms using $page (zero-based, confirmed via official
    Nutanix.dev docs), covering all VMs regardless of cluster size.
.PARAMETER PcIp
    IP address or FQDN of the Prism Central instance (without https:// or port).
.PARAMETER Credential
    Prism Central credentials (PSCredential object), e.g. via Get-Credential.
.PARAMETER VmNames
    Explicit list of VM names to target. Mandatory for the 'ByName' parameter set;
    mutually exclusive with -CategoryKey/-CategoryValue. Matching is case-insensitive.
.PARAMETER CategoryKey
    Category key (e.g. "Patching") used to select VMs. Mandatory for the 'ByCategory'
    parameter set; must be used together with -CategoryValue, and is mutually exclusive
    with -VmNames.
.PARAMETER CategoryValue
    Category value (e.g. "Gruppe1") used together with -CategoryKey to select all VMs
    tagged with that key/value pair. Mandatory for the 'ByCategory' parameter set.
.PARAMETER RecoveryPointName
    Name assigned to the created recovery point. Defaults to
    "OnDemand-Group-<timestamp>" if not specified.
.PARAMETER RetentionDays
    Number of days until the recovery point expires and is eligible for cleanup.
    Default: 1 day.
.PARAMETER ApiVersion
    Nutanix v4 API revision to target (e.g. "v4.0", "v4.1"). Default: "v4.0". v4
    revisions are documented as backward compatible within the v4 family, so this
    normally only needs to be changed to intentionally use a newer revision's features.
.PARAMETER TimeoutSeconds
    Maximum time (in seconds) to wait for the recovery-point creation task to finish
    before the script stops polling and warns that the task may still be running.
    Default: 600 seconds (10 minutes).
.EXAMPLE
    .\New-NtnxGroupRecoveryPoint.ps1 -PcIp 10.0.0.10 -Credential $creds -VmNames "VM01" -WhatIf

    Dry run for a single named VM - resolves and prints the VM without creating anything.
.EXAMPLE
    .\New-NtnxGroupRecoveryPoint.ps1 -PcIp 10.0.0.10 -Credential $creds -VmNames "VM01","VM02"

    Creates a recovery point for two explicitly named VMs, using default retention (1 day)
    and default timeout (600 seconds).
.EXAMPLE
    .\New-NtnxGroupRecoveryPoint.ps1 -PcIp 10.0.0.10 -Credential $creds -CategoryKey "Patching" -CategoryValue "Group1" -WhatIf

    Dry run for all VMs tagged with category Patching:Group1 - shows which VMs would be
    targeted without creating a recovery point.
.EXAMPLE
    .\New-NtnxGroupRecoveryPoint.ps1 -PcIp 10.0.0.10 -Credential $creds -CategoryKey "Patching" -CategoryValue "Group2" -RecoveryPointName "PrePatch-Group2" -RetentionDays 3 -TimeoutSeconds 900

    Creates a recovery point for all VMs in category Patching:Group2, with a custom name,
    3-day retention, and a 15-minute timeout for the task-polling loop.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'ByName')]
param(
    [Parameter(Mandatory)][string]$PcIp,
    [Parameter(Mandatory)][pscredential]$Credential,

    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [string[]]$VmNames,

    [Parameter(Mandatory, ParameterSetName = 'ByCategory')]
    [string]$CategoryKey,

    [Parameter(Mandatory, ParameterSetName = 'ByCategory')]
    [string]$CategoryValue,

    [string]$RecoveryPointName = "OnDemand-Group-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
    [int]$RetentionDays = 1,
    [string]$ApiVersion = "v4.0",
    [int]$TimeoutSeconds = 600
)

$PSDefaultParameterValues = @{ 'Invoke-RestMethod:SkipCertificateCheck' = $true }

$baseUri = "https://$($PcIp):9440/api"
$authHeader = @{
    Authorization = "Basic " + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("$($Credential.UserName):$($Credential.GetNetworkCredential().Password)")
    )
}

function Invoke-NtnxApi {
    param($Method, $Path, $Body)
    $params = @{ Method = $Method; Uri = "$baseUri$Path"; Headers = $authHeader }
    if ($Body) {
        $params.Body        = ($Body | ConvertTo-Json -Depth 10)
        $params.ContentType = "application/json"
    }
    Invoke-RestMethod @params
}

function Get-AllNtnxVms {
    # Paginated fetch of all VMs. Page size capped at 100 - confirmed against the
    # live API (not documentation): a $limit above 100 on this endpoint returns
    # HTTP 400 "Numeric instance is greater than the required maximum (maximum: 100)".
    # Pagination parameter is $page (zero-based), NOT $offset - confirmed via the
    # official Nutanix.dev article "Updating VMs with the Nutanix v4 APIs and
    # PowerShell" and a Nutanix Community code sample, both of which use
    # $page=<n>&$limit=100. Using $offset (as an earlier version of this script did)
    # is silently ignored by the API, causing it to return the same first page every
    # time - which looks like a near-infinite loop for any VM count above 100.
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

# --- Resolve target VMs depending on parameter set (read-only - runs even under -WhatIf) ---
$vmExtIds = @()

if ($PSCmdlet.ParameterSetName -eq 'ByName') {

    # Case-insensitive matching done client-side (see NOTES above).
    $allVms = Get-AllNtnxVms

    foreach ($name in $VmNames) {
        $match = $allVms | Where-Object { $_.name -eq $name }  # -eq is case-insensitive in PowerShell
        if (-not $match) {
            Write-Warning "VM '$name' not found - skipping"
            continue
        }
        $vmExtIds += [pscustomobject]@{ Name = $match.name; ExtId = $match.extId }
    }

} else {
    # ByCategory: resolve the category extId first, then filter VMs client-side.
    # 'categories' is not a documented $filter field on the VM list endpoint, so
    # matching is done locally rather than via $filter on the VM query itself.

    $catFilter  = "key eq '$CategoryKey' and value eq '$CategoryValue'"
    $catEncoded = [uri]::EscapeDataString($catFilter)
    $catResult  = Invoke-NtnxApi -Method GET -Path "/prism/$ApiVersion/config/categories?`$filter=$catEncoded"

    if (-not $catResult.data) {
        throw "No category found matching key '$CategoryKey' and value '$CategoryValue'. Check spelling/case in Prism Central."
    }
    $categoryExtId = $catResult.data[0].extId
    Write-Verbose "Resolved category '$CategoryKey`:$CategoryValue' to extId $categoryExtId"

    $allVms = Get-AllNtnxVms

    foreach ($vm in $allVms) {
        if ($vm.categories -and ($vm.categories.extId -contains $categoryExtId)) {
            $vmExtIds += [pscustomobject]@{ Name = $vm.name; ExtId = $vm.extId }
        }
    }

    if (-not $vmExtIds) {
        throw "No VMs found tagged with category '$CategoryKey`:$CategoryValue'."
    }
}

if (-not $vmExtIds) { throw "No matching VMs found - aborting." }

Write-Host "`nVMs targeted for recovery point '$RecoveryPointName':"
$vmExtIds | Format-Table -AutoSize

# --- Create the Recovery Point (state-changing, gated by ShouldProcess) ---
$expiration = (Get-Date).AddDays($RetentionDays).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$body = @{
    name           = $RecoveryPointName
    expirationTime = $expiration
    vmRecoveryPointSpecs = $vmExtIds | ForEach-Object { @{ entityExtId = $_.ExtId } }
}

$targetDescription = "$($vmExtIds.Count) VM(s): $($vmExtIds.Name -join ', ')"

if ($PSCmdlet.ShouldProcess($targetDescription, "Create recovery point '$RecoveryPointName' (expires $expiration)")) {

    $createResponse = Invoke-NtnxApi -Method POST -Path "/dataprotection/$ApiVersion/config/recovery-points" -Body $body
    $taskExtId = $createResponse.data.extId
    Write-Host "Recovery point creation submitted. Task: $taskExtId"

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 5
        $task = Invoke-NtnxApi -Method GET -Path "/prism/$ApiVersion/config/tasks/$taskExtId"
        Write-Host "Status: $($task.data.status)  Progress: $($task.data.progressPercentage)%"

        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Warning "Timeout of $TimeoutSeconds seconds reached while waiting for task $taskExtId. Task may still be running on the cluster - check Prism Central manually."
            break
        }
    } while ($task.data.status -in @("QUEUED","RUNNING"))

    if ($task.data.status -eq "SUCCEEDED") {
        Write-Host "Recovery point '$RecoveryPointName' created successfully for $($vmExtIds.Count) VM(s)." -ForegroundColor Green
    } elseif ($task.data.status -in @("QUEUED","RUNNING")) {
        Write-Warning "Polling stopped due to timeout - task status was last seen as '$($task.data.status)'."
    } else {
        Write-Warning "Task ended with status: $($task.data.status)"
        $task.data | ConvertTo-Json -Depth 5
    }
} else {
    Write-Host "`n[WhatIf] No changes made. Above would have been the target VM set and payload." -ForegroundColor Yellow
}
