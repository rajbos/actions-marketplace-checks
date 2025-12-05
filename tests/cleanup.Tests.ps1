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
            $shouldCleanup = $false
            $reason = ""
            
            # Criterion 1: Original repo no longer exists (forkFound is false)
            if ($repo.forkFound -eq $false) {
                $shouldCleanup = $true
                $reason = "Original repo no longer exists (forkFound=false)"
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
    It "Should identify repos where forkFound is false" {
        # Arrange
        $repos = @(
            @{
                name = "test_repo1"
                owner = "test"
                forkFound = $false
                actionType = @{ actionType = "Node" }
            },
            @{
                name = "test_repo2"
                owner = "test"
                forkFound = $true
                actionType = @{ actionType = "Node" }
            }
        )
        
        # Act
        $result = GetReposToCleanupForTest -repos $repos
        
        # Assert
        $result.Count | Should -Be 1
        $result[0].name | Should -Be "test_repo1"
        $result[0].reason | Should -BeLike "*forkFound=false*"
    }
    
    It "Should identify repos with invalid action type 'No file found'" {
        # Arrange
        $repos = @(
            @{
                name = "test_repo1"
                owner = "test"
                forkFound = $true
                actionType = @{ actionType = "No file found" }
            },
            @{
                name = "test_repo2"
                owner = "test"
                forkFound = $true
                actionType = @{ actionType = "Node" }
            }
        )
        
        # Act
        $result = GetReposToCleanupForTest -repos $repos
        
        # Assert
        $result.Count | Should -Be 1
        $result[0].name | Should -Be "test_repo1"
        $result[0].reason | Should -BeLike "*Invalid action type: No file found*"
    }
    
    It "Should identify repos with invalid action type 'No owner found'" {
        # Arrange
        $repos = @(
            @{
                name = "test_repo1"
                owner = "test"
                forkFound = $true
                actionType = @{ actionType = "No owner found" }
            }
        )
        
        # Act
        $result = GetReposToCleanupForTest -repos $repos
        
        # Assert
        $result.Count | Should -Be 1
        $result[0].reason | Should -BeLike "*Invalid action type: No owner found*"
    }
    
    It "Should identify repos with invalid action type 'No repo found'" {
        # Arrange
        $repos = @(
            @{
                name = "test_repo1"
                owner = "test"
                forkFound = $true
                actionType = @{ actionType = "No repo found" }
            }
        )
        
        # Act
        $result = GetReposToCleanupForTest -repos $repos
        
        # Assert
        $result.Count | Should -Be 1
        $result[0].reason | Should -BeLike "*Invalid action type: No repo found*"
    }
    
    It "Should identify empty repos with no content when forkFound is false" {
        # Arrange
        $repos = @(
            @{
                name = "test_repo1"
                owner = "test"
                forkFound = $false
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
    
    It "Should identify empty repos with no content when actionType is 'No file found'" {
        # Arrange
        $repos = @(
            @{
                name = "test_repo1"
                owner = "test"
                forkFound = $true
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
        $result[0].reason | Should -BeLike "*Empty repo with no content*"
    }
    
    It "Should NOT cleanup repos with valid content even if repoSize is 0" {
        # Arrange - A repo with size 0 but has tags/releases should not be cleaned up
        $repos = @(
            @{
                name = "test_repo1"
                owner = "test"
                forkFound = $true
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
                forkFound = $false
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
        $result[0].reason | Should -BeLike "*forkFound=false*"
        $result[0].reason | Should -BeLike "*Invalid action type*"
        $result[0].reason | Should -BeLike "*Empty repo with no content*"
    }
    
    It "Should handle the specific case from the issue (zesticio_update-release-branch)" {
        # Arrange - This is the exact structure of the repo mentioned in the issue
        $repos = @(
            @{
                name = "zesticio_update-release-branch"
                owner = "actions-marketplace-validations"
                forkFound = $false
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
        $result[0].reason | Should -BeLike "*forkFound=false*"
        $result[0].reason | Should -BeLike "*Invalid action type: No file found*"
    }
}
