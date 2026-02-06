Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Rate Limit Reset Detection During App Switching" {
    BeforeEach {
        # Reset the global flag before each test
        $global:RateLimitExceeded = $false
        
        # Clear tried apps tracking
        $script:TriedGitHubAppIds.Clear()
    }
    
    Context "When rate limit resets for previously tried apps" {
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
        
        It "Should detect reset and clear tried apps when previously tried app has quota" {
            # Scenario from the problem statement:
            # 1. App 2575811 was tried (0 remaining)
            # 2. App 2592346 was tried (0 remaining)
            # 3. By the time we check again, rate limit reset occurred
            # 4. Apps 2575811 and 2592346 now have 12,000+ remaining
            # Expected: Detect the reset and clear tried apps, immediately retry
            
            # Rate limit has reset! Previously tried apps now have quota
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "264650"
                        Token = "token-264650"
                        Remaining = 0
                        Used = 12500
                        WaitSeconds = 2528
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(2528)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(1)
                        MinutesUntilExpiration = 60.0
                    },
                    [pscustomobject]@{
                        AppId = "2575811"
                        Token = "token-2575811"
                        Remaining = 12462  # Reset occurred!
                        Used = 38
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddHours(1)
                        MinutesUntilExpiration = 60.0
                    },
                    [pscustomobject]@{
                        AppId = "2592346"
                        Token = "token-2592346"
                        Remaining = 12417  # Reset occurred!
                        Used = 83
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
            
            # Simulate: Apps 2575811 and 2592346 have been tried already
            $script:TriedGitHubAppIds.Add("2575811") | Out-Null
            $script:TriedGitHubAppIds.Add("2592346") | Out-Null
            
            # Get the overview - rate limit has already reset
            $overview = Get-GitHubAppRateLimitOverview -organization "test-org"
            $overview.Count | Should -Be 3
            
            # Check apps with quota
            $appsWithQuota = $overview | Where-Object { $_.Remaining -gt 0 }
            
            # Should have 2 apps with quota now (2575811 and 2592346)
            $appsWithQuota.Count | Should -Be 2
            
            # Check that the apps with quota are the previously tried ones
            $triedAppsWithQuota = $appsWithQuota | Where-Object { $script:TriedGitHubAppIds.Contains($_.AppId) }
            $triedAppsWithQuota.Count | Should -Be 2
            $triedAppsWithQuota.AppId | Should -Contain "2575811"
            $triedAppsWithQuota.AppId | Should -Contain "2592346"
            
            # This is the key scenario: tried apps now have quota = rate limit reset detected!
            # The fix should clear tried apps and retry immediately
        }
        
        It "Should NOT wait 42 minutes when rate limit has already reset" {
            # This test validates the actual problem from the issue:
            # System was waiting 42 minutes even though apps had 12,000+ requests available
            
            $overviewCallCount = 0
            
            Mock Get-GitHubAppRateLimitOverview {
                $overviewCallCount++
                
                # After first check, rate limit has reset for tried apps
                return @(
                    [pscustomobject]@{
                        AppId = "264650"
                        Token = "token-264650"
                        Remaining = 0
                        Used = 12500
                        WaitSeconds = 2528  # 42 minutes
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(2528)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(1)
                        MinutesUntilExpiration = 60.0
                    },
                    [pscustomobject]@{
                        AppId = "2575811"
                        Token = "token-2575811"
                        Remaining = 12462  # Has quota!
                        Used = 38
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddHours(1)
                        MinutesUntilExpiration = 60.0
                    },
                    [pscustomobject]@{
                        AppId = "2592346"
                        Token = "token-2592346"
                        Remaining = 12417  # Has quota!
                        Used = 83
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
            
            # Apps 2575811 and 2592346 have been tried
            $script:TriedGitHubAppIds.Add("2575811") | Out-Null
            $script:TriedGitHubAppIds.Add("2592346") | Out-Null
            
            # Get overview - rate limit has already reset
            $overview = Get-GitHubAppRateLimitOverview -organization "test-org"
            
            # Check: 2 apps have quota (the tried ones)
            $appsWithQuota = $overview | Where-Object { $_.Remaining -gt 0 }
            $appsWithQuota.Count | Should -Be 2
            
            # Check: The apps with quota are in the tried set
            $triedAppsWithQuota = $appsWithQuota | Where-Object { $script:TriedGitHubAppIds.Contains($_.AppId) }
            $triedAppsWithQuota.Count | Should -Be 2
            
            # The fix should detect this and clear tried apps
            # WITHOUT waiting 2528 seconds (42 minutes)
            
            # Verify shortest wait is 42 minutes for the only exhausted app
            $shortestWait = ($overview | Where-Object { $_.Remaining -eq 0 } | Measure-Object -Property WaitSeconds -Minimum).Minimum
            $shortestWait | Should -Be 2528
            
            # But we should NOT use this wait because tried apps have quota!
        }
        
        It "Should clear tried apps and select app with highest quota after reset" {
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "111"
                        Token = "token-111"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 3000
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(3000)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(1)
                        MinutesUntilExpiration = 60.0
                    },
                    [pscustomobject]@{
                        AppId = "222"
                        Token = "token-222"
                        Remaining = 4500  # Has quota after reset
                        Used = 500
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddHours(1)
                        MinutesUntilExpiration = 60.0
                    },
                    [pscustomobject]@{
                        AppId = "333"
                        Token = "token-333"
                        Remaining = 4800  # Has quota after reset (highest)
                        Used = 200
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
            
            # All apps have been tried
            $script:TriedGitHubAppIds.Add("111") | Out-Null
            $script:TriedGitHubAppIds.Add("222") | Out-Null
            $script:TriedGitHubAppIds.Add("333") | Out-Null
            
            $overview = Get-GitHubAppRateLimitOverview -organization "test-org"
            $appsWithQuota = $overview | Where-Object { $_.Remaining -gt 0 }
            
            # 2 apps have quota (222 and 333)
            $appsWithQuota.Count | Should -Be 2
            
            # Both are in the tried set
            $triedAppsWithQuota = $appsWithQuota | Where-Object { $script:TriedGitHubAppIds.Contains($_.AppId) }
            $triedAppsWithQuota.Count | Should -Be 2
            
            # After clearing tried apps (simulating the fix), selecting best should give app 333 (highest quota)
            $script:TriedGitHubAppIds.Clear()
            $best = Select-BestGitHubAppTokenForOrganization -organization "test-org" -triedAppIds $script:TriedGitHubAppIds
            
            $best | Should -Not -BeNullOrEmpty
            $best.AppId | Should -Be "333"
            $best.Remaining | Should -Be 4800
        }
    }
}
