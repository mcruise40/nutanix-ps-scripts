<#
.SYNOPSIS
    Deletes one or more Nutanix Recovery Points by their ExtId via the Prism Central v4 API.
.NOTES
    Reuses Invoke-NtnxApi and Get-AllNtnxVms from New-NtnxGroupRecoveryPoint.ps1 (same
    auth/pagination pattern, including the mandatory Ntnx-Request-Id idempotency header
    on DELETE calls). Resolves and shows the associated VM name(s) per recovery point
    where available (e.g. Volume-Group-only recovery points have none - shown without
    a VM tag in that case).

    SAFETY: Deletion is irreversible. ConfirmImpact is 'High', which matches the default
    $ConfirmPreference - so WITHOUT any extra parameter, the script prompts individually
    for each recovery point before deleting it (standard ShouldProcess prompt: Yes/No/
    Yes to All/No to All/Halt). Pass -Confirm:$false to skip all prompts and delete
    immediately. Note: a bare -Confirm (without :$false) does NOT skip prompting - by
    PowerShell design, -Confirm always means "force a prompt", so it has no effect here
    since prompting already happens by default; -Confirm:$false is the only way to
    suppress it. -WhatIf previews without deleting or prompting, as usual.
.PARAMETER PcIp
    IP address or FQDN of the Prism Central instance (without https:// or port).
.PARAMETER Credential
    Prism Central credentials (PSCredential object), e.g. via Get-Credential.
.PARAMETER RecoveryPointExtIds
    One or more Recovery Point ExtIds to delete (e.g. from Get-NtnxRecoveryPoints.ps1's
    ExtId column).
.PARAMETER ApiVersion
    Nutanix v4 API revision to target. Default: "v4.2".
.PARAMETER TimeoutSeconds
    Maximum time (in seconds) to wait for each deletion task to finish before the script
    stops polling that task and warns it may still be running. Default: 600 seconds.
.EXAMPLE
    .\Remove-NtnxRecoveryPoints.ps1 -PcIp 10.0.20.10 -Credential $creds -RecoveryPointExtIds "1ffff90f-f11f-4613-88d6-ceadac77f16d" -WhatIf

    Dry run: shows which recovery point would be deleted (name resolved for clarity),
    deletes nothing, no prompt.
.EXAMPLE
    .\Remove-NtnxRecoveryPoints.ps1 -PcIp 10.0.20.10 -Credential $creds -RecoveryPointExtIds "id1","id2","id3"

    Prompts individually for each of the three recovery points before deleting it
    (default behavior - no extra parameter needed).
.EXAMPLE
    .\Remove-NtnxRecoveryPoints.ps1 -PcIp 10.0.20.10 -Credential $creds -RecoveryPointExtIds "id1","id2","id3" -Confirm:$false

    Deletes all three recovery points immediately, without any prompt.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$PcIp,
    [Parameter(Mandatory)][pscredential]$Credential,
    [Parameter(Mandatory)][string[]]$RecoveryPointExtIds,
    [string]$ApiVersion = "v4.2",
    [int]$TimeoutSeconds = 600
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

function Remove-NtnxRecoveryPoint {
    # Deletes ONE recovery point by ExtId and polls its task. Returns $true on SUCCEEDED.
    param(
        [Parameter(Mandatory)][string]$ExtId,
        [string]$Label
    )

    if (-not $Label) { $Label = $ExtId }

    $deleteResponse = Invoke-NtnxApi -Method DELETE -Path "/dataprotection/$ApiVersion/config/recovery-points/$ExtId"
    $taskExtId = $deleteResponse.data.extId
    if (-not $taskExtId) {
        throw "No task extId returned for $label. Response: $($deleteResponse | ConvertTo-Json -Depth 5)"
    }
    Write-Host "  Task: $taskExtId"

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 5
        $task = Invoke-NtnxApi -Method GET -Path "/prism/$ApiVersion/config/tasks/$taskExtId"
        Write-Host "  Status: $($task.data.status)  Progress: $($task.data.progressPercentage)%"
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Warning "Timeout of $TimeoutSeconds seconds reached for task $taskExtId ($label)."
            return $false
        }
    } while ($task.data.status -in @("QUEUED", "RUNNING"))

    if ($task.data.status -eq "SUCCEEDED") {
        Write-Host "Recovery point $label deleted successfully." -ForegroundColor Green
        return $true
    }
    Write-Warning "Task for $label ended with status: $($task.data.status)"
    return $false
}

# VM lookup for resolving vmExtId -> name in recovery point labels below.
$vmLookup = @{}
(Get-AllNtnxVms) | ForEach-Object { $vmLookup[$_.extId] = $_.name }

# --- Process each ExtId ---
$results = foreach ($extId in $RecoveryPointExtIds) {

    # Best-effort name/VM lookup for clearer prompts/logs - falls back to just the ExtId
    # if the GET fails (e.g. already deleted, or a transient error).
    $displayName = $null
    $vmNames = @()
    try {
        $rp = Invoke-NtnxApi -Method GET -Path "/dataprotection/$ApiVersion/config/recovery-points/$extId"
        $displayName = $rp.data.name
        # Some recovery points have no vmRecoveryPoints (e.g. Volume-Group-only) -
        # filter out empty/null vmExtIds before the lookup (same null-safety as
        # Get-NtnxRecoveryPoints.ps1).
        $vmNames = @($rp.data.vmRecoveryPoints | Where-Object { $_.vmExtId } | ForEach-Object {
            if ($vmLookup.ContainsKey($_.vmExtId)) { $vmLookup[$_.vmExtId] } else { $_.vmExtId }
        })
    } catch {
        Write-Verbose "Could not resolve name/VM for $extId - proceeding with ExtId only."
    }

    $label = if ($displayName) { "'$displayName'" } else { $extId }
    if ($vmNames) { $label += " [VM: $($vmNames -join ', ')]" }
    if ($displayName) { $label += " ($extId)" }

    Write-Host "`n--- $label ---"

    if ($PSCmdlet.ShouldProcess($label, "Permanently delete recovery point")) {
        try {
            $success = Remove-NtnxRecoveryPoint -ExtId $extId -Label $label
        } catch {
            Write-Warning "Deletion of $label failed: $($_.Exception.Message)"
            $success = $false
        }
        [pscustomobject]@{ ExtId = $extId; Name = $displayName; VMs = ($vmNames -join ', '); Success = $success }
    } else {
        Write-Host "[WhatIf] No changes made for $label." -ForegroundColor Yellow
    }
}

if ($results) {
    $succeeded = ($results | Where-Object Success).Count
    $color = if ($succeeded -eq $results.Count) { 'Green' } else { 'Yellow' }
    Write-Host "`n$succeeded of $($results.Count) recovery points deleted successfully." -ForegroundColor $color
}
