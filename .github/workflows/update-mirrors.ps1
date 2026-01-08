Param (
    $actions,
    $numberOfReposToDo = 100,
    $access_token = $env:GITHUB_TOKEN,
    $access_token_destination = $env:GITHUB_TOKEN
)

. $PSScriptRoot/library.ps1

Test-AccessTokens -accessToken $access_token -numberOfReposToDo $numberOfReposToDo

function UpdateForkedRepos {
    Param (
        $existingForks,
        [int] $numberOfReposToDo
    )

    Write-Message -message "Running mirror sync for [$(DisplayIntWithDots $existingForks.Count)] mirrors" -logToSummary $true
    
    $i = 0
    $max = $numberOfReposToDo
    $synced = 0
    $failed = 0
    $upToDate = 0
    $conflicts = 0
    $upstreamNotFound = 0
    $skipped = 0

    foreach ($existingFork in $existingForks) {

        if ($i -ge $max) {
            # do not run too long
            Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
            break
        }

            # Ensure default flags if missing (support hashtable or object)
            if ($null -eq $existingFork.mirrorFound) {
                if ($existingFork -is [hashtable]) { $existingFork["mirrorFound"] = $true }
                else { $existingFork | Add-Member -Name mirrorFound -Value $true -MemberType NoteProperty -Force }
            }
            if ($null -eq $existingFork.upstreamFound) {
                if ($existingFork -is [hashtable]) { $existingFork["upstreamFound"] = $true }
                else { $existingFork | Add-Member -Name upstreamFound -Value $true -MemberType NoteProperty -Force }
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

        Write-Host "$($i+1)/$max Syncing mirror [actions-marketplace-validations/$($existingFork.name)] with upstream [$upstreamOwner/$upstreamRepo]"
        
        $result = SyncMirrorWithUpstream -owner $forkOrg -repo $existingFork.name -upstreamOwner $upstreamOwner -upstreamRepo $upstreamRepo -access_token $access_token_destination
        
        # Normalize result for hashtable or object
        $resultSuccess = if ($result -is [hashtable]) { $result["success"] } else { $result.success }
        $resultMessage = if ($result -is [hashtable]) { $result["message"] } else { $result.message }
        $resultErrorType = if ($result -is [hashtable]) { $result["error_type"] } else { $result.error_type }
        $resultMergeType = if ($result -is [hashtable]) { $result["merge_type"] } else { $result.merge_type }

        if ($resultSuccess) {
            if ($resultMessage -like "*Already up to date*") {
                Write-Debug "Mirror [$($existingFork.name)] already up to date"
                $upToDate++
            }
            else {
                # Update the sync timestamp for any successful sync (merge or force update)
                if ($existingFork -is [hashtable]) { $existingFork["lastSynced"] = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ") }
                else { $existingFork | Add-Member -Name lastSynced -Value (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ") -MemberType NoteProperty -Force }
                
                if ($resultMergeType -eq "force_update") {
                    Write-Host "$i/$max Force updated mirror [$($existingFork.name)] (resolved merge conflict)"
                    $synced++
                }
                else {
                    Write-Host "$i/$max Successfully synced mirror [$($existingFork.name)]"
                    $synced++
                }
            }
            # Clear any previous sync errors on success
            if (Get-Member -InputObject $existingFork -Name "lastSyncError" -MemberType Properties) {
                if ($existingFork -is [hashtable]) { $existingFork["lastSyncError"] = $null }
                else { $existingFork.lastSyncError = $null }
            }
        }
        else {
            # Handle different error types
            $errorType = $resultErrorType
            
            if ($errorType -eq "upstream_not_found") {
                Write-Warning "$i/$max Upstream repository not found for mirror [$($existingFork.name)] - marking as unavailable"
                $upstreamNotFound++
                # Mark the upstream as not found so we skip it in future runs
                if ($existingFork -is [hashtable]) { $existingFork["upstreamAvailable"] = $false }
                else { $existingFork | Add-Member -Name upstreamAvailable -Value $false -MemberType NoteProperty -Force }
            }
            elseif ($errorType -eq "mirror_not_found") {
                Write-Warning "$i/$max Mirror repository not found [$($existingFork.name)] - attempting to create mirror and retry"
                # Attempt to create the missing mirror if upstream exists
                $createResult = $false
                try {
                    # Try to call ForkActionRepo - it may be mocked in tests or defined in functions.ps1
                    $createResult = ForkActionRepo -owner $upstreamOwner -repo $upstreamRepo
                }
                catch [System.Management.Automation.CommandNotFoundException] {
                    # ForkActionRepo not found - define a stub for test contexts
                    function script:ForkActionRepo {
                        Param (
                            $owner,
                            $repo
                        )
                        # Default stub for test contexts; returns false
                        return $false
                    }
                    # Retry the call with the stub
                    try {
                        $createResult = ForkActionRepo -owner $upstreamOwner -repo $upstreamRepo
                    }
                    catch {
                        Write-Warning "Error while creating mirror [$upstreamOwner/$upstreamRepo]: $($_.Exception.Message)"
                        $createResult = $false
                    }
                }
                catch {
                    Write-Warning "Error while creating mirror [$upstreamOwner/$upstreamRepo]: $($_.Exception.Message)"
                    $createResult = $false
                }

                if ($createResult) {
                    # Mark mirrorFound true and retry one sync
                    if ($existingFork -is [hashtable]) { $existingFork["mirrorFound"] = $true } else { $existingFork.mirrorFound = $true }
                    Write-Host "Created mirror [$forkOrg/$($existingFork.name)], retrying sync"
                    $retry = SyncMirrorWithUpstream -owner $forkOrg -repo $existingFork.name -upstreamOwner $upstreamOwner -upstreamRepo $upstreamRepo -access_token $access_token_destination
                    # Normalize retry result
                    $retrySuccess = if ($retry -is [hashtable]) { $retry["success"] } else { $retry.success }
                    $retryMessage = if ($retry -is [hashtable]) { $retry["message"] } else { $retry.message }
                    $retryErrorType = if ($retry -is [hashtable]) { $retry["error_type"] } else { $retry.error_type }
                    if ($retrySuccess) {
                        if ($retryMessage -like "*Already up to date*") { $upToDate++ } else { $synced++ }
                        if ($existingFork -is [hashtable]) { $existingFork["lastSynced"] = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ") } else { $existingFork | Add-Member -Name lastSynced -Value (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ") -MemberType NoteProperty -Force }
                        if (Get-Member -InputObject $existingFork -Name "lastSyncError" -MemberType Properties) { if ($existingFork -is [hashtable]) { $existingFork["lastSyncError"] = $null } else { $existingFork.lastSyncError = $null } }
                    }
                    else {
                        Write-Warning "Retry sync failed for [$($existingFork.name)]: $retryMessage"
                        $failed++
                        if ($existingFork -is [hashtable]) {
                            $existingFork["lastSyncError"] = $retryMessage
                            $existingFork["lastSyncErrorType"] = $retryErrorType
                            $existingFork["lastSyncAttempt"] = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
                        }
                        else {
                            $existingFork | Add-Member -Name lastSyncError -Value $retryMessage -MemberType NoteProperty -Force
                            $existingFork | Add-Member -Name lastSyncErrorType -Value $retryErrorType -MemberType NoteProperty -Force
                            $existingFork | Add-Member -Name lastSyncAttempt -Value (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ") -MemberType NoteProperty -Force
                        }
                    }
                }
                else {
                    Write-Warning "Could not create mirror for [$upstreamOwner/$upstreamRepo]; marking mirrorFound as false"
                    if ($existingFork -is [hashtable]) { $existingFork["mirrorFound"] = $false } else { $existingFork.mirrorFound = $false }
                    $failed++
                }
            }
            elseif ($errorType -eq "merge_conflict" -or $resultMessage -like "*Merge conflict*") {
                Write-Warning "$i/$max Merge conflict detected for mirror [$($existingFork.name)]"
                $conflicts++
            }
            elseif ($errorType -eq "auth_error") {
                Write-Warning "$i/$max Authentication error for mirror [$($existingFork.name)]: $resultMessage"
                $failed++
            }
            elseif ($errorType -eq "git_reference_error" -or $errorType -eq "ambiguous_refspec") {
                Write-Warning "$i/$max Git reference error for mirror [$($existingFork.name)]: $resultMessage"
                $failed++
            }
            else {
                Write-Warning "$i/$max Failed to sync mirror [$($existingFork.name)]: $resultMessage"
                $failed++
            }
            
            # Track failed sync with error details
            if ($existingFork -is [hashtable]) {
                $existingFork["lastSyncError"] = $resultMessage
                $existingFork["lastSyncErrorType"] = $errorType
                $existingFork["lastSyncAttempt"] = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
            }
            else {
                $existingFork | Add-Member -Name lastSyncError -Value $resultMessage -MemberType NoteProperty -Force
                $existingFork | Add-Member -Name lastSyncErrorType -Value $errorType -MemberType NoteProperty -Force
                $existingFork | Add-Member -Name lastSyncAttempt -Value (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ") -MemberType NoteProperty -Force
            }
        }
        
        $i++ | Out-Null
    }

    Write-Message -message "" -logToSummary $true
    Write-Message -message "## Mirror Sync Run Summary" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "### Current Run Statistics" -logToSummary $true
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
    
    return $existingForks
}

function ShowOverallDatasetStatistics {
    Param (
        $existingForks
    )
    
    Write-Message -message "" -logToSummary $true
    Write-Message -message "### Overall Dataset Statistics" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Calculate 7-day window
    $sevenDaysAgo = (Get-Date).AddDays(-7)
    
    # Total repos in dataset
    $totalRepos = $existingForks.Count
    
    # Count repos with mirrorFound = true (valid mirrors)
    $reposWithMirrors = ($existingForks | Where-Object { $_.mirrorFound -eq $true }).Count
    
    # Count repos synced in the last 7 days
    $reposSyncedLast7Days = ($existingForks | Where-Object { 
        if ($_.mirrorFound -eq $true -and $_.lastSynced) {
            try {
                $syncDate = [DateTime]::Parse($_.lastSynced)
                return $syncDate -gt $sevenDaysAgo
            } catch {
                Write-Debug "Failed to parse lastSynced date for repo: $($_.name)"
                return $false
            }
        }
        return $false
    }).Count
    
    # Count repos with valid mirrors but no lastSynced timestamp or unparseable timestamp
    $reposNeverSynced = ($existingForks | Where-Object { 
        if ($_.mirrorFound -eq $true) {
            if ([string]::IsNullOrEmpty($_.lastSynced)) {
                return $true
            }
            # Also count repos where lastSynced exists but cannot be parsed
            try {
                [DateTime]::Parse($_.lastSynced) | Out-Null
                return $false
            } catch {
                return $true
            }
        }
        return $false
    }).Count
    
    # Calculate percentages
    if ($reposWithMirrors -gt 0) {
        $percentChecked = [math]::Round(($reposSyncedLast7Days / $reposWithMirrors) * 100, 2)
        $percentRemaining = [math]::Round((($reposWithMirrors - $reposSyncedLast7Days) / $reposWithMirrors) * 100, 2)
        $percentNeverSynced = [math]::Round(($reposNeverSynced / $reposWithMirrors) * 100, 2)
    } else {
        $percentChecked = 0
        $percentRemaining = 0
        $percentNeverSynced = 0
    }
    
    $reposNotChecked = $reposWithMirrors - $reposSyncedLast7Days
    
    Write-Message -message "**Total Repositories in Dataset:** $totalRepos" -logToSummary $true
    Write-Message -message "**Repositories with Valid Mirrors:** $reposWithMirrors" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "#### Last 7 Days Activity" -logToSummary $true
    Write-Message -message "| Metric | Count | Percentage |" -logToSummary $true
    Write-Message -message "|--------|------:|-----------:|" -logToSummary $true
    Write-Message -message "| ✅ Repos Checked (Last 7 Days) | $reposSyncedLast7Days | ${percentChecked}% |" -logToSummary $true
    Write-Message -message "| ⏳ Repos Not Checked Yet | $reposNotChecked | ${percentRemaining}% |" -logToSummary $true
    Write-Message -message "| 🆕 Repos Never Checked | $reposNeverSynced | ${percentNeverSynced}% |" -logToSummary $true
    Write-Message -message "" -logToSummary $true
}

GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination
$existingForks = UpdateForkedRepos -existingForks $actions -numberOfReposToDo $numberOfReposToDo
ShowOverallDatasetStatistics -existingForks $existingForks
SaveStatus -existingForks $existingForks
GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination -waitForRateLimit $false
