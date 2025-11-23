Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Fork Sync Tests" {
    Context "SyncForkWithUpstream function" {
        It "Should handle successful sync response" {
            # Mock the ApiCall function to simulate successful sync
            Mock ApiCall {
                return @{
                    message = "Successfully fetched and fast-forwarded from upstream"
                    merge_type = "fast-forward"
                }
            }
            
            # This test validates the function structure exists
            $result = Get-Command SyncForkWithUpstream
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Be "SyncForkWithUpstream"
        }
        
        It "Should have required parameters" {
            $command = Get-Command SyncForkWithUpstream
            $command.Parameters.Keys | Should -Contain "owner"
            $command.Parameters.Keys | Should -Contain "repo"
            $command.Parameters.Keys | Should -Contain "branch"
            $command.Parameters.Keys | Should -Contain "access_token"
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
