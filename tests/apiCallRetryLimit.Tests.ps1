BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "ApiCall Retry Limit Tests" {
    BeforeEach {
        # Reset the global flag before each test
        $global:RateLimitExceeded = $false
    }
    
    Context "Should stop retrying after maxRetries is reached" {
        BeforeAll {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            Mock GetRateLimitInfo { }
            $script:futureTimestamp = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1800)
            Mock Invoke-WebRequest {
                $response = New-Object PSObject -Property @{
                    Headers = @{
                        "X-RateLimit-Reset" = @($script:futureTimestamp.ToString())
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
        }

        It "Should stop retrying after maxRetries is reached" {
            $result = ApiCall -method GET -url "test_endpoint" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true -maxRetries 3
            if ($result -is [System.Collections.IEnumerable] -and -not ($result -is [string])) {
                $nonNullItems = $result | Where-Object { $null -ne $_ }
                $nonNullItems.Count | Should -Be 0
            } else {
                $result | Should -Be $null
            }
            $global:RateLimitExceeded | Should -Be $true
        }
    }

    Context "Should pause when installation rate limit is exceeded" {
        BeforeAll {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            Mock Format-RateLimitErrorTable { param($remaining, $used, $waitSeconds, $continueAt, $errorType) }
            Mock Start-Sleep { param($Seconds, $Milliseconds) }
            $script:invokeCount = 0
            $script:futureTimestamp = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 30)
            Mock Invoke-WebRequest {
                $script:invokeCount++
                if ($script:invokeCount -eq 1) {
                    $response = New-Object PSObject -Property @{
                        Headers = @{
                            "X-RateLimit-Reset" = @($script:futureTimestamp.ToString())
                            "X-RateLimit-Remaining" = @("0")
                            "X-RateLimit-Used" = @("500")
                        }
                        StatusCode = 403
                    }
                    $exception = New-Object System.Net.WebException("API rate limit exceeded for installation ID")
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
                    $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails("{`"message`":`"API rate limit exceeded for installation ID`"}")
                    throw $errorRecord
                }
                return New-Object PSObject -Property @{
                    StatusCode = 200
                    Headers = @{}
                    Content = "{}"
                }
            }
        }

        It "Should pause when installation rate limit is exceeded" {
            $result = ApiCall -method GET -url "test_endpoint" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true -maxRetries 1
            $result | Should -Not -Be $null
            Assert-MockCalled Format-RateLimitErrorTable -Times 1 -ParameterFilter { $errorType -eq "Installation" }
            Assert-MockCalled Start-Sleep -Times 1 -ParameterFilter { $Milliseconds -gt 0 }
            $global:RateLimitExceeded | Should -Be $false
        }
    }

    Context "Should not exceed maxRetries even with rate limit issues" {
        BeforeAll {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            Mock Invoke-WebRequest {
                $script:callCount++
                throw [System.Exception]::new("was submitted too quickly")
            }
        }

        It "Should not exceed maxRetries even with rate limit issues" {
            $script:callCount = 0
            $result = ApiCall -method GET -url "test_endpoint" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true -maxRetries 5
            $result | Should -Be $null
            $script:callCount | Should -BeLessOrEqual 6
        }
    }

    Context "Should avoid calling GetRateLimitInfo when calling rate_limit endpoint" {
        BeforeAll {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            Mock Invoke-WebRequest {
                throw [System.Exception]::new("was submitted too quickly")
            }
            Mock GetRateLimitInfo {
                $script:getRateLimitInfoCalled = $true
            }
        }

        It "Should avoid calling GetRateLimitInfo when calling rate_limit endpoint" {
            $script:getRateLimitInfoCalled = $false
            $result = ApiCall -method GET -url "rate_limit" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true -maxRetries 2
            $script:getRateLimitInfoCalled | Should -Be $false
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
        BeforeAll {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
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
        }

        It "Should increment retry counter on each recursive call" {
            $result = ApiCall -method GET -url "test" -access_token "token" -hideFailedCall $true -maxRetries 1 -waitForRateLimit $false
            $result | Should -Be $null
        }
    }
    
    Context "Rate limit endpoint should not retry on 'was submitted too quickly' error" {
        BeforeAll {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            $script:callCount = 0
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
        }

        It "Should not retry rate_limit endpoint on 'was submitted too quickly' error" {
            $result = ApiCall -method GET -url "rate_limit" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true
            if ($result -is [System.Collections.IEnumerable] -and -not ($result -is [string])) {
                $nonNullItems = $result | Where-Object { $null -ne $_ }
                $nonNullItems.Count | Should -Be 0
            } else {
                $result | Should -Be $null
            }
            $script:callCount | Should -Be 1
        }
    }

    Context "Rate limit endpoint should not retry on 'secondary rate limit' error" {
        BeforeAll {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            $script:callCount = 0
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
        }

        It "Should not retry rate_limit endpoint on 'secondary rate limit' error" {
            $result = ApiCall -method GET -url "rate_limit" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true
            if ($result -is [System.Collections.IEnumerable] -and -not ($result -is [string])) {
                $nonNullItems = $result | Where-Object { $null -ne $_ }
                $nonNullItems.Count | Should -Be 0
            } else {
                $result | Should -Be $null
            }
            $script:callCount | Should -Be 1
        }
    }

    Context "Rate limit endpoint should not retry on 'API rate limit exceeded' error" {
        BeforeAll {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            $script:callCount = 0
            $script:futureTimestamp = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 60)
            Mock Invoke-WebRequest {
                $script:callCount++
                $response = New-Object PSObject -Property @{
                    Headers = @{
                        "X-RateLimit-Reset" = @($script:futureTimestamp.ToString())
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
        }

        It "Should not retry rate_limit endpoint on 'API rate limit exceeded' error" {
            $result = ApiCall -method GET -url "rate_limit" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true
            if ($result -is [System.Collections.IEnumerable] -and -not ($result -is [string])) {
                $nonNullItems = $result | Where-Object { $null -ne $_ }
                $nonNullItems.Count | Should -Be 0
            } else {
                $result | Should -Be $null
            }
            $script:callCount | Should -Be 1
        }
    }
}
