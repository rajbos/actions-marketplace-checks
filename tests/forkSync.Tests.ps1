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
