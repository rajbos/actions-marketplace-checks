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
    
    foreach ($repo in $status) {
        $shouldCleanup = $false
        $reason = ""
        
        # Criterion 1: Original repo no longer exists (upstreamFound=false)
        if ($repo.upstreamFound -eq $false) {
            $shouldCleanup = $true
            $reason = "Original repo no longer exists (upstreamFound=false)"
        }
        
        # Criterion 2: Empty repo with no content (repoSize is 0 or null AND no tags/releases)
        if (($null -eq $repo.repoSize -or $repo.repoSize -eq 0) -and
            ($null -eq $repo.tagInfo -or $repo.tagInfo.Count -eq 0) -and
            ($null -eq $repo.releaseInfo -or $repo.releaseInfo.Count -eq 0)) {
            
            # Only mark for cleanup if the original repo no longer exists
            if ($repo.upstreamFound -eq $false) {
                $shouldCleanup = $true
                if ($reason -ne "") {
                    $reason += " AND "
                }
                $reason += "Empty repo with no content (size=$($repo.repoSize), no tags/releases)"
            }
        }
        
        if ($shouldCleanup) {
            $reposToCleanup.Add(@{
                name = $repo.name
                owner = $repo.owner
                reason = $reason
            }) | Out-Null
        }
    }
    
    Write-Host "Found [$($reposToCleanup.Count)] repos to cleanup"
    Write-Output -NoEnumerate $reposToCleanup
}

function RemoveRepos {
    Param (
        $repos,
        $owner,
        $dryRun
    )

    $i = 1
    $repoCount = $repos.Count
    
    if ($dryRun) {
        Write-Host "DRY RUN MODE - No repos will be actually deleted"
        Write-Host ""
    }
    
    foreach ($repo in $repos) 
    {
        $repoName = $repo.name
        Write-Host "$($i)/$($repoCount) Would delete repo [$($owner)/$($repoName)]"
        Write-Host "  Reason: $($repo.reason)"
        
        if (-not $dryRun) {
            $url = "/repos/$owner/$repoName"
            try {
                ApiCall -method DELETE -url $url -access_token $access_token
                Write-Host "  Successfully deleted [$owner/$repoName]"
            }
            catch {
                Write-Host "  Error deleting [$owner/$repoName]: $($_.Exception.Message)"
            }
        }
        
        $i++
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

# Limit to numberOfReposToDo
if ($reposToCleanup.Count -gt $numberOfReposToDo) {
    Write-Host "Limiting cleanup to first [$numberOfReposToDo] repos (total found: [$($reposToCleanup.Count)])"
    $reposToCleanup = $reposToCleanup | Select-Object -First $numberOfReposToDo
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
Write-Message -message "Owner: [$owner]" -logToSummary $true
Write-Message -message "Number of repos considered: [$numberOfReposToDo]" -logToSummary $true
Write-Message -message "Dry run: [$dryRun]" -logToSummary $true
Write-Message -message "" -logToSummary $true
Write-Message -message "Found [$($reposToCleanup.Count)] repos to cleanup" -logToSummary $true
if ($reposToCleanup.Count -gt 0) {
    Write-Message -message "" -logToSummary $true
    Write-Message -message "| Repository | Reason |" -logToSummary $true
    Write-Message -message "|-----------|--------|" -logToSummary $true
    foreach ($repo in $reposToCleanup) {
        Write-Message -message "| $($repo.name) | $($repo.reason) |" -logToSummary $true
    }
    Write-Message -message "" -logToSummary $true
}

# Remove the repos
if ($reposToCleanup.Count -gt 0) {
    RemoveRepos -repos $reposToCleanup -owner $owner -dryRun $dryRun
    
    if (-not $dryRun) {
        # Update status file to remove deleted repos
        RemoveReposFromStatus -repos $reposToCleanup -statusFile $statusFile
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
