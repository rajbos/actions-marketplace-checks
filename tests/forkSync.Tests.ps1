Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Mirror Sync Tests" {
    Context "SyncMirrorWithUpstream function" {
        It "Should have function defined" {
            $result = Get-Command SyncMirrorWithUpstream
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Be "SyncMirrorWithUpstream"
        }
        
        It "Should have required parameters" {
            $command = Get-Command SyncMirrorWithUpstream
            $command.Parameters.Keys | Should -Contain "owner"
            $command.Parameters.Keys | Should -Contain "repo"
            $command.Parameters.Keys | Should -Contain "upstreamOwner"
            $command.Parameters.Keys | Should -Contain "upstreamRepo"
            $command.Parameters.Keys | Should -Contain "access_token"
        }
        
        It "Should return validation error for empty upstream owner" {
            $result = SyncMirrorWithUpstream -owner "test" -repo "test" -upstreamOwner "" -upstreamRepo "test" -access_token "test_token"
            $result.success | Should -Be $false
            $result.error_type | Should -Be "validation_error"
        }
        
        It "Should return validation error for empty upstream repo" {
            $result = SyncMirrorWithUpstream -owner "test" -repo "test" -upstreamOwner "test" -upstreamRepo "" -access_token "test_token"
            $result.success | Should -Be $false
            $result.error_type | Should -Be "validation_error"
        }
        
        It "Should return validation error for null upstream owner" {
            $result = SyncMirrorWithUpstream -owner "test" -repo "test" -upstreamOwner $null -upstreamRepo "test" -access_token "test_token"
            $result.success | Should -Be $false
            $result.error_type | Should -Be "validation_error"
        }
    }
    
    Context "Test-RepositoryExists function" {
        It "Should have function defined" {
            $result = Get-Command Test-RepositoryExists
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Be "Test-RepositoryExists"
        }
        
        It "Should have required parameters" {
            $command = Get-Command Test-RepositoryExists
            $command.Parameters.Keys | Should -Contain "owner"
            $command.Parameters.Keys | Should -Contain "repo"
            $command.Parameters.Keys | Should -Contain "access_token"
        }
        
        It "Should return false for empty owner" {
            $result = Test-RepositoryExists -owner "" -repo "test" -access_token "test_token"
            $result | Should -Be $false
        }
        
        It "Should return false for empty repo" {
            $result = Test-RepositoryExists -owner "test" -repo "" -access_token "test_token"
            $result | Should -Be $false
        }
        
        It "Should return false for null owner" {
            $result = Test-RepositoryExists -owner $null -repo "test" -access_token "test_token"
            $result | Should -Be $false
        }
        
        It "Should return false for whitespace-only owner" {
            $result = Test-RepositoryExists -owner "   " -repo "test" -access_token "test_token"
            $result | Should -Be $false
        }
    }
    
    Context "Invoke-GitCommandWithRetry function" {
        It "Should have function defined" {
            $result = Get-Command Invoke-GitCommandWithRetry
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Be "Invoke-GitCommandWithRetry"
        }
        
        It "Should have required parameters" {
            $command = Get-Command Invoke-GitCommandWithRetry
            $command.Parameters.Keys | Should -Contain "GitCommand"
            $command.Parameters.Keys | Should -Contain "GitArguments"
            $command.Parameters.Keys | Should -Contain "Description"
            $command.Parameters.Keys | Should -Contain "MaxRetries"
            $command.Parameters.Keys | Should -Contain "InitialDelaySeconds"
        }
        
        It "Should return success for git version command" {
            $result = Invoke-GitCommandWithRetry -GitCommand "--version" -Description "Test git version" -MaxRetries 1 -InitialDelaySeconds 1
            $result.Success | Should -Be $true
            $result.ExitCode | Should -Be 0
        }
        
        It "Should return failure for non-existent command" {
            $result = Invoke-GitCommandWithRetry -GitCommand "nonexistent-command" -Description "Test failure" -MaxRetries 1 -InitialDelaySeconds 1
            $result.Success | Should -Be $false
        }
    }
    
    Context "UpdateForkedRepos function from update-forks.ps1" {
        It "Should have UpdateForkedRepos function defined after script execution" {
            # Dot source the script content to define functions without executing main logic
            $scriptContent = Get-Content $PSScriptRoot/../.github/workflows/update-forks.ps1 -Raw
            # Extract just the function definition
            $functionMatch = [regex]::Match($scriptContent, 'function UpdateForkedRepos\s*\{[\s\S]*?\n\}(?=\s*\n)')
            
            $functionMatch.Success | Should -Be $true
            $functionMatch.Value | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Disable-GitHubActions function" {
        It "Should have function defined" {
            $result = Get-Command Disable-GitHubActions
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Be "Disable-GitHubActions"
        }
        
        It "Should have required parameters" {
            $command = Get-Command Disable-GitHubActions
            $command.Parameters.Keys | Should -Contain "owner"
            $command.Parameters.Keys | Should -Contain "repo"
            $command.Parameters.Keys | Should -Contain "access_token"
        }
        
        It "Should return false for empty owner" {
            $result = Disable-GitHubActions -owner "" -repo "test" -access_token "test_token" 3>$null
            $result | Should -Be $false
        }
        
        It "Should return false for empty repo" {
            $result = Disable-GitHubActions -owner "test" -repo "" -access_token "test_token" 3>$null
            $result | Should -Be $false
        }
        
        It "Should return false for null owner" {
            $result = Disable-GitHubActions -owner $null -repo "test" -access_token "test_token" 3>$null
            $result | Should -Be $false
        }
        
        It "Should return false for whitespace-only owner" {
            $result = Disable-GitHubActions -owner "   " -repo "test" -access_token "test_token" 3>$null
            $result | Should -Be $false
        }
        
        It "Should return false for whitespace-only repo" {
            $result = Disable-GitHubActions -owner "test" -repo "   " -access_token "test_token" 3>$null
            $result | Should -Be $false
        }
    }
    
    Context "Get-RepositoryDefaultBranchCommit function" {
        It "Should have function defined" {
            $result = Get-Command Get-RepositoryDefaultBranchCommit
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Be "Get-RepositoryDefaultBranchCommit"
        }
        
        It "Should have required parameters" {
            $command = Get-Command Get-RepositoryDefaultBranchCommit
            $command.Parameters.Keys | Should -Contain "owner"
            $command.Parameters.Keys | Should -Contain "repo"
            $command.Parameters.Keys | Should -Contain "access_token"
        }
        
        It "Should return failure for empty owner" {
            $result = Get-RepositoryDefaultBranchCommit -owner "" -repo "test" -access_token "test_token"
            $result.success | Should -Be $false
            $result.sha | Should -BeNullOrEmpty
            $result.error | Should -Be "Invalid owner or repo"
        }
        
        It "Should return failure for empty repo" {
            $result = Get-RepositoryDefaultBranchCommit -owner "test" -repo "" -access_token "test_token"
            $result.success | Should -Be $false
            $result.sha | Should -BeNullOrEmpty
            $result.error | Should -Be "Invalid owner or repo"
        }
        
        It "Should return failure for null owner" {
            $result = Get-RepositoryDefaultBranchCommit -owner $null -repo "test" -access_token "test_token"
            $result.success | Should -Be $false
            $result.sha | Should -BeNullOrEmpty
        }
        
        It "Should return failure for whitespace-only owner" {
            $result = Get-RepositoryDefaultBranchCommit -owner "   " -repo "test" -access_token "test_token"
            $result.success | Should -Be $false
            $result.error | Should -Be "Invalid owner or repo"
        }
    }
    
    Context "Compare-RepositoryCommitHashes function" {
        It "Should have function defined" {
            $result = Get-Command Compare-RepositoryCommitHashes
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Be "Compare-RepositoryCommitHashes"
        }
        
        It "Should have required parameters" {
            $command = Get-Command Compare-RepositoryCommitHashes
            $command.Parameters.Keys | Should -Contain "sourceOwner"
            $command.Parameters.Keys | Should -Contain "sourceRepo"
            $command.Parameters.Keys | Should -Contain "mirrorOwner"
            $command.Parameters.Keys | Should -Contain "mirrorRepo"
            $command.Parameters.Keys | Should -Contain "access_token"
        }
        
        It "Should return can_compare false for empty source owner" {
            $result = Compare-RepositoryCommitHashes -sourceOwner "" -sourceRepo "test" -mirrorOwner "test" -mirrorRepo "test" -access_token "test_token"
            $result.can_compare | Should -Be $false
            $result.in_sync | Should -Be $false
        }
        
        It "Should return can_compare false for empty source repo" {
            $result = Compare-RepositoryCommitHashes -sourceOwner "test" -sourceRepo "" -mirrorOwner "test" -mirrorRepo "test" -access_token "test_token"
            $result.can_compare | Should -Be $false
            $result.in_sync | Should -Be $false
        }
        
        It "Should return can_compare false for empty mirror owner" {
            $result = Compare-RepositoryCommitHashes -sourceOwner "test" -sourceRepo "test" -mirrorOwner "" -mirrorRepo "test" -access_token "test_token"
            $result.can_compare | Should -Be $false
            $result.in_sync | Should -Be $false
        }
        
        It "Should return can_compare false for empty mirror repo" {
            $result = Compare-RepositoryCommitHashes -sourceOwner "test" -sourceRepo "test" -mirrorOwner "test" -mirrorRepo "" -access_token "test_token"
            $result.can_compare | Should -Be $false
            $result.in_sync | Should -Be $false
        }
        
        It "Should have error message when comparison fails" {
            $result = Compare-RepositoryCommitHashes -sourceOwner "" -sourceRepo "test" -mirrorOwner "test" -mirrorRepo "test" -access_token "test_token"
            $result.error | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "LFS handling in SyncMirrorWithUpstream" {
        It "Should set GIT_LFS_SKIP_SMUDGE environment variable during sync operations" {
            # This test verifies that the fix for LFS errors is in place
            # We check if the code sets the environment variable by examining the function source
            $functionContent = (Get-Command SyncMirrorWithUpstream).Definition
            $functionContent | Should -Match 'GIT_LFS_SKIP_SMUDGE'
        }
        
        It "Should have cleanup code for GIT_LFS_SKIP_SMUDGE environment variable" {
            # Verify that cleanup code exists to remove the environment variable
            $functionContent = (Get-Command SyncMirrorWithUpstream).Definition
            $functionContent | Should -Match 'Remove-Item Env:\\GIT_LFS_SKIP_SMUDGE'
        }
        
        It "Should mention LFS in debug messages" {
            # Verify that the debug messaging indicates LFS handling
            $functionContent = (Get-Command SyncMirrorWithUpstream).Definition
            $functionContent | Should -Match 'LFS skip smudge enabled'
        }
    }
}
