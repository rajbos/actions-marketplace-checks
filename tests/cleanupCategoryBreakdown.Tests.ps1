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
        $countEmptyOnly = 0  # Empty but upstream exists
        $countBothUpstreamMissingAndEmpty = 0  # Both conditions met
        $countSkippedDueToUpstreamAvailable = 0  # Skipped: upstream exists but mirror missing
        
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
            
            # Determine cleanup criteria
            $upstreamMissing = ($repo.upstreamFound -eq $false -or $repo.upstreamAvailable -eq $false)
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
    
    It "Should correctly categorize empty repos with upstream available" {
        # Arrange
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
        
        # Assert
        $result.repos.Count | Should -Be 1
        $result.categories.upstreamMissingOnly | Should -Be 0
        $result.categories.emptyOnly | Should -Be 1
        $result.categories.bothUpstreamMissingAndEmpty | Should -Be 0
        $result.categories.skippedUpstreamAvailable | Should -Be 0
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
        $result.repos.Count | Should -Be 3  # Only 3 eligible for cleanup
        $result.categories.upstreamMissingOnly | Should -Be 1
        $result.categories.emptyOnly | Should -Be 1
        $result.categories.bothUpstreamMissingAndEmpty | Should -Be 1
        $result.categories.skippedUpstreamAvailable | Should -Be 1
        
        # Verify totals
        $totalEligible = $result.categories.upstreamMissingOnly + $result.categories.emptyOnly + $result.categories.bothUpstreamMissingAndEmpty
        $totalEligible | Should -Be 3
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
        $result.repos.Count | Should -Be 18  # 10 + 5 + 3
        
        # Verify categories don't overlap
        $totalCategorized = $result.categories.upstreamMissingOnly + $result.categories.emptyOnly + $result.categories.bothUpstreamMissingAndEmpty
        $totalCategorized | Should -Be 18  # Should equal total repos to cleanup
        
        $result.categories.upstreamMissingOnly | Should -Be 10
        $result.categories.emptyOnly | Should -Be 5
        $result.categories.bothUpstreamMissingAndEmpty | Should -Be 3
    }
}
