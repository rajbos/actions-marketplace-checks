Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Token Validation Tests" {
    Context "Test-AccessTokens function" {
        It "Should throw error when accessToken is null" {
            { Test-AccessTokens -accessToken $null -access_token_destination "valid_token" -numberOfReposToDo 10 } | 
                Should -Throw -ExpectedMessage "*No access token provided*"
        }

        It "Should throw error when accessToken is empty string" {
            { Test-AccessTokens -accessToken "" -access_token_destination "valid_token" -numberOfReposToDo 10 } | 
                Should -Throw -ExpectedMessage "*No access token provided*"
        }

        It "Should throw error when accessToken is whitespace" {
            { Test-AccessTokens -accessToken "   " -access_token_destination "valid_token" -numberOfReposToDo 10 } | 
                Should -Throw -ExpectedMessage "*No access token provided*"
        }

        It "Should throw error when access_token_destination is null" {
            { Test-AccessTokens -accessToken "valid_token" -access_token_destination $null -numberOfReposToDo 10 } | 
                Should -Throw -ExpectedMessage "*No access token for destination provided*"
        }

        It "Should throw error when access_token_destination is empty string" {
            { Test-AccessTokens -accessToken "valid_token" -access_token_destination "" -numberOfReposToDo 10 } | 
                Should -Throw -ExpectedMessage "*No access token for destination provided*"
        }

        It "Should not throw error when both tokens are valid" {
            { Test-AccessTokens -accessToken "valid_token_123" -access_token_destination "valid_token_456" -numberOfReposToDo 10 } | 
                Should -Not -Throw
        }

        It "Should set GITHUB_TOKEN environment variable" {
            Test-AccessTokens -accessToken "test_token_789" -access_token_destination "dest_token_789" -numberOfReposToDo 10
            $env:GITHUB_TOKEN | Should -Be "test_token_789"
        }
    }

    Context "ApiCall function token validation" {
        It "Should throw error when access_token is null" {
            { ApiCall -method GET -url "rate_limit" -access_token $null } | 
                Should -Throw -ExpectedMessage "*No access token available*"
        }

        It "Should throw error when access_token is empty string" {
            { ApiCall -method GET -url "rate_limit" -access_token "" } | 
                Should -Throw -ExpectedMessage "*No access token available*"
        }

        It "Should throw error when access_token is whitespace" {
            { ApiCall -method GET -url "rate_limit" -access_token "   " } | 
                Should -Throw -ExpectedMessage "*No access token available*"
        }
    }
}
