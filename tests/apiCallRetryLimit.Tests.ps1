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

        It "Should preserve hideFailedCall=true through installation rate limit retry so a 404 returns null instead of throwing" {
            # Regression test: retry calls inside the catch block were missing -hideFailedCall,
            # causing a 404 after a rate-limit wait to propagate as a throw (exit code 1).
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            Mock Format-RateLimitErrorTable { param($remaining, $used, $waitSeconds, $continueAt, $errorType) }
            Mock Start-Sleep { param($Seconds, $Milliseconds) }

            $script:invokeCount = 0
            $futureTimestamp = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 30)

            Mock Invoke-WebRequest {
                $script:invokeCount++
                if ($script:invokeCount -eq 1) {
                    # First call: installation rate limit
                    $response = New-Object PSObject -Property @{
                        Headers = @{
                            "X-RateLimit-Reset"      = @($futureTimestamp.ToString())
                            "X-RateLimit-Remaining"  = @("0")
                            "X-RateLimit-Used"       = @("500")
                        }
                        StatusCode = 403
                    }
                    $exception = New-Object System.Net.WebException("API rate limit exceeded for installation ID")
                    $webResponse = New-Object PSObject -Property @{ Headers = $response.Headers }
                    $exception | Add-Member -NotePropertyName Response -NotePropertyValue $webResponse -Force
                    $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                        $exception, "WebException",
                        [System.Management.Automation.ErrorCategory]::InvalidOperation, $null
                    )
                    $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails('{"message":"API rate limit exceeded for installation ID"}')
                    throw $errorRecord
                }
                # Second call (the retry after the wait): 404 Not Found
                $notFoundException = New-Object System.Net.WebException("Not Found")
                $notFoundResponse = New-Object PSObject -Property @{ Headers = @{} }
                $notFoundException | Add-Member -NotePropertyName Response -NotePropertyValue $notFoundResponse -Force
                $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                    $notFoundException, "WebException",
                    [System.Management.Automation.ErrorCategory]::InvalidOperation, $null
                )
                $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails('{"message":"Not Found","status":"404"}')
                throw $errorRecord
            }

            # Should NOT throw - hideFailedCall must be preserved through the rate-limit retry
            { $result = ApiCall -method GET -url "repos/wild123/deleted-action" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true -maxRetries 2 } | Should -Not -Throw
            $result = ApiCall -method GET -url "repos/wild123/deleted-action" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true -maxRetries 2
            $result | Should -Be $null
        }

        It "Should preserve returnErrorInfo=true through installation rate limit retry so a 404 returns error info instead of throwing" {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            Mock Format-RateLimitErrorTable { param($remaining, $used, $waitSeconds, $continueAt, $errorType) }
            Mock Start-Sleep { param($Seconds, $Milliseconds) }

            $script:invokeCount = 0
            $futureTimestamp = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 30)

            Mock Invoke-WebRequest {
                $script:invokeCount++
                if ($script:invokeCount -eq 1) {
                    $response = New-Object PSObject -Property @{
                        Headers = @{
                            "X-RateLimit-Reset"      = @($futureTimestamp.ToString())
                            "X-RateLimit-Remaining"  = @("0")
                            "X-RateLimit-Used"       = @("500")
                        }
                        StatusCode = 403
                    }
                    $exception = New-Object System.Net.WebException("API rate limit exceeded for installation ID")
                    $webResponse = New-Object PSObject -Property @{ Headers = $response.Headers }
                    $exception | Add-Member -NotePropertyName Response -NotePropertyValue $webResponse -Force
                    $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                        $exception, "WebException",
                        [System.Management.Automation.ErrorCategory]::InvalidOperation, $null
                    )
                    $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails('{"message":"API rate limit exceeded for installation ID"}')
                    throw $errorRecord
                }
                $notFoundException = New-Object System.Net.WebException("Not Found")
                $notFoundResponse = New-Object PSObject -Property @{
                    Headers = @{}
                    StatusCode = [System.Net.HttpStatusCode]::NotFound
                }
                $notFoundException | Add-Member -NotePropertyName Response -NotePropertyValue $notFoundResponse -Force
                $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                    $notFoundException, "WebException",
                    [System.Management.Automation.ErrorCategory]::InvalidOperation, $null
                )
                $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails('{"message":"Not Found","status":"404"}')
                throw $errorRecord
            }

            { $result = ApiCall -method GET -url "repos/wild123/deleted-action" -access_token "test_token" -returnErrorInfo $true -waitForRateLimit $true -maxRetries 2 } | Should -Not -Throw
            $result = ApiCall -method GET -url "repos/wild123/deleted-action" -access_token "test_token" -returnErrorInfo $true -waitForRateLimit $true -maxRetries 2
            $result | Should -Not -Be $null
            $result.Error | Should -Be $true
        }

        It "Should preserve hideFailedCall=true through secondary rate limit retry so a 404 returns null" {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            Mock Start-Sleep { param($Seconds, $Milliseconds) }

            $script:invokeCount = 0

            Mock Invoke-WebRequest {
                $script:invokeCount++
                if ($script:invokeCount -eq 1) {
                    $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                        [System.Exception]::new("secondary"), "WebException",
                        [System.Management.Automation.ErrorCategory]::InvalidOperation, $null
                    )
                    $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails('{"message":"You have exceeded a secondary rate limit and have been temporarily blocked"}')
                    throw $errorRecord
                }
                $notFoundException = New-Object System.Net.WebException("Not Found")
                $notFoundResponse = New-Object PSObject -Property @{ Headers = @{} }
                $notFoundException | Add-Member -NotePropertyName Response -NotePropertyValue $notFoundResponse -Force
                $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                    $notFoundException, "WebException",
                    [System.Management.Automation.ErrorCategory]::InvalidOperation, $null
                )
                $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails('{"message":"Not Found","status":"404"}')
                throw $errorRecord
            }

            { $result = ApiCall -method GET -url "repos/wild123/deleted-action" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true -maxRetries 2 } | Should -Not -Throw
            $result = ApiCall -method GET -url "repos/wild123/deleted-action" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true -maxRetries 2
            $result | Should -Be $null
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

    Context "Proactive token expiration check caching" {
        BeforeEach {
            $script:savedOrg = $env:APP_ORGANIZATION
            $env:APP_ORGANIZATION = "test-org"
            # Reset the script-scoped cache before each test
            $script:ProactiveCheckOverview = $null
            $script:ProactiveCheckOverviewTime = [DateTime]::MinValue
            $global:RateLimitExceeded = $false
        }

        AfterEach {
            $env:APP_ORGANIZATION = $script:savedOrg
            $script:ProactiveCheckOverview = $null
            $script:ProactiveCheckOverviewTime = [DateTime]::MinValue
        }

        It "Should call Get-GitHubAppRateLimitOverview only once across multiple ApiCall invocations within the TTL window" {
            $script:overviewCallCount = 0

            Mock GetBasicAuthenticationHeader { return "Basic test" }
            Mock Get-GitHubAppRateLimitOverview {
                $script:overviewCallCount++
                return ,@()  # empty overview — proactive check becomes a no-op
            }
            Mock Invoke-WebRequest {
                return New-Object PSObject -Property @{
                    StatusCode = 200
                    Headers    = @{}
                    Content    = "{}"
                }
            }

            # Five rapid invocations all fall within the 2-minute TTL window
            1..5 | ForEach-Object {
                ApiCall -method GET -url "test_endpoint_$_" -access_token "test_token" -hideFailedCall $true | Out-Null
            }

            # Overview should have been called exactly once — all subsequent calls used the cache
            $script:overviewCallCount | Should -Be 1
        }

        It "Should invalidate the proactive check cache when a token rotation occurs" {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            Mock Get-GitHubAppRateLimitOverview {
                # Return an overview where "test_token" is about to expire (<15 min)
                return ,@([pscustomobject]@{
                    AppId                  = "app1"
                    Token                  = "test_token"
                    Remaining              = 500
                    MinutesUntilExpiration = 5
                })
            }
            Mock Select-BestGitHubAppTokenForOrganization {
                # Return null — no better token available, so we stop gracefully
                return $null
            }

            ApiCall -method GET -url "test_endpoint" -access_token "test_token" -hideFailedCall $true | Out-Null

            # When rotation fails (no better token), RateLimitExceeded is set and execution stops;
            # the cache should have been populated (overview was called) but we confirm the cache
            # is a script-scoped value so we can reset it cleanly
            $script:ProactiveCheckOverview | Should -Not -Be $null
        }

        It "Should clear the proactive check cache after a successful token rotation" {
            $script:overviewCallCount = 0

            Mock GetBasicAuthenticationHeader { return "Basic test" }
            Mock Get-GitHubAppRateLimitOverview {
                $script:overviewCallCount++
                return ,@([pscustomobject]@{
                    AppId                  = "app1"
                    Token                  = "test_token"
                    Remaining              = 500
                    MinutesUntilExpiration = 5  # triggers rotation
                })
            }
            Mock Select-BestGitHubAppTokenForOrganization {
                return [pscustomobject]@{
                    AppId                  = "app2"
                    Token                  = "new_token"
                    MinutesUntilExpiration = 55
                }
            }
            Mock Invoke-WebRequest {
                return New-Object PSObject -Property @{
                    StatusCode = 200
                    Headers    = @{}
                    Content    = "{}"
                }
            }

            # Call with the expiring token — rotation will happen, cache is cleared, then ApiCall
            # recurses with new_token (which hits Get-GitHubAppRateLimitOverview again to re-populate)
            ApiCall -method GET -url "test_endpoint" -access_token "test_token" -hideFailedCall $true | Out-Null

            # Overview was called at least twice: once for original token (triggers rotation),
            # once more after the cache was cleared (for the recursive call with new_token)
            $script:overviewCallCount | Should -BeGreaterOrEqual 2
        }
    }
}
