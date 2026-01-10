Param (
  $actions,
  $forkNames,  # Array of fork names to process in this chunk
  [int] $chunkId = 0,
  $access_token = $env:GITHUB_TOKEN,
  $access_token_destination = $env:GITHUB_TOKEN,
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
    # Share the token manager instance with library.ps1 so ApiCall can
    # coordinate app switching and failover across all requests in this chunk.
    $script:GitHubAppTokenManagerInstance = $tokenManager
    $tokenResult = $tokenManager.GetTokenForOrganization($appOrganization)

    $access_token = $tokenResult.Token
    $access_token_destination = $tokenResult.Token
}

Test-AccessTokens -accessToken $access_token -numberOfReposToDo $forkNames.Count

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
    $mirrorsCreated = 0
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

        # Don't skip repos with mirrorFound=false - let them proceed to recovery logic
        # The sync attempt will detect mirror_not_found and attempt to create it

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
                Write-Warning "$i/$($forksToProcess.Count) Upstream repository not found for mirror [$($existingFork.name)] - marking as unavailable"
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
                Write-Warning "$i/$($forksToProcess.Count) Mirror repository not found [$($existingFork.name)] - attempting to create mirror and retry"
                # Attempt to create the missing mirror if upstream exists
                $createResult = $false
                $createErrorMessage = $null
                try {
                    # Source functions.ps1 to get ForkActionRepo function
                    if (-not (Get-Command ForkActionRepo -ErrorAction SilentlyContinue)) {
                        . $PSScriptRoot/functions.ps1
                    }
                    $createResult = ForkActionRepo -owner $upstreamOwner -repo $upstreamRepo
                }
                catch {
                    $createErrorMessage = $_.Exception.Message
                    Write-Warning "Error while creating mirror [$upstreamOwner/$upstreamRepo]: $createErrorMessage"
                    $createResult = $false
                }

                if ($createResult) {
                    # Mark mirrorFound true and retry one sync
                    $mirrorsCreated++
                    $existingFork.mirrorFound = $true
                    Write-Host "Created mirror [$forkOrg/$($existingFork.name)], retrying sync"
                    $retry = SyncMirrorWithUpstream -owner $forkOrg -repo $existingFork.name -upstreamOwner $upstreamOwner -upstreamRepo $upstreamRepo -access_token $access_token_destination
                    if ($retry.success) {
                        Write-Host "Successfully synced newly created mirror [$($existingFork.name)]"
                        $synced++
                        $existingFork | Add-Member -Name lastSynced -Value (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ") -MemberType NoteProperty -Force
                    }
                    else {
                        Write-Warning "Failed to sync newly created mirror [$($existingFork.name)]: $($retry.message)"
                        $failed++
                        $existingFork | Add-Member -Name lastSyncError -Value $retry.message -MemberType NoteProperty -Force
                        $existingFork | Add-Member -Name lastSyncErrorType -Value $retry.error_type -MemberType NoteProperty -Force
                        $existingFork | Add-Member -Name lastSyncAttempt -Value (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ") -MemberType NoteProperty -Force
                        
                        # Add to failed repos list
                        $failedReposList += @{
                            name = $existingFork.name
                            errorType = $retry.error_type
                            errorMessage = $retry.message
                        }
                    }
                }
                else {
                    $createErrorMessage = if ($createErrorMessage) { $createErrorMessage } else { $result.message }
                    Write-Warning "Could not create mirror for [$upstreamOwner/$upstreamRepo]; marking mirrorFound as false. Error: $createErrorMessage"
                    $existingFork.mirrorFound = $false
                    $failed++
                    
                    # Add to failed repos list
                    $failedReposList += @{
                        name = $existingFork.name
                        errorType = "mirror_create_failed"
                        errorMessage = $createErrorMessage
                    }

                    $existingFork | Add-Member -Name lastSyncError -Value $createErrorMessage -MemberType NoteProperty -Force
                    $existingFork | Add-Member -Name lastSyncErrorType -Value "mirror_create_failed" -MemberType NoteProperty -Force
                    $existingFork | Add-Member -Name lastSyncAttempt -Value (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ") -MemberType NoteProperty -Force
                }
            }
            elseif ($errorType -eq "merge_conflict" -or $result.message -like "*Merge conflict*") {
                Write-Warning "$i/$($forksToProcess.Count) Merge conflict detected for mirror [$($existingFork.name)]"
                $conflicts++
                
                # Add to failed repos list
                $failedReposList += @{
                    name = $existingFork.name
                    errorType = "merge_conflict"
                    errorMessage = $result.message
                }
            }
            elseif ($errorType -eq "auth_error") {
                Write-Warning "$i/$($forksToProcess.Count) Authentication error for mirror [$($existingFork.name)]: $($result.message)"
                $failed++
                
                # Add to failed repos list
                $failedReposList += @{
                    name = $existingFork.name
                    errorType = $errorType
                    errorMessage = $result.message
                }
            }
            elseif ($errorType -eq "git_reference_error" -or $errorType -eq "ambiguous_refspec") {
                Write-Warning "$i/$($forksToProcess.Count) Git reference error for mirror [$($existingFork.name)]: $($result.message)"
                $failed++
                
                # Add to failed repos list
                $failedReposList += @{
                    name = $existingFork.name
                    errorType = $errorType
                    errorMessage = $result.message
                }
            }
            else {
                Write-Warning "$i/$($forksToProcess.Count) Failed to sync mirror [$($existingFork.name)]: $($result.message)"
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
    Write-Message -message "| 🆕 Mirrors Created | $mirrorsCreated |" -logToSummary $true
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
            mirrorsCreated = $mirrorsCreated
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
    -mirrorsCreated $result.stats.mirrorsCreated `
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
