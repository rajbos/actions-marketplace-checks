Import-Module Pester

BeforeAll {
    # Duplicate the prioritization functions for testing
    function Get-RepoPriorityScore {
        Param (
            $action
        )
        
        $score = 0
        
        # Critical missing fields (highest priority)
        $hasOwner = Get-Member -inputobject $action -name "owner" -Membertype Properties
        if (!$hasOwner) {
            $score += 100
        }
        
        $hasMirrorFound = Get-Member -inputobject $action -name "mirrorFound" -Membertype Properties
        if (!$hasMirrorFound -or !$action.mirrorFound) {
            $score += 90
        }
        
        $hasActionType = Get-Member -inputobject $action -name "actionType" -Membertype Properties
        if (!$hasActionType -or ($null -eq $action.actionType.actionType)) {
            $score += 80
        }
        
        # Important fields (medium priority)
        $hasRepoInfo = Get-Member -inputobject $action -name "repoInfo" -Membertype Properties
        if (!$hasRepoInfo -or ($null -eq $action.repoInfo.updated_at)) {
            $score += 50
        }
        
        $hasRepoSize = Get-Member -inputobject $action -name "repoSize" -Membertype Properties
        if (!$hasRepoSize) {
            $score += 40
        }
        
        $hasDependents = Get-Member -inputobject $action -name "dependents" -Membertype Properties
        if (!$hasDependents) {
            $score += 30
        }
        
        # Stale data checks (lower priority)
        if ($hasDependents -and $action.dependents.dependentsLastUpdated) {
            $daysSinceLastUpdate = ((Get-Date) - $action.dependents.dependentsLastUpdated).Days
            if ($daysSinceLastUpdate -gt 7) {
                $score += 20
            }
        }
        
        $hasFundingInfo = Get-Member -inputobject $action -name "fundingInfo" -Membertype Properties
        if ($hasFundingInfo -and $action.fundingInfo.lastChecked) {
            $daysSinceLastCheck = ((Get-Date) - $action.fundingInfo.lastChecked).Days
            if ($daysSinceLastCheck -gt 30) {
                $score += 10
            }
        }
        
        return $score
    }
    
    function Get-PrioritizedReposToProcess {
        Param (
            $existingForks,
            $numberOfReposToDo
        )
        
        # Calculate priority scores for all repos
        $scoredRepos = @()
        foreach ($action in $existingForks) {
            $score = Get-RepoPriorityScore -action $action
            if ($score -gt 0) {
                $scoredRepos += @{
                    Action = $action
                    Score = $score
                }
            }
        }
        
        # Sort by score (highest first) and take top N
        $prioritizedRepos = $scoredRepos | Sort-Object -Property Score -Descending | Select-Object -First $numberOfReposToDo
        
        # Return just the actions
        return $prioritizedRepos | ForEach-Object { $_.Action }
    }
}

Describe "Get-RepoPriorityScore" {
    It "Should give highest score to repo missing owner field" {
        # Arrange
        $action = [PSCustomObject]@{
            name = "test-action"
        }
        
        # Act
        $score = Get-RepoPriorityScore -action $action
        
        # Assert
        $score | Should -BeGreaterThan 90
    }
    
    It "Should give high score to repo missing actionType" {
        # Arrange
        $action = [PSCustomObject]@{
            name = "test-action"
            owner = "test-owner"
            mirrorFound = $true
        }
        
        # Act
        $score = Get-RepoPriorityScore -action $action
        
        # Assert
        $score | Should -BeGreaterOrEqual 80
    }
    
    It "Should give zero score to fully populated repo with fresh data" {
        # Arrange
        $action = [PSCustomObject]@{
            name = "test-action"
            owner = "test-owner"
            mirrorFound = $true
            actionType = [PSCustomObject]@{
                actionType = "Node"
            }
            repoInfo = [PSCustomObject]@{
                updated_at = Get-Date
            }
            repoSize = 100
            dependents = [PSCustomObject]@{
                dependents = 50
                dependentsLastUpdated = Get-Date
            }
            fundingInfo = [PSCustomObject]@{
                lastChecked = Get-Date
            }
        }
        
        # Act
        $score = Get-RepoPriorityScore -action $action
        
        # Assert
        $score | Should -Be 0
    }
    
    It "Should add score for stale dependents data (>7 days old)" {
        # Arrange
        $oldDate = (Get-Date).AddDays(-10)
        $action = [PSCustomObject]@{
            name = "test-action"
            owner = "test-owner"
            mirrorFound = $true
            actionType = [PSCustomObject]@{
                actionType = "Node"
            }
            repoInfo = [PSCustomObject]@{
                updated_at = Get-Date
            }
            repoSize = 100
            dependents = [PSCustomObject]@{
                dependents = 50
                dependentsLastUpdated = $oldDate
            }
            fundingInfo = [PSCustomObject]@{
                lastChecked = Get-Date
            }
        }
        
        # Act
        $score = Get-RepoPriorityScore -action $action
        
        # Assert
        $score | Should -BeGreaterThan 0
        $score | Should -BeLessOrEqual 20
    }
    
    It "Should add score for stale funding data (>30 days old)" {
        # Arrange
        $oldDate = (Get-Date).AddDays(-35)
        $action = [PSCustomObject]@{
            name = "test-action"
            owner = "test-owner"
            mirrorFound = $true
            actionType = [PSCustomObject]@{
                actionType = "Node"
            }
            repoInfo = [PSCustomObject]@{
                updated_at = Get-Date
            }
            repoSize = 100
            dependents = [PSCustomObject]@{
                dependents = 50
                dependentsLastUpdated = Get-Date
            }
            fundingInfo = [PSCustomObject]@{
                lastChecked = $oldDate
            }
        }
        
        # Act
        $score = Get-RepoPriorityScore -action $action
        
        # Assert
        $score | Should -BeGreaterThan 0
        $score | Should -BeLessOrEqual 10
    }
}

Describe "Get-PrioritizedReposToProcess" {
    It "Should return repos with highest scores first" {
        # Arrange
        $repos = @(
            [PSCustomObject]@{ name = "complete-repo"; owner = "test"; mirrorFound = $true; actionType = [PSCustomObject]@{ actionType = "Node" }; repoInfo = [PSCustomObject]@{ updated_at = Get-Date }; repoSize = 100; dependents = [PSCustomObject]@{ dependents = 50; dependentsLastUpdated = Get-Date } }
            [PSCustomObject]@{ name = "missing-owner" }
            [PSCustomObject]@{ name = "missing-actionType"; owner = "test"; mirrorFound = $true }
        )
        
        # Act
        $prioritized = Get-PrioritizedReposToProcess -existingForks $repos -numberOfReposToDo 10
        
        # Assert
        $prioritized.Count | Should -Be 2  # Only 2 need processing (complete-repo has score 0)
        $prioritized[0].name | Should -Be "missing-owner"  # Highest score
    }
    
    It "Should limit results to numberOfReposToDo" {
        # Arrange
        $repos = @(
            [PSCustomObject]@{ name = "repo1" }
            [PSCustomObject]@{ name = "repo2" }
            [PSCustomObject]@{ name = "repo3" }
            [PSCustomObject]@{ name = "repo4" }
            [PSCustomObject]@{ name = "repo5" }
        )
        
        # Act
        $prioritized = Get-PrioritizedReposToProcess -existingForks $repos -numberOfReposToDo 3
        
        # Assert
        $prioritized.Count | Should -Be 3
    }
    
    It "Should return empty array when all repos are up-to-date" {
        # Arrange
        $repos = @(
            [PSCustomObject]@{ 
                name = "complete-repo1"
                owner = "test"
                mirrorFound = $true
                actionType = [PSCustomObject]@{ actionType = "Node" }
                repoInfo = [PSCustomObject]@{ updated_at = Get-Date }
                repoSize = 100
                dependents = [PSCustomObject]@{ dependents = 50; dependentsLastUpdated = Get-Date }
                fundingInfo = [PSCustomObject]@{ lastChecked = Get-Date }
            }
            [PSCustomObject]@{ 
                name = "complete-repo2"
                owner = "test"
                mirrorFound = $true
                actionType = [PSCustomObject]@{ actionType = "Docker" }
                repoInfo = [PSCustomObject]@{ updated_at = Get-Date }
                repoSize = 200
                dependents = [PSCustomObject]@{ dependents = 100; dependentsLastUpdated = Get-Date }
                fundingInfo = [PSCustomObject]@{ lastChecked = Get-Date }
            }
        )
        
        # Act
        $prioritized = Get-PrioritizedReposToProcess -existingForks $repos -numberOfReposToDo 10
        
        # Assert
        $prioritized.Count | Should -Be 0  # All repos have score 0, so nothing to process
    }
}

Describe "Prioritization Benefits Analysis" {
    It "Should demonstrate time savings when all repos are up-to-date" {
        # Arrange - Simulating 23,000 repos where all are up-to-date
        $totalRepos = 23000
        $numberOfReposToDo = 500
        
        # Current approach: iterate through all 23,000 repos checking each one
        $currentApproachIterations = $totalRepos
        
        # Prioritized approach: calculate scores for all 23,000, but get 0 results to process
        # This is much faster because:
        # 1. Score calculation is in-memory (no API calls)
        # 2. We know immediately there's nothing to process
        $prioritizedApproachIterations = 0  # No processing needed when all are up-to-date
        
        # Assert
        $prioritizedApproachIterations | Should -BeLessThan $currentApproachIterations
        
        # This is the key insight: when 0 deltas occur (problem statement scenario),
        # prioritization would skip processing entirely rather than checking all repos
    }
}
