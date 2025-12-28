Param (
  $numberOfReposToDo = 10,
  $access_token = $env:GITHUB_TOKEN,
  $owner = "actions-marketplace-validations",
  $dryRun = $true
)

. $PSScriptRoot/library.ps1

# Constants
$MaxDisplayReposToCleanup = 15  # Maximum number of repos to display in "to cleanup" list
$MaxDisplayReposCleaned = 10    # Maximum number of repos to display in "cleaned" and "invalid" lists

function Test-RepoExists {
    Param (
        $repoOwner,
        $repoName,
        $access_token
    )
    
    try {
        $url = "/repos/$repoOwner/$repoName"
        $result = ApiCall -method GET -url $url -access_token $access_token -hideFailedCall $true
        if ($result.Error) {
            return $false
        }
        return $true
    }
    catch {
        return $false
    }
}

function GetReposToCleanup {
    Param (
        $statusFile,
        $access_token = $null,
        $mirrorOwner = "actions-marketplace-validations"
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
                totalEligible = 0
                skippedUpstreamAvailable = 0
                invalidEntries = 0
            }
            fileSize = 0
        }
    }
    
    # Get file size before processing
    $fileInfo = Get-Item $statusFile
    $fileSizeBytes = $fileInfo.Length
    
    $status = Get-Content $statusFile | ConvertFrom-Json
    Write-Host "Loaded [$($status.Count)] repos from status file"
    
    $reposToCleanup = New-Object System.Collections.ArrayList
    $validStatus = New-Object System.Collections.ArrayList
    $invalidEntries = New-Object System.Collections.ArrayList
    $ownerFixed = $false  # Track if any owners were fixed
    
    # Tracking distinct, non-overlapping categories for clearer reporting
    $countUpstreamMissingOnly = 0  # Upstream missing but not empty
    $countEmptyOnly = 0  # Empty but upstream exists
    $countBothUpstreamMissingAndEmpty = 0  # Both conditions met
    $countSkippedDueToUpstreamAvailable = 0  # Skipped: upstream exists but mirror missing
    $countSkippedDueToMirrorExists = 0  # Skipped: mirror exists AND upstream exists
    
    foreach ($repo in $status) {
        # Detect invalid entries (owner null/empty or name '_' or empty)
        $isInvalid = ($null -eq $repo) -or ([string]::IsNullOrEmpty($repo.name)) -or ($repo.name -eq "_")
        
        # Special handling for null/empty owner - extract from repo name (format: owner_repo)
        if (-not $isInvalid -and [string]::IsNullOrEmpty($repo.owner)) {
            # Extract owner from repo name using the pattern owner_repo
            if ($repo.name -match '^([^_]+)_') {
                $extractedOwner = $matches[1]
                Write-Host "Fixing repo with null/empty owner: [$($repo.name)] -> owner: [$extractedOwner]"
                $repo.owner = $extractedOwner
                $ownerFixed = $true
                $isInvalid = $false
            }
            else {
                # If we can't extract owner from name, verify if repo exists in mirror org
                if ($access_token -and -not [string]::IsNullOrEmpty($repo.name)) {
                    Write-Host "Validating repo with null/empty owner (no underscore pattern): [$($repo.name)]"
                    $repoExists = Test-RepoExists -repoOwner $mirrorOwner -repoName $repo.name -access_token $access_token
                    if ($repoExists) {
                        Write-Host "  Repo exists in GitHub, fixing owner to [$mirrorOwner]"
                        # Fix the owner field
                        $repo.owner = $mirrorOwner
                        $ownerFixed = $true
                        $isInvalid = $false
                    }
                    else {
                        Write-Host "  Repo does not exist in GitHub, marking as invalid"
                        $isInvalid = $true
                    }
                }
                else {
                    # No access token or no name, mark as invalid
                    $isInvalid = $true
                }
            }
        }
        
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
        
        # If mirror exists AND upstream still exists, do NOT cleanup
        # The mirror might have content not reflected in repoSize/tags/releases metrics
        # and will be filled/synced by other workflows
        if ($repo.mirrorFound -eq $true -and $upstreamStillExists) {
            $countSkippedDueToMirrorExists++
            Write-Debug "Skipping cleanup for [$($repo.name)] because mirror exists and upstream still exists"
            continue
        }
        
        # Determine cleanup criteria
        # Criterion 1: Original repo no longer exists 
        # Check both upstreamFound=false (from initial discovery) and upstreamAvailable=false (from sync failures)
        $upstreamMissing = ($repo.upstreamFound -eq $false -or $repo.upstreamAvailable -eq $false)
        
        # Criterion 2: Empty repo with no content (repoSize is 0 or null AND no tags/releases)
        # (Note: mirrorFound = true cases are already filtered out above)
        $isEmpty = (($null -eq $repo.repoSize -or $repo.repoSize -eq 0) -and
                    ($null -eq $repo.tagInfo -or $repo.tagInfo.Count -eq 0) -and
                    ($null -eq $repo.releaseInfo -or $repo.releaseInfo.Count -eq 0))
        
        # Categorize for distinct reporting
        # Only cleanup if upstream is missing (deleted/unavailable)
        # Do NOT cleanup empty repos if upstream still exists - they should be synced by other workflows
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
        # Removed: elseif ($isEmpty) - We should NOT cleanup empty repos if upstream still exists
        
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
    Write-Host "    - Mirror and upstream both exist (will be synced): [$countSkippedDueToMirrorExists]"
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
    elseif ($ownerFixed) {
        Write-Host "    - Fixed owner field for repos with null/empty owner"
        # Save status file with fixed owners
        $validCombined = @()
        $validCombined += $validStatus
        # Include cleanup candidates so they still exist for deletion process
        $validCombined += $reposToCleanup | ForEach-Object { $_ }
        $validCombined | ConvertTo-Json -Depth 10 | Out-File -FilePath $statusFile -Encoding UTF8
        if ($env:BLOB_SAS_TOKEN) {
            try { Set-StatusToBlobStorage -sasToken $env:BLOB_SAS_TOKEN } catch { }
        }
    }
    Write-Host "" # empty line for readability
    
    # Return both repos and category counts (including total for convenience)
    return @{
        repos = $reposToCleanup
        invalidEntries = $invalidEntries
        categories = @{
            upstreamMissingOnly = $countUpstreamMissingOnly
            emptyOnly = $countEmptyOnly
            bothUpstreamMissingAndEmpty = $countBothUpstreamMissingAndEmpty
            totalEligible = $totalEligibleForCleanup
            skippedUpstreamAvailable = $countSkippedDueToUpstreamAvailable
            skippedMirrorExists = $countSkippedDueToMirrorExists
            invalidEntries = $invalidEntries.Count
            originalStatusCount = $status.Count
        }
        fileSize = $fileSizeBytes
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
    $cleanedRepos = New-Object System.Collections.ArrayList
    
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
                $cleanedRepos.Add($repo) | Out-Null
                $deletedCount++
            }
            catch {
                Write-Host "  Error deleting [$owner/$repoName]: $($_.Exception.Message)"
            }
        }
        else {
            # In dry run, we still count towards the max to simulate selection of X repos to cleanup
            $cleanedRepos.Add($repo) | Out-Null
            $deletedCount++
        }
        
        $i++
    }

    Write-Host "Processed [$deletedCount] repos (limit: [$maxCount])"
    
    return @{
        count = $deletedCount
        repos = $cleanedRepos
    }
}

function RemoveReposFromStatus {
    Param (
        $repos,
        $statusFile
    )
    
    Write-Host "Removing [$($repos.Count)] repos from status file"
    
    if (-not (Test-Path $statusFile)) {
        Write-Error "Status file not found at [$statusFile]"
        return 0
    }
    
    $status = Get-Content $statusFile | ConvertFrom-Json
    $repoNamesToRemove = $repos | ForEach-Object { $_.name }
    
    # Filter out the repos to cleanup
    $updatedStatus = $status | Where-Object { $repoNamesToRemove -notcontains $_.name }
    
    $removedCount = $status.Count - $updatedStatus.Count
    Write-Host "Status file updated: [$($status.Count)] repos -> [$($updatedStatus.Count)] repos (removed $removedCount actions)"
    
    # Save the updated status
    $updatedStatus | ConvertTo-Json -Depth 10 | Out-File -FilePath $statusFile -Encoding UTF8
    Write-Host "Status file saved to [$statusFile]"
    
    return $removedCount
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
$cleanupResult = GetReposToCleanup -statusFile $statusFile -access_token $access_token -mirrorOwner $owner
$reposToCleanup = $cleanupResult.repos
$invalidEntries = $cleanupResult.invalidEntries
$categories = $cleanupResult.categories
$statusFileSize = $cleanupResult.fileSize

# Format file size for display
$fileSizeFormatted = if ($statusFileSize -ge 1MB) {
    "{0:N2} MB" -f ($statusFileSize / 1MB)
} elseif ($statusFileSize -ge 1KB) {
    "{0:N2} KB" -f ($statusFileSize / 1KB)
} else {
    "$statusFileSize bytes"
}

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
Write-Message -message "" -logToSummary $true
Write-Message -message "### Status File Information" -logToSummary $true
Write-Message -message "**Downloaded status.json:**" -logToSummary $true
Write-Message -message "- Total repos in file: **$("{0:N0}" -f $categories.originalStatusCount)**" -logToSummary $true
Write-Message -message "- File size: **$fileSizeFormatted**" -logToSummary $true
Write-Message -message "" -logToSummary $true
Write-Message -message "### Execution Parameters" -logToSummary $true
Write-Message -message "Owner: [$owner]" -logToSummary $true
Write-Message -message "Number of repos to process (max): [$numberOfReposToDo]" -logToSummary $true
Write-Message -message "Dry run: [$dryRun]" -logToSummary $true
Write-Message -message "" -logToSummary $true

Write-Message -message "### Repository Status Breakdown" -logToSummary $true
Write-Message -message "" -logToSummary $true
Write-Message -message "| Category | Count | Description |" -logToSummary $true
Write-Message -message "|----------|------:|-------------|" -logToSummary $true
Write-Message -message "| **Eligible for Cleanup** | **$($categories.totalEligible)** | **Total repos that can be cleaned up** |" -logToSummary $true
Write-Message -message "| → Upstream missing (has content) | $($categories.upstreamMissingOnly) | Upstream repo deleted, our mirror has content |" -logToSummary $true
Write-Message -message "| → Both upstream missing & empty | $($categories.bothUpstreamMissingAndEmpty) | Upstream deleted and mirror is empty |" -logToSummary $true
Write-Message -message "| | | |" -logToSummary $true
$totalSkipped = $categories.skippedUpstreamAvailable + $categories.skippedMirrorExists
Write-Message -message "| **Not Eligible for Cleanup** | **$totalSkipped** | **Skipped - will be processed by other workflows** |" -logToSummary $true
Write-Message -message "| → Mirror missing (upstream exists) | $($categories.skippedUpstreamAvailable) | Upstream available, mirror will be created |" -logToSummary $true
Write-Message -message "| → Mirror and upstream both exist | $($categories.skippedMirrorExists) | Mirror and upstream exist, will be synced |" -logToSummary $true
if ($categories.invalidEntries -gt 0) {
    $afterCount = $categories.originalStatusCount - $categories.invalidEntries
    Write-Message -message "| → Invalid entries | $($categories.invalidEntries) | $($categories.originalStatusCount) → $afterCount actions (removed $($categories.invalidEntries)) |" -logToSummary $true
}
Write-Message -message "" -logToSummary $true

# Show first N invalid entries if any
if ($invalidEntries.Count -gt 0) {
    $displayInvalidCount = [Math]::Min($MaxDisplayReposCleaned, $invalidEntries.Count)
    Write-Message -message "" -logToSummary $true
    Write-Message -message "<details>" -logToSummary $true
    Write-Message -message "<summary>Invalid Entries Removed (showing first $displayInvalidCount of $($invalidEntries.Count))</summary>" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "| # | Name | Owner | Reason | Link |" -logToSummary $true
    Write-Message -message "|---:|------|-------|--------|------|" -logToSummary $true
    $index = 1
    foreach ($entry in ($invalidEntries | Select-Object -First $MaxDisplayReposCleaned)) {
        $name = if ([string]::IsNullOrEmpty($entry.name)) { "(empty)" } else { $entry.name }
        $owner = if ([string]::IsNullOrEmpty($entry.owner)) { "(empty)" } else { $entry.owner }
        $reason = ""
        if ($null -eq $entry) {
            $reason = "Null entry"
        }
        elseif ([string]::IsNullOrEmpty($entry.name)) {
            $reason = "Name is null or empty"
        }
        elseif ($entry.name -eq "_") {
            $reason = "Name is '_'"
        }
        elseif ([string]::IsNullOrEmpty($entry.owner)) {
            $reason = "Owner is null or empty"
        }
        
        # Create clickable link if we have valid owner and name
        $link = "N/A"
        if (-not [string]::IsNullOrEmpty($entry.owner) -and -not [string]::IsNullOrEmpty($entry.name) -and $entry.name -ne "_") {
            $repoUrl = "https://github.com/$($entry.owner)/$($entry.name)"
            $link = "[$($entry.owner)/$($entry.name)]($repoUrl)"
        }
        
        Write-Message -message "| $index | $name | $owner | $reason | $link |" -logToSummary $true
        $index++
    }
    Write-Message -message "" -logToSummary $true
    Write-Message -message "</details>" -logToSummary $true
    Write-Message -message "" -logToSummary $true
}

if ($reposToCleanup.Count -gt 0) {
    $displayToCleanupCount = [Math]::Min($MaxDisplayReposToCleanup, $reposToCleanup.Count)
    Write-Message -message "" -logToSummary $true
    Write-Message -message "<details>" -logToSummary $true
    Write-Message -message "<summary>Repos to Clean Up (showing first $displayToCleanupCount of $($reposToCleanup.Count))</summary>" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "| # | Our repo | Upstream | Reason |" -logToSummary $true
    Write-Message -message "|---:|---------|----------|--------|" -logToSummary $true
    $index = 1
    foreach ($repo in ($reposToCleanup | Select-Object -First $MaxDisplayReposToCleanup)) {
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
    Write-Message -message "</details>" -logToSummary $true
    Write-Message -message "" -logToSummary $true
}

# Remove the repos
$totalCleaned = 0
$totalRemovedFromStatus = 0
$cleanedRepos = @()
if ($reposToCleanup.Count -gt 0) {
    $cleanupResult = RemoveRepos -repos $reposToCleanup -owner $owner -dryRun $dryRun -maxCount $numberOfReposToDo
    $totalCleaned = $cleanupResult.count
    $cleanedRepos = $cleanupResult.repos
    
    if (-not $dryRun) {
        # Update status file to remove deleted repos
        # Use the actual cleaned repos (not the original list)
        $totalRemovedFromStatus = RemoveReposFromStatus -repos $cleanedRepos -statusFile $statusFile
    }
}
else {
    Write-Host "No repos found to cleanup"
}

# Add cleaned repos summary
if ($cleanedRepos.Count -gt 0) {
    $displayCleanedCount = [Math]::Min($MaxDisplayReposCleaned, $cleanedRepos.Count)
    Write-Message -message "" -logToSummary $true
    Write-Message -message "<details>" -logToSummary $true
    Write-Message -message "<summary>Repos Cleaned Up (showing first $displayCleanedCount of $($cleanedRepos.Count))</summary>" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "| # | Our repo | Upstream | Reason |" -logToSummary $true
    Write-Message -message "|---:|---------|----------|--------|" -logToSummary $true
    $index = 1
    foreach ($repo in ($cleanedRepos | Select-Object -First $MaxDisplayReposCleaned)) {
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
    Write-Message -message "</details>" -logToSummary $true
    Write-Message -message "" -logToSummary $true
}

# Add total cleaned to step summary
Write-Message -message "" -logToSummary $true
Write-Message -message "**Total repos cleaned: $totalCleaned**" -logToSummary $true
if (-not $dryRun -and $totalRemovedFromStatus -gt 0) {
    Write-Message -message "**Total actions removed from status file: $totalRemovedFromStatus**" -logToSummary $true
}
Write-Message -message "" -logToSummary $true

if ($access_token) {
    try {
        GetRateLimitInfo -access_token $access_token
    }
    catch {
        Write-Host "Warning: Could not get rate limit info: $($_.Exception.Message)"
    }
}
