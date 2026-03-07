Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Rate Limit Job Runtime Check" {
    Context "Test-WouldExceedJobRuntime function" {
        BeforeEach {
            # Reset JobStartTime before each test to avoid cross-test pollution
            $global:JobStartTime = [DateTime]::UtcNow
        }

        It "Should have function defined" {
            Get-Command Test-WouldExceedJobRuntime | Should -Not -BeNullOrEmpty
        }

        It "Should have required parameter waitSeconds" {
            $params = (Get-Command Test-WouldExceedJobRuntime).Parameters
            $params.ContainsKey('waitSeconds') | Should -Be $true
            $params['waitSeconds'].Attributes.Mandatory | Should -Be $true
        }

        It "Should have optional parameter maxRuntimeMinutes with default 60" {
            $params = (Get-Command Test-WouldExceedJobRuntime).Parameters
            $params.ContainsKey('maxRuntimeMinutes') | Should -Be $true
            $params['maxRuntimeMinutes'].Attributes.Mandatory | Should -Be $false
        }

        It "Should return false when wait fits within remaining runtime" {
            # Job started 10 minutes ago, 50 minutes remaining; wait 20 minutes -> ok
            $global:JobStartTime = [DateTime]::UtcNow.AddMinutes(-10)
            $result = Test-WouldExceedJobRuntime -waitSeconds 1200  # 20 minutes
            $result | Should -Be $false
        }

        It "Should return true when wait would exceed remaining runtime" {
            # Job started 50 minutes ago, only 10 minutes remaining; wait 20 minutes -> exceeds
            $global:JobStartTime = [DateTime]::UtcNow.AddMinutes(-50)
            $result = Test-WouldExceedJobRuntime -waitSeconds 1200  # 20 minutes
            $result | Should -Be $true
        }

        It "Should return true for the exact scenario from the issue (22+ min wait, 54 min elapsed)" {
            # The issue shows: 01:14 UTC is ~54 min into a run that started ~00:20 UTC.
            # Waiting 1365 seconds (22.75 min) would push past 76 minutes total.
            $global:JobStartTime = [DateTime]::UtcNow.AddMinutes(-54)
            $result = Test-WouldExceedJobRuntime -waitSeconds 1365
            $result | Should -Be $true
        }

        It "Should return false when JobStartTime is null" {
            $global:JobStartTime = $null
            $result = Test-WouldExceedJobRuntime -waitSeconds 9999
            $result | Should -Be $false
        }

        It "Should return false when job just started and wait is short" {
            $global:JobStartTime = [DateTime]::UtcNow
            $result = Test-WouldExceedJobRuntime -waitSeconds 300  # 5 minutes
            $result | Should -Be $false
        }

        It "Should respect custom maxRuntimeMinutes parameter" {
            # Job started 75 minutes ago; with 90-minute limit, 10 minutes remain; wait 9 min -> ok
            $global:JobStartTime = [DateTime]::UtcNow.AddMinutes(-75)
            $result = Test-WouldExceedJobRuntime -waitSeconds 540 -maxRuntimeMinutes 90  # 9 min
            $result | Should -Be $false
        }

        It "Should return true with custom maxRuntimeMinutes when wait exceeds remaining time" {
            # Job started 80 minutes ago; with 90-minute limit, 10 min remain; wait 15 min -> exceeds
            $global:JobStartTime = [DateTime]::UtcNow.AddMinutes(-80)
            $result = Test-WouldExceedJobRuntime -waitSeconds 900 -maxRuntimeMinutes 90  # 15 min
            $result | Should -Be $true
        }
    }

    Context "ApiCall soft-aborts when wait would exceed job runtime" {
        BeforeEach {
            $global:RateLimitExceeded = $false
            $script:TriedGitHubAppIds.Clear()
            # Simulate job started 54 minutes ago (from the issue scenario)
            $global:JobStartTime = [DateTime]::UtcNow.AddMinutes(-54)
        }

        AfterEach {
            # Restore sensible default so other tests are not affected
            $global:JobStartTime = [DateTime]::UtcNow
        }

        It "Should soft-abort instead of waiting when installation rate limit wait would exceed runtime (>20 min wait)" {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            Mock Format-RateLimitErrorTable { }
            # Start-Sleep should NOT be called
            Mock Start-Sleep { throw "Start-Sleep was called but should not have been" }

            # Wait time: 1365 seconds (22.75 min) -- matches the issue scenario, also > 20 min
            $futureTimestamp = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1365)

            Mock Invoke-WebRequest {
                $response = New-Object PSObject -Property @{
                    Headers = @{
                        "X-RateLimit-Reset"     = @($futureTimestamp.ToString())
                        "X-RateLimit-Remaining" = @("0")
                        "X-RateLimit-Used"      = @("500")
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

            $result = ApiCall -method GET -url "test_endpoint" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true -maxRetries 1

            # Should have stopped execution (returned null)
            $result | Should -Be $null
            # Global flag should be set
            $global:RateLimitExceeded | Should -Be $true
        }

        It "Should soft-abort when wait is under 20 min but still exceeds remaining runtime" {
            # Job started 55 minutes ago, 5 minutes remaining; wait = 600 seconds (10 min) -> exceeds
            $global:JobStartTime = [DateTime]::UtcNow.AddMinutes(-55)

            Mock GetBasicAuthenticationHeader { return "Basic test" }
            Mock Format-RateLimitErrorTable { }
            # Start-Sleep should NOT be called
            Mock Start-Sleep { throw "Start-Sleep was called but should not have been" }

            # Wait time: 600 seconds (10 minutes) - LESS than 1200 so 20-min check won't catch it
            $futureTimestamp = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 600)

            Mock Invoke-WebRequest {
                $response = New-Object PSObject -Property @{
                    Headers = @{
                        "X-RateLimit-Reset"     = @($futureTimestamp.ToString())
                        "X-RateLimit-Remaining" = @("0")
                        "X-RateLimit-Used"      = @("500")
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

            $result = ApiCall -method GET -url "test_endpoint" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true -maxRetries 1

            # Should have stopped execution (returned null) due to runtime check
            $result | Should -Be $null
            # Global flag should be set
            $global:RateLimitExceeded | Should -Be $true
        }

        It "Should wait normally when wait fits within remaining runtime" {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            Mock Format-RateLimitErrorTable { }
            Mock Start-Sleep { }  # Allow sleep (but don't actually sleep)

            # Job started only 2 minutes ago, so a 5-minute wait is fine
            $global:JobStartTime = [DateTime]::UtcNow.AddMinutes(-2)

            $script:invokeCount = 0
            $futureTimestamp = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 300)  # 5 minutes

            Mock Invoke-WebRequest {
                $script:invokeCount++
                if ($script:invokeCount -eq 1) {
                    $response = New-Object PSObject -Property @{
                        Headers = @{
                            "X-RateLimit-Reset"     = @($futureTimestamp.ToString())
                            "X-RateLimit-Remaining" = @("0")
                            "X-RateLimit-Used"      = @("500")
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
                    Headers    = @{}
                    Content    = "{}"
                }
            }

            $result = ApiCall -method GET -url "test_endpoint" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true -maxRetries 1

            # Should have retried and succeeded
            $result | Should -Not -Be $null
            # Global flag should NOT be set
            $global:RateLimitExceeded | Should -Be $false
            # Sleep should have been called
            Assert-MockCalled Start-Sleep -Times 1 -ParameterFilter { $Milliseconds -gt 0 }
        }
    }
}
