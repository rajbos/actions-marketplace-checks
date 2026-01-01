Param (
    $actions,
    $forkNames,  # Array of fork names to process in this chunk
    [int] $chunkId = 0,
    $access_token = $env:GITHUB_TOKEN,
    $access_token_destination = $env:GITHUB_TOKEN,
    [string[]] $application_id = @($env:APPLICATION_ID),
    [string[]] $application_private_key = @($env:APPLICATION_PRIVATE_KEY),
    [string] $application_organization = $env:APPLICATION_ORGANIZATION,
    [string] $github_api_url = $env:GITHUB_API_URL
)

. $PSScriptRoot/library.ps1

$resolvedApiUrl = if ([string]::IsNullOrWhiteSpace($github_api_url)) { "https://api.github.com" } else { $github_api_url }
$shouldGenerateToken = ([string]::IsNullOrWhiteSpace($access_token) -or [string]::IsNullOrWhiteSpace($access_token_destination))

$usableAppIds = @()
foreach ($id in $application_id) {
    if (-not [string]::IsNullOrWhiteSpace($id)) {
        $usableAppIds += $id
    }
}

$usableAppKeys = @()
foreach ($key in $application_private_key) {
    if (-not [string]::IsNullOrWhiteSpace($key)) {
        $usableAppKeys += $key
    }
}

$tokenManager = $null
if ($usableAppIds.Count -gt 0 -and $usableAppKeys.Count -gt 0) {
    $tokenManager = Initialize-AppTokenManager -appIds $usableAppIds -privateKeys $usableAppKeys -organization $application_organization -apiUrl $resolvedApiUrl
    if ($tokenManager -and $tokenManager.Tokens.Count -gt 0) {
        try {
            $managerToken = Get-AppTokenManagerToken
            if (-not [string]::IsNullOrWhiteSpace($managerToken)) {
                $access_token = $managerToken
                $access_token_destination = $managerToken
                $shouldGenerateToken = $false
            }
        }
        catch {
            Write-Warning "Failed to retrieve GitHub App token from manager initialization: $($_.Exception.Message)"
        }
    }
}

$selectedAppId = if ($usableAppIds.Count -gt 0) { $usableAppIds[0] } else { $null }
$selectedPrivateKey = if ($usableAppKeys.Count -gt 0) { $usableAppKeys[0] } else { $null }

if ($shouldGenerateToken -and -not [string]::IsNullOrWhiteSpace($selectedAppId) -and -not [string]::IsNullOrWhiteSpace($selectedPrivateKey)) {
    try {
        $generatedToken = Get-TokenFromApp -appId $selectedAppId -pemKey $selectedPrivateKey -organization $application_organization -apiUrl $resolvedApiUrl
        if ([string]::IsNullOrWhiteSpace($generatedToken)) {
            Write-Error "Failed to generate GitHub App installation token."
        } else {
            if ([string]::IsNullOrWhiteSpace($access_token)) {
                $access_token = $generatedToken
            }
            if ([string]::IsNullOrWhiteSpace($access_token_destination)) {
                $access_token_destination = $generatedToken
            }
        }
    }
    catch {
        Write-Error "Error generating GitHub App token for update-forks-chunk.ps1: $($_)"
    }
}

Test-AccessTokens -accessToken $access_token -access_token_destination $access_token_destination -numberOfReposToDo $forkNames.Count

function UpdateForkedReposChunk {
    Param (
        $existingForks,
        $forkNamesToProcess,
        [int] $chunkId
    )

    Write-Message -message "# Chunk [$chunkId] - Mirror Sync" -logToSummary $true
    Write-Message -message "Processing [$(DisplayIntWithDots $forkNamesToProcess.Count)] mirrors in this chunk" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Create a hashtable for fast lookup
    $forksByName = @{}
    foreach ($fork in $existingForks) {
        $forksByName[$fork.name] = $fork
    }
    
    # Filter to only the forks we should process in this chunk
    $forksToProcess = @()
    foreach ($forkName in $forkNamesToProcess) {
        if ($forksByName.ContainsKey($forkName)) {
            $forksToProcess += $forksByName[$forkName]
        }
        else {
            Write-Warning "Fork [$forkName] not found in status, skipping"
        }
    }
    
    Write-Message -message "Found [$(DisplayIntWithDots $forksToProcess.Count)] forks to process" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    $i = 0
    $synced = 0
    $failed = 0
    $upToDate = 0
    $conflicts = 0
    $upstreamNotFound = 0
    $skipped = 0
    $failedReposList = @()

    foreach ($existingFork in $forksToProcess) {

        # Check if rate limit has been exceeded with long reset time
        if (Test-RateLimitExceeded) {
            Write-Warning "Rate limit exceeded with long reset time, stopping chunk processing"
            Write-Message -message "⚠️ Rate limit exceeded - stopping chunk [$chunkId] processing early" -logToSummary $true
            Write-Message -message "Processed [$(DisplayIntWithDots $i)] out of [$(DisplayIntWithDots $forksToProcess.Count)] forks before hitting rate limit" -logToSummary $true
            break
        }

        # Ensure default flags if missing
        if ($null -eq $existingFork.mirrorFound) {
            $existingFork | Add-Member -Name mirrorFound -Value $true -MemberType NoteProperty -Force
        }
        if ($null -eq $existingFork.upstreamFound) {
            $existingFork | Add-Member -Name upstreamFound -Value $true -MemberType NoteProperty -Force
        }

        # Skip repos when mirrorFound is false
        if ($existingFork.mirrorFound -eq $false) {
            Write-Debug "Mirror not found for [$($existingFork.name)], skipping"
            $skipped++
            continue
        }

        # Get the upstream owner and repo from the mirror name
        # Mirror name format: upstreamOwner_upstreamRepo
        ($upstreamOwner, $upstreamRepo) = GetOrgActionInfo -forkedOwnerRepo $existingFork.name
        
        if ([string]::IsNullOrEmpty($upstreamOwner) -or [string]::IsNullOrEmpty($upstreamRepo)) {
            Write-Warning "Could not parse upstream owner/repo from mirror name [$($existingFork.name)], skipping"
            $skipped++
            continue
        }

        Write-Host "$($i+1)/$($forksToProcess.Count) Syncing mirror [actions-marketplace-validations/$($existingFork.name)] with upstream [$upstreamOwner/$upstreamRepo]"
        
        $result = SyncMirrorWithUpstream -owner $forkOrg -repo $existingFork.name -upstreamOwner $upstreamOwner -upstreamRepo $upstreamRepo -access_token $access_token_destination
        
        if ($result.success) {
            # Update the sync timestamp for all successfully checked repos
            $existingFork | Add-Member -Name lastSynced -Value (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ") -MemberType NoteProperty -Force
            
            if ($result.message -like "*Already up to date*") {
                Write-Debug "Mirror [$($existingFork.name)] already up to date"
                $upToDate++
            }
            elseif ($result.merge_type -eq "force_update") {
                Write-Host "$i/$($forksToProcess.Count) Force updated mirror [$($existingFork.name)] (resolved merge conflict)"
                $synced++
            }
            else {
                Write-Host "$i/$($forksToProcess.Count) Successfully synced mirror [$($existingFork.name)]"
                $synced++
            }
            # Clear any previous sync errors on success
            if (Get-Member -InputObject $existingFork -Name "lastSyncError" -MemberType Properties) {
                $existingFork.lastSyncError = $null
            }
        }
        else {
            # Handle different error types
            $errorType = $result.error_type
            
            if ($errorType -eq "upstream_not_found") {
                Write-Warning "$($i+1)/$($forksToProcess.Count) Upstream repository not found for mirror [$($existingFork.name)] - marking as unavailable"
                $upstreamNotFound++
                # Mark the upstream as not found so we skip it in future runs
                $existingFork | Add-Member -Name upstreamAvailable -Value $false -MemberType NoteProperty -Force
                
                # Add to failed repos list
                $failedReposList += @{
                    name = $existingFork.name
                    errorType = $errorType
                    errorMessage = $result.message
                }
            }
            elseif ($errorType -eq "mirror_not_found") {
                    Write-Warning "$($i+1)/$($forksToProcess.Count) Mirror repository not found [$($existingFork.name)] - marking mirrorFound as false"
                    $existingFork.mirrorFound = $false
                $failed++
                
                # Add to failed repos list
                $failedReposList += @{
                    name = $existingFork.name
                    errorType = $errorType
                    errorMessage = $result.message
                }
            }
            elseif ($errorType -eq "merge_conflict" -or $result.message -like "*Merge conflict*") {
                Write-Warning "$($i+1)/$($forksToProcess.Count) Merge conflict detected for mirror [$($existingFork.name)]"
                $conflicts++
                
                # Add to failed repos list
                $failedReposList += @{
                    name = $existingFork.name
                    errorType = "merge_conflict"
                    errorMessage = $result.message
                }
            }
            elseif ($errorType -eq "auth_error") {
                Write-Warning "$($i+1)/$($forksToProcess.Count) Authentication error for mirror [$($existingFork.name)]: $($result.message)"
                $failed++
                
                # Add to failed repos list
                $failedReposList += @{
                    name = $existingFork.name
                    errorType = $errorType
                    errorMessage = $result.message
                }
            }
            elseif ($errorType -eq "git_reference_error" -or $errorType -eq "ambiguous_refspec") {
                Write-Warning "$($i+1)/$($forksToProcess.Count) Git reference error for mirror [$($existingFork.name)]: $($result.message)"
                $failed++
                
                # Add to failed repos list
                $failedReposList += @{
                    name = $existingFork.name
                    errorType = $errorType
                    errorMessage = $result.message
                }
            }
            else {
                Write-Warning "$($i+1)/$($forksToProcess.Count) Failed to sync mirror [$($existingFork.name)]: $($result.message)"
                $failed++
                
                # Add to failed repos list with descriptive error type for unclassified errors
                $failedReposList += @{
                    name = $existingFork.name
                    errorType = if ($errorType) { $errorType } else { "unspecified_error" }
                    errorMessage = $result.message
                }
            }
            
            # Track failed sync with error details
            $existingFork | Add-Member -Name lastSyncError -Value $result.message -MemberType NoteProperty -Force
            $existingFork | Add-Member -Name lastSyncErrorType -Value $errorType -MemberType NoteProperty -Force
            $existingFork | Add-Member -Name lastSyncAttempt -Value (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ") -MemberType NoteProperty -Force
        }
        
        $i++ | Out-Null
    }

    Write-Message -message "" -logToSummary $true
    Write-Message -message "## Chunk [$chunkId] - Mirror Sync Summary" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "| Status | Count |" -logToSummary $true
    Write-Message -message "|--------|------:|" -logToSummary $true
    Write-Message -message "| ✅ Synced | $synced |" -logToSummary $true
    Write-Message -message "| ✓ Up to Date | $upToDate |" -logToSummary $true
    Write-Message -message "| ⚠️ Conflicts | $conflicts |" -logToSummary $true
    Write-Message -message "| ❌ Upstream Not Found | $upstreamNotFound |" -logToSummary $true
    Write-Message -message "| ❌ Failed | $failed |" -logToSummary $true
    Write-Message -message "| ⏭️ Skipped | $skipped |" -logToSummary $true
    Write-Message -message "| **Total Processed** | **$i** |" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Return both processed forks and statistics
    return @{
        processedForks = $forksToProcess
        stats = @{
            synced = $synced
            upToDate = $upToDate
            conflicts = $conflicts
            upstreamNotFound = $upstreamNotFound
            failed = $failed
            skipped = $skipped
            totalProcessed = $i
        }
        failedRepos = $failedReposList
    }
}

Write-Message -message "Starting chunk [$chunkId] with [$(DisplayIntWithDots $forkNames.Count)] forks to process" -logToSummary $true

GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination

$result = UpdateForkedReposChunk -existingForks $actions -forkNamesToProcess $forkNames -chunkId $chunkId

# Save partial status update for this chunk
Save-PartialStatusUpdate -processedForks $result.processedForks -chunkId $chunkId -outputPath "status-partial-$chunkId.json"

# Save chunk summary statistics for consolidation
Save-ChunkSummary `
    -chunkId $chunkId `
    -synced $result.stats.synced `
    -upToDate $result.stats.upToDate `
    -conflicts $result.stats.conflicts `
    -upstreamNotFound $result.stats.upstreamNotFound `
    -failed $result.stats.failed `
    -skipped $result.stats.skipped `
    -totalProcessed $result.stats.totalProcessed `
    -failedRepos $result.failedRepos `
    -outputPath "chunk-summary-$chunkId.json"

GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination -waitForRateLimit $false

Write-Message -message "✓ Chunk [$chunkId] processing complete" -logToSummary $true

# Explicitly exit with success code to prevent PowerShell from propagating
# any non-zero exit codes from git or API commands
exit 0
