Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "ApiCall Parameter Preservation Through Retries" {
    BeforeEach {
        $global:RateLimitExceeded = $false
    }

    Context "hideFailedCall is preserved after installation rate limit retry" {
        It "Should not throw when a 404 follows an installation rate limit error and hideFailedCall is true" {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            Mock Format-RateLimitErrorTable { param($remaining, $used, $waitSeconds, $continueAt, $errorType) }
            Mock Start-Sleep { param($Seconds, $Milliseconds) }
            Mock Select-BestGitHubAppTokenForOrganization { return $null }
            Mock Get-GitHubAppRateLimitOverview { return @() }

            $script:invokeCount = 0
            $futureTimestamp = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 30)

            Mock Invoke-WebRequest {
                $script:invokeCount++
                if ($script:invokeCount -eq 1) {
                    # First call: installation rate limit
                    $webResponse = New-Object PSObject -Property @{
                        Headers = @{
                            "X-RateLimit-Reset"      = @($futureTimestamp.ToString())
                            "X-RateLimit-Remaining"  = @("0")
                            "X-RateLimit-Used"       = @("500")
                        }
                    }
                    $exception = New-Object System.Net.WebException("API rate limit exceeded for installation ID")
                    $exception | Add-Member -NotePropertyName Response -NotePropertyValue $webResponse -Force
                    $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                        $exception, "WebException",
                        [System.Management.Automation.ErrorCategory]::InvalidOperation, $null
                    )
                    $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails("{`"message`":`"API rate limit exceeded for installation ID`"}")
                    throw $errorRecord
                }
                else {
                    # Second call (retry): 404 Not Found
                    $webResponse = New-Object PSObject -Property @{ Headers = @{} }
                    $exception = New-Object System.Net.WebException("Not Found")
                    $exception | Add-Member -NotePropertyName Response -NotePropertyValue $webResponse -Force
                    $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                        $exception, "WebException",
                        [System.Management.Automation.ErrorCategory]::InvalidOperation, $null
                    )
                    $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails("{`"message`":`"Not Found`",`"status`":`"404`"}")
                    throw $errorRecord
                }
            }

            # Should not throw; hideFailedCall must be preserved through the retry
            { ApiCall -method GET -url "repos/some-org/some-repo" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true -maxRetries 2 } | Should -Not -Throw
        }

        It "Should return null (not throw) when a 404 follows an installation rate limit error and hideFailedCall is true" {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            Mock Format-RateLimitErrorTable { param($remaining, $used, $waitSeconds, $continueAt, $errorType) }
            Mock Start-Sleep { param($Seconds, $Milliseconds) }
            Mock Select-BestGitHubAppTokenForOrganization { return $null }
            Mock Get-GitHubAppRateLimitOverview { return @() }

            $script:invokeCount = 0
            $futureTimestamp = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 30)

            Mock Invoke-WebRequest {
                $script:invokeCount++
                if ($script:invokeCount -eq 1) {
                    $webResponse = New-Object PSObject -Property @{
                        Headers = @{
                            "X-RateLimit-Reset"     = @($futureTimestamp.ToString())
                            "X-RateLimit-Remaining" = @("0")
                            "X-RateLimit-Used"      = @("500")
                        }
                    }
                    $exception = New-Object System.Net.WebException("API rate limit exceeded for installation ID")
                    $exception | Add-Member -NotePropertyName Response -NotePropertyValue $webResponse -Force
                    $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                        $exception, "WebException",
                        [System.Management.Automation.ErrorCategory]::InvalidOperation, $null
                    )
                    $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails("{`"message`":`"API rate limit exceeded for installation ID`"}")
                    throw $errorRecord
                }
                else {
                    $webResponse = New-Object PSObject -Property @{ Headers = @{} }
                    $exception = New-Object System.Net.WebException("Not Found")
                    $exception | Add-Member -NotePropertyName Response -NotePropertyValue $webResponse -Force
                    $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                        $exception, "WebException",
                        [System.Management.Automation.ErrorCategory]::InvalidOperation, $null
                    )
                    $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails("{`"message`":`"Not Found`",`"status`":`"404`"}")
                    throw $errorRecord
                }
            }

            $result = ApiCall -method GET -url "repos/some-org/some-repo" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true -maxRetries 2

            $result | Should -Be $null
            $global:RateLimitExceeded | Should -Be $false
        }
    }

    Context "returnErrorInfo is preserved after installation rate limit retry" {
        It "Should return error info (not throw) when a 404 follows an installation rate limit error and returnErrorInfo is true" {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            Mock Format-RateLimitErrorTable { param($remaining, $used, $waitSeconds, $continueAt, $errorType) }
            Mock Start-Sleep { param($Seconds, $Milliseconds) }
            Mock Select-BestGitHubAppTokenForOrganization { return $null }
            Mock Get-GitHubAppRateLimitOverview { return @() }

            $script:invokeCount = 0
            $futureTimestamp = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 30)

            Mock Invoke-WebRequest {
                $script:invokeCount++
                if ($script:invokeCount -eq 1) {
                    $webResponse = New-Object PSObject -Property @{
                        Headers = @{
                            "X-RateLimit-Reset"     = @($futureTimestamp.ToString())
                            "X-RateLimit-Remaining" = @("0")
                            "X-RateLimit-Used"      = @("500")
                        }
                    }
                    $exception = New-Object System.Net.WebException("API rate limit exceeded for installation ID")
                    $exception | Add-Member -NotePropertyName Response -NotePropertyValue $webResponse -Force
                    $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                        $exception, "WebException",
                        [System.Management.Automation.ErrorCategory]::InvalidOperation, $null
                    )
                    $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails("{`"message`":`"API rate limit exceeded for installation ID`"}")
                    throw $errorRecord
                }
                else {
                    # Simulate a 404 response with a proper StatusCode on the exception response
                    $innerWebResponse = New-Object PSObject -Property @{
                        Headers    = @{}
                        StatusCode = [System.Net.HttpStatusCode]::NotFound
                    }
                    $exception = New-Object System.Net.WebException("Not Found")
                    $exception | Add-Member -NotePropertyName Response -NotePropertyValue $innerWebResponse -Force
                    $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                        $exception, "WebException",
                        [System.Management.Automation.ErrorCategory]::InvalidOperation, $null
                    )
                    $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails("{`"message`":`"Not Found`",`"status`":`"404`"}")
                    throw $errorRecord
                }
            }

            $result = ApiCall -method GET -url "repos/some-org/some-repo" -access_token "test_token" -returnErrorInfo $true -waitForRateLimit $true -maxRetries 2

            $result | Should -Not -Be $null
            $result.Error | Should -Be $true
            $global:RateLimitExceeded | Should -Be $false
        }
    }

    Context "hideFailedCall is preserved after secondary rate limit retry" {
        It "Should not throw when a 404 follows a secondary rate limit error and hideFailedCall is true" {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            Mock Start-Sleep { param($Seconds, $Milliseconds) }

            $script:invokeCount = 0

            Mock Invoke-WebRequest {
                $script:invokeCount++
                if ($script:invokeCount -eq 1) {
                    $exception = New-Object System.Net.WebException("You have exceeded a secondary rate limit")
                    $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                        $exception, "WebException",
                        [System.Management.Automation.ErrorCategory]::InvalidOperation, $null
                    )
                    $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails("{`"message`":`"You have exceeded a secondary rate limit and have been temporarily blocked from content creation. Please retry your request again later.`"}")
                    throw $errorRecord
                }
                else {
                    $webResponse = New-Object PSObject -Property @{ Headers = @{} }
                    $exception = New-Object System.Net.WebException("Not Found")
                    $exception | Add-Member -NotePropertyName Response -NotePropertyValue $webResponse -Force
                    $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                        $exception, "WebException",
                        [System.Management.Automation.ErrorCategory]::InvalidOperation, $null
                    )
                    $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails("{`"message`":`"Not Found`",`"status`":`"404`"}")
                    throw $errorRecord
                }
            }

            { ApiCall -method GET -url "repos/some-org/some-repo" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true -maxRetries 2 } | Should -Not -Throw
        }
    }

    Context "hideFailedCall is preserved after 'was submitted too quickly' retry" {
        It "Should not throw when a 404 follows a 'was submitted too quickly' error and hideFailedCall is true" {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            Mock Start-Sleep { param($Seconds, $Milliseconds) }
            Mock GetRateLimitInfo { }

            $script:invokeCount = 0

            Mock Invoke-WebRequest {
                $script:invokeCount++
                if ($script:invokeCount -eq 1) {
                    $exception = New-Object System.Net.WebException("was submitted too quickly")
                    $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                        $exception, "WebException",
                        [System.Management.Automation.ErrorCategory]::InvalidOperation, $null
                    )
                    $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails("{`"message`":`"was submitted too quickly`"}")
                    throw $errorRecord
                }
                else {
                    $webResponse = New-Object PSObject -Property @{ Headers = @{} }
                    $exception = New-Object System.Net.WebException("Not Found")
                    $exception | Add-Member -NotePropertyName Response -NotePropertyValue $webResponse -Force
                    $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                        $exception, "WebException",
                        [System.Management.Automation.ErrorCategory]::InvalidOperation, $null
                    )
                    $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails("{`"message`":`"Not Found`",`"status`":`"404`"}")
                    throw $errorRecord
                }
            }

            { ApiCall -method GET -url "repos/some-org/some-repo" -access_token "test_token" -hideFailedCall $true -waitForRateLimit $true -maxRetries 2 } | Should -Not -Throw
        }
    }
}
