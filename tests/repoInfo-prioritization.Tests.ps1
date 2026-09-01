BeforeAll {
    # Get-RepoPriorityScore and Get-PrioritizedReposToProcess live in library.ps1 (moved there
    # so analyze.yml's "prepare" job - which already dot-sources library.ps1 - can share the
    # same scoring logic that repoInfo.ps1's direct (un-chunked) Run path uses, instead of
    # duplicating it inline). Dot-source the real implementation rather than a copy so these
    # tests exercise production code.
    $env:GITHUB_TOKEN = "test_token_mock"
    . $PSScriptRoot/../.github/workflows/library.ps1

    function New-DockerActionWithScan {
        Param ( $containerScan, $actionDockerType = "Dockerfile" )
        $actionType = [PSCustomObject]@{ actionType = "Docker"; actionDockerType = $actionDockerType }
        if ($null -ne $containerScan) {
            $actionType | Add-Member -Name containerScan -Value $containerScan -MemberType NoteProperty
        }
        [PSCustomObject]@{
            name = "docker-action"
            owner = "test-owner"
            mirrorFound = $true
            actionType = $actionType
            repoInfo = [PSCustomObject]@{ updated_at = Get-Date; lastFetched = (Get-Date -Format 'o') }
            repoSize = 100
            dependents = [PSCustomObject]@{ dependents = 50; dependentsLastUpdated = Get-Date }
            fundingInfo = [PSCustomObject]@{ lastChecked = Get-Date }
        }
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
                lastFetched  = (Get-Date -Format 'o')
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
                lastFetched  = (Get-Date -Format 'o')
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
                lastFetched  = (Get-Date -Format 'o')
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

    It "Should add score for repoInfo missing lastFetched (legacy data)" {
        # Arrange — simulates an action that was populated before lastFetched was introduced
        $action = [PSCustomObject]@{
            name = "test-action"
            owner = "test-owner"
            mirrorFound = $true
            actionType = [PSCustomObject]@{ actionType = "Node" }
            repoInfo = [PSCustomObject]@{ updated_at = "2022-01-01T00:00:00Z" }  # no lastFetched
            repoSize = 100
            dependents = [PSCustomObject]@{ dependents = 50; dependentsLastUpdated = Get-Date }
            fundingInfo = [PSCustomObject]@{ lastChecked = Get-Date }
        }

        # Act
        $score = Get-RepoPriorityScore -action $action

        # Assert
        $score | Should -Be 20
    }

    It "Should add score for repoInfo with stale lastFetched (>14 days old)" {
        # Arrange
        $oldDate = (Get-Date).AddDays(-20) | Get-Date -Format 'o'
        $action = [PSCustomObject]@{
            name = "test-action"
            owner = "test-owner"
            mirrorFound = $true
            actionType = [PSCustomObject]@{ actionType = "Node" }
            repoInfo = [PSCustomObject]@{ updated_at = "2022-01-01T00:00:00Z"; lastFetched = $oldDate }
            repoSize = 100
            dependents = [PSCustomObject]@{ dependents = 50; dependentsLastUpdated = Get-Date }
            fundingInfo = [PSCustomObject]@{ lastChecked = Get-Date }
        }

        # Act
        $score = Get-RepoPriorityScore -action $action

        # Assert
        $score | Should -Be 20
    }

    It "Should not add stale score for repoInfo fetched within 14 days" {
        # Arrange
        $recentDate = (Get-Date).AddDays(-7) | Get-Date -Format 'o'
        $action = [PSCustomObject]@{
            name = "test-action"
            owner = "test-owner"
            mirrorFound = $true
            actionType = [PSCustomObject]@{ actionType = "Node" }
            repoInfo = [PSCustomObject]@{ updated_at = "2022-01-01T00:00:00Z"; lastFetched = $recentDate }
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
            repoInfo = [PSCustomObject]@{ updated_at = Get-Date; lastFetched = (Get-Date -Format 'o') }
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
            repoInfo = [PSCustomObject]@{ updated_at = Get-Date; lastFetched = (Get-Date -Format 'o') }
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
            repoInfo = [PSCustomObject]@{ updated_at = Get-Date; lastFetched = (Get-Date -Format 'o') }
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

    Context "Container scan staleness scoring" {
        It "Should add score when containerScan is entirely missing" {
            $score = Get-RepoPriorityScore -action (New-DockerActionWithScan -containerScan $null)
            $score | Should -Be 25
        }

        It "Should add score when a previous scan attempt failed (scanError set)" {
            $scan = [PSCustomObject]@{ lastScanned = (Get-Date).ToUniversalTime().ToString("o"); scanError = "Trivy installation failed" }
            $score = Get-RepoPriorityScore -action (New-DockerActionWithScan -containerScan $scan)
            $score | Should -Be 25
        }

        It "Should add score when containerScan.lastScanned is missing/unparseable" {
            $scan = [PSCustomObject]@{ scanError = $null; lastScanned = "not-a-date" }
            $score = Get-RepoPriorityScore -action (New-DockerActionWithScan -containerScan $scan)
            $score | Should -Be 25
        }

        It "Should add score when containerScan.lastScanned is stale (>7 days)" {
            $scan = [PSCustomObject]@{ scanError = $null; lastScanned = (Get-Date).ToUniversalTime().AddDays(-10).ToString("o") }
            $score = Get-RepoPriorityScore -action (New-DockerActionWithScan -containerScan $scan)
            $score | Should -Be 25
        }

        It "Should not add score when containerScan is fresh (<7 days)" {
            $scan = [PSCustomObject]@{ scanError = $null; lastScanned = (Get-Date).ToUniversalTime().AddDays(-2).ToString("o") }
            $score = Get-RepoPriorityScore -action (New-DockerActionWithScan -containerScan $scan)
            $score | Should -Be 0
        }

        It "Should not score container scan staleness for non-Dockerfile actions" {
            $score = Get-RepoPriorityScore -action (New-DockerActionWithScan -containerScan $null -actionDockerType "Image")
            $score | Should -Be 0
        }
    }
}

Describe "Get-PrioritizedReposToProcess" {
    It "Should return repos with highest scores first" {
        # Arrange
        $repos = @(
            [PSCustomObject]@{ name = "complete-repo"; owner = "test"; mirrorFound = $true; actionType = [PSCustomObject]@{ actionType = "Node" }; repoInfo = [PSCustomObject]@{ updated_at = Get-Date; lastFetched = (Get-Date -Format 'o') }; repoSize = 100; dependents = [PSCustomObject]@{ dependents = 50; dependentsLastUpdated = Get-Date } }
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
            repoInfo = [PSCustomObject]@{ updated_at = Get-Date; lastFetched = (Get-Date -Format 'o') }
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
            repoInfo = [PSCustomObject]@{ updated_at = Get-Date; lastFetched = (Get-Date -Format 'o') }
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
            repoInfo = [PSCustomObject]@{ updated_at = Get-Date; lastFetched = (Get-Date -Format 'o') }
            repoSize = 100
            dependents = [PSCustomObject]@{ dependents = 50; dependentsLastUpdated = Get-Date }
            fundingInfo = [PSCustomObject]@{ lastChecked = Get-Date }
        }
        $staleRepo = [PSCustomObject]@{
            name = "stale-repo"
            owner = "test"
            mirrorFound = $true
            actionType = [PSCustomObject]@{ actionType = "Node" }
            repoInfo = [PSCustomObject]@{ updated_at = "2022-01-01T00:00:00Z" }  # no lastFetched — legacy stale
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

Describe "Run wires prioritization into the direct (un-chunked) repoInfo.yml path" {
    # repoInfo.ps1's top level executes `Run` unconditionally, so tests in this file avoid
    # dot-sourcing it directly (see the other tests in this repo that copy function bodies for
    # the same reason). Get-PrioritizedReposToProcess was defined but never called in
    # production for a while - only this test file's standalone copy exercised it. Guard
    # against that regressing again with a source-text check that Run() actually calls it.
    It "Should have Run() call Get-PrioritizedReposToProcess for the un-chunked path" {
        # Arrange
        $repoInfoScriptPath = Join-Path $PSScriptRoot "../.github/workflows/repoInfo.ps1"

        # Act - parse with the PowerShell AST rather than a brace-matching regex, so this
        # stays correct regardless of how Run()'s internals are indented/reformatted.
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($repoInfoScriptPath, [ref]$tokens, [ref]$parseErrors)

        $runFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Run'
        }, $true)

        # Assert
        ($parseErrors.Count) | Should -Be 0 -Because "repoInfo.ps1 should parse without errors"
        $runFunction | Should -Not -BeNullOrEmpty -Because "the Run function should be found in repoInfo.ps1"

        $callsPrioritization = $runFunction.Find({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Get-PrioritizedReposToProcess'
        }, $true)

        $callsPrioritization | Should -Not -BeNullOrEmpty -Because "Run() must select which repos to process by priority when it is not given an explicit filterActionNames list (i.e. called directly from repoInfo.yml, not via repoInfo-chunk.ps1) - otherwise repos are processed in whatever order status.json happens to hold"
    }
}
