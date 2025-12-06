Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "ApiCall Context Information Tests" {
    Context "When URL is empty" {
        It "Should return false when URL is empty" {
            # Arrange
            $contextInfo = "Repository: https://github.com/test/repo, File: Dockerfile"
            
            # Act
            $result = ApiCall -method GET -url "" -access_token "test_token" -contextInfo $contextInfo
            
            # Assert
            $result | Should -Be $false
        }
        
        It "Should return false when URL is null" {
            # Arrange
            $contextInfo = "Repository: https://github.com/owner/repo, File: dockerfile"
            
            # Act
            $result = ApiCall -method GET -url $null -access_token "test_token" -contextInfo $contextInfo
            
            # Assert
            $result | Should -Be $false
        }
        
        It "Should return false when URL is empty without context info" {
            # Act
            $result = ApiCall -method GET -url "" -access_token "test_token"
            
            # Assert
            $result | Should -Be $false
        }
    }
    
    Context "ApiCall with valid URL" {
        It "Should accept contextInfo parameter without error" {
            # This test verifies that adding the contextInfo parameter doesn't break normal ApiCall usage
            # We're not actually making the API call (would need valid token), just checking the parameter is accepted
            
            # Arrange
            $contextInfo = "Repository: https://github.com/test/repo, File: Dockerfile"
            
            # Act & Assert - Should not throw an error for having the parameter
            { 
                # We expect this to fail due to invalid token, but not due to the contextInfo parameter
                ApiCall -method GET -url "rate_limit" -access_token "invalid_token" -contextInfo $contextInfo -hideFailedCall $true
            } | Should -Not -Throw -Because "contextInfo parameter should be accepted"
        }
    }
    
    Context "Integration with GetRepoDockerBaseImage" {
        It "Should have contextInfo parameter in ApiCall function" {
            # Verify the ApiCall function has the contextInfo parameter
            $function = Get-Command ApiCall
            $parameters = $function.Parameters.Keys
            
            $parameters | Should -Contain "contextInfo" -Because "ApiCall should accept contextInfo parameter"
        }
    }
}
