Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Rate Limit Loop Prevention" {
    BeforeEach {
        # Reset the global flag before each test
        $global:RateLimitExceeded = $false
        
        # Clear tried apps tracking and reset loop detection
        $script:TriedGitHubAppIds.Clear()
        $script:LastAttemptedAppId = $null
        $script:ConsecutiveResetDetections = 0
    }
    
    Context "When Installation and Core API rate limits differ" {
        BeforeAll {
            # Setup mock environment for 3 GitHub Apps
            $env:APP_ORGANIZATION = "test-org"
            $env:APP_ID = "2575811"
            $env:APP_ID_2 = "264650"
            $env:APP_ID_3 = "2592346"
            $env:APPLICATION_PRIVATE_KEY = "mock-key-1"
            $env:APPLICATION_PRIVATE_KEY_2 = "mock-key-2"
            $env:APPLICATION_PRIVATE_KEY_3 = "mock-key-3"
        }
        
        It "Should prevent infinite loop when same app has Installation limit 0 but Core API quota" {
            # This simulates the exact problem from the issue:
            # - App 2592346 hits Installation rate limit (0 remaining)
            # - Gets marked as tried
            # - /rate_limit endpoint shows Core API has 11649 remaining
            # - System thinks rate limit reset, clears tried apps
            # - Immediately tries 2592346 again, hits Installation limit
            # - Loop would continue infinitely without fix
            
            Mock Get-GitHubAppRateLimitOverview {
                # This returns Core API rate limits (from /rate_limit endpoint)
                return @(
                    [pscustomobject]@{
                        AppId = "264650"
                        Token = "token-264650"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 2528
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(2528)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(1)
                        MinutesUntilExpiration = 60.0
                    },
                    [pscustomobject]@{
                        AppId = "2575811"
                        Token = "token-2575811"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 2528
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(2528)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(1)
                        MinutesUntilExpiration = 60.0
                    },
                    [pscustomobject]@{
                        AppId = "2592346"
                        Token = "token-2592346"
                        Remaining = 11649  # Core API has quota!
                        Used = 851
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddHours(1)
                        MinutesUntilExpiration = 60.0
                    }
                )
            }
            
            Mock Get-TokenFromApp {
                return @{
                    token = "mock-token"
                    expiresAt = ([DateTime]::UtcNow.AddHours(1)).ToString("o")
                }
            }
            
            Mock Test-IsLikelyGitHubAppPemKey { return $true }
            
            # Simulate: App 2592346 was just tried due to Installation rate limit
            $script:TriedGitHubAppIds.Add("2592346") | Out-Null
            $script:LastAttemptedAppId = "2592346"
            
            # Get overview - shows 2592346 has Core API quota
            $overview = Get-GitHubAppRateLimitOverview -organization "test-org"
            
            # Find apps with quota
            $appsWithQuota = $overview | Where-Object { $_.Remaining -gt 0 }
            $appsWithQuota.Count | Should -Be 1
            $appsWithQuota[0].AppId | Should -Be "2592346"
            
            # Check if the app with quota was previously tried
            $triedAppsWithQuota = $appsWithQuota | Where-Object { $script:TriedGitHubAppIds.Contains($_.AppId) }
            $triedAppsWithQuota.Count | Should -Be 1
            
            # Test the new validation function
            $isValidReset = Test-RateLimitResetIsValid -triedAppsWithQuota $triedAppsWithQuota -triedAppIds $script:TriedGitHubAppIds -organization "test-org"
            
            # Should be FALSE - this is a false positive (different rate limit types)
            $isValidReset | Should -Be $false
            
            # Tried apps should NOT be cleared
            $script:TriedGitHubAppIds.Count | Should -Be 1
            $script:TriedGitHubAppIds.Contains("2592346") | Should -Be $true
        }
        
        It "Should detect consecutive reset attempts and stop after 3" {
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "2592346"
                        Token = "token-2592346"
                        Remaining = 11649
                        Used = 851
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddHours(1)
                        MinutesUntilExpiration = 60.0
                    }
                )
            }
            
            Mock Get-TokenFromApp {
                return @{
                    token = "mock-token"
                    expiresAt = ([DateTime]::UtcNow.AddHours(1)).ToString("o")
                }
            }
            
            Mock Test-IsLikelyGitHubAppPemKey { return $true }
            
            $script:TriedGitHubAppIds.Add("2592346") | Out-Null
            $script:LastAttemptedAppId = "2592346"
            
            $overview = Get-GitHubAppRateLimitOverview -organization "test-org"
            $appsWithQuota = $overview | Where-Object { $_.Remaining -gt 0 }
            $triedAppsWithQuota = $appsWithQuota | Where-Object { $script:TriedGitHubAppIds.Contains($_.AppId) }
            
            # First attempt
            $script:ConsecutiveResetDetections = 0
            $isValidReset1 = Test-RateLimitResetIsValid -triedAppsWithQuota $triedAppsWithQuota -triedAppIds $script:TriedGitHubAppIds -organization "test-org"
            $isValidReset1 | Should -Be $false
            $script:ConsecutiveResetDetections | Should -Be 0
            
            # Second attempt
            $script:ConsecutiveResetDetections = 1
            $isValidReset2 = Test-RateLimitResetIsValid -triedAppsWithQuota $triedAppsWithQuota -triedAppIds $script:TriedGitHubAppIds -organization "test-org"
            $isValidReset2 | Should -Be $false
            
            # Third attempt
            $script:ConsecutiveResetDetections = 2
            $isValidReset3 = Test-RateLimitResetIsValid -triedAppsWithQuota $triedAppsWithQuota -triedAppIds $script:TriedGitHubAppIds -organization "test-org"
            $isValidReset3 | Should -Be $false
            
            # Fourth attempt - should hit the limit
            $script:ConsecutiveResetDetections = 3
            $isValidReset4 = Test-RateLimitResetIsValid -triedAppsWithQuota $triedAppsWithQuota -triedAppIds $script:TriedGitHubAppIds -organization "test-org"
            $isValidReset4 | Should -Be $false
        }
        
        It "Should allow valid reset when different app would be selected" {
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "264650"
                        Token = "token-264650"
                        Remaining = 12500  # This app now has quota!
                        Used = 0
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddHours(1)
                        MinutesUntilExpiration = 60.0
                    },
                    [pscustomobject]@{
                        AppId = "2592346"
                        Token = "token-2592346"
                        Remaining = 11649
                        Used = 851
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddHours(1)
                        MinutesUntilExpiration = 60.0
                    }
                )
            }
            
            Mock Get-TokenFromApp {
                return @{
                    token = "mock-token"
                    expiresAt = ([DateTime]::UtcNow.AddHours(1)).ToString("o")
                }
            }
            
            Mock Test-IsLikelyGitHubAppPemKey { return $true }
            
            # App 2592346 was tried
            $script:TriedGitHubAppIds.Add("2592346") | Out-Null
            $script:LastAttemptedAppId = "2592346"
            
            $overview = Get-GitHubAppRateLimitOverview -organization "test-org"
            $appsWithQuota = $overview | Where-Object { $_.Remaining -gt 0 }
            $triedAppsWithQuota = $appsWithQuota | Where-Object { $script:TriedGitHubAppIds.Contains($_.AppId) }
            
            # Now a different app (264650) would be selected because it has higher quota
            $script:ConsecutiveResetDetections = 0
            $isValidReset = Test-RateLimitResetIsValid -triedAppsWithQuota $triedAppsWithQuota -triedAppIds $script:TriedGitHubAppIds -organization "test-org"
            
            # Should be TRUE - we would select a different app
            $isValidReset | Should -Be $true
            # Counter should be incremented when reset is valid
            $script:ConsecutiveResetDetections | Should -Be 1
        }
        
        It "Should reset tracking variables when clearing tried apps after wait" {
            # Verify that Reset-TriedGitHubApps clears all tracking
            $script:TriedGitHubAppIds.Add("123") | Out-Null
            $script:LastAttemptedAppId = "123"
            $script:ConsecutiveResetDetections = 5
            
            Reset-TriedGitHubApps
            
            $script:TriedGitHubAppIds.Count | Should -Be 0
            $script:LastAttemptedAppId | Should -BeNullOrEmpty
            $script:ConsecutiveResetDetections | Should -Be 0
        }
    }
}
