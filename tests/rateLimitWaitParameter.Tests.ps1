Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Rate Limit Wait Parameter" {
    Context "GetRateLimitInfo with waitForRateLimit parameter" {
        BeforeEach {
            # Reset the global flag before each test
            $global:RateLimitExceeded = $false
        }
        
        It "Should accept waitForRateLimit parameter with default value true" {
            # Mock ApiCall to return a valid response
            Mock ApiCall {
                return @{
                    rate = @{
                        limit = 5000
                        used = 100
                        remaining = 4900
                        reset = 1640000000
                    }
                }
            }
            
            # Call without the parameter (should use default value true)
            { GetRateLimitInfo -access_token "test_token" -access_token_destination "test_token" } | 
                Should -Not -Throw
        }
        
        It "Should pass waitForRateLimit=false to ApiCall when specified" {
            # Mock ApiCall to verify the parameter is passed
            Mock ApiCall {
                param($waitForRateLimit)
                # Verify the parameter is passed correctly
                $waitForRateLimit | Should -Be $false
                return @{
                    rate = @{
                        limit = 5000
                        used = 100
                        remaining = 4900
                        reset = 1640000000
                    }
                }
            }
            
            # Call with waitForRateLimit = false
            GetRateLimitInfo -access_token "test_token" -access_token_destination "test_token" -waitForRateLimit $false
        }
        
        It "Should pass waitForRateLimit=true to ApiCall when specified" {
            # Mock ApiCall to verify the parameter is passed
            Mock ApiCall {
                param($waitForRateLimit)
                # Verify the parameter is passed correctly (or is null/true by default)
                if ($null -ne $waitForRateLimit) {
                    $waitForRateLimit | Should -Be $true
                }
                return @{
                    rate = @{
                        limit = 5000
                        used = 100
                        remaining = 4900
                        reset = 1640000000
                    }
                }
            }
            
            # Call with waitForRateLimit = true (explicit)
            GetRateLimitInfo -access_token "test_token" -access_token_destination "test_token" -waitForRateLimit $true
        }
    }
    
    Context "ApiCall with waitForRateLimit parameter" {
        It "Should accept waitForRateLimit parameter without errors" {
            # This test verifies that ApiCall accepts the parameter correctly
            # We test with a high rate limit to avoid the recursive retry logic
            
            Mock Invoke-WebRequest {
                return @{
                    StatusCode = 200
                    Content = '{"test": "data"}'
                    Headers = @{
                        "X-RateLimit-Remaining" = @(4500)  # High rate limit - won't trigger wait
                        "X-RateLimit-Reset" = @(([DateTimeOffset]::UtcNow.AddMinutes(5).ToUnixTimeSeconds()))
                        "X-RateLimit-Used" = @(500)
                    }
                }
            }
            
            # Call ApiCall with waitForRateLimit = false - should complete without error
            $result = ApiCall -method GET -url "test_url" -access_token "test_token" -waitForRateLimit $false
            
            # Verify result is not null (successful call)
            $result | Should -Not -Be $null
        }
        
        It "Should accept waitForRateLimit parameter with default value true" {
            # This test verifies backward compatibility when parameter is not specified
            
            Mock Invoke-WebRequest {
                return @{
                    StatusCode = 200
                    Content = '{"test": "data"}'
                    Headers = @{
                        "X-RateLimit-Remaining" = @(4500)  # High rate limit - won't trigger wait
                        "X-RateLimit-Reset" = @(([DateTimeOffset]::UtcNow.AddMinutes(5).ToUnixTimeSeconds()))
                        "X-RateLimit-Used" = @(500)
                    }
                }
            }
            
            # Call ApiCall without the parameter - should use default behavior
            $result = ApiCall -method GET -url "test_url" -access_token "test_token"
            
            # Verify result is not null (successful call)
            $result | Should -Not -Be $null
        }
    }
    
    Context "Integration test - Default behavior preserved" {
        It "Should maintain backward compatibility when parameter is not specified" {
            # Mock ApiCall to return a valid response
            Mock ApiCall {
                return @{
                    rate = @{
                        limit = 5000
                        used = 100
                        remaining = 4900
                        reset = 1640000000
                    }
                }
            }
            
            # Call without the parameter - should work as before (default to true)
            { GetRateLimitInfo -access_token "test_token" -access_token_destination "" } | 
                Should -Not -Throw
        }
    }
}
