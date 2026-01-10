BeforeAll {
    . "$PSScriptRoot/../.github/workflows/library.ps1"
}

Describe "App Cycling Prevention Tests" {
    BeforeEach {
        $global:RateLimitExceeded = $false
        # Clear any environment variables
        $env:APP_ORGANIZATION = $null
        $env:APP_ID = $null
        $env:APP_ID_2 = $null
        $env:APP_ID_3 = $null
        $env:APPLICATION_PRIVATE_KEY = $null
        $env:APPLICATION_PRIVATE_KEY_2 = $null
        $env:APPLICATION_PRIVATE_KEY_3 = $null
    }

    Context "When all apps have been tried" {
        It "Should detect cycling and stop gracefully if wait > 20 minutes" {
            # Setup: Create mock apps with long wait times
            $env:APP_ORGANIZATION = "test-org"
            
            # Mock Get-GitHubAppRateLimitOverview to return apps with long wait times
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "111111"
                        Token = "token1"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 1500  # 25 minutes
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(1500)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(1)
                        MinutesUntilExpiration = 60
                    },
                    [pscustomobject]@{
                        AppId = "222222"
                        Token = "token2"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 1800  # 30 minutes
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(1800)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(1)
                        MinutesUntilExpiration = 60
                    }
                )
            }
            
            # Mock Select-BestGitHubAppTokenForOrganization to return apps with quota
            $callCount = 0
            Mock Select-BestGitHubAppTokenForOrganization {
                $callCount++
                if ($callCount -eq 1) {
                    # First call - return app1
                    return [pscustomobject]@{
                        AppId = "111111"
                        Token = "token1"
                        Remaining = 100
                        Used = 4900
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                    }
                }
                elseif ($callCount -eq 2) {
                    # Second call - return app2 (simulating rotation)
                    return [pscustomobject]@{
                        AppId = "222222"
                        Token = "token2"
                        Remaining = 100
                        Used = 4900
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                    }
                }
                else {
                    # Third call - return app1 again (cycling detected)
                    return [pscustomobject]@{
                        AppId = "111111"
                        Token = "token1"
                        Remaining = 100
                        Used = 4900
                        WaitSeconds = 1500  # All apps need to wait
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(1500)
                    }
                }
            }
            
            # Mock Invoke-WebRequest to simulate installation rate limit errors
            $requestCount = 0
            Mock Invoke-WebRequest {
                $requestCount++
                # Simulate installation rate limit error
                $errorDetails = New-Object System.Management.Automation.ErrorDetails("{`"message`":`"API rate limit exceeded for installation ID 123456`"}")
                $exception = New-Object System.Exception("API rate limit exceeded for installation ID 123456")
                
                # Create mock response headers
                $headers = @{
                    "X-RateLimit-Remaining" = @("0")
                    "X-RateLimit-Used" = @("5000")
                    "X-RateLimit-Reset" = @(([DateTimeOffset]::UtcNow.AddSeconds(60).ToUnixTimeSeconds()).ToString())
                }
                
                # Attach headers to exception
                $exception | Add-Member -NotePropertyName "Response" -NotePropertyValue ([pscustomobject]@{ Headers = $headers })
                
                $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                    $exception,
                    "WebCmdletWebResponseException",
                    [System.Management.Automation.ErrorCategory]::InvalidOperation,
                    $null
                )
                $errorRecord.ErrorDetails = $errorDetails
                throw $errorRecord
            }
            
            Mock Format-RateLimitErrorTable {}
            Mock Write-Message {}
            
            # Execute the API call
            $result = ApiCall -method GET -url "https://api.github.com/repos/test/repo" -waitForRateLimit $true -access_token "test-token"
            
            # Verify the result - should be null or contain nulls when rate limit exceeded
            if ($null -ne $result) {
                # If it's an array, verify all elements are null
                $result | ForEach-Object { $_ | Should -BeNullOrEmpty }
            }
            $global:RateLimitExceeded | Should -Be $true
            
            # Verify that Select-BestGitHubAppTokenForOrganization was called 3 times
            # (once for each app, then detected cycling on third attempt)
            Should -Invoke Select-BestGitHubAppTokenForOrganization -Times 3
        }
        
        It "Should wait for shortest reset period if < 20 minutes after cycling" {
            # Setup: Create mock apps with short wait times
            $env:APP_ORGANIZATION = "test-org"
            
            # Mock Get-GitHubAppRateLimitOverview to return apps with short wait times
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "111111"
                        Token = "token1"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 300  # 5 minutes
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(300)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(1)
                        MinutesUntilExpiration = 60
                    },
                    [pscustomobject]@{
                        AppId = "222222"
                        Token = "token2"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 600  # 10 minutes
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(600)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(1)
                        MinutesUntilExpiration = 60
                    }
                )
            }
            
            # Mock Select-BestGitHubAppTokenForOrganization
            $callCount = 0
            Mock Select-BestGitHubAppTokenForOrganization {
                $callCount++
                if ($callCount -eq 1) {
                    return [pscustomobject]@{
                        AppId = "111111"
                        Token = "token1"
                        Remaining = 100
                        WaitSeconds = 0
                    }
                }
                elseif ($callCount -eq 2) {
                    return [pscustomobject]@{
                        AppId = "222222"
                        Token = "token2"
                        Remaining = 100
                        WaitSeconds = 0
                    }
                }
                else {
                    # Third call - cycling detected, return shortest wait
                    return [pscustomobject]@{
                        AppId = "111111"
                        Token = "token1"
                        Remaining = 100
                        WaitSeconds = 300  # 5 minutes
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(300)
                    }
                }
            }
            
            # Mock Invoke-WebRequest
            $requestCount = 0
            Mock Invoke-WebRequest {
                $requestCount++
                if ($requestCount -le 3) {
                    # First few requests fail with rate limit
                    $errorDetails = New-Object System.Management.Automation.ErrorDetails("{`"message`":`"API rate limit exceeded for installation ID 123456`"}")
                    $exception = New-Object System.Exception("API rate limit exceeded for installation ID 123456")
                    $headers = @{
                        "X-RateLimit-Remaining" = @("0")
                        "X-RateLimit-Used" = @("5000")
                        "X-RateLimit-Reset" = @(([DateTimeOffset]::UtcNow.AddSeconds(60).ToUnixTimeSeconds()).ToString())
                    }
                    $exception | Add-Member -NotePropertyName "Response" -NotePropertyValue ([pscustomobject]@{ Headers = $headers })
                    $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                        $exception,
                        "WebCmdletWebResponseException",
                        [System.Management.Automation.ErrorCategory]::InvalidOperation,
                        $null
                    )
                    $errorRecord.ErrorDetails = $errorDetails
                    throw $errorRecord
                }
                else {
                    # After waiting, succeed
                    return [pscustomobject]@{
                        StatusCode = 200
                        Content = '{"name":"test-repo"}'
                        Headers = @{
                            "X-RateLimit-Remaining" = @("4500")
                            "X-RateLimit-Used" = @("500")
                            "X-RateLimit-Reset" = @(([DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()).ToString())
                        }
                    }
                }
            }
            
            Mock Start-Sleep {}
            Mock Format-RateLimitErrorTable {}
            Mock Write-Message {}
            
            # Execute the API call
            $result = ApiCall -method GET -url "https://api.github.com/repos/test/repo" -waitForRateLimit $true -access_token "test-token"
            
            # Verify that Start-Sleep was called with 300 seconds (5 minutes)
            Should -Invoke Start-Sleep -Times 1 -ParameterFilter { $Seconds -eq 300 }
            
            # Verify successful result after waiting
            $result | Should -Not -BeNullOrEmpty
            $result.name | Should -Be "test-repo"
        }
    }
    
    Context "When apps have not cycled yet" {
        It "Should continue switching to apps with quota without detecting cycling" {
            # Setup
            $env:APP_ORGANIZATION = "test-org"
            
            # Mock Get-GitHubAppRateLimitOverview
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "111111"
                        Token = "token1"
                        Remaining = 0
                        WaitSeconds = 100
                    },
                    [pscustomobject]@{
                        AppId = "222222"
                        Token = "token2"
                        Remaining = 100
                        WaitSeconds = 0
                    }
                )
            }
            
            # Mock Select-BestGitHubAppTokenForOrganization - only called once
            Mock Select-BestGitHubAppTokenForOrganization {
                return [pscustomobject]@{
                    AppId = "222222"
                    Token = "token2"
                    Remaining = 100
                    WaitSeconds = 0
                }
            }
            
            # Mock Invoke-WebRequest
            $requestCount = 0
            Mock Invoke-WebRequest {
                $requestCount++
                if ($requestCount -eq 1) {
                    # First request fails
                    $errorDetails = New-Object System.Management.Automation.ErrorDetails("{`"message`":`"API rate limit exceeded for installation ID 123456`"}")
                    $exception = New-Object System.Exception("API rate limit exceeded for installation ID 123456")
                    $headers = @{
                        "X-RateLimit-Remaining" = @("0")
                        "X-RateLimit-Used" = @("5000")
                    }
                    $exception | Add-Member -NotePropertyName "Response" -NotePropertyValue ([pscustomobject]@{ Headers = $headers })
                    $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                        $exception,
                        "WebCmdletWebResponseException",
                        [System.Management.Automation.ErrorCategory]::InvalidOperation,
                        $null
                    )
                    $errorRecord.ErrorDetails = $errorDetails
                    throw $errorRecord
                }
                else {
                    # Second request succeeds with new app
                    return [pscustomobject]@{
                        StatusCode = 200
                        Content = '{"name":"test-repo"}'
                        Headers = @{
                            "X-RateLimit-Remaining" = @("4500")
                            "X-RateLimit-Used" = @("500")
                            "X-RateLimit-Reset" = @(([DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()).ToString())
                        }
                    }
                }
            }
            
            Mock Format-RateLimitErrorTable {}
            
            # Execute
            $result = ApiCall -method GET -url "https://api.github.com/repos/test/repo" -waitForRateLimit $true -access_token "test-token"
            
            # Verify successful switch without cycling detection
            $result | Should -Not -BeNullOrEmpty
            $result.name | Should -Be "test-repo"
            $global:RateLimitExceeded | Should -Be $false
            
            # Should only call once (found app with quota immediately)
            Should -Invoke Select-BestGitHubAppTokenForOrganization -Times 1
        }
    }
}
