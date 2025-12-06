BeforeAll {
    # Set mock tokens to avoid validation errors
    $env:GITHUB_TOKEN = "test_token_mock"
    
    # Load library
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Analyze Workflow Chunking Functions" {
    Context "Split-ActionsIntoChunks function" {
        It "Should split actions evenly into chunks" {
            $testData = @(
                @{ name = "action1"; repoUrl = "https://github.com/owner1/repo1" }
                @{ name = "action2"; repoUrl = "https://github.com/owner2/repo2" }
                @{ name = "action3"; repoUrl = "https://github.com/owner3/repo3" }
                @{ name = "action4"; repoUrl = "https://github.com/owner4/repo4" }
                @{ name = "action5"; repoUrl = "https://github.com/owner5/repo5" }
                @{ name = "action6"; repoUrl = "https://github.com/owner6/repo6" }
                @{ name = "action7"; repoUrl = "https://github.com/owner7/repo7" }
                @{ name = "action8"; repoUrl = "https://github.com/owner8/repo8" }
            )
            
            $chunks = Split-ActionsIntoChunks -actions $testData -numberOfChunks 2
            
            $chunks.Count | Should -Be 2
            $chunks[0].Count | Should -Be 4
            $chunks[1].Count | Should -Be 4
        }
        
        It "Should handle uneven splits" {
            $testData = @(
                @{ name = "action1"; repoUrl = "https://github.com/owner1/repo1" }
                @{ name = "action2"; repoUrl = "https://github.com/owner2/repo2" }
                @{ name = "action3"; repoUrl = "https://github.com/owner3/repo3" }
                @{ name = "action4"; repoUrl = "https://github.com/owner4/repo4" }
                @{ name = "action5"; repoUrl = "https://github.com/owner5/repo5" }
            )
            
            $chunks = Split-ActionsIntoChunks -actions $testData -numberOfChunks 2
            
            $chunks.Count | Should -Be 2
            $chunks[0].Count | Should -Be 3  # Ceiling(5/2) = 3
            $chunks[1].Count | Should -Be 2
        }
        
        It "Should filter to actions with repoUrl when filterToUnprocessed is true" {
            $testData = @(
                @{ name = "action1"; repoUrl = "https://github.com/owner1/repo1" }
                @{ name = "action2"; repoUrl = "" }
                @{ name = "action3"; repoUrl = "https://github.com/owner3/repo3" }
                @{ name = "action4" }  # No repoUrl property
            )
            
            $chunks = Split-ActionsIntoChunks -actions $testData -numberOfChunks 2 -filterToUnprocessed $true
            
            $chunks.Count | Should -Be 2
            # Should only include action1 and action3
            ($chunks[0] + $chunks[1]).Count | Should -Be 2
        }
        
        It "Should handle empty action list" {
            $testData = @()
            
            $chunks = Split-ActionsIntoChunks -actions $testData -numberOfChunks 2
            
            $chunks.Count | Should -Be 0
        }
        
        It "Should handle actions without repoUrl when filtering" {
            $testData = @(
                @{ name = "action1"; repoUrl = "" }
                @{ name = "action2" }
            )
            
            $chunks = Split-ActionsIntoChunks -actions $testData -numberOfChunks 2 -filterToUnprocessed $true
            
            $chunks.Count | Should -Be 0
        }
        
        It "Should handle more chunks than actions" {
            $testData = @(
                @{ name = "action1"; repoUrl = "https://github.com/owner1/repo1" }
                @{ name = "action2"; repoUrl = "https://github.com/owner2/repo2" }
            )
            
            $chunks = Split-ActionsIntoChunks -actions $testData -numberOfChunks 5
            
            # Should create only as many chunks as needed
            $chunks.Count | Should -BeLessOrEqual 5
            # Total items should equal number of valid actions
            $totalItems = 0
            foreach ($key in $chunks.Keys) {
                $totalItems += $chunks[$key].Count
            }
            $totalItems | Should -Be 2
        }
        
        It "Should use forkedRepoName if name is not available" {
            $testData = @(
                @{ forkedRepoName = "owner1_repo1"; repoUrl = "https://github.com/owner1/repo1" }
                @{ forkedRepoName = "owner2_repo2"; repoUrl = "https://github.com/owner2/repo2" }
            )
            
            $chunks = Split-ActionsIntoChunks -actions $testData -numberOfChunks 1
            
            $chunks.Count | Should -Be 1
            $chunks[0].Count | Should -Be 2
            $chunks[0] | Should -Contain "owner1_repo1"
            $chunks[0] | Should -Contain "owner2_repo2"
        }
        
        It "Should prioritize forkedRepoName over name property" {
            $testData = @(
                @{ forkedRepoName = "owner1_repo1"; name = "action1"; repoUrl = "https://github.com/owner1/repo1" }
                @{ forkedRepoName = "owner2_repo2"; name = "action2"; repoUrl = "https://github.com/owner2/repo2" }
            )
            
            $chunks = Split-ActionsIntoChunks -actions $testData -numberOfChunks 1
            
            $chunks.Count | Should -Be 1
            $chunks[0].Count | Should -Be 2
            # Should use forkedRepoName, not name
            $chunks[0] | Should -Contain "owner1_repo1"
            $chunks[0] | Should -Contain "owner2_repo2"
            $chunks[0] | Should -Not -Contain "action1"
            $chunks[0] | Should -Not -Contain "action2"
        }
    }
    
    Context "Integration with existing Split-ForksIntoChunks" {
        It "Should work similarly to Split-ForksIntoChunks" {
            $testActions = @(
                @{ name = "action1"; repoUrl = "https://github.com/owner1/repo1" }
                @{ name = "action2"; repoUrl = "https://github.com/owner2/repo2" }
                @{ name = "action3"; repoUrl = "https://github.com/owner3/repo3" }
                @{ name = "action4"; repoUrl = "https://github.com/owner4/repo4" }
            )
            
            $testForks = @(
                @{ name = "fork1"; forkFound = $true }
                @{ name = "fork2"; forkFound = $true }
                @{ name = "fork3"; forkFound = $true }
                @{ name = "fork4"; forkFound = $true }
            )
            
            $actionChunks = Split-ActionsIntoChunks -actions $testActions -numberOfChunks 2
            $forkChunks = Split-ForksIntoChunks -existingForks $testForks -numberOfChunks 2
            
            # Both should split into 2 chunks
            $actionChunks.Count | Should -Be 2
            $forkChunks.Count | Should -Be 2
            
            # Both should have 2 items per chunk
            $actionChunks[0].Count | Should -Be 2
            $forkChunks[0].Count | Should -Be 2
        }
    }
}
