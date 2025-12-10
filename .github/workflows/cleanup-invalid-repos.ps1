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
        return @()
    }
    
    $status = Get-Content $statusFile | ConvertFrom-Json
    Write-Host "Loaded [$($status.Count)] repos from status file"
    
    $reposToCleanup = New-Object System.Collections.ArrayList
    $countUpstreamMissing = 0
    $countEmptyRepos = 0
    $countSkippedDueToUpstreamAvailable = 0
    
    foreach ($repo in $status) {
        $shouldCleanup = $false
        $reason = ""
        
        # If upstream exists but our mirror is missing, do NOT cleanup
        $upstreamAvailable = ($repo.upstreamFound -eq $true)
        $mirrorMissing = ($null -eq $repo.mirrorFound -or $repo.mirrorFound -eq $false)
        if ($upstreamAvailable -and $mirrorMissing) {
            $countSkippedDueToUpstreamAvailable++
            Write-Debug "Skipping cleanup for [$($repo.name)] because upstream exists and mirror is missing, mirror should be created in another script/run"
            continue
        }
        
        # Criterion 1: Original repo no longer exists (upstreamFound=false)
        if ($repo.upstreamFound -eq $false) {
            $shouldCleanup = $true
            $reason = "Original repo no longer exists (upstreamFound=false)"
            $countUpstreamMissing++
        }
        
        # Criterion 2: Empty repo with no content (repoSize is 0 or null AND no tags/releases)
        if (($null -eq $repo.repoSize -or $repo.repoSize -eq 0) -and
            ($null -eq $repo.tagInfo -or $repo.tagInfo.Count -eq 0) -and
            ($null -eq $repo.releaseInfo -or $repo.releaseInfo.Count -eq 0)) {
            $countEmptyRepos++
            # Mark empty forks for cleanup regardless of upstream state
            $shouldCleanup = $true
            if ($reason -ne "") {
                $reason += " AND "
            }
            $reason += "Empty repo with no content (size=$($repo.repoSize), no tags/releases)"
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
        }
    }
    
    Write-Host "Found [$($reposToCleanup.Count)] repos to cleanup"
    Write-Host "  Diagnostics: upstream missing=[$countUpstreamMissing], empty repos=[$countEmptyRepos], skipped (upstream exists, mirror missing)=[$countSkippedDueToUpstreamAvailable]"
    Write-Host "" # empty line for readability
    Write-Output -NoEnumerate $reposToCleanup
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
$reposToCleanup = GetReposToCleanup -statusFile $statusFile

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
Write-Message -message "Number of repos considered: [$numberOfReposToDo]" -logToSummary $true
Write-Message -message "Dry run: [$dryRun]" -logToSummary $true
Write-Message -message "" -logToSummary $true
Write-Message -message "Found [$($reposToCleanup.Count)] repos eligible to cleanup" -logToSummary $true
Write-Message -message "" -logToSummary $true

if ($reposToCleanup.Count -gt 0) {
    Write-Message -message "" -logToSummary $true
    Write-Message -message "Showing first 15 of [$($reposToCleanup.Count)] repos:" -logToSummary $true
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
if ($reposToCleanup.Count -gt 0) {
    RemoveRepos -repos $reposToCleanup -owner $owner -dryRun $dryRun -maxCount $numberOfReposToDo
    
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

if ($access_token) {
    try {
        GetRateLimitInfo -access_token $access_token
    }
    catch {
        Write-Host "Warning: Could not get rate limit info: $($_.Exception.Message)"
    }
}
