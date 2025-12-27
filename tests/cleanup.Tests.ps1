Import-Module Pester

BeforeAll {
    # Import the cleanup script functions by dot-sourcing it
    # We'll need to define the functions separately for testing
    
    function GetReposToCleanupForTest {
        Param (
            $repos
        )
        
        $reposToCleanup = New-Object System.Collections.ArrayList
        
        foreach ($repo in $repos) {
            # Skip if upstream exists and mirror is missing (mirror should be created)
            $upstreamStillExists = ($repo.upstreamFound -eq $true) -and ($repo.upstreamAvailable -ne $false)
            $mirrorMissing = ($null -eq $repo.mirrorFound -or $repo.mirrorFound -eq $false)
            if ($upstreamStillExists -and $mirrorMissing) {
                continue
            }
            
            # Skip if mirror exists AND upstream still exists
            # The mirror will be filled/synced by other workflows
            if ($repo.mirrorFound -eq $true -and $upstreamStillExists) {
                continue
            }
            
            $shouldCleanup = $false
            $reason = ""
            
            # Criterion 1: Original repo no longer exists
            # Check both upstreamFound=false (from initial discovery) and upstreamAvailable=false (from sync failures)
            if ($repo.upstreamFound -eq $false -or $repo.upstreamAvailable -eq $false) {
                $shouldCleanup = $true
                $reason = "Original repo no longer exists (upstreamFound=$($repo.upstreamFound), upstreamAvailable=$($repo.upstreamAvailable))"
            }
            
            # Criterion 2: Empty repo with no content (repoSize is 0 or null AND no tags/releases)
            if (($null -eq $repo.repoSize -or $repo.repoSize -eq 0) -and
                ($null -eq $repo.tagInfo -or $repo.tagInfo.Count -eq 0) -and
                ($null -eq $repo.releaseInfo -or $repo.releaseInfo.Count -eq 0)) {
                
                $shouldCleanup = $true
                if ($reason -ne "") {
                    $reason += " AND "
                }
                $reason += "Empty repo with no content (size=$($repo.repoSize), no tags/releases)"
            }
            
            if ($shouldCleanup) {
                $reposToCleanup.Add(@{
                    name = $repo.name
                    owner = $repo.owner
                    reason = $reason
                }) | Out-Null
            }
        }
        
        Write-Output -NoEnumerate $reposToCleanup
    }
}

Describe "GetReposToCleanup" {
    It "Should identify repos where upstreamFound is false" {
        # Arrange
        $repos = @(
            @{
                name = "test_repo1"
                owner = "test"
                upstreamFound = $false
                actionType = @{ actionType = "Node" }
            },
            @{
                name = "test_repo2"
                owner = "test"
                upstreamFound = $true
                actionType = @{ actionType = "Node" }
            }
        )
        
        # Act
        $result = GetReposToCleanupForTest -repos $repos
        
        # Assert
        $result.Count | Should -Be 1
        $result[0].name | Should -Be "test_repo1"
        $result[0].reason | Should -BeLike "*upstreamFound=false*"
    }
    
    It "Should identify empty repos with no content when upstreamFound is false" {
        # Arrange
        $repos = @(
            @{
                name = "test_repo1"
                owner = "test"
                upstreamFound = $false
                actionType = @{ actionType = "Node" }
                repoSize = 0
                tagInfo = @()
                releaseInfo = @()
            }
        )
        
        # Act
        $result = GetReposToCleanupForTest -repos $repos
        
        # Assert
        $result.Count | Should -Be 1
        $result[0].reason | Should -BeLike "*Empty repo with no content*"
    }
    
    It "Should NOT cleanup repos with valid content even if repoSize is 0" {
        # Arrange - A repo with size 0 but has tags/releases should not be cleaned up
        $repos = @(
            @{
                name = "test_repo1"
                owner = "test"
                upstreamFound = $true
                actionType = @{ actionType = "Node" }
                repoSize = 0
                tagInfo = @("v1.0.0")
                releaseInfo = @("v1.0.0")
            }
        )
        
        # Act
        $result = GetReposToCleanupForTest -repos $repos
        
        # Assert
        $result.Count | Should -Be 0
    }
    
    It "Should combine multiple reasons when applicable" {
        # Arrange
        $repos = @(
            @{
                name = "test_repo1"
                owner = "test"
                upstreamFound = $false
                actionType = @{ 
                    actionType = "No file found"
                    fileFound = "No file found"
                }
                repoSize = $null
                tagInfo = $null
                releaseInfo = $null
            }
        )
        
        # Act
        $result = GetReposToCleanupForTest -repos $repos
        
        # Assert
        $result.Count | Should -Be 1
        $result[0].reason | Should -BeLike "*upstreamFound=false*"
        $result[0].reason | Should -BeLike "*Empty repo with no content*"
    }
    
    It "Should handle the specific case from the issue (zesticio_update-release-branch)" {
        # Arrange - This is the exact structure of the repo mentioned in the issue
        $repos = @(
            @{
                name = "zesticio_update-release-branch"
                owner = "actions-marketplace-validations"
                upstreamFound = $false
                actionType = @{
                    actionType = "No file found"
                    actionDockerType = "No file found"
                    fileFound = "No file found"
                    nodeVersion = $null
                }
                vulnerabilityStatus = @{
                    high = 0
                    critical = 0
                    lastUpdated = "2022-11-20T12:12:35.0969035Z"
                }
                dependabotEnabled = $true
                mirrorLastUpdated = $null
                repoSize = $null
                ossfDateLastUpdate = "2024-04-25T04:27:27.2503115+00:00"
                dependents = @{
                    dependentsLastUpdated = "2025-09-10T15:13:23.5914485+00:00"
                    dependents = ""
                }
                verified = $false
            }
        )
        
        # Act
        $result = GetReposToCleanupForTest -repos $repos
        
        # Assert
        $result.Count | Should -Be 1
        $result[0].name | Should -Be "zesticio_update-release-branch"
        $result[0].reason | Should -BeLike "*upstreamFound=*"
    }
    
    It "Should identify repos where upstreamAvailable is false (set by update workflow) and mirror is empty" {
        # Arrange - Repository where update workflow marked upstream as unavailable and mirror is empty
        $repos = @(
            @{
                name = "test_repo_unavailable"
                owner = "actions-marketplace-validations"
                upstreamFound = $true  # Initially found
                upstreamAvailable = $false  # But later marked as unavailable by sync workflow
                mirrorFound = $false  # Mirror doesn't exist or is not found
                actionType = @{ actionType = "Node" }
            }
        )
        
        # Act
        $result = GetReposToCleanupForTest -repos $repos
        
        # Assert
        $result.Count | Should -Be 1
        $result[0].name | Should -Be "test_repo_unavailable"
        $result[0].reason | Should -BeLike "*upstreamAvailable=False*"
    }
    
    It "Should NOT cleanup repos where upstream exists but mirror is missing" {
        # Arrange - Upstream still exists but mirror hasn't been created yet
        $repos = @(
            @{
                name = "test_repo_no_mirror"
                owner = "actions-marketplace-validations"
                upstreamFound = $true
                upstreamAvailable = $true  # Explicitly not false
                mirrorFound = $false
                actionType = @{ actionType = "Node" }
            }
        )
        
        # Act
        $result = GetReposToCleanupForTest -repos $repos
        
        # Assert
        $result.Count | Should -Be 0  # Should not cleanup - mirror should be created instead
    }
    
    It "Should NOT cleanup repos where mirror exists and upstream still exists" {
        # Arrange - Mirror exists and upstream exists (the case from the issue)
        $repos = @(
            @{
                name = "test_repo_mirror_exists"
                owner = "actions-marketplace-validations"
                upstreamFound = $true   # Upstream exists
                mirrorFound = $true     # Mirror exists
                repoSize = 0            # Appears empty
                tagInfo = @()           # No tags
                releaseInfo = @()       # No releases
                actionType = @{ actionType = "Node" }
            }
        )
        
        # Act
        $result = GetReposToCleanupForTest -repos $repos
        
        # Assert
        $result.Count | Should -Be 0  # Should NOT cleanup - mirror exists and upstream exists
    }
    
    It "Should cleanup repos where mirror exists but upstream is gone and mirror is empty" {
        # Arrange - Mirror exists but upstream is gone and mirror is empty
        $repos = @(
            @{
                name = "test_repo_orphaned_mirror"
                owner = "actions-marketplace-validations"
                upstreamFound = $false  # Upstream is gone
                mirrorFound = $true     # Mirror exists
                repoSize = 0            # Empty
                tagInfo = @()           # No tags
                releaseInfo = @()       # No releases
                actionType = @{ actionType = "Node" }
            }
        )
        
        # Act
        $result = GetReposToCleanupForTest -repos $repos
        
        # Assert
        $result.Count | Should -Be 1  # Should cleanup - orphaned empty mirror
        $result[0].reason | Should -BeLike "*Original repo no longer exists*"
        $result[0].reason | Should -BeLike "*Empty repo with no content*"
    }
}
