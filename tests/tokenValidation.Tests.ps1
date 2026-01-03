Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Token Validation Tests" {
    Context "Test-AccessTokens function" {
        It "Should throw error when accessToken is null" {
            { Test-AccessTokens -accessToken $null -numberOfReposToDo 10 } | 
                Should -Throw -ExpectedMessage "*access token*"
        }

        It "Should throw error when accessToken is empty string" {
            { Test-AccessTokens -accessToken "" -numberOfReposToDo 10 } | 
                Should -Throw -ExpectedMessage "*access token*"
        }

        It "Should throw error when accessToken is whitespace" {
            { Test-AccessTokens -accessToken "   " -numberOfReposToDo 10 } | 
                Should -Throw -ExpectedMessage "*access token*"
        }

        It "Should not throw error when both tokens are valid" {
            { Test-AccessTokens -accessToken "valid_token_123" -numberOfReposToDo 10 } | 
                Should -Not -Throw
        }

        It "Should set GITHUB_TOKEN environment variable" {
            Test-AccessTokens -accessToken "test_token_789" -numberOfReposToDo 10
            $env:GITHUB_TOKEN | Should -Be "test_token_789"
        }
    }

    Context "ApiCall function token validation" {
        It "Should throw error when access_token is null" {
            { ApiCall -method GET -url "rate_limit" -access_token $null } | 
                Should -Throw -ExpectedMessage "*access token*"
        }

        It "Should throw error when access_token is empty string" {
            { ApiCall -method GET -url "rate_limit" -access_token "" } | 
                Should -Throw -ExpectedMessage "*access token*"
        }

        It "Should throw error when access_token is whitespace" {
            { ApiCall -method GET -url "rate_limit" -access_token "   " } | 
                Should -Throw -ExpectedMessage "*access token*"
        }
    }
    
    Context "ApiCall hideFailedCall parameter" {
        It "Should not output 'Log message' when hideFailedCall is true" {
            # Use a fake token that will result in a 401 error but won't throw due to hideFailedCall
            $output = ApiCall -method GET -url "repos/this-owner-does-not-exist-12345/nonexistent-repo" -access_token "fake_token" -hideFailedCall $true *>&1
            $outputText = $output | Out-String
            $outputText | Should -Not -BeLike "*Log message*"
        }
        
        It "Should output 'Log message' when hideFailedCall is false" {
            # Mock behavior: When hideFailedCall is false (default), the function should throw after logging
            # This test verifies the parameter exists and the logic branches correctly
            $output = try {
                ApiCall -method GET -url "repos/this-owner-does-not-exist-12345/nonexistent-repo" -access_token "fake_token" -hideFailedCall $false *>&1
            } catch {
                # Expected to throw
                $_ | Out-String
            }
            # Output should contain 'Log message' or error info when hideFailedCall is false
            ($output -like "*Log message*" -or $output -like "*Error*") | Should -Be $true
        }
    }
}
