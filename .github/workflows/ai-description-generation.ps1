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
    $maxSingleWaitMinutes = 20,
    # Ollama model tag in use for this run - recorded per-record so a future
    # model upgrade can identify and selectively regenerate stale entries.
    $ollamaModel = ($env:OLLAMA_MODEL ?? "qwen2.5-coder:3b"),
    # Base URL of the already-running Ollama service container for this job.
    $ollamaUrl = ($env:OLLAMA_URL ?? "http://localhost:11434")
)

# Generates an AI description (`aiDescription`) for every action record, using a
# small local language model (SLM) fed each repo's README plus its known
# action.yml/action.yaml content. This is a NEW, separate field from the real
# `description` field parsed straight from action.yml (owned by
# description-backfill.ps1) - it is never overwritten or confused with it.
#
# Context: description-backfill.ps1 found that only ~8% of records missing a
# `description` actually have one in action.yml - 91% genuinely have none
# there. READMEs carry much more signal, hence generating a description with a
# local model instead of relying solely on the sparse action.yml field.
#
# Design mirrors description-backfill.ps1:
# - runs on its own dedicated 5th GitHub App (isolated rate-limit pool - see
#   ai-description-generation.yml), so it never contends with the other
#   hourly workflows or with description-backfill's 4th app
# - is time-budget bound (not repo-count bound), so it can use as much of a
#   single long-running job as the rate limit and inference time allow
# - candidates are selected by `aiDescriptionGeneratedAt` not yet being set,
#   so a full pass over ~35,000+ records happens across multiple scheduled
#   runs rather than requiring one run to cover everything
#
# The Ollama model itself is loaded ONCE per job (as a service container,
# started by the workflow before this script runs) - this script only makes
# one HTTP call per repo against the already-warm model, it never
# starts/stops the model itself.

. $PSScriptRoot/library.ps1

$startTime = Get-Date
Write-Host "AI description generation run started at [$startTime]"
Write-Host "Max runtime: [$maxRuntimeMinutes] minutes (safety margin below the 6 hour job cap)"
Write-Host "Ollama model: [$ollamaModel] at [$ollamaUrl]"

if ([string]::IsNullOrWhiteSpace($accessToken)) {
    # Fail fast on an obviously-bad key (e.g. a placeholder value, or the app
    # ID/path pasted by mistake) before ever attempting a token exchange or
    # processing a single candidate.
    if (-not (Test-IsLikelyGitHubAppPemKey -pemKey $env:APPLICATION_PRIVATE_KEY)) {
        Write-Error "APPLICATION_PRIVATE_KEY does not look like a PEM-encoded GitHub App private key (missing a '-----BEGIN ... PRIVATE KEY-----' header, or too short). Refusing to start AI description generation - update the AUTOMATION_APP_KEY secret with the real private key contents before re-running."
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
    Write-Error "Startup credential check failed: could not call GET /rate_limit with the obtained token ($($_.Exception.Message)). Refusing to start AI description generation - verify APP_ID/APPLICATION_PRIVATE_KEY (AUTOMATION_APP_KEY4) are correct and the app is installed on [$($env:APP_ORGANIZATION)]."
    exit 1
}

$coreLimit = $rateLimitCheck.resources.core.limit
Write-Host "Startup credential check OK - authenticated core rate limit is [$(DisplayIntWithDots $coreLimit)] requests/hour"
if ($coreLimit -le 60) {
    # 60/hour is the standard unauthenticated limit - seeing exactly that
    # means the token did not actually authenticate as the App/installation,
    # even though we received a non-empty token string.
    Write-Error "Startup credential check failed: authenticated core rate limit is only [$coreLimit] requests/hour, which means the token is not actually authenticated as the GitHub App (this is the standard unauthenticated limit). Refusing to start AI description generation - verify APP_ID/APPLICATION_PRIVATE_KEY (AUTOMATION_APP_KEY4) are correct and the app is installed on [$($env:APP_ORGANIZATION)]."
    exit 1
}

# Second startup guard: confirm the Ollama service container is actually up
# and the model was pulled successfully before spending any API calls -
# mirrors the credential guard above, applied to the local model dependency.
try {
    $tagsCheck = Invoke-RestMethod -Uri "$($ollamaUrl.TrimEnd('/'))/api/tags" -Method GET -ErrorAction Stop
    $availableModels = @($tagsCheck.models | ForEach-Object { $_.name })
    $modelAvailable = ($availableModels -contains $ollamaModel) -or
        ((-not ($ollamaModel -like "*:*")) -and (@($availableModels | Where-Object { $_.Split(':')[0] -eq $ollamaModel }).Count -gt 0))
    if (-not $modelAvailable) {
        Write-Error "Startup check failed: Ollama model [$ollamaModel] is not in the service's available models list ($($availableModels -join ', ')). Refusing to start - check the 'Set up Ollama' step logs for pull failures."
        exit 1
    }
    Write-Host "Startup check OK - Ollama model [$ollamaModel] is available"
}
catch {
    Write-Error "Startup check failed: could not reach Ollama at [$ollamaUrl] ($($_.Exception.Message)). Refusing to start - verify the ollama service container is running and 'Set up Ollama' step completed."
    exit 1
}

Import-Module powershell-yaml -Force

if (-not (Test-Path $statusFile)) {
    Write-Error "No status.json found at [$statusFile] - nothing to process. Did the 'Download status.json from blob storage' step run?"
    exit 1
}

Write-Host "Loading existing status from [$statusFile]"
$existingForks = Get-Content $statusFile | ConvertFrom-Json
$existingForks = Normalize-ActionDates -actions $existingForks
Write-Host "Loaded [$(DisplayIntWithDots $existingForks.Count)] existing records"

function LoadAiDescriptionPromptTemplate {
    $promptPath = Join-Path $PSScriptRoot "action-ai-description-prompt.txt"
    if (Test-Path $promptPath) {
        return Get-Content -Path $promptPath -Raw
    }
    Write-Warning "AI description prompt template not found at [$promptPath]"
    return $null
}

$promptTemplate = LoadAiDescriptionPromptTemplate
if ($null -eq $promptTemplate) {
    Write-Error "Cannot generate AI descriptions without the prompt template - aborting."
    exit 1
}

function CallOllamaForDescription {
    Param (
        [Parameter(Mandatory = $true)]
        [string] $readmeContent,
        [Parameter(Mandatory = $false)]
        [string] $actionYmlContent = "",
        [int] $attempt = 1
    )

    $maxAttempts = 2
    $backoffSeconds = 15

    try {
        # Use plain .Replace() (literal string replace, not -replace/regex)
        # so readme/action.yml content containing regex metacharacters (e.g.
        # `$`, `{`) can't break the placeholder substitution.
        $fullPrompt = $promptTemplate.Replace('{README_CONTENT}', $readmeContent).Replace('{ACTION_YML_CONTENT}', $actionYmlContent)

        $body = @{
            model = $ollamaModel
            stream = $false
            messages = @(
                @{
                    role = "user"
                    content = $fullPrompt
                }
            )
            options = @{
                temperature = 0.5
                num_predict = 300
            }
        } | ConvertTo-Json -Depth 10

        $url = "$($ollamaUrl.TrimEnd('/'))/api/chat"
        $response = Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop

        if ($response.message -and $response.message.content) {
            return $response.message.content.Trim()
        }
        else {
            throw "No response content from Ollama"
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Debug "Attempt $attempt failed to call Ollama: $errorMessage"

        if ($attempt -lt $maxAttempts) {
            Start-Sleep -Seconds $backoffSeconds
            return CallOllamaForDescription -readmeContent $readmeContent -actionYmlContent $actionYmlContent -attempt ($attempt + 1)
        }
        else {
            Write-Debug "Failed to generate AI description after $maxAttempts attempts: $errorMessage"
            return $null
        }
    }
}

# Candidates: every record that has not yet had an AI description generated
# (or explicitly checked-and-failed), regardless of whether the real
# `description` field is populated - this is intentionally NOT limited to
# missing-description records, unlike description-backfill.ps1.
$candidates = @($existingForks | Where-Object {
    $hasField = $null -ne (Get-Member -InputObject $_ -Name "aiDescriptionGeneratedAt" -MemberType Properties)
    $hasValue = $hasField -and (-not [string]::IsNullOrWhiteSpace("$($_.aiDescriptionGeneratedAt)"))
    -not $hasValue
})

Write-Message -message "# AI Description Generation" -logToSummary $true
Write-Message -message "" -logToSummary $true
Write-Message -message "Using Ollama model [$ollamaModel]" -logToSummary $true
Write-Message -message "Found [$(DisplayIntWithDots $candidates.Count)] candidates without an AI description yet (out of [$(DisplayIntWithDots $existingForks.Count)] total records)" -logToSummary $true

$processed = 0
$generated = 0
$noSignal = 0
$errors = 0
$stoppedEarly = $false
$stopReason = ""
$lastProgressLog = Get-Date

Write-Host "Starting processing loop..."

$eligibleFileNames = @("action.yml", "action.yaml")

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

    try {
        # README content - the main signal for the AI description.
        $readmeContent = ""
        try {
            $readmeUrl = "/repos/$owner/$repo/readme"
            $readmeResponse = ApiCall -method GET -url $readmeUrl -hideFailedCall $true -access_token $accessToken
            if ($null -ne $readmeResponse -and -not [string]::IsNullOrWhiteSpace($readmeResponse.content)) {
                $readmeContent = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($readmeResponse.content -replace "`n", ""))
            }
        }
        catch {
            Write-Debug "Error downloading README for [$owner/$repo]: $($_.Exception.Message)"
        }

        # action.yml/action.yaml content - secondary context, reusing the
        # already-known file path from a previous repoInfo.ps1 run instead of
        # re-probing for it from scratch.
        $actionYmlContent = ""
        $fileFound = $action.actionType.fileFound
        if ($null -ne $fileFound -and ($eligibleFileNames -contains $fileFound)) {
            try {
                $fileUrl = "/repos/$owner/$repo/contents/$fileFound"
                $fileResponse = ApiCall -method GET -url $fileUrl -hideFailedCall $true -access_token $accessToken
                if ($null -ne $fileResponse -and -not [string]::IsNullOrWhiteSpace($fileResponse.download_url)) {
                    $downloaded = ApiCall -method GET -url $fileResponse.download_url -returnErrorInfo $true -access_token $accessToken
                    if (-not (($downloaded -is [hashtable]) -and $downloaded.ContainsKey('Error'))) {
                        $actionYmlContent = "$downloaded"
                    }
                }
            }
            catch {
                Write-Debug "Error downloading [$fileFound] for [$owner/$repo]: $($_.Exception.Message)"
            }
        }

        if ([string]::IsNullOrWhiteSpace($readmeContent) -and [string]::IsNullOrWhiteSpace($actionYmlContent)) {
            # No signal at all to generate from - mark as checked so this
            # record is not re-selected as a candidate on every future run.
            $noSignal++
            $aiDescription = $null
        }
        else {
            # Truncate to stay well within the model's context window and
            # keep per-repo inference time bounded.
            if ($readmeContent.Length -gt 4000) {
                $readmeContent = $readmeContent.Substring(0, 4000) + "`n`n[README truncated for AI description generation]"
            }
            if ($actionYmlContent.Length -gt 2000) {
                $actionYmlContent = $actionYmlContent.Substring(0, 2000) + "`n[action.yml truncated for AI description generation]"
            }

            $aiDescription = CallOllamaForDescription -readmeContent $readmeContent -actionYmlContent $actionYmlContent
            if ($null -ne $aiDescription) {
                $generated++
            }
            else {
                $errors++
            }
        }

        # Always write the "checked" properties, even when generation
        # returned $null - matches the same "null means unknown, not empty"
        # convention description-backfill.ps1 uses, so this record is not
        # re-selected as a candidate next run. A future refresh policy can
        # explicitly clear aiDescriptionGeneratedAt to force regeneration.
        $now = (Get-Date).ToUniversalTime().ToString("o")

        $hasDescField = Get-Member -InputObject $action -Name "aiDescription" -MemberType Properties
        if (-not $hasDescField) {
            $action | Add-Member -Name aiDescription -Value $aiDescription -MemberType NoteProperty
        }
        else {
            $action.aiDescription = $aiDescription
        }

        $hasGenAtField = Get-Member -InputObject $action -Name "aiDescriptionGeneratedAt" -MemberType Properties
        if (-not $hasGenAtField) {
            $action | Add-Member -Name aiDescriptionGeneratedAt -Value $now -MemberType NoteProperty
        }
        else {
            $action.aiDescriptionGeneratedAt = $now
        }

        $hasModelField = Get-Member -InputObject $action -Name "aiDescriptionModel" -MemberType Properties
        if (-not $hasModelField) {
            $action | Add-Member -Name aiDescriptionModel -Value $ollamaModel -MemberType NoteProperty
        }
        else {
            $action.aiDescriptionModel = $ollamaModel
        }
    }
    catch {
        Write-Debug "Unexpected error processing [$owner/$repo]: $($_.Exception.Message)"
        $errors++
    }

    $secondsSinceLastLog = ((Get-Date) - $lastProgressLog).TotalSeconds
    if (($processed % 100 -eq 0) -or ($secondsSinceLastLog -ge 60)) {
        $elapsed = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
        Write-Host "Progress: processed [$processed] of [$($candidates.Count)] candidates ([$generated] generated, [$noSignal] no signal, [$errors] errors) - elapsed [$elapsed] min"
        $lastProgressLog = Get-Date
        # Checkpoint periodically so a crash or an unexpected kill doesn't
        # lose several hours of API calls and inference time we already paid
        # for.
        SaveStatus -existingForks $existingForks
    }
}

$totalElapsedMinutes = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)

Write-Host ""
Write-Host "AI description generation finished: processed [$processed] of [$($candidates.Count)] candidates in [$totalElapsedMinutes] minutes"
Write-Host "  Descriptions generated: $generated"
Write-Host "  No signal (no README/action.yml content): $noSignal"
Write-Host "  Errors: $errors"
if ($stoppedEarly) {
    Write-Host "  Stopped early: $stopReason"
}

Write-Message -message "" -logToSummary $true
Write-Message -message "| Metric | Count |" -logToSummary $true
Write-Message -message "|--------|------:|" -logToSummary $true
Write-Message -message "| Candidates found | $(DisplayIntWithDots $candidates.Count) |" -logToSummary $true
Write-Message -message "| Processed this run | $(DisplayIntWithDots $processed) |" -logToSummary $true
Write-Message -message "| ✅ Descriptions generated | $(DisplayIntWithDots $generated) |" -logToSummary $true
Write-Message -message "| ⬜ No signal | $(DisplayIntWithDots $noSignal) |" -logToSummary $true
Write-Message -message "| ❌ Errors | $(DisplayIntWithDots $errors) |" -logToSummary $true
Write-Message -message "| ⏱️ Elapsed minutes | $totalElapsedMinutes |" -logToSummary $true
if ($stoppedEarly) {
    Write-Message -message "" -logToSummary $true
    Write-Message -message "⚠️ Stopped early: $stopReason. Remaining [$(DisplayIntWithDots ($candidates.Count - $processed))] candidates will be picked up on the next scheduled run." -logToSummary $true
}

SaveStatus -existingForks $existingForks

GetRateLimitInfo -access_token $accessToken -access_token_destination $accessToken -waitForRateLimit $false

exit 0
