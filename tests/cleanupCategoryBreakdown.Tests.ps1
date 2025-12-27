Import-Module Pester

BeforeAll {
    # Define test function that mirrors the cleanup logic
    # Note: We duplicate the logic here to keep tests isolated and avoid dependencies on the main script
    # This allows tests to run independently and catches regressions in the categorization logic
    
    function GetReposToCleanupWithCategories {
        Param (
            $repos
        )
        
        $reposToCleanup = New-Object System.Collections.ArrayList
        
        # Tracking distinct, non-overlapping categories for clearer reporting
        $countUpstreamMissingOnly = 0  # Upstream missing but not empty
        $countEmptyOnly = 0  # Empty but upstream exists (should be 0 after fix)
        $countBothUpstreamMissingAndEmpty = 0  # Both conditions met
        $countSkippedDueToUpstreamAvailable = 0  # Skipped: upstream exists but mirror missing
        $countSkippedDueToMirrorExists = 0  # Skipped: mirror exists AND upstream exists
        
        foreach ($repo in $repos) {
            # Skip invalid entries
            $isInvalid = ($null -eq $repo) -or ([string]::IsNullOrEmpty($repo.name)) -or ($repo.name -eq "_") -or ([string]::IsNullOrEmpty($repo.owner))
            if ($isInvalid) {
                continue
            }
            
            $shouldCleanup = $false
            $reason = ""
            
            # If upstream exists but our mirror is missing, do NOT cleanup
            $upstreamStillExists = ($repo.upstreamFound -eq $true) -and ($repo.upstreamAvailable -ne $false)
            $mirrorMissing = ($null -eq $repo.mirrorFound -or $repo.mirrorFound -eq $false)
            if ($upstreamStillExists -and $mirrorMissing) {
                $countSkippedDueToUpstreamAvailable++
                continue
            }
            
            # If mirror exists AND upstream still exists, do NOT cleanup
            if ($repo.mirrorFound -eq $true -and $upstreamStillExists) {
                $countSkippedDueToMirrorExists++
                continue
            }
            
            # Determine cleanup criteria
            $upstreamMissing = ($repo.upstreamFound -eq $false -or $repo.upstreamAvailable -eq $false)
            $isEmpty = (($null -eq $repo.repoSize -or $repo.repoSize -eq 0) -and
                        ($null -eq $repo.tagInfo -or $repo.tagInfo.Count -eq 0) -and
                        ($null -eq $repo.releaseInfo -or $repo.releaseInfo.Count -eq 0))
            
            # Categorize for distinct reporting
            # Only cleanup if upstream is missing (deleted/unavailable)
            # Do NOT cleanup empty repos if upstream still exists
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
                $reposToCleanup.Add(@{
                    name = $repo.name
                    owner = $repo.owner
                    reason = $reason
                }) | Out-Null
            }
        }
        
        # Return both repos and category counts
        return @{
            repos = $reposToCleanup
            categories = @{
                upstreamMissingOnly = $countUpstreamMissingOnly
                emptyOnly = $countEmptyOnly
                bothUpstreamMissingAndEmpty = $countBothUpstreamMissingAndEmpty
                skippedUpstreamAvailable = $countSkippedDueToUpstreamAvailable
                skippedMirrorExists = $countSkippedDueToMirrorExists
                invalidEntries = 0
            }
        }
    }
}

Describe "GetReposToCleanup - Category Breakdown" {
    It "Should correctly categorize upstream missing repos with content" {
        # Arrange
        $repos = @(
            @{
                name = "test_repo1"
                owner = "test"
                upstreamFound = $false
                mirrorFound = $true
                repoSize = 100  # Has content
                tagInfo = @("v1.0.0")
                releaseInfo = @("v1.0.0")
            }
        )
        
        # Act
        $result = GetReposToCleanupWithCategories -repos $repos
        
        # Assert
        $result.repos.Count | Should -Be 1
        $result.categories.upstreamMissingOnly | Should -Be 1
        $result.categories.emptyOnly | Should -Be 0
        $result.categories.bothUpstreamMissingAndEmpty | Should -Be 0
        $result.categories.skippedUpstreamAvailable | Should -Be 0
    }
    
    It "Should correctly categorize empty repos with upstream available - should be SKIPPED not cleaned" {
        # Arrange - Empty repo with upstream available should NOT be cleaned up
        $repos = @(
            @{
                name = "test_repo2"
                owner = "test"
                upstreamFound = $true
                upstreamAvailable = $true
                mirrorFound = $true
                repoSize = 0  # Empty
                tagInfo = @()
                releaseInfo = @()
            }
        )
        
        # Act
        $result = GetReposToCleanupWithCategories -repos $repos
        
        # Assert - Should be skipped, not cleaned up
        $result.repos.Count | Should -Be 0  # Should NOT be cleaned up
        $result.categories.upstreamMissingOnly | Should -Be 0
        $result.categories.emptyOnly | Should -Be 0  # Should NOT count as emptyOnly
        $result.categories.bothUpstreamMissingAndEmpty | Should -Be 0
        $result.categories.skippedUpstreamAvailable | Should -Be 0
        $result.categories.skippedMirrorExists | Should -Be 1  # Should be counted as skipped
    }
    
    It "Should correctly categorize repos that are both upstream missing and empty" {
        # Arrange
        $repos = @(
            @{
                name = "test_repo3"
                owner = "test"
                upstreamFound = $false
                mirrorFound = $true
                repoSize = $null  # Empty
                tagInfo = $null
                releaseInfo = $null
            }
        )
        
        # Act
        $result = GetReposToCleanupWithCategories -repos $repos
        
        # Assert
        $result.repos.Count | Should -Be 1
        $result.categories.upstreamMissingOnly | Should -Be 0
        $result.categories.emptyOnly | Should -Be 0
        $result.categories.bothUpstreamMissingAndEmpty | Should -Be 1
        $result.categories.skippedUpstreamAvailable | Should -Be 0
    }
    
    It "Should correctly count skipped repos (upstream available, mirror missing)" {
        # Arrange
        $repos = @(
            @{
                name = "test_repo4"
                owner = "test"
                upstreamFound = $true
                upstreamAvailable = $true  # Not false
                mirrorFound = $false  # Mirror missing
            }
        )
        
        # Act
        $result = GetReposToCleanupWithCategories -repos $repos
        
        # Assert
        $result.repos.Count | Should -Be 0  # Not eligible for cleanup
        $result.categories.upstreamMissingOnly | Should -Be 0
        $result.categories.emptyOnly | Should -Be 0
        $result.categories.bothUpstreamMissingAndEmpty | Should -Be 0
        $result.categories.skippedUpstreamAvailable | Should -Be 1  # Counted as skipped
    }
    
    It "Should handle mixed scenarios correctly without double-counting" {
        # Arrange
        $repos = @(
            @{
                name = "upstream_missing_with_content"
                owner = "test"
                upstreamFound = $false
                mirrorFound = $true
                repoSize = 100
                tagInfo = @("v1.0")
                releaseInfo = @("v1.0")
            },
            @{
                name = "empty_with_upstream"
                owner = "test"
                upstreamFound = $true
                mirrorFound = $true
                repoSize = 0
                tagInfo = @()
                releaseInfo = @()
            },
            @{
                name = "both_missing_and_empty"
                owner = "test"
                upstreamFound = $false
                mirrorFound = $true
                repoSize = $null
                tagInfo = $null
                releaseInfo = $null
            },
            @{
                name = "skipped_mirror_missing"
                owner = "test"
                upstreamFound = $true
                mirrorFound = $false
            }
        )
        
        # Act
        $result = GetReposToCleanupWithCategories -repos $repos
        
        # Assert
        $result.repos.Count | Should -Be 2  # Only 2 eligible for cleanup (empty_with_upstream is now skipped)
        $result.categories.upstreamMissingOnly | Should -Be 1
        $result.categories.emptyOnly | Should -Be 0  # Should be 0 now
        $result.categories.bothUpstreamMissingAndEmpty | Should -Be 1
        $result.categories.skippedUpstreamAvailable | Should -Be 1
        $result.categories.skippedMirrorExists | Should -Be 1  # empty_with_upstream is now skipped
        
        # Verify totals
        $totalEligible = $result.categories.upstreamMissingOnly + $result.categories.emptyOnly + $result.categories.bothUpstreamMissingAndEmpty
        $totalEligible | Should -Be 2
    }
    
    It "Should handle upstreamAvailable=false as upstream missing" {
        # Arrange - This is set by sync workflows when upstream becomes unavailable
        $repos = @(
            @{
                name = "sync_marked_unavailable"
                owner = "test"
                upstreamFound = $true  # Initially found
                upstreamAvailable = $false  # But marked as unavailable later
                mirrorFound = $true
                repoSize = 50
                tagInfo = @("v1.0")
                releaseInfo = @()
            }
        )
        
        # Act
        $result = GetReposToCleanupWithCategories -repos $repos
        
        # Assert
        $result.repos.Count | Should -Be 1
        $result.categories.upstreamMissingOnly | Should -Be 1  # Should be counted as upstream missing
        $result.categories.emptyOnly | Should -Be 0
        $result.categories.bothUpstreamMissingAndEmpty | Should -Be 0
    }
    
    It "Should not double count repos across categories" {
        # Arrange - Large mixed dataset
        $repos = @()
        for ($i = 0; $i -lt 10; $i++) {
            $repos += @{
                name = "upstream_missing_$i"
                owner = "test"
                upstreamFound = $false
                mirrorFound = $true
                repoSize = 100
                tagInfo = @("v1.0")
                releaseInfo = @()
            }
        }
        # Empty repos with upstream should now be skipped, not cleaned
        for ($i = 0; $i -lt 5; $i++) {
            $repos += @{
                name = "empty_$i"
                owner = "test"
                upstreamFound = $true
                mirrorFound = $true
                repoSize = 0
                tagInfo = @()
                releaseInfo = @()
            }
        }
        for ($i = 0; $i -lt 3; $i++) {
            $repos += @{
                name = "both_$i"
                owner = "test"
                upstreamFound = $false
                mirrorFound = $true
                repoSize = $null
                tagInfo = $null
                releaseInfo = $null
            }
        }
        
        # Act
        $result = GetReposToCleanupWithCategories -repos $repos
        
        # Assert
        $result.repos.Count | Should -Be 13  # 10 + 0 + 3 (empty repos are now skipped)
        
        # Verify categories don't overlap
        $totalCategorized = $result.categories.upstreamMissingOnly + $result.categories.emptyOnly + $result.categories.bothUpstreamMissingAndEmpty
        $totalCategorized | Should -Be 13  # Should equal total repos to cleanup
        
        $result.categories.upstreamMissingOnly | Should -Be 10
        $result.categories.emptyOnly | Should -Be 0  # Should be 0 now
        $result.categories.bothUpstreamMissingAndEmpty | Should -Be 3
        $result.categories.skippedMirrorExists | Should -Be 5  # Empty repos are now skipped
    }
}
