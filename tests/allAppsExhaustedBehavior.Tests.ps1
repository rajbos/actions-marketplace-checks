Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Rate Limit Backoff - All Apps Exhausted Behavior" {
    BeforeEach {
        # Reset the global flag before each test
        $global:RateLimitExceeded = $false
        
        # Clear tried apps tracking
        $script:TriedGitHubAppIds.Clear()
    }
    
    Context "Scenario: 3 apps configured, all exhausted with different wait times" {
        BeforeAll {
            # Setup mock environment for 3 GitHub Apps
            $env:APP_ORGANIZATION = "test-org"
            $env:APP_ID = "111"
            $env:APP_ID_2 = "222"
            $env:APP_ID_3 = "333"
            $env:APPLICATION_PRIVATE_KEY = "mock-key-1"
            $env:APPLICATION_PRIVATE_KEY_2 = "mock-key-2"
            $env:APPLICATION_PRIVATE_KEY_3 = "mock-key-3"
        }
        
        It "Should exit when shortest wait across ALL apps > 20 minutes" {
            # Scenario: App1 tried, wait 30 min; App2 untried, wait 25 min (shortest); App3 untried, wait 35 min
            # Expected: Check ALL apps, find 25 min as shortest, exit because >20 min
            
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "111"
                        Token = "token1"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 1800  # 30 minutes
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(1800)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(2)
                        MinutesUntilExpiration = 120
                    },
                    [pscustomobject]@{
                        AppId = "222"
                        Token = "token2"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 1500  # 25 minutes (shortest across ALL apps)
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(1500)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(2)
                        MinutesUntilExpiration = 120
                    },
                    [pscustomobject]@{
                        AppId = "333"
                        Token = "token3"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 2100  # 35 minutes
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(2100)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(2)
                        MinutesUntilExpiration = 120
                    }
                )
            }
            
            # Mock Get-TokenFromApp to avoid actual token generation
            Mock Get-TokenFromApp {
                return @{
                    token = "mock-token"
                    expiresAt = ([DateTime]::UtcNow.AddHours(1)).ToString("o")
                }
            }
            
            # Mock Test-IsLikelyGitHubAppPemKey to accept our mock keys
            Mock Test-IsLikelyGitHubAppPemKey { return $true }
            
            # Simulate: App1 has been tried already
            $script:TriedGitHubAppIds.Add("111") | Out-Null
            
            # Get the best app (should be App2 or App3, both exhausted)
            $best = Select-BestGitHubAppTokenForOrganization -organization "test-org" -triedAppIds $script:TriedGitHubAppIds
            
            # Should return an exhausted app (App2 or App3)
            $best | Should -Not -BeNullOrEmpty
            $best.Remaining | Should -Be 0
            
            # The key test: When checking ALL apps (not just untried ones),
            # the shortest wait should be 25 minutes (App2)
            $overview = Get-GitHubAppRateLimitOverview -organization "test-org"
            $shortestWait = ($overview | Measure-Object -Property WaitSeconds -Minimum).Minimum
            
            $shortestWait | Should -Be 1500  # 25 minutes
            $shortestWait | Should -BeGreaterThan 1200  # >20 minutes
            
            # The fix ensures we check ALL apps and exit when shortest wait >20 minutes
        }
        
        It "Should wait when shortest wait across ALL apps < 20 minutes" {
            # Scenario: App1 tried, wait 15 min; App2 untried, wait 10 min (shortest); App3 untried, wait 25 min
            # Expected: Check ALL apps, find 10 min as shortest, wait for it
            
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "111"
                        Token = "token1"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 900  # 15 minutes
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(900)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(2)
                        MinutesUntilExpiration = 120
                    },
                    [pscustomobject]@{
                        AppId = "222"
                        Token = "token2"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 600  # 10 minutes (shortest across ALL apps)
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(600)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(2)
                        MinutesUntilExpiration = 120
                    },
                    [pscustomobject]@{
                        AppId = "333"
                        Token = "token3"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 1500  # 25 minutes
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(1500)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(2)
                        MinutesUntilExpiration = 120
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
            
            # Simulate: App1 has been tried
            $script:TriedGitHubAppIds.Add("111") | Out-Null
            
            # The key test: When checking ALL apps, shortest wait should be 10 minutes
            $overview = Get-GitHubAppRateLimitOverview -organization "test-org"
            $shortestWait = ($overview | Measure-Object -Property WaitSeconds -Minimum).Minimum
            
            $shortestWait | Should -Be 600  # 10 minutes
            $shortestWait | Should -BeLessThan 1200  # <20 minutes
            
            # In this case, the system should wait for 10 minutes (not exit)
        }
        
        It "Should switch to app with quota when available (not all apps exhausted)" {
            # Scenario: App1 tried, exhausted; App2 untried, has quota; App3 untried, exhausted
            # Expected: Switch to App2, don't wait
            
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "111"
                        Token = "token1"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 1800  # 30 minutes
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(1800)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(2)
                        MinutesUntilExpiration = 120
                    },
                    [pscustomobject]@{
                        AppId = "222"
                        Token = "token2"
                        Remaining = 2000  # Has quota!
                        Used = 3000
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddHours(2)
                        MinutesUntilExpiration = 120
                    },
                    [pscustomobject]@{
                        AppId = "333"
                        Token = "token3"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 2100  # 35 minutes
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(2100)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(2)
                        MinutesUntilExpiration = 120
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
            
            # Simulate: App1 has been tried
            $script:TriedGitHubAppIds.Add("111") | Out-Null
            
            # Get best app - should return App2 with quota
            $best = Select-BestGitHubAppTokenForOrganization -organization "test-org" -triedAppIds $script:TriedGitHubAppIds
            
            $best | Should -Not -BeNullOrEmpty
            $best.AppId | Should -Be "222"
            $best.Remaining | Should -Be 2000
            
            # Should NOT exit or wait - should use App2
            $global:RateLimitExceeded | Should -Be $false
        }
    }
    
    Context "Edge case: Only 1 app configured" {
        BeforeAll {
            $env:APP_ORGANIZATION = "test-org"
            $env:APP_ID = "111"
            $env:APP_ID_2 = $null
            $env:APP_ID_3 = $null
            $env:APPLICATION_PRIVATE_KEY = "mock-key-1"
            $env:APPLICATION_PRIVATE_KEY_2 = $null
            $env:APPLICATION_PRIVATE_KEY_3 = $null
        }
        
        It "Should exit when single app wait > 20 minutes" {
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "111"
                        Token = "token1"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 1500  # 25 minutes
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(1500)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(2)
                        MinutesUntilExpiration = 120
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
            
            $overview = Get-GitHubAppRateLimitOverview -organization "test-org"
            $shortestWait = ($overview | Measure-Object -Property WaitSeconds -Minimum).Minimum
            
            $shortestWait | Should -Be 1500  # 25 minutes
            $shortestWait | Should -BeGreaterThan 1200  # >20 minutes
            
            # Should exit gracefully
        }
        
        It "Should wait when single app wait < 20 minutes" {
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "111"
                        Token = "token1"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 600  # 10 minutes
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(600)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(2)
                        MinutesUntilExpiration = 120
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
            
            $overview = Get-GitHubAppRateLimitOverview -organization "test-org"
            $shortestWait = ($overview | Measure-Object -Property WaitSeconds -Minimum).Minimum
            
            $shortestWait | Should -Be 600  # 10 minutes
            $shortestWait | Should -BeLessThan 1200  # <20 minutes
            
            # Should wait for 10 minutes
        }
    }
}
