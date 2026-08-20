<#
.SYNOPSIS
    Creates on-demand Recovery Points for a group of AHV VMs via Prism Central v4 API,
    one recovery point per VM. Target VMs are selected either by explicit name list, or
    by a Category key/value pair.
.NOTES
    Always one API call per VM, for both crash-consistent and app-consistent (avoids the
    API's 1-VM-per-request limit for app-consistent - error DP-10100 - and keeps behavior
    uniform). A group failure/timeout on one VM does not stop the others; see summary line.
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
    Name used as-is for every created recovery point (same name across all targeted VMs -
    no VM suffix, since Prism Central's Data Protection view is already organized per-VM).
    Defaults to "OnDemand-<timestamp>" if not specified.
.PARAMETER RetentionDays
    Number of days until the recovery point expires and is eligible for cleanup.
    Default: 1 day.
.PARAMETER ApiVersion
    Nutanix v4 API revision to target (e.g. "v4.2", "v4.3"). Default: "v4.2" (v4.3/v4.4
    not supported in this environment's lab PC). v4
    revisions are documented as backward compatible within the v4 family, so this
    normally only needs to be changed to intentionally use a newer revision's features.
.PARAMETER TimeoutSeconds
    Maximum time (in seconds) to wait for each recovery-point creation task to finish
    before the script stops polling that task and warns it may still be running.
    Default: 600 seconds (10 minutes).
.PARAMETER AppConsistent
    If set, requests application-consistent recovery points instead of the default
    crash-consistent ones (sets recoveryPointType to APPLICATION_CONSISTENT). Requires NGT
    on the guest: VSS on Windows, or /usr/local/sbin/pre_freeze + /usr/local/sbin/post_thaw
    scripts on Linux; without these, Nutanix silently falls back to crash-consistent
    (no error).
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

    Creates one crash-consistent recovery point per VM for two explicitly named VMs,
    using default retention (1 day) and default timeout (600 seconds).
.EXAMPLE
    .\New-NtnxGroupRecoveryPoint.ps1 -PcIp 10.0.0.10 -Credential $creds -CategoryKey "Patching" -CategoryValue "Group1" -WhatIf

    Dry run for all VMs tagged with category Patching:Group1 - shows which VMs would be
    targeted without creating anything.
.EXAMPLE
    .\New-NtnxGroupRecoveryPoint.ps1 -PcIp 10.0.0.10 -Credential $creds -CategoryKey "Patching" -CategoryValue "Group1" -RecoveryPointName "PrePatch" -RetentionDays 3 -TimeoutSeconds 900

    Creates one recovery point named "PrePatch" for each VM in category Patching:Group1
    (same name across all of them), with 3-day retention and a 15-minute per-VM task timeout.
.EXAMPLE
    .\New-NtnxGroupRecoveryPoint.ps1 -PcIp 10.0.0.10 -Credential $creds -CategoryKey "Patching" -CategoryValue "Group1" -AppConsistent

    Creates one application-consistent recovery point per VM in category Patching:Group1.
    VMs without VSS/NGT prerequisites silently fall back to crash-consistent for that VM.
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

    [string]$RecoveryPointName = "OnDemand-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
    [int]$RetentionDays = 1,
    [string]$ApiVersion = "v4.2",
    [int]$TimeoutSeconds = 600,

    # recoveryPointType is a top-level request field, not per-VM.
    [switch]$AppConsistent,

    # Optional; only relevant in project-scoped / multi-tenant setups (e.g. Nutanix Central).
    [string]$ProjectExtId
)

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

function New-NtnxRecoveryPoint {
    # Builds the body, POSTs, and polls the task for ONE recovery point (one or more VMs).
    # Returns $true on SUCCEEDED, $false otherwise (timeout, non-success task status).
    param(
        [Parameter(Mandatory)][array]$VmEntries,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ExpirationTime,
        [switch]$AppConsistent,
        [string]$ProjectExtId
    )

    $body = @{
        name              = $Name
        expirationTime    = $ExpirationTime
        recoveryPointType = if ($AppConsistent) { "APPLICATION_CONSISTENT" } else { "CRASH_CONSISTENT" }
        # @(...) forces an array even with a single VM - see Get-AllNtnxVms note above.
        vmRecoveryPoints  = @($VmEntries | ForEach-Object {
            $spec = @{ vmExtId = $_.ExtId }
            if ($AppConsistent) {
                # 'writers' omitted: API rejects an empty array (minItems 1).
                $spec.applicationConsistentProperties = @{
                    '$objectType'          = 'dataprotection.v4.common.VssProperties'
                    backupType             = 'FULL_BACKUP'
                    shouldIncludeWriters   = $false
                    shouldStoreVssMetadata = $false
                }
            }
            $spec
        })
    }
    if ($ProjectExtId) { $body.projectExtId = $ProjectExtId }

    $createResponse = Invoke-NtnxApi -Method POST -Path "/dataprotection/$ApiVersion/config/recovery-points" -Body $body
    $taskExtId = $createResponse.data.extId
    if (-not $taskExtId) {
        # Guard against a false-positive "SUCCEEDED" from polling the tasks collection
        # without an ID (see task-polling loop below).
        throw "No task extId returned. Response: $($createResponse | ConvertTo-Json -Depth 5)"
    }
    Write-Host "  Task: $taskExtId"

    $vmLabel = ($VmEntries.Name -join ', ')
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 5
        $task = Invoke-NtnxApi -Method GET -Path "/prism/$ApiVersion/config/tasks/$taskExtId"
        Write-Host "  Status: $($task.data.status)  Progress: $($task.data.progressPercentage)%"
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Warning "Timeout of $TimeoutSeconds seconds reached for task $taskExtId (VM: $vmLabel, name '$Name')."
            return $false
        }
    } while ($task.data.status -in @("QUEUED", "RUNNING"))

    if ($task.data.status -eq "SUCCEEDED") {
        Write-Host "Recovery point '$Name' created successfully for VM: $vmLabel." -ForegroundColor Green
        return $true
    }
    Write-Warning "Task for VM '$vmLabel' (recovery point '$Name') ended with status: $($task.data.status)"
    return $false
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

Write-Host "`nVMs targeted:"
$vmExtIds | Format-Table -AutoSize

# --- Build one recovery point job per VM (state-changing, gated by ShouldProcess) ---
# Unified for both crash-consistent and app-consistent: one API call per VM, so
# AppConsistent's API-enforced 1-VM-per-request limit (DP-10100) never applies, and
# behavior is consistent regardless of -AppConsistent.
# The recovery point Name is used as-is (no VM suffix) for every VM: Prism Central's
# Data Protection > VM Recovery Points view is already organized per-VM (click a VM to
# see its recovery points) - there is no flat cross-VM list where a name suffix would
# aid identification, per direct confirmation from the environment's Prism Central UI.
$expiration = (Get-Date).AddDays($RetentionDays).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$jobs = @($vmExtIds | ForEach-Object {
    [pscustomobject]@{ Name = $RecoveryPointName; Vms = @($_) }
})

$results = foreach ($job in $jobs) {
    $vmLabel = $job.Vms[0].Name
    $targetDescription = "VM: $vmLabel"
    Write-Host "`n--- VM: $vmLabel ---"

    if ($PSCmdlet.ShouldProcess($targetDescription, "Create recovery point '$($job.Name)' (expires $expiration)")) {
        try {
            $success = New-NtnxRecoveryPoint -VmEntries $job.Vms -Name $job.Name -ExpirationTime $expiration `
                -AppConsistent:$AppConsistent -ProjectExtId $ProjectExtId
        } catch {
            Write-Warning "Recovery point for VM '$vmLabel' failed: $($_.Exception.Message)"
            $success = $false
        }
        [pscustomobject]@{ Vm = $vmLabel; Name = $job.Name; Success = $success }
    } else {
        Write-Host "[WhatIf] No changes made for VM '$vmLabel' (recovery point '$($job.Name)')." -ForegroundColor Yellow
    }
}

if ($results) {
    $succeeded = ($results | Where-Object Success).Count
    $color = if ($succeeded -eq $results.Count) { 'Green' } else { 'Yellow' }
    Write-Host "`n$succeeded of $($results.Count) tasks executed successfully." -ForegroundColor $color
}
