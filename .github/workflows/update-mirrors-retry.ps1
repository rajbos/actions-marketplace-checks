Param (
    [int] $maxItems = 10,
    [string] $queuePath,
    [string[]] $appIds = @($env:APP_ID, $env:APP_ID_2, $env:APP_ID_3),
    [string[]] $appPrivateKeys = @($env:APPLICATION_PRIVATE_KEY, $env:APPLICATION_PRIVATE_KEY_2, $env:APPLICATION_PRIVATE_KEY_3),
    [string] $appOrganization = $env:APP_ORGANIZATION
)

. $PSScriptRoot/library.ps1

if ($appPrivateKeys.Count -gt 0 -and $appIds.Count -gt 0) {
    if ([string]::IsNullOrWhiteSpace($appOrganization)) {
        throw "APP_ORGANIZATION must be provided when using GitHub App credentials"
    }

    $tokenManager = New-GitHubAppTokenManager -AppIds $appIds -AppPrivateKeys $appPrivateKeys
    $script:GitHubAppTokenManagerInstance = $tokenManager
    $tokenResult = $tokenManager.GetTokenForOrganization($appOrganization)

    $access_token = $tokenResult.Token
    $access_token_destination = $tokenResult.Token
}

$queue = @() + (Load-RetryQueue -QueuePath $queuePath)
if ($queue.Count -eq 0) {
    Write-Message -message "Retry queue empty. Nothing to process." -logToSummary $true
    exit 0
}

$now = Get-Date
$ready = $queue | Where-Object {
    if ($_.nextAttempt) {
        try {
            return [DateTime]::Parse($_.nextAttempt) -le $now
        } catch { return $true }
    }
    return $true
} | Select-Object -First $maxItems

if ($ready.Count -eq 0) {
    Write-Message -message "Retry queue has entries but none are due yet." -logToSummary $true
    exit 0
}

Write-Message -message "Processing [$($ready.Count)] mirrors from retry queue" -logToSummary $true

$processed = 0
$success = 0
$failed = 0

foreach ($item in $ready) {
    $processed++
    $mirrorName = $item.name
    ($upstreamOwner, $upstreamRepo) = GetOrgActionInfo -forkedOwnerRepo $mirrorName

    if ([string]::IsNullOrWhiteSpace($upstreamOwner) -or [string]::IsNullOrWhiteSpace($upstreamRepo)) {
        Write-Warning "[$mirrorName] could not be parsed into upstream owner/repo; leaving in queue"
        continue
    }

    Write-Host "[$processed/$($ready.Count)] Retrying mirror create/sync for [$mirrorName] from [$upstreamOwner/$upstreamRepo]"

    $createError = $null
    $createResult = $false
    try {
        if (-not (Get-Command ForkActionRepo -ErrorAction SilentlyContinue)) {
            . $PSScriptRoot/functions.ps1
        }
        $createResult = ForkActionRepo -owner $upstreamOwner -repo $upstreamRepo
    }
    catch {
        $createError = $_.Exception.Message
        $createResult = $false
    }

    if ($createResult) {
        Write-Host "Mirror created for [$mirrorName], attempting sync"
        $sync = SyncMirrorWithUpstream -owner $forkOrg -repo $mirrorName -upstreamOwner $upstreamOwner -upstreamRepo $upstreamRepo -access_token $access_token_destination
        $syncSuccess = if ($sync -is [hashtable]) { $sync.success } else { $sync.success }
        if ($syncSuccess) {
            Write-Host "Successfully synced [$mirrorName]; removing from queue"
            $queue = $queue | Where-Object { $_.name -ne $mirrorName }
            $success++
            continue
        }
        else {
            $createError = if ($sync.message) { $sync.message } else { "Unknown sync failure" }
            Write-Warning "Sync failed for [$mirrorName]: $createError"
        }
    }
    else {
        if (-not $createError) { $createError = "ForkActionRepo returned false" }
        Write-Warning "Create failed for [$mirrorName]: $createError"
    }

    # Update queue item for backoff
    $item.attempts = if ($item.attempts) { $item.attempts + 1 } else { 1 }
    $item.lastAttempt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $item.errorMessage = $createError
    $item.errorType = "mirror_create_failed"
    $nextWaitMinutes = [math]::Min(180, [math]::Pow(2, [double]$item.attempts))
    $item.nextAttempt = (Get-Date).AddMinutes($nextWaitMinutes).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $failed++
}

Save-RetryQueue -Queue $queue -QueuePath $queuePath | Out-Null

Write-Message -message "Retry run complete: processed $processed, succeeded $success, failed $failed, remaining queue $($queue.Count)" -logToSummary $true

exit 0
