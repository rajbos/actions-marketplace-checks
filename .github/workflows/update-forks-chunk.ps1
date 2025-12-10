Param (
  $actions,
  $forkNames,  # Array of fork names to process in this chunk
  [int] $chunkId = 0,
  $access_token = $env:GITHUB_TOKEN,
  $access_token_destination = $env:GITHUB_TOKEN
)

. $PSScriptRoot/library.ps1

Test-AccessTokens -accessToken $access_token -access_token_destination $access_token_destination -numberOfReposToDo $forkNames.Count

function UpdateForkedReposChunk {
    Param (
        $existingForks,
        $forkNamesToProcess,
        [int] $chunkId
    )

    Write-Message -message "# Chunk [$chunkId] - Mirror Sync" -logToSummary $true
    Write-Message -message "Processing [$($forkNamesToProcess.Count)] mirrors in this chunk" -logToSummary $true
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
    
    Write-Message -message "Found [$($forksToProcess.Count)] forks to process" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    $i = 0
    $synced = 0
    $failed = 0
    $upToDate = 0
    $conflicts = 0
    $upstreamNotFound = 0
    $skipped = 0

    foreach ($existingFork in $forksToProcess) {

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
            }
            elseif ($errorType -eq "mirror_not_found") {
                    Write-Warning "$i/$($forksToProcess.Count) Mirror repository not found [$($existingFork.name)] - marking mirrorFound as false"
                    $existingFork.mirrorFound = $false
                $failed++
            }
            elseif ($errorType -eq "merge_conflict" -or $result.message -like "*Merge conflict*") {
                Write-Warning "$i/$($forksToProcess.Count) Merge conflict detected for mirror [$($existingFork.name)]"
                $conflicts++
            }
            elseif ($errorType -eq "auth_error") {
                Write-Warning "$i/$($forksToProcess.Count) Authentication error for mirror [$($existingFork.name)]: $($result.message)"
                $failed++
            }
            elseif ($errorType -eq "git_reference_error" -or $errorType -eq "ambiguous_refspec") {
                Write-Warning "$i/$($forksToProcess.Count) Git reference error for mirror [$($existingFork.name)]: $($result.message)"
                $failed++
            }
            else {
                Write-Warning "$i/$($forksToProcess.Count) Failed to sync mirror [$($existingFork.name)]: $($result.message)"
                $failed++
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
    
    return $forksToProcess
}

Write-Message -message "Starting chunk [$chunkId] with [$($forkNames.Count)] forks to process" -logToSummary $true

GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination

$processedForks = UpdateForkedReposChunk -existingForks $actions -forkNamesToProcess $forkNames -chunkId $chunkId

# Save partial status update for this chunk
Save-PartialStatusUpdate -processedForks $processedForks -chunkId $chunkId -outputPath "status-partial-$chunkId.json"

GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination

Write-Message -message "✓ Chunk [$chunkId] processing complete" -logToSummary $true

# Explicitly exit with success code to prevent PowerShell from propagating
# any non-zero exit codes from git or API commands
exit 0
