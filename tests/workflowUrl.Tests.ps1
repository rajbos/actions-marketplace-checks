BeforeAll {
    # Import library functions
    . "$PSScriptRoot/../.github/workflows/library.ps1"
}

Describe "Get-WorkflowUrl Function" {
    Context "When GitHub Actions environment variables are set" {
        BeforeEach {
            # Save original environment variables
            $script:originalGitHubServerUrl = $env:GITHUB_SERVER_URL
            $script:originalGitHubRepository = $env:GITHUB_REPOSITORY
            
            # Set test environment variables
            $env:GITHUB_SERVER_URL = "https://github.com"
            $env:GITHUB_REPOSITORY = "testorg/testrepo"
        }
        
        AfterEach {
            # Restore original environment variables
            $env:GITHUB_SERVER_URL = $script:originalGitHubServerUrl
            $env:GITHUB_REPOSITORY = $script:originalGitHubRepository
        }
        
        It "Should generate URL using environment variables" {
            $result = Get-WorkflowUrl -workflowFileName "test.yml"
            $result | Should -Be "https://github.com/testorg/testrepo/actions/workflows/test.yml"
        }
        
        It "Should work with different workflow file names" {
            $result = Get-WorkflowUrl -workflowFileName "analyze.yml"
            $result | Should -Be "https://github.com/testorg/testrepo/actions/workflows/analyze.yml"
            
            $result = Get-WorkflowUrl -workflowFileName "report.yml"
            $result | Should -Be "https://github.com/testorg/testrepo/actions/workflows/report.yml"
        }
        
        It "Should respect GITHUB_SERVER_URL when set to GitHub Enterprise" {
            $env:GITHUB_SERVER_URL = "https://github.enterprise.com"
            $result = Get-WorkflowUrl -workflowFileName "test.yml"
            $result | Should -Be "https://github.enterprise.com/testorg/testrepo/actions/workflows/test.yml"
        }
    }
    
    Context "When GitHub Actions environment variables are not set" {
        BeforeEach {
            # Save original environment variables
            $script:originalGitHubServerUrl = $env:GITHUB_SERVER_URL
            $script:originalGitHubRepository = $env:GITHUB_REPOSITORY
            
            # Clear environment variables to test fallback
            $env:GITHUB_SERVER_URL = $null
            $env:GITHUB_REPOSITORY = $null
        }
        
        AfterEach {
            # Restore original environment variables
            $env:GITHUB_SERVER_URL = $script:originalGitHubServerUrl
            $env:GITHUB_REPOSITORY = $script:originalGitHubRepository
        }
        
        It "Should use default repository when environment variables are not set" {
            $result = Get-WorkflowUrl -workflowFileName "analyze.yml"
            $result | Should -Be "https://github.com/rajbos/actions-marketplace-checks/actions/workflows/analyze.yml"
        }
        
        It "Should use default server URL when GITHUB_SERVER_URL is not set" {
            $env:GITHUB_REPOSITORY = "someorg/somerepo"
            $result = Get-WorkflowUrl -workflowFileName "test.yml"
            $result | Should -Be "https://github.com/someorg/somerepo/actions/workflows/test.yml"
        }
    }
    
    Context "Parameter validation" {
        It "Should require workflowFileName parameter" {
            # PowerShell will prompt for required parameters in interactive mode
            # Test that the parameter is marked as mandatory
            $function = Get-Command Get-WorkflowUrl
            $param = $function.Parameters['workflowFileName']
            $param.Attributes.Mandatory | Should -Contain $true
        }
        
        It "Should accept workflow filename as named parameter" {
            $env:GITHUB_REPOSITORY = "testorg/testrepo"
            $result = Get-WorkflowUrl -workflowFileName "analyze.yml"
            $result | Should -Match "analyze.yml$"
        }
        
        It "Should accept workflow filename as positional parameter" {
            $env:GITHUB_REPOSITORY = "testorg/testrepo"
            $result = Get-WorkflowUrl "report.yml"
            $result | Should -Match "report.yml$"
        }
    }
    
    Context "Real-world workflow files" {
        BeforeEach {
            $env:GITHUB_SERVER_URL = "https://github.com"
            $env:GITHUB_REPOSITORY = "rajbos/actions-marketplace-checks"
        }
        
        It "Should generate correct URL for analyze.yml" {
            $result = Get-WorkflowUrl "analyze.yml"
            $result | Should -Be "https://github.com/rajbos/actions-marketplace-checks/actions/workflows/analyze.yml"
        }
        
        It "Should generate correct URL for repoInfo.yml" {
            $result = Get-WorkflowUrl "repoInfo.yml"
            $result | Should -Be "https://github.com/rajbos/actions-marketplace-checks/actions/workflows/repoInfo.yml"
        }
        
        It "Should generate correct URL for report.yml" {
            $result = Get-WorkflowUrl "report.yml"
            $result | Should -Be "https://github.com/rajbos/actions-marketplace-checks/actions/workflows/report.yml"
        }
        
        It "Should generate correct URL for ossf-scan.yml" {
            $result = Get-WorkflowUrl "ossf-scan.yml"
            $result | Should -Be "https://github.com/rajbos/actions-marketplace-checks/actions/workflows/ossf-scan.yml"
        }
        
        It "Should generate correct URL for dependabot-updates.yml" {
            $result = Get-WorkflowUrl "dependabot-updates.yml"
            $result | Should -Be "https://github.com/rajbos/actions-marketplace-checks/actions/workflows/dependabot-updates.yml"
        }
    }
}
