Param (
  $actions,
  $numberOfReposToDo = 100,
  $access_token = $env:GITHUB_TOKEN,
  $access_token_destination = $env:GITHUB_TOKEN
)

. $PSScriptRoot/library.ps1

Test-AccessTokens -accessToken $access_token -access_token_destination $access_token_destination -numberOfReposToDo $numberOfReposToDo

function UpdateForkedRepos {
    Param (
        $existingForks,
        [int] $numberOfReposToDo
    )

    Write-Message -message "Running mirror sync for [$($existingForks.Count)] mirrors" -logToSummary $true
    
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

            # Ensure default flags if missing
            if ($null -eq $existingFork.mirrorFound) {
                $existingFork | Add-Member -Name mirrorFound -Value $true -MemberType NoteProperty -Force
            }
            if ($null -eq $existingFork.upstreamFound) {
                $existingFork | Add-Member -Name upstreamFound -Value $true -MemberType NoteProperty -Force
            }

            # Skip repos that don't have mirrorFound property or where it's false
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

        Write-Host "$($i+1)/$max Syncing mirror [actions-marketplace-validations/$($existingFork.name)] with upstream [$upstreamOwner/$upstreamRepo]"
        
        $result = SyncMirrorWithUpstream -owner $forkOrg -repo $existingFork.name -upstreamOwner $upstreamOwner -upstreamRepo $upstreamRepo -access_token $access_token_destination
        
        if ($result.success) {
            if ($result.message -like "*Already up to date*") {
                Write-Debug "Mirror [$($existingFork.name)] already up to date"
                $upToDate++
            }
            else {
                Write-Host "$i/$max Successfully synced mirror [$($existingFork.name)]"
                $synced++
                # Update the sync timestamp
                $existingFork | Add-Member -Name lastSynced -Value (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ") -MemberType NoteProperty -Force
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
                Write-Warning "$i/$max Upstream repository not found for mirror [$($existingFork.name)] - marking as unavailable"
                $upstreamNotFound++
                # Mark the upstream as not found so we skip it in future runs
                $existingFork | Add-Member -Name upstreamAvailable -Value $false -MemberType NoteProperty -Force
            }
            elseif ($errorType -eq "mirror_not_found") {
                Write-Warning "$i/$max Mirror repository not found [$($existingFork.name)] - marking mirrorFound as false"
                $existingFork.mirrorFound = $false
                $failed++
            }
            elseif ($errorType -eq "merge_conflict" -or $result.message -like "*Merge conflict*") {
                Write-Warning "$i/$max Merge conflict detected for mirror [$($existingFork.name)]"
                $conflicts++
            }
            elseif ($errorType -eq "auth_error") {
                Write-Warning "$i/$max Authentication error for mirror [$($existingFork.name)]: $($result.message)"
                $failed++
            }
            elseif ($errorType -eq "git_reference_error" -or $errorType -eq "ambiguous_refspec") {
                Write-Warning "$i/$max Git reference error for mirror [$($existingFork.name)]: $($result.message)"
                $failed++
            }
            else {
                Write-Warning "$i/$max Failed to sync mirror [$($existingFork.name)]: $($result.message)"
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
        if ($_.lastSynced) {
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
    
    # Calculate percentages
    if ($reposWithMirrors -gt 0) {
        $percentChecked = [math]::Round(($reposSyncedLast7Days / $reposWithMirrors) * 100, 2)
        $percentRemaining = [math]::Round((($reposWithMirrors - $reposSyncedLast7Days) / $reposWithMirrors) * 100, 2)
    } else {
        $percentChecked = 0
        $percentRemaining = 0
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
    Write-Message -message "" -logToSummary $true
}

GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination
$existingForks = UpdateForkedRepos -existingForks $actions -numberOfReposToDo $numberOfReposToDo
ShowOverallDatasetStatistics -existingForks $existingForks
SaveStatus -existingForks $existingForks
GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination
