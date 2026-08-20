<#
.SYNOPSIS
    Creates on-demand Recovery Points for a group of AHV VMs via Prism Central v4 API.
    Target VMs are selected either by explicit name list, or by a Category key/value pair.
.NOTES
    Max 32 combined VM + volume group entries per request (enforced in this script).
    Field schema for -AppConsistent is partially inferred, not fully confirmed - verify
    via developers.nutanix.com API reference before production use, not via PC's local
    REST API Explorer (v4 endpoints aren't published there).
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
    Category value (e.g. "Group1") used together with -CategoryKey to select all VMs
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
.PARAMETER AppConsistent
    If set, requests an application-consistent (VSS-based) recovery point instead of the
    default crash-consistent one, by setting the top-level recoveryPointType field to
    APPLICATION_CONSISTENT (confirmed enum value, official API Reference) and adding a
    per-VM applicationConsistentProperties block. Only effective for Windows VMs with
    NGT/VSS support (per Nutanix docs).
.PARAMETER ProjectExtId
    Optional. External identifier of the project to associate with the recovery point.
    Documented as optional on the Create Recovery Point request; relevant mainly in
    project-scoped / multi-tenant setups (e.g. Nutanix Central). Omitted from the request
    entirely if not supplied.
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
    .\New-NtnxGroupRecoveryPoint.ps1 -PcIp 10.0.0.10 -Credential $creds -CategoryKey "Patching" -CategoryValue "Group1" -RecoveryPointName "PrePatch-Group1" -RetentionDays 3 -TimeoutSeconds 900

    Creates a recovery point for all VMs in category Patching:Group1, with a custom name,
    3-day retention, and a 15-minute timeout for the task-polling loop.
.EXAMPLE
    .\New-NtnxGroupRecoveryPoint.ps1 -PcIp 10.0.0.10 -Credential $creds -VmNames "VM01" -AppConsistent -WhatIf

    Dry run requesting an application-consistent (VSS-based) recovery point for a single
    named VM. Field placement for AppConsistent is unverified - test carefully.
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
    [int]$TimeoutSeconds = 600,

    # recoveryPointType is a top-level request field, not per-VM.
    [switch]$AppConsistent,

    # Optional; only relevant in project-scoped / multi-tenant setups (e.g. Nutanix Central).
    [string]$ProjectExtId
)

# API limit: max 32 combined VM + volume group entries per request.
$NtnxRecoveryPointMaxEntities = 32

$PSDefaultParameterValues = @{ 'Invoke-RestMethod:SkipCertificateCheck' = $true }

$baseUri = "https://$($PcIp):9440/api"
$authHeader = @{
    Authorization = "Basic " + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("$($Credential.UserName):$($Credential.GetNetworkCredential().Password)")
    )
}

function Invoke-NtnxApi {
    # Ntnx-Request-Id is mandatory on v4 POST/PUT/DELETE requests (idempotency token).
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
        # Surface the actual API error body (not just the generic HTTP status) and
        # re-throw as a terminating error, so the script stops instead of silently
        # continuing with a $null response (which previously caused false-positive
        # "SUCCEEDED" reports further down the script).
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
    # ByCategory: resolve category extId first, then filter VMs client-side.

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

if ($vmExtIds.Count -gt $NtnxRecoveryPointMaxEntities) {
    throw "$($vmExtIds.Count) VMs matched, but the Nutanix v4 Create Recovery Point API " +
          "accepts a maximum of $NtnxRecoveryPointMaxEntities entities (VMs + volume groups " +
          "combined) per request - confirmed by the official API Reference. Narrow -VmNames, " +
          "use a more specific Category, or split the group into multiple runs."
}

Write-Host "`nVMs targeted for recovery point '$RecoveryPointName':"
$vmExtIds | Format-Table -AutoSize

# --- Create the Recovery Point (state-changing, gated by ShouldProcess) ---
$expiration = (Get-Date).AddDays($RetentionDays).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# Field schema per official Nutanix API Reference for Create Recovery Point; per-VM
# fields (vmExtId, applicationConsistentProperties) inferred - verify before production.
$body = @{
    name              = $RecoveryPointName
    expirationTime    = $expiration
    recoveryPointType = if ($AppConsistent) { "APPLICATION_CONSISTENT" } else { "CRASH_CONSISTENT" }
    vmRecoveryPoints  = $vmExtIds | ForEach-Object {
        $spec = @{ vmExtId = $_.ExtId }
        if ($AppConsistent) {
            $spec.applicationConsistentProperties = @{
                '$objectType'          = 'dataprotection.v4.common.VssProperties'
                backupType             = 'FULL_BACKUP'
                shouldIncludeWriters   = $false
                writers                = @()
                shouldStoreVssMetadata = $false
            }
        }
        $spec
    }
}

if ($ProjectExtId) {
    $body.projectExtId = $ProjectExtId
}

$targetDescription = "$($vmExtIds.Count) VM(s): $($vmExtIds.Name -join ', ')"

if ($PSCmdlet.ShouldProcess($targetDescription, "Create recovery point '$RecoveryPointName' (expires $expiration)")) {

    $createResponse = Invoke-NtnxApi -Method POST -Path "/dataprotection/$ApiVersion/config/recovery-points" -Body $body
    $taskExtId = $createResponse.data.extId

    if (-not $taskExtId) {
        # Defensive guard: if we ever reach this point with no task extId (e.g. an
        # unexpected response shape), stop here rather than letting the polling loop
        # below query the tasks collection without an ID - which previously returned
        # ALL tasks and caused a false-positive "SUCCEEDED" due to PowerShell's -eq
        # array-comparison behavior.
        throw "Recovery point creation did not return a task extId - aborting before polling. Response: $($createResponse | ConvertTo-Json -Depth 5)"
    }

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
