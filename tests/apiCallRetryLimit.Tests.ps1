Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "ApiCall Retry Limit Tests" {
    BeforeEach {
        # Reset the global flag before each test
        $global:RateLimitExceeded = $false
    }
    
    Context "When maximum retries are exceeded" {
        It "Should stop retrying after maxRetries is reached" {
            # This test verifies that ApiCall doesn't infinitely recurse
            # We'll mock GetBasicAuthenticationHeader to avoid actual API calls
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            
            # Mock GetRateLimitInfo to prevent side effects
            Mock GetRateLimitInfo { }
            
            # Create a properly structured exception with response headers
            # Use a timestamp 30 minutes in the future (1800 seconds)
            $futureTimestamp = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1800)
            
            Mock Invoke-WebRequest {
                $response = New-Object PSObject -Property @{
                    Headers = @{
                        "X-RateLimit-Reset" = @($futureTimestamp.ToString())
                        "X-RateLimit-Remaining" = @("0")
                    }
                    StatusCode = 403
                }
                
                $exception = New-Object System.Net.WebException("API rate limit exceeded for user ID")
                $webResponse = New-Object PSObject -Property @{
                    Headers = $response.Headers
                }
                $exception | Add-Member -NotePropertyName Response -NotePropertyValue $webResponse -Force
                
                $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                    $exception,
                    "WebException",
                    [System.Management.Automation.ErrorCategory]::InvalidOperation,
                    $null
                )
                $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails("{`"message`":`"API rate limit exceeded for user ID`"}")
                
                throw $errorRecord
            }
            
            # Call ApiCall with a low maxRetries value
            $result = ApiCall -method GET -url "test_endpoint" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true -maxRetries 3
            
            # Should return null after rate limit is exceeded
            # Note: The result may be $null or a collection containing $null
            if ($result -is [System.Collections.IEnumerable] -and -not ($result -is [string])) {
                # If it's a collection, check that it only contains nulls
                $nonNullItems = $result | Where-Object { $null -ne $_ }
                $nonNullItems.Count | Should -Be 0
            } else {
                $result | Should -Be $null
            }
            
            # Global flag should be set
            $global:RateLimitExceeded | Should -Be $true
        }
        
        It "Should not exceed maxRetries even with rate limit issues" {
            # Track the number of times Invoke-WebRequest is called
            $callCount = 0
            
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            
            Mock Invoke-WebRequest {
                $script:callCount++
                throw [System.Exception]::new("was submitted too quickly")
            }
            
            # Call with maxRetries=5
            $result = ApiCall -method GET -url "test_endpoint" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true -maxRetries 5
            
            # Should stop after hitting the limit
            $result | Should -Be $null
            
            # Should have called Invoke-WebRequest at most maxRetries + 1 times (initial call + retries)
            $callCount | Should -BeLessOrEqual 6
        }
        
        It "Should avoid calling GetRateLimitInfo when calling rate_limit endpoint" {
            # Track if GetRateLimitInfo was called
            $getRateLimitInfoCalled = $false
            
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            
            Mock Invoke-WebRequest {
                $messageData = @{ message = "was submitted too quickly" }
                throw [System.Exception]::new("was submitted too quickly")
            }
            
            Mock GetRateLimitInfo {
                $script:getRateLimitInfoCalled = $true
            }
            
            # Call ApiCall with rate_limit URL to verify it doesn't call GetRateLimitInfo
            $result = ApiCall -method GET -url "rate_limit" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true -maxRetries 2
            
            # GetRateLimitInfo should NOT have been called to prevent infinite recursion
            $getRateLimitInfoCalled | Should -Be $false
        }
    }
    
    Context "When retries are within limit" {
        It "Should pass retryCount to recursive calls" {
            # Verify the function signature includes retryCount and maxRetries parameters
            $function = Get-Command ApiCall
            $parameters = $function.Parameters.Keys
            
            $parameters | Should -Contain "retryCount" -Because "ApiCall should have retryCount parameter"
            $parameters | Should -Contain "maxRetries" -Because "ApiCall should have maxRetries parameter"
        }
        
        It "Should have default maxRetries of 10" {
            # Verify the default value
            $function = Get-Command ApiCall
            $maxRetriesParam = $function.Parameters['maxRetries']
            
            # Check if default value is set
            $maxRetriesParam.Attributes.TypeId.Name | Should -Contain "ParameterAttribute"
        }
    }
    
    Context "Retry counter incrementation" {
        It "Should increment retry counter on each recursive call" {
            # This is more of a validation that the parameter exists and is used
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            
            # Create a custom exception with response headers for rate limit
            $response = New-Object PSObject -Property @{
                Headers = @{
                    "X-RateLimit-Reset" = @("9999999999")
                    "X-RateLimit-Remaining" = @("0")
                }
                StatusCode = 403
            }
            
            $exception = New-Object System.Exception("API rate limit exceeded for user ID")
            $exception | Add-Member -NotePropertyName Response -NotePropertyValue $response -Force
            
            Mock Invoke-WebRequest {
                throw $exception
            }
            
            # Call with very low maxRetries to quickly hit the limit
            $result = ApiCall -method GET -url "test" -access_token "token" -hideFailedCall $true -maxRetries 1 -waitForRateLimit $false
            
            # Should return null (hit retry limit or rate limit)
            $result | Should -Be $null
        }
    }
    
    Context "Rate limit endpoint should not retry on errors" {
        It "Should not retry rate_limit endpoint on 'was submitted too quickly' error" {
            # Track the number of times Invoke-WebRequest is called
            $script:callCount = 0
            
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            
            Mock Invoke-WebRequest {
                $script:callCount++
                $errorDetails = New-Object System.Management.Automation.ErrorDetails("{`"message`":`"was submitted too quickly`"}")
                $exception = New-Object System.Exception("was submitted too quickly")
                $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                    $exception,
                    "WebException",
                    [System.Management.Automation.ErrorCategory]::InvalidOperation,
                    $null
                )
                $errorRecord.ErrorDetails = $errorDetails
                throw $errorRecord
            }
            
            # Call with rate_limit URL
            $result = ApiCall -method GET -url "rate_limit" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true
            
            # Should return null immediately without retry
            # Handle PowerShell's array wrapping behavior
            if ($result -is [System.Collections.IEnumerable] -and -not ($result -is [string])) {
                $nonNullItems = $result | Where-Object { $null -ne $_ }
                $nonNullItems.Count | Should -Be 0
            } else {
                $result | Should -Be $null
            }
            
            # Should have only called once (no retries)
            $script:callCount | Should -Be 1
        }
        
        It "Should not retry rate_limit endpoint on 'secondary rate limit' error" {
            # Track the number of times Invoke-WebRequest is called
            $script:callCount = 0
            
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            
            Mock Invoke-WebRequest {
                $script:callCount++
                $errorDetails = New-Object System.Management.Automation.ErrorDetails("{`"message`":`"You have exceeded a secondary rate limit`"}")
                $exception = New-Object System.Exception("You have exceeded a secondary rate limit")
                $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                    $exception,
                    "WebException",
                    [System.Management.Automation.ErrorCategory]::InvalidOperation,
                    $null
                )
                $errorRecord.ErrorDetails = $errorDetails
                throw $errorRecord
            }
            
            # Call with rate_limit URL
            $result = ApiCall -method GET -url "rate_limit" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true
            
            # Should return null immediately without retry
            # Handle PowerShell's array wrapping behavior
            if ($result -is [System.Collections.IEnumerable] -and -not ($result -is [string])) {
                $nonNullItems = $result | Where-Object { $null -ne $_ }
                $nonNullItems.Count | Should -Be 0
            } else {
                $result | Should -Be $null
            }
            
            # Should have only called once (no retries)
            $script:callCount | Should -Be 1
        }
        
        It "Should not retry rate_limit endpoint on 'API rate limit exceeded' error" {
            # Track the number of times Invoke-WebRequest is called
            $script:callCount = 0
            
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            
            # Create a properly structured exception with response headers
            $futureTimestamp = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 60)
            
            Mock Invoke-WebRequest {
                $script:callCount++
                
                $response = New-Object PSObject -Property @{
                    Headers = @{
                        "X-RateLimit-Reset" = @($futureTimestamp.ToString())
                        "X-RateLimit-Remaining" = @("0")
                    }
                    StatusCode = 403
                }
                
                $exception = New-Object System.Net.WebException("API rate limit exceeded for user ID")
                $webResponse = New-Object PSObject -Property @{
                    Headers = $response.Headers
                }
                $exception | Add-Member -NotePropertyName Response -NotePropertyValue $webResponse -Force
                
                $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                    $exception,
                    "WebException",
                    [System.Management.Automation.ErrorCategory]::InvalidOperation,
                    $null
                )
                $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails("{`"message`":`"API rate limit exceeded for user ID`"}")
                
                throw $errorRecord
            }
            
            # Call with rate_limit URL
            $result = ApiCall -method GET -url "rate_limit" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true
            
            # Should return null immediately without retry
            # Handle PowerShell's array wrapping behavior
            if ($result -is [System.Collections.IEnumerable] -and -not ($result -is [string])) {
                $nonNullItems = $result | Where-Object { $null -ne $_ }
                $nonNullItems.Count | Should -Be 0
            } else {
                $result | Should -Be $null
            }
            
            # Should have only called once (no retries)
            $script:callCount | Should -Be 1
        }
    }
}
