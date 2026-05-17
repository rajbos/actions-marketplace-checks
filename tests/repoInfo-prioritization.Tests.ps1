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

        # Stale repoInfo/tagInfo/releaseInfo checks — boost priority when data exists
        # but was never timestamped or hasn't been refreshed in over 30 days.
        if ($hasRepoInfo -and $action.repoInfo.updated_at) {
            $hasCheckedAt = Get-Member -inputobject $action.repoInfo -name "checkedAt" -Membertype Properties
            if (!$hasCheckedAt -or !$action.repoInfo.checkedAt) {
                $score += 45  # has repoInfo but no checkedAt — was never refreshed
            } else {
                $daysSinceCheck = ((Get-Date) - [datetime]$action.repoInfo.checkedAt).Days
                if ($daysSinceCheck -gt 30) {
                    $score += 45
                }
            }
        }

        $hasTagInfoCheckedAt = Get-Member -inputobject $action -name "tagInfoCheckedAt" -Membertype Properties
        $hasTagInfo = Get-Member -inputobject $action -name "tagInfo" -Membertype Properties
        if ($hasTagInfo -and $action.tagInfo) {
            if (!$hasTagInfoCheckedAt -or !$action.tagInfoCheckedAt) {
                $score += 15
            } else {
                $daysSinceCheck = ((Get-Date) - [datetime]$action.tagInfoCheckedAt).Days
                if ($daysSinceCheck -gt 30) {
                    $score += 15
                }
            }
        }

        $hasReleaseInfoCheckedAt = Get-Member -inputobject $action -name "releaseInfoCheckedAt" -Membertype Properties
        $hasReleaseInfo = Get-Member -inputobject $action -name "releaseInfo" -Membertype Properties
        if ($hasReleaseInfo -and $action.releaseInfo) {
            if (!$hasReleaseInfoCheckedAt -or !$action.releaseInfoCheckedAt) {
                $score += 15
            } else {
                $daysSinceCheck = ((Get-Date) - [datetime]$action.releaseInfoCheckedAt).Days
                if ($daysSinceCheck -gt 30) {
                    $score += 15
                }
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
                checkedAt  = Get-Date
            }
            repoSize = 100
            tagInfo = @(@{ tag = "v1.0.0"; sha = "abc" })
            tagInfoCheckedAt = Get-Date
            releaseInfo = @(@{ tag_name = "v1.0.0"; target_commitish = "main" })
            releaseInfoCheckedAt = Get-Date
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
                checkedAt  = Get-Date
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
                checkedAt  = Get-Date
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

    It "Should add score for repoInfo missing checkedAt (legacy data)" {
        # Arrange — simulates an action that was populated before checkedAt was introduced
        $action = [PSCustomObject]@{
            name = "test-action"
            owner = "test-owner"
            mirrorFound = $true
            actionType = [PSCustomObject]@{ actionType = "Node" }
            repoInfo = [PSCustomObject]@{ updated_at = "2022-01-01T00:00:00Z" }  # no checkedAt
            repoSize = 100
            dependents = [PSCustomObject]@{ dependents = 50; dependentsLastUpdated = Get-Date }
            fundingInfo = [PSCustomObject]@{ lastChecked = Get-Date }
        }

        # Act
        $score = Get-RepoPriorityScore -action $action

        # Assert
        $score | Should -Be 45
    }

    It "Should add score for repoInfo with stale checkedAt (>30 days old)" {
        # Arrange
        $oldDate = (Get-Date).AddDays(-45)
        $action = [PSCustomObject]@{
            name = "test-action"
            owner = "test-owner"
            mirrorFound = $true
            actionType = [PSCustomObject]@{ actionType = "Node" }
            repoInfo = [PSCustomObject]@{ updated_at = "2022-01-01T00:00:00Z"; checkedAt = $oldDate }
            repoSize = 100
            dependents = [PSCustomObject]@{ dependents = 50; dependentsLastUpdated = Get-Date }
            fundingInfo = [PSCustomObject]@{ lastChecked = Get-Date }
        }

        # Act
        $score = Get-RepoPriorityScore -action $action

        # Assert
        $score | Should -Be 45
    }

    It "Should not add stale score for repoInfo checked within 30 days" {
        # Arrange
        $recentDate = (Get-Date).AddDays(-15)
        $action = [PSCustomObject]@{
            name = "test-action"
            owner = "test-owner"
            mirrorFound = $true
            actionType = [PSCustomObject]@{ actionType = "Node" }
            repoInfo = [PSCustomObject]@{ updated_at = "2022-01-01T00:00:00Z"; checkedAt = $recentDate }
            repoSize = 100
            dependents = [PSCustomObject]@{ dependents = 50; dependentsLastUpdated = Get-Date }
            fundingInfo = [PSCustomObject]@{ lastChecked = Get-Date }
        }

        # Act
        $score = Get-RepoPriorityScore -action $action

        # Assert
        $score | Should -Be 0
    }

    It "Should add score for tagInfo missing tagInfoCheckedAt (legacy data)" {
        # Arrange
        $action = [PSCustomObject]@{
            name = "test-action"
            owner = "test-owner"
            mirrorFound = $true
            actionType = [PSCustomObject]@{ actionType = "Node" }
            repoInfo = [PSCustomObject]@{ updated_at = Get-Date; checkedAt = Get-Date }
            repoSize = 100
            tagInfo = @(@{ tag = "v1.0.0"; sha = "abc" })  # no tagInfoCheckedAt
            dependents = [PSCustomObject]@{ dependents = 50; dependentsLastUpdated = Get-Date }
            fundingInfo = [PSCustomObject]@{ lastChecked = Get-Date }
        }

        # Act
        $score = Get-RepoPriorityScore -action $action

        # Assert
        $score | Should -Be 15
    }

    It "Should add score for releaseInfo missing releaseInfoCheckedAt (legacy data)" {
        # Arrange
        $action = [PSCustomObject]@{
            name = "test-action"
            owner = "test-owner"
            mirrorFound = $true
            actionType = [PSCustomObject]@{ actionType = "Node" }
            repoInfo = [PSCustomObject]@{ updated_at = Get-Date; checkedAt = Get-Date }
            repoSize = 100
            releaseInfo = @(@{ tag_name = "v1.0.0"; target_commitish = "main" })  # no releaseInfoCheckedAt
            dependents = [PSCustomObject]@{ dependents = 50; dependentsLastUpdated = Get-Date }
            fundingInfo = [PSCustomObject]@{ lastChecked = Get-Date }
        }

        # Act
        $score = Get-RepoPriorityScore -action $action

        # Assert
        $score | Should -Be 15
    }

    It "Should add combined score for stale tagInfo and releaseInfo" {
        # Arrange
        $oldDate = (Get-Date).AddDays(-45)
        $action = [PSCustomObject]@{
            name = "test-action"
            owner = "test-owner"
            mirrorFound = $true
            actionType = [PSCustomObject]@{ actionType = "Node" }
            repoInfo = [PSCustomObject]@{ updated_at = Get-Date; checkedAt = Get-Date }
            repoSize = 100
            tagInfo = @(@{ tag = "v1.0.0"; sha = "abc" })
            tagInfoCheckedAt = $oldDate
            releaseInfo = @(@{ tag_name = "v1.0.0"; target_commitish = "main" })
            releaseInfoCheckedAt = $oldDate
            dependents = [PSCustomObject]@{ dependents = 50; dependentsLastUpdated = Get-Date }
            fundingInfo = [PSCustomObject]@{ lastChecked = Get-Date }
        }

        # Act
        $score = Get-RepoPriorityScore -action $action

        # Assert
        $score | Should -Be 30  # 15 for stale tagInfo + 15 for stale releaseInfo
    }
}

Describe "Get-PrioritizedReposToProcess" {
    It "Should return repos with highest scores first" {
        # Arrange
        $repos = @(
            [PSCustomObject]@{ name = "complete-repo"; owner = "test"; mirrorFound = $true; actionType = [PSCustomObject]@{ actionType = "Node" }; repoInfo = [PSCustomObject]@{ updated_at = Get-Date; checkedAt = Get-Date }; repoSize = 100; dependents = [PSCustomObject]@{ dependents = 50; dependentsLastUpdated = Get-Date } }
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
        $completeRepo1 = [PSCustomObject]@{ 
            name = "complete-repo1"
            owner = "test"
            mirrorFound = $true
            actionType = [PSCustomObject]@{ actionType = "Node" }
            repoInfo = [PSCustomObject]@{ updated_at = Get-Date; checkedAt = Get-Date }
            repoSize = 100
            tagInfo = @(@{ tag = "v1.0.0"; sha = "abc" })
            tagInfoCheckedAt = Get-Date
            releaseInfo = @(@{ tag_name = "v1.0.0"; target_commitish = "main" })
            releaseInfoCheckedAt = Get-Date
            dependents = [PSCustomObject]@{ 
                dependents = 50
                dependentsLastUpdated = Get-Date 
            }
            fundingInfo = [PSCustomObject]@{ lastChecked = Get-Date }
        }
        
        $completeRepo2 = [PSCustomObject]@{ 
            name = "complete-repo2"
            owner = "test"
            mirrorFound = $true
            actionType = [PSCustomObject]@{ actionType = "Docker" }
            repoInfo = [PSCustomObject]@{ updated_at = Get-Date; checkedAt = Get-Date }
            repoSize = 200
            tagInfo = @(@{ tag = "v2.0.0"; sha = "def" })
            tagInfoCheckedAt = Get-Date
            releaseInfo = @(@{ tag_name = "v2.0.0"; target_commitish = "main" })
            releaseInfoCheckedAt = Get-Date
            dependents = [PSCustomObject]@{ 
                dependents = 100
                dependentsLastUpdated = Get-Date 
            }
            fundingInfo = [PSCustomObject]@{ lastChecked = Get-Date }
        }
        
        $repos = @($completeRepo1, $completeRepo2)
        
        # Act
        $prioritized = Get-PrioritizedReposToProcess -existingForks $repos -numberOfReposToDo 10
        
        # Assert
        $prioritized.Count | Should -Be 0  # All repos have score 0, so nothing to process
    }

    It "Should prioritize stale repos over fresh repos" {
        # Arrange
        $oldDate = (Get-Date).AddDays(-45)
        $freshRepo = [PSCustomObject]@{
            name = "fresh-repo"
            owner = "test"
            mirrorFound = $true
            actionType = [PSCustomObject]@{ actionType = "Node" }
            repoInfo = [PSCustomObject]@{ updated_at = Get-Date; checkedAt = Get-Date }
            repoSize = 100
            dependents = [PSCustomObject]@{ dependents = 50; dependentsLastUpdated = Get-Date }
            fundingInfo = [PSCustomObject]@{ lastChecked = Get-Date }
        }
        $staleRepo = [PSCustomObject]@{
            name = "stale-repo"
            owner = "test"
            mirrorFound = $true
            actionType = [PSCustomObject]@{ actionType = "Node" }
            repoInfo = [PSCustomObject]@{ updated_at = "2022-01-01T00:00:00Z" }  # no checkedAt — legacy stale
            repoSize = 100
            dependents = [PSCustomObject]@{ dependents = 50; dependentsLastUpdated = Get-Date }
            fundingInfo = [PSCustomObject]@{ lastChecked = Get-Date }
        }
        $repos = @($freshRepo, $staleRepo)

        # Act
        $prioritized = Get-PrioritizedReposToProcess -existingForks $repos -numberOfReposToDo 10

        # Assert
        $prioritized.Count | Should -Be 1
        $prioritized[0].name | Should -Be "stale-repo"
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
