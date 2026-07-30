Param (
    $accessToken = $env:GITHUB_TOKEN,
    # Hard safety margin below GitHub-hosted runners' 6 hour job cap. We stop
    # starting new work (including new rate-limit waits) once we're within
    # this margin, so a clean SaveStatus always happens before the runner's
    # own timeout could kill the job mid-write.
    $maxRuntimeMinutes = 340,
    # Longest single rate-limit wait ApiCall will take before switching apps
    # or stopping gracefully (see library.ps1). Used to make sure we never
    # start an iteration that could still be waiting when we cross the
    # maxRuntimeMinutes mark.
    $maxSingleWaitMinutes = 20
)

# Dedicated, low-overhead backfill for the `description` field only.
#
# Context: repoInfo.ps1's main pipeline (GetInfo/GetMoreInfo) backfills
# description as a side effect of its regular per-repo bookkeeping, but that
# pipeline shares its GitHub Apps and per-run update budget with three other
# hourly workflows (analyze, releaseInfo-refresh, update-mirrors), and does a
# lot of unrelated work (owner backfill, mirrorLastUpdated, repoSize,
# dependents refresh, Trivy scans) per repo before it ever reaches the
# description check. That crowds out the description backfill and burns
# through the shared rate limit before real progress is made.
#
# This script instead:
# - runs on its own dedicated GitHub App (isolated rate-limit pool - see
#   description-backfill.yml), so it never contends with the other workflows
# - only targets records that are missing a description AND already have a
#   known action.yml/action.yaml path from a previous repoInfo.ps1 run, so
#   each repo costs exactly 2 API calls (contents metadata + raw file
#   download) instead of the 4-6+ calls GetActionType needs when probing for
#   the file from scratch
# - is time-budget bound (not repo-count bound), so it can use as much of a
#   single long-running job as the rate limit allows

. $PSScriptRoot/library.ps1

$startTime = Get-Date
Write-Host "Description backfill run started at [$startTime]"
Write-Host "Max runtime: [$maxRuntimeMinutes] minutes (safety margin below the 6 hour job cap)"

if ([string]::IsNullOrWhiteSpace($accessToken)) {
    # Fail fast on an obviously-bad key (e.g. a placeholder value, or the app
    # ID/path pasted by mistake) before ever attempting a token exchange or
    # processing a single candidate. This is the exact scenario that let a
    # prior run burn its whole time budget doing nothing useful: the app
    # secret was still a placeholder, but the script kept iterating through
    # ~29,000 candidates anyway.
    if (-not (Test-IsLikelyGitHubAppPemKey -pemKey $env:APPLICATION_PRIVATE_KEY)) {
        Write-Error "APPLICATION_PRIVATE_KEY does not look like a PEM-encoded GitHub App private key (missing a '-----BEGIN ... PRIVATE KEY-----' header, or too short). Refusing to start the backfill - update the AUTOMATION_APP_KEY4 secret with the real private key contents before re-running."
        exit 1
    }

    try {
        $tokenManager = New-GitHubAppTokenManagerFromEnvironment
        $script:GitHubAppTokenManagerInstance = $tokenManager
        $tokenResult = $tokenManager.GetTokenForOrganization($env:APP_ORGANIZATION)
        $accessToken = $tokenResult.Token
    }
    catch {
        Write-Error "Failed to obtain GitHub App token for organization [$($env:APP_ORGANIZATION)]: $($_.Exception.Message)"
        throw
    }
}
$env:GITHUB_TOKEN = $accessToken

# Second guard: confirm the token we got back actually authenticates as the
# GitHub App, rather than trusting that a non-empty token is a working one.
# An unauthenticated/failed token still reports a real (very low) rate limit
# via api.github.com/rate_limit, so we can detect it cheaply with a single
# call instead of discovering it thousands of failed candidates later.
try {
    $rateLimitCheck = Invoke-RestMethod -Uri "https://api.github.com/rate_limit" -Headers @{
        Authorization = "Bearer $accessToken"
        Accept        = "application/vnd.github+json"
    } -Method GET -ErrorAction Stop
}
catch {
    Write-Error "Startup credential check failed: could not call GET /rate_limit with the obtained token ($($_.Exception.Message)). Refusing to start the backfill - verify APP_ID/APPLICATION_PRIVATE_KEY (AUTOMATION_APP_KEY4) are correct and the app is installed on [$($env:APP_ORGANIZATION)]."
    exit 1
}

$coreLimit = $rateLimitCheck.resources.core.limit
Write-Host "Startup credential check OK - authenticated core rate limit is [$(DisplayIntWithDots $coreLimit)] requests/hour"
if ($coreLimit -le 60) {
    # 60/hour is the standard unauthenticated limit - seeing exactly that
    # means the token did not actually authenticate as the App/installation,
    # even though we received a non-empty token string.
    Write-Error "Startup credential check failed: authenticated core rate limit is only [$coreLimit] requests/hour, which means the token is not actually authenticated as the GitHub App (this is the standard unauthenticated limit). Refusing to start the backfill - verify APP_ID/APPLICATION_PRIVATE_KEY (AUTOMATION_APP_KEY4) are correct and the app is installed on [$($env:APP_ORGANIZATION)]."
    exit 1
}

Import-Module powershell-yaml -Force

if (-not (Test-Path $statusFile)) {
    Write-Error "No status.json found at [$statusFile] - nothing to backfill. Did the 'Download status.json from blob storage' step run?"
    exit 1
}

Write-Host "Loading existing status from [$statusFile]"
$existingForks = Get-Content $statusFile | ConvertFrom-Json
$existingForks = Normalize-ActionDates -actions $existingForks
Write-Host "Loaded [$(DisplayIntWithDots $existingForks.Count)] existing records"

# Candidates: no description yet, but we already know exactly which file to
# read it from. Anything with fileFound in ("No file found", "Error
# downloading file", "Unknown", $null, "Dockerfile", "dockerfile") has no
# action.yml/action.yaml to read a description from, so skip those instead
# of spending a wasted API call on them.
$eligibleFileNames = @("action.yml", "action.yaml")
$candidates = @($existingForks | Where-Object {
    $hasDescriptionField = $null -ne (Get-Member -InputObject $_ -Name "description" -MemberType Properties)
    $hasDescriptionValue = $hasDescriptionField -and ($null -ne $_.description) -and ("$($_.description)".Trim().Length -gt 0)
    $fileFound = $_.actionType.fileFound
    (-not $hasDescriptionValue) -and ($null -ne $fileFound) -and ($eligibleFileNames -contains $fileFound)
})

Write-Message -message "# Description Backfill" -logToSummary $true
Write-Message -message "" -logToSummary $true
Write-Message -message "Found [$(DisplayIntWithDots $candidates.Count)] candidates missing a description with a known action.yml/action.yaml path (out of [$(DisplayIntWithDots $existingForks.Count)] total records)" -logToSummary $true

$processed = 0
$updated = 0
$notFound = 0
$errors = 0
$stoppedEarly = $false
$stopReason = ""

foreach ($action in $candidates) {
    $timeSpan = (Get-Date) - $startTime
    $remainingMinutes = $maxRuntimeMinutes - $timeSpan.TotalMinutes
    if ($remainingMinutes -le $maxSingleWaitMinutes) {
        # Not enough runway left to safely start another iteration that
        # might need to wait out a rate limit reset. Stop now so SaveStatus
        # below always completes well inside the runner's own timeout.
        $stoppedEarly = $true
        $stopReason = "Approaching the [$maxRuntimeMinutes] minute safety margin (elapsed [$([math]::Round($timeSpan.TotalMinutes, 1))] minutes)"
        Write-Host "Stopping: $stopReason"
        break
    }

    $processed++
    ($owner, $repo) = GetOrgActionInfo($action.name)
    if ([string]::IsNullOrWhiteSpace($owner) -or [string]::IsNullOrWhiteSpace($repo)) {
        continue
    }

    $fileFound = $action.actionType.fileFound

    try {
        $url = "/repos/$owner/$repo/contents/$fileFound"
        $response = ApiCall -method GET -url $url -hideFailedCall $true -access_token $accessToken

        if ($null -eq $response -or [string]::IsNullOrWhiteSpace($response.download_url)) {
            $notFound++
            continue
        }

        $fileContent = ApiCall -method GET -url $response.download_url -returnErrorInfo $true -access_token $accessToken
        if (($fileContent -is [hashtable]) -and ($fileContent.ContainsKey('Error'))) {
            Write-Debug "Error downloading [$fileFound] for [$owner/$repo]: StatusCode $($fileContent.StatusCode)"
            $errors++
            continue
        }

        $yaml = $null
        try {
            $yaml = ConvertFrom-Yaml $fileContent
        }
        catch {
            Write-Debug "Error converting [$owner/$repo] [$fileFound] to yaml: $($_.Exception.Message)"
            $errors++
            continue
        }

        $description = $null
        if ($yaml.description -is [string] -and $yaml.description.Trim().Length -gt 0) {
            $description = $yaml.description.Trim()
        }

        # Always write the property, even when $null. This marks the record
        # as "checked" (hasDescriptionField becomes true), matching the same
        # "null means unknown, not empty" convention repoInfo.ps1 already
        # uses, so this record is not re-selected as a candidate next run.
        $hasField = Get-Member -InputObject $action -Name "description" -MemberType Properties
        if (-not $hasField) {
            $action | Add-Member -Name description -Value $description -MemberType NoteProperty
        }
        else {
            $action.description = $description
        }

        if ($null -ne $description) {
            $updated++
        }
        else {
            $notFound++
        }
    }
    catch {
        Write-Debug "Unexpected error processing [$owner/$repo]: $($_.Exception.Message)"
        $errors++
    }

    if ($processed % 500 -eq 0) {
        $elapsed = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
        Write-Host "Progress: processed [$processed] of [$($candidates.Count)] candidates ([$updated] descriptions found, [$notFound] blank, [$errors] errors) - elapsed [$elapsed] min"
        # Checkpoint periodically so a crash or an unexpected kill doesn't
        # lose several hours of API calls we already paid for.
        SaveStatus -existingForks $existingForks
    }
}

$totalElapsedMinutes = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)

Write-Host ""
Write-Host "Description backfill finished: processed [$processed] of [$($candidates.Count)] candidates in [$totalElapsedMinutes] minutes"
Write-Host "  Descriptions found: $updated"
Write-Host "  Confirmed blank/unavailable: $notFound"
Write-Host "  Errors: $errors"
if ($stoppedEarly) {
    Write-Host "  Stopped early: $stopReason"
}

Write-Message -message "" -logToSummary $true
Write-Message -message "| Metric | Count |" -logToSummary $true
Write-Message -message "|--------|------:|" -logToSummary $true
Write-Message -message "| Candidates found | $(DisplayIntWithDots $candidates.Count) |" -logToSummary $true
Write-Message -message "| Processed this run | $(DisplayIntWithDots $processed) |" -logToSummary $true
Write-Message -message "| ✅ Descriptions found | $(DisplayIntWithDots $updated) |" -logToSummary $true
Write-Message -message "| ⬜ Confirmed blank | $(DisplayIntWithDots $notFound) |" -logToSummary $true
Write-Message -message "| ❌ Errors | $(DisplayIntWithDots $errors) |" -logToSummary $true
Write-Message -message "| ⏱️ Elapsed minutes | $totalElapsedMinutes |" -logToSummary $true
if ($stoppedEarly) {
    Write-Message -message "" -logToSummary $true
    Write-Message -message "⚠️ Stopped early: $stopReason. Remaining [$(DisplayIntWithDots ($candidates.Count - $processed))] candidates will be picked up on the next scheduled run." -logToSummary $true
}

SaveStatus -existingForks $existingForks

GetRateLimitInfo -access_token $accessToken -access_token_destination $accessToken -waitForRateLimit $false

exit 0
