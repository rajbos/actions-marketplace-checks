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
            $command.Parameters.Keys | Should -Contain "Command"
            $command.Parameters.Keys | Should -Contain "Description"
            $command.Parameters.Keys | Should -Contain "MaxRetries"
            $command.Parameters.Keys | Should -Contain "InitialDelaySeconds"
        }
        
        It "Should return success for git version command" {
            $result = Invoke-GitCommandWithRetry -Command "git --version 2>&1" -Description "Test git version" -MaxRetries 1 -InitialDelaySeconds 1
            $result.Success | Should -Be $true
            $result.ExitCode | Should -Be 0
        }
        
        It "Should return failure for non-existent command" {
            $result = Invoke-GitCommandWithRetry -Command "git nonexistent-command 2>&1" -Description "Test failure" -MaxRetries 1 -InitialDelaySeconds 1
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
}
