Param (
  $numberOfReposToDo = 10,
  $access_token = $env:GITHUB_TOKEN,
  $owner = "actions-marketplace-validations",
  $dryRun = $true
)

. $PSScriptRoot/library.ps1

function GetReposToCleanup {
    Param (
        $statusFile
    )
    
    Write-Host "Loading status file from [$statusFile]"
    if (-not (Test-Path $statusFile)) {
        Write-Error "Status file not found at [$statusFile]"
        return @{
            repos = @()
            categories = @{
                upstreamMissingOnly = 0
                emptyOnly = 0
                bothUpstreamMissingAndEmpty = 0
                skippedUpstreamAvailable = 0
                invalidEntries = 0
            }
        }
    }
    
    $status = Get-Content $statusFile | ConvertFrom-Json
    Write-Host "Loaded [$($status.Count)] repos from status file"
    
    $reposToCleanup = New-Object System.Collections.ArrayList
    $validStatus = New-Object System.Collections.ArrayList
    $invalidEntries = New-Object System.Collections.ArrayList
    
    # Tracking distinct, non-overlapping categories for clearer reporting
    $countUpstreamMissingOnly = 0  # Upstream missing but not empty
    $countEmptyOnly = 0  # Empty but upstream exists
    $countBothUpstreamMissingAndEmpty = 0  # Both conditions met
    $countSkippedDueToUpstreamAvailable = 0  # Skipped: upstream exists but mirror missing
    
    foreach ($repo in $status) {
        # Detect invalid entries (owner null/empty or name '_' or empty)
        $isInvalid = ($null -eq $repo) -or ([string]::IsNullOrEmpty($repo.name)) -or ($repo.name -eq "_") -or ([string]::IsNullOrEmpty($repo.owner))
        if ($isInvalid) {
            $invalidEntries.Add($repo) | Out-Null
            # Skip further processing for invalid entries
            continue
        }
        $shouldCleanup = $false
        $reason = ""
        
        # If upstream exists but our mirror is missing, do NOT cleanup
        # Check both upstreamFound (set during initial discovery) and upstreamAvailable (set during sync failures)
        $upstreamStillExists = ($repo.upstreamFound -eq $true) -and ($repo.upstreamAvailable -ne $false)
        $mirrorMissing = ($null -eq $repo.mirrorFound -or $repo.mirrorFound -eq $false)
        if ($upstreamStillExists -and $mirrorMissing) {
            $countSkippedDueToUpstreamAvailable++
            Write-Debug "Skipping cleanup for [$($repo.name)] because upstream exists and mirror is missing, mirror should be created in another script/run"
            continue
        }
        
        # Determine cleanup criteria
        # Criterion 1: Original repo no longer exists 
        # Check both upstreamFound=false (from initial discovery) and upstreamAvailable=false (from sync failures)
        $upstreamMissing = ($repo.upstreamFound -eq $false -or $repo.upstreamAvailable -eq $false)
        
        # Criterion 2: Empty repo with no content (repoSize is 0 or null AND no tags/releases)
        $isEmpty = (($null -eq $repo.repoSize -or $repo.repoSize -eq 0) -and
                    ($null -eq $repo.tagInfo -or $repo.tagInfo.Count -eq 0) -and
                    ($null -eq $repo.releaseInfo -or $repo.releaseInfo.Count -eq 0))
        
        # Categorize for distinct reporting
        if ($upstreamMissing -and $isEmpty) {
            $shouldCleanup = $true
            $reason = "Original repo no longer exists (upstreamFound=$($repo.upstreamFound), upstreamAvailable=$($repo.upstreamAvailable)) AND Empty repo with no content (size=$($repo.repoSize), no tags/releases)"
            $countBothUpstreamMissingAndEmpty++
        }
        elseif ($upstreamMissing) {
            $shouldCleanup = $true
            $reason = "Original repo no longer exists (upstreamFound=$($repo.upstreamFound), upstreamAvailable=$($repo.upstreamAvailable))"
            $countUpstreamMissingOnly++
        }
        elseif ($isEmpty) {
            $shouldCleanup = $true
            $reason = "Empty repo with no content (size=$($repo.repoSize), no tags/releases)"
            $countEmptyOnly++
        }
        
        if ($shouldCleanup) {
            # Derive upstream full name from our mirror repo name in form owner_reponame
            $upstreamFullName = $null
            if ($repo.name -and ($repo.name -match '_')) {
                $firstUnderscoreIndex = $repo.name.IndexOf('_')
                if ($firstUnderscoreIndex -gt 0 -and $firstUnderscoreIndex -lt ($repo.name.Length - 1)) {
                    $upOwner = $repo.name.Substring(0, $firstUnderscoreIndex)
                    $upName = $repo.name.Substring($firstUnderscoreIndex + 1)
                    $upstreamFullName = "$upOwner/$upName"
                }
            }

            $reposToCleanup.Add(@{
                name = $repo.name
                owner = $repo.owner
                reason = $reason
                upstreamFullName = $upstreamFullName
            }) | Out-Null
            # Do not add to valid list; will be removed separately via RemoveReposFromStatus
        }
        else {
            # Keep valid and not-to-clean entries
            $validStatus.Add($repo) | Out-Null
        }
    }
    
    # Calculate total eligible for cleanup
    $totalEligibleForCleanup = $countUpstreamMissingOnly + $countEmptyOnly + $countBothUpstreamMissingAndEmpty
    
    Write-Host "Found [$($reposToCleanup.Count)] repos to cleanup"
    Write-Host ""
    Write-Host "Breakdown of repo statuses:"
    Write-Host "  Cleanup Categories:"
    Write-Host "    - Upstream missing (has content): [$countUpstreamMissingOnly]"
    Write-Host "    - Empty (upstream exists): [$countEmptyOnly]"
    Write-Host "    - Both upstream missing AND empty: [$countBothUpstreamMissingAndEmpty]"
    Write-Host "    = Total eligible for cleanup: [$totalEligibleForCleanup]"
    Write-Host ""
    Write-Host "  Skipped (not eligible for cleanup):"
    Write-Host "    - Upstream available, mirror missing (will be created): [$countSkippedDueToUpstreamAvailable]"
    if ($invalidEntries.Count -gt 0) {
        Write-Host "    - Invalid entries (removed from status): [$($invalidEntries.Count)]"
        # Overwrite status file once with valid entries + entries to be cleaned (so they remain until deletion completes)
        $validCombined = @()
        $validCombined += $validStatus
        # Include cleanup candidates so they still exist for deletion process; they will be removed later if dryRun is false
        $validCombined += $reposToCleanup | ForEach-Object { $_ }
        $validCombined | ConvertTo-Json -Depth 10 | Out-File -FilePath $statusFile -Encoding UTF8
        if ($env:BLOB_SAS_TOKEN) {
            try { Set-StatusToBlobStorage -sasToken $env:BLOB_SAS_TOKEN } catch { }
        }
    }
    Write-Host "" # empty line for readability
    
    # Return both repos and category counts
    return @{
        repos = $reposToCleanup
        categories = @{
            upstreamMissingOnly = $countUpstreamMissingOnly
            emptyOnly = $countEmptyOnly
            bothUpstreamMissingAndEmpty = $countBothUpstreamMissingAndEmpty
            skippedUpstreamAvailable = $countSkippedDueToUpstreamAvailable
            invalidEntries = $invalidEntries.Count
        }
    }
}

function RemoveRepos {
    Param (
        $repos,
        $owner,
        $dryRun,
        $maxCount
    )

    $i = 1
    $repoCount = $repos.Count
    $deletedCount = 0
    
    if ($dryRun) {
        Write-Host "DRY RUN MODE - No repos will be actually deleted"
        Write-Host ""
    }
    
    foreach ($repo in $repos) 
    {
        if ($maxCount -and $deletedCount -ge $maxCount) {
            break
        }
        $repoName = $repo.name
        Write-Host "$($i)/$($repoCount) Would delete repo [$($owner)/$($repoName)]"
        Write-Host "  Reason: $($repo.reason)"
        
        if (-not $dryRun) {
            $url = "/repos/$owner/$repoName"
            try {
                ApiCall -method DELETE -url $url -access_token $access_token
                Write-Host "  Successfully deleted [$owner/$repoName]"
                $deletedCount++
            }
            catch {
                Write-Host "  Error deleting [$owner/$repoName]: $($_.Exception.Message)"
            }
        }
        else {
            # In dry run, we still count towards the max to simulate selection of X repos to cleanup
            $deletedCount++
        }
        
        $i++
    }

    Write-Host "Processed [$deletedCount] repos (limit: [$maxCount])"
    
    return $deletedCount
}

function RemoveReposFromStatus {
    Param (
        $repos,
        $statusFile
    )
    
    Write-Host "Removing [$($repos.Count)] repos from status file"
    
    if (-not (Test-Path $statusFile)) {
        Write-Error "Status file not found at [$statusFile]"
        return
    }
    
    $status = Get-Content $statusFile | ConvertFrom-Json
    $repoNamesToRemove = $repos | ForEach-Object { $_.name }
    
    # Filter out the repos to cleanup
    $updatedStatus = $status | Where-Object { $repoNamesToRemove -notcontains $_.name }
    
    Write-Host "Status file updated: [$($status.Count)] repos -> [$($updatedStatus.Count)] repos"
    
    # Save the updated status
    $updatedStatus | ConvertTo-Json -Depth 10 | Out-File -FilePath $statusFile -Encoding UTF8
    Write-Host "Status file saved to [$statusFile]"
}

# Main execution
Write-Host "Cleanup Invalid Repos Script"
Write-Host "=============================="
Write-Host "Owner: [$owner]"
Write-Host "Number of repos to cleanup: [$numberOfReposToDo]"
Write-Host "Dry run: [$dryRun]"
Write-Host ""

if ($access_token) {
    try {
        GetRateLimitInfo -access_token $access_token
    }
    catch {
        Write-Host "Warning: Could not get rate limit info: $($_.Exception.Message)"
    }
}

# Get repos to cleanup from status file
$cleanupResult = GetReposToCleanup -statusFile $statusFile
$reposToCleanup = $cleanupResult.repos
$categories = $cleanupResult.categories

# Display summary
Write-Host ""
Write-Host "Summary of repos to cleanup:"
Write-Host "=============================="
foreach ($repo in $reposToCleanup) {
    Write-Host "  - $($repo.name): $($repo.reason)"
}
Write-Host ""

# Write summary to GitHub Step Summary
Write-Message -message "" -logToSummary $true
Write-Message -message "## Cleanup Summary" -logToSummary $true
Write-Message -message "Owner: [$owner]" -logToSummary $true
Write-Message -message "Number of repos to process (max): [$numberOfReposToDo]" -logToSummary $true
Write-Message -message "Dry run: [$dryRun]" -logToSummary $true
Write-Message -message "" -logToSummary $true

# Calculate totals for the summary table
$totalEligibleForCleanup = $categories.upstreamMissingOnly + $categories.emptyOnly + $categories.bothUpstreamMissingAndEmpty

Write-Message -message "### Repository Status Breakdown" -logToSummary $true
Write-Message -message "" -logToSummary $true
Write-Message -message "| Category | Count | Description |" -logToSummary $true
Write-Message -message "|----------|------:|-------------|" -logToSummary $true
Write-Message -message "| **Eligible for Cleanup** | **$totalEligibleForCleanup** | **Total repos that can be cleaned up** |" -logToSummary $true
Write-Message -message "| → Upstream missing (has content) | $($categories.upstreamMissingOnly) | Upstream repo deleted, our mirror has content |" -logToSummary $true
Write-Message -message "| → Empty repo (upstream exists) | $($categories.emptyOnly) | Empty mirror, upstream still available |" -logToSummary $true
Write-Message -message "| → Both upstream missing & empty | $($categories.bothUpstreamMissingAndEmpty) | Upstream deleted and mirror is empty |" -logToSummary $true
Write-Message -message "| | | |" -logToSummary $true
Write-Message -message "| **Not Eligible for Cleanup** | **$($categories.skippedUpstreamAvailable)** | **Skipped - will be processed by other workflows** |" -logToSummary $true
Write-Message -message "| → Mirror missing (upstream exists) | $($categories.skippedUpstreamAvailable) | Upstream available, mirror will be created |" -logToSummary $true
if ($categories.invalidEntries -gt 0) {
    Write-Message -message "| → Invalid entries | $($categories.invalidEntries) | Removed from status file |" -logToSummary $true
}
Write-Message -message "" -logToSummary $true

if ($reposToCleanup.Count -gt 0) {
    Write-Message -message "" -logToSummary $true
    Write-Message -message "### Repos to Clean Up (showing first 15 of $($reposToCleanup.Count))" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "| # | Our repo | Upstream | Reason |" -logToSummary $true
    Write-Message -message "|---:|---------|----------|--------|" -logToSummary $true
    $index = 1
    foreach ($repo in ($reposToCleanup | Select-Object -First 15)) {
        $repoLink = "https://github.com/$owner/$($repo.name)"
        $repoCell = "[$($repo.name)]($repoLink)"
        $upstreamCell = "n/a"
        if ($repo.upstreamFullName) {
            $upstreamLink = "https://github.com/$($repo.upstreamFullName)"
            $upstreamCell = "[$($repo.upstreamFullName)]($upstreamLink)"
        }
        Write-Message -message "| $index | $repoCell | $upstreamCell | $($repo.reason) |" -logToSummary $true
        $index++
    }
    Write-Message -message "" -logToSummary $true
}

# Remove the repos
$totalCleaned = 0
if ($reposToCleanup.Count -gt 0) {
    $totalCleaned = RemoveRepos -repos $reposToCleanup -owner $owner -dryRun $dryRun -maxCount $numberOfReposToDo
    
    if (-not $dryRun) {
        # Update status file to remove deleted repos
        # Only remove up to numberOfReposToDo from status
        $reposRemoved = $reposToCleanup | Select-Object -First $numberOfReposToDo
        RemoveReposFromStatus -repos $reposRemoved -statusFile $statusFile
    }
}
else {
    Write-Host "No repos found to cleanup"
}

# Add total cleaned to step summary
Write-Message -message "" -logToSummary $true
Write-Message -message "**Total repos cleaned: $totalCleaned**" -logToSummary $true
Write-Message -message "" -logToSummary $true

if ($access_token) {
    try {
        GetRateLimitInfo -access_token $access_token
    }
    catch {
        Write-Host "Warning: Could not get rate limit info: $($_.Exception.Message)"
    }
}
