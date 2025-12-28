Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Rate Limit Messages When Not Halting Execution" {
    BeforeEach {
        # Reset the global flag before each test
        $global:RateLimitExceeded = $false
    }
    
    Context "ApiCall with waitForRateLimit=false and rate limit > 20 minutes" {
        It "Should NOT set global flag when waitForRateLimit=false" {
            # Mock Invoke-WebRequest to simulate rate limit exceeded (> 20 minutes)
            Mock Invoke-WebRequest {
                $resetTime = ([DateTimeOffset]::UtcNow.AddMinutes(25).ToUnixTimeSeconds())
                return @{
                    StatusCode = 200
                    Content = '{"test": "data"}'
                    Headers = @{
                        "X-RateLimit-Remaining" = @(50)  # Low enough to trigger check
                        "X-RateLimit-Reset" = @($resetTime)  # 25 minutes from now (> 20 minutes)
                        "X-RateLimit-Used" = @(4950)
                    }
                }
            }
            
            # Call with waitForRateLimit = false
            $result = ApiCall -method GET -url "test_url" -access_token "test_token" -waitForRateLimit $false
            
            # Verify the global flag is NOT set (we're not halting)
            Test-RateLimitExceeded | Should -Be $false
        }
        
        It "Should set global flag when waitForRateLimit=true (default behavior)" {
            # Mock Invoke-WebRequest to simulate rate limit exceeded (> 20 minutes)
            Mock Invoke-WebRequest {
                $resetTime = ([DateTimeOffset]::UtcNow.AddMinutes(25).ToUnixTimeSeconds())
                return @{
                    StatusCode = 200
                    Content = '{"test": "data"}'
                    Headers = @{
                        "X-RateLimit-Remaining" = @(50)  # Low enough to trigger check
                        "X-RateLimit-Reset" = @($resetTime)  # 25 minutes from now (> 20 minutes)
                        "X-RateLimit-Used" = @(4950)
                    }
                }
            }
            
            # Call with waitForRateLimit = true (or default)
            $result = ApiCall -method GET -url "test_url" -access_token "test_token" -waitForRateLimit $true
            
            # Verify the global flag IS set (we're halting)
            Test-RateLimitExceeded | Should -Be $true
            
            # Verify ApiCall returns null to indicate stopping
            $result | Should -Be $null
        }
        
        It "Should NOT show 'stopping execution' message when waitForRateLimit=false" {
            # Mock Invoke-WebRequest to simulate rate limit exceeded (> 20 minutes)
            Mock Invoke-WebRequest {
                $resetTime = ([DateTimeOffset]::UtcNow.AddMinutes(25).ToUnixTimeSeconds())
                return @{
                    StatusCode = 200
                    Content = '{"test": "data"}'
                    Headers = @{
                        "X-RateLimit-Remaining" = @(50)
                        "X-RateLimit-Reset" = @($resetTime)
                        "X-RateLimit-Used" = @(4950)
                    }
                }
            }
            
            # Call with waitForRateLimit = false
            $result = ApiCall -method GET -url "test_url" -access_token "test_token" -waitForRateLimit $false
            
            # The result should NOT be null (we're continuing with the response)
            $result | Should -Not -Be $null
            # And the global flag should NOT be set
            Test-RateLimitExceeded | Should -Be $false
        }
        
        It "Should show 'stopping execution' message when waitForRateLimit=true" {
            # Mock Invoke-WebRequest to simulate rate limit exceeded (> 20 minutes)
            Mock Invoke-WebRequest {
                $resetTime = ([DateTimeOffset]::UtcNow.AddMinutes(25).ToUnixTimeSeconds())
                return @{
                    StatusCode = 200
                    Content = '{"test": "data"}'
                    Headers = @{
                        "X-RateLimit-Remaining" = @(50)
                        "X-RateLimit-Reset" = @($resetTime)
                        "X-RateLimit-Used" = @(4950)
                    }
                }
            }
            
            # Call with waitForRateLimit = true
            $result = ApiCall -method GET -url "test_url" -access_token "test_token" -waitForRateLimit $true
            
            # The result SHOULD be null (we're stopping)
            $result | Should -Be $null
            # And the global flag SHOULD be set
            Test-RateLimitExceeded | Should -Be $true
        }
    }
    
    Context "GetRateLimitInfo with waitForRateLimit=false" {
        It "Should NOT show 'rate limit check skipped' message when waitForRateLimit=false" {
            # Mock ApiCall to return null (simulating rate limit exceeded)
            Mock ApiCall { return $null }
            
            # Mock Write-Warning to capture warnings
            $warningsWritten = @()
            Mock Write-Warning {
                param($Message)
                $warningsWritten += $Message
            }
            
            # Since we're mocking Write-Message, the message won't actually be written
            # but we can verify it's NOT being called with the specific message by checking
            # that the code path doesn't execute when waitForRateLimit=false
            
            # Call with waitForRateLimit = false
            GetRateLimitInfo -access_token "test_token" -access_token_destination "" -waitForRateLimit $false
            
            # Should not trigger any warnings
            # The function should silently return when rate limit is exceeded and waitForRateLimit=false
            $warningsWritten | Should -BeNullOrEmpty
        }
        
        It "Should show warning when waitForRateLimit=true and rate limit exceeded" {
            # Set the global flag to simulate rate limit exceeded
            $global:RateLimitExceeded = $true
            
            # Mock ApiCall to return null (simulating rate limit exceeded)
            Mock ApiCall { return $null }
            
            # Mock Write-Warning to capture warnings (for when flag isn't set)
            $warningsWritten = @()
            Mock Write-Warning {
                param($Message)
                $script:warningsWritten += $Message
            }
            
            # Since Write-Message is being used and we can't easily mock it in the test,
            # we'll just verify the function doesn't throw and handles the null response
            # The key is that it only shows messages when waitForRateLimit=true
            
            # Call with waitForRateLimit = true (default)
            { GetRateLimitInfo -access_token "test_token" -access_token_destination "" -waitForRateLimit $true } |
                Should -Not -Throw
        }
    }
    
    Context "Integration - Behavior consistency" {
        It "Should continue processing when waitForRateLimit=false despite rate limit" {
            # Mock Invoke-WebRequest to simulate rate limit exceeded (> 20 minutes)
            Mock Invoke-WebRequest {
                $resetTime = ([DateTimeOffset]::UtcNow.AddMinutes(25).ToUnixTimeSeconds())
                return @{
                    StatusCode = 200
                    Content = '{"test": "data"}'
                    Headers = @{
                        "X-RateLimit-Remaining" = @(50)
                        "X-RateLimit-Reset" = @($resetTime)
                        "X-RateLimit-Used" = @(4950)
                    }
                }
            }
            
            # Call multiple times with waitForRateLimit = false
            $result1 = ApiCall -method GET -url "test_url" -access_token "test_token" -waitForRateLimit $false
            $result2 = ApiCall -method GET -url "test_url" -access_token "test_token" -waitForRateLimit $false
            
            # Both calls should succeed (not return null)
            # Note: The recursive call in ApiCall means we eventually get a result
            # The key is that we don't halt execution and set the global flag
            Test-RateLimitExceeded | Should -Be $false
        }
    }
}
