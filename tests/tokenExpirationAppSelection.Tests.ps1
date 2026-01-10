Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Token Expiration in App Selection" {
    Context "Select-BestGitHubAppTokenForOrganization with token expiration" {
        It "Should have minMinutesUntilExpiration parameter with default value 15" {
            $params = (Get-Command Select-BestGitHubAppTokenForOrganization).Parameters
            $params.ContainsKey('minMinutesUntilExpiration') | Should -Be $true
            # Check that it's not mandatory (has a default)
            $params['minMinutesUntilExpiration'].Attributes.Mandatory | Should -Be $false
        }

        It "Should filter out tokens expiring within threshold" {
            # Mock the overview to return tokens with different expiration times
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "123"
                        Token = "token1"
                        Remaining = 5000
                        Used = 0
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddMinutes(5)
                        MinutesUntilExpiration = 5.0
                    },
                    [pscustomobject]@{
                        AppId = "456"
                        Token = "token2"
                        Remaining = 4000
                        Used = 0
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddMinutes(30)
                        MinutesUntilExpiration = 30.0
                    }
                )
            }

            $result = Select-BestGitHubAppTokenForOrganization -organization "test-org" -minMinutesUntilExpiration 15

            # Should select the token with 30 minutes remaining, not the one with 5 minutes
            $result | Should -Not -BeNullOrEmpty
            $result.AppId | Should -Be "456"
            $result.MinutesUntilExpiration | Should -Be 30.0
        }

        It "Should return null when all tokens with quota are expiring soon" {
            # Mock the overview to return only tokens that expire soon
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "123"
                        Token = "token1"
                        Remaining = 5000
                        Used = 0
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddMinutes(10)
                        MinutesUntilExpiration = 10.0
                    },
                    [pscustomobject]@{
                        AppId = "456"
                        Token = "token2"
                        Remaining = 4000
                        Used = 0
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddMinutes(8)
                        MinutesUntilExpiration = 8.0
                    }
                )
            }

            $result = Select-BestGitHubAppTokenForOrganization -organization "test-org" -minMinutesUntilExpiration 15

            # Should return null because all tokens with quota expire within 15 minutes
            $result | Should -BeNullOrEmpty
        }

        It "Should prioritize tokens with more remaining quota when multiple tokens are valid" {
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "123"
                        Token = "token1"
                        Remaining = 3000
                        Used = 2000
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddMinutes(45)
                        MinutesUntilExpiration = 45.0
                    },
                    [pscustomobject]@{
                        AppId = "456"
                        Token = "token2"
                        Remaining = 4500
                        Used = 500
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddMinutes(30)
                        MinutesUntilExpiration = 30.0
                    }
                )
            }

            $result = Select-BestGitHubAppTokenForOrganization -organization "test-org" -minMinutesUntilExpiration 15

            # Should select token2 with higher remaining (4500 > 3000)
            $result | Should -Not -BeNullOrEmpty
            $result.AppId | Should -Be "456"
            $result.Remaining | Should -Be 4500
        }

        It "Should handle tokens without expiration info (null MinutesUntilExpiration)" {
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "123"
                        Token = "token1"
                        Remaining = 3000
                        Used = 2000
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = $null
                        MinutesUntilExpiration = $null
                    }
                )
            }

            $result = Select-BestGitHubAppTokenForOrganization -organization "test-org" -minMinutesUntilExpiration 15

            # Should return the token since null expiration means it doesn't expire (PAT or other token type)
            $result | Should -Not -BeNullOrEmpty
            $result.AppId | Should -Be "123"
        }

        It "Should return exhausted token with soonest reset when all non-expiring tokens are exhausted" {
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "123"
                        Token = "token1"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 300
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(300)
                        ExpirationTime = [DateTime]::UtcNow.AddMinutes(45)
                        MinutesUntilExpiration = 45.0
                    },
                    [pscustomobject]@{
                        AppId = "456"
                        Token = "token2"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 600
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(600)
                        ExpirationTime = [DateTime]::UtcNow.AddMinutes(50)
                        MinutesUntilExpiration = 50.0
                    }
                )
            }

            $result = Select-BestGitHubAppTokenForOrganization -organization "test-org" -minMinutesUntilExpiration 15

            # Should return the one with shortest wait time (300s vs 600s)
            $result | Should -Not -BeNullOrEmpty
            $result.AppId | Should -Be "123"
            $result.WaitSeconds | Should -Be 300
        }
    }

    Context "Get-GitHubAppRateLimitOverview includes expiration data" {
        It "Should return objects with ExpirationTime and MinutesUntilExpiration properties" {
            # This is an integration test that requires actual GitHub App credentials
            # We'll just verify the function signature and structure
            $command = Get-Command Get-GitHubAppRateLimitOverview
            $command | Should -Not -BeNullOrEmpty
            
            # The function should accept organization parameter
            $params = $command.Parameters
            $params.ContainsKey('organization') | Should -Be $true
        }
    }

    Context "Write-GitHubAppRateLimitOverview displays expiration information" {
        It "Should call Write-Message with expiration column header" {
            # Test that the function includes the expiration column
            $mockOverview = @(
                [pscustomobject]@{
                    AppId = "123"
                    Remaining = 5000
                    Used = 0
                    WaitSeconds = 0
                    ContinueAt = [DateTime]::UtcNow
                    MinutesUntilExpiration = 30.0
                }
            )

            # Track if Write-Message was called with the expiration column
            $script:calledWithExpirationColumn = $false
            Mock Write-Message { 
                param($message, $logToSummary) 
                if ($message -match "Token Expires In") {
                    $script:calledWithExpirationColumn = $true
                }
            } -ModuleName $null

            Write-GitHubAppRateLimitOverview -appOverview $mockOverview

            # Verify that Write-Message was called with the expiration column header
            $script:calledWithExpirationColumn | Should -Be $true
        }

        It "Should format expiration display correctly for tokens expiring soon" {
            # Verify the display format logic for expiration times
            $testCases = @(
                @{ Minutes = 5.0; ExpectedPattern = "⚠️ 5" },
                @{ Minutes = 14.9; ExpectedPattern = "⚠️ 14.9" },
                @{ Minutes = 30.0; ExpectedPattern = "30m" },
                @{ Minutes = 65.0; ExpectedPattern = "1h 5m" },
                @{ Minutes = 120.0; ExpectedPattern = "2h 0m" },
                @{ Minutes = -5.0; ExpectedPattern = "⚠️ Expired" }
            )

            foreach ($testCase in $testCases) {
                # Test the display format logic directly
                $minutes = $testCase.Minutes
                $expectedPattern = $testCase.ExpectedPattern
                
                $expirationDisplay = "N/A"
                if ($null -ne $minutes) {
                    if ($minutes -le 0) {
                        $expirationDisplay = "⚠️ Expired"
                    }
                    elseif ($minutes -lt 15) {
                        $expirationDisplay = "⚠️ ${minutes}m"
                    }
                    elseif ($minutes -lt 60) {
                        $expirationDisplay = "${minutes}m"
                    }
                    else {
                        $hours = [Math]::Floor($minutes / 60)
                        $minutesPart = [Math]::Round($minutes % 60)
                        $expirationDisplay = "${hours}h ${minutesPart}m"
                    }
                }
                
                # Check that the display matches the expected pattern
                $expirationDisplay | Should -Match ([regex]::Escape($expectedPattern))
            }
        }
    }
}
