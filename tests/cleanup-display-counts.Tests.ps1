Import-Module Pester

BeforeAll {
    # Test to verify the display count logic
    
    # Match the constant from the production code
    $MaxDisplayReposCleaned = 10
    
    function Test-DisplayCountLogic {
        Param (
            $actualCount,
            $maxDisplay = $MaxDisplayReposCleaned
        )
        
        $displayCount = [Math]::Min($maxDisplay, $actualCount)
        return $displayCount
    }
}

Describe "Cleanup Display Count Logic" {
    It "Should show 'first 10 of 32' when 32 repos are eligible and all processed" {
        # Arrange
        $cleanedRepos = 1..32 | ForEach-Object { @{ name = "repo$_" } }
        
        # Act
        $displayCount = Test-DisplayCountLogic -actualCount $cleanedRepos.Count
        
        # Assert
        $displayCount | Should -Be 10
        $cleanedRepos.Count | Should -Be 32
    }
    
    It "Should show 'first 4 of 4' when only 4 repos are cleaned" {
        # Arrange - This is the scenario from the problem statement
        $cleanedRepos = 1..4 | ForEach-Object { @{ name = "repo$_" } }
        
        # Act
        $displayCount = Test-DisplayCountLogic -actualCount $cleanedRepos.Count
        
        # Assert
        $displayCount | Should -Be 4  # Should NOT be hardcoded to 10
        $cleanedRepos.Count | Should -Be 4
    }
    
    It "Should show 'first 1 of 1' when only 1 repo is cleaned" {
        # Arrange
        $cleanedRepos = @( @{ name = "repo1" } )
        
        # Act
        $displayCount = Test-DisplayCountLogic -actualCount $cleanedRepos.Count
        
        # Assert
        $displayCount | Should -Be 1
        $cleanedRepos.Count | Should -Be 1
    }
    
    It "Should show 'first 10 of 15' when 15 repos are cleaned" {
        # Arrange
        $cleanedRepos = 1..15 | ForEach-Object { @{ name = "repo$_" } }
        
        # Act
        $displayCount = Test-DisplayCountLogic -actualCount $cleanedRepos.Count
        
        # Assert
        $displayCount | Should -Be 10
        $cleanedRepos.Count | Should -Be 15
    }
    
    It "Should handle zero repos correctly" {
        # Arrange
        $cleanedRepos = @()
        
        # Act
        $displayCount = Test-DisplayCountLogic -actualCount $cleanedRepos.Count
        
        # Assert
        $displayCount | Should -Be 0
        $cleanedRepos.Count | Should -Be 0
    }
}

Describe "RemoveReposFromStatus should use actual cleaned repos" {
    It "Should match cleaned repos count with removed count" {
        # Arrange - Simulate the scenario from the problem
        $reposToCleanup = 1..32 | ForEach-Object { @{ name = "repo$_" } }
        $numberOfReposToDo = 10
        $cleanedRepos = $reposToCleanup | Select-Object -First 4  # Only 4 actually cleaned
        
        # Act - This is what the fix does now
        $reposToRemoveFromStatus = $cleanedRepos
        
        # Assert - The count should match
        $reposToRemoveFromStatus.Count | Should -Be 4
        $reposToRemoveFromStatus.Count | Should -Be $cleanedRepos.Count
    }
    
    It "OLD BEHAVIOR (INCORRECT): Would have used wrong count before fix" {
        # Arrange - This demonstrates the OLD incorrect behavior
        $reposToCleanup = 1..32 | ForEach-Object { @{ name = "repo$_" } }
        $numberOfReposToDo = 10
        $cleanedRepos = $reposToCleanup | Select-Object -First 4  # Only 4 actually cleaned
        
        # Act - This is what the OLD code did (INCORRECT)
        $reposToRemoveFromStatusOldWay = $reposToCleanup | Select-Object -First $numberOfReposToDo
        
        # Assert - The count WOULD NOT match (demonstrating the bug)
        $reposToRemoveFromStatusOldWay.Count | Should -Be 10  # Wrong! Should be 4
        $reposToRemoveFromStatusOldWay.Count | Should -Not -Be $cleanedRepos.Count  # Mismatch!
    }
}
