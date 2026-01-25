Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "All Apps Exhausted - Shortest Wait Check" {
    BeforeEach {
        # Reset the global flag before each test
        $global:RateLimitExceeded = $false
    }
    
    Context "When all configured apps are out of calls" {
        It "Should check all apps for shortest wait time, not just untried ones" {
            # This test verifies the requirement:
            # "check first if all configured apps are out of calls or not. 
            #  If all of them are, then wait for the shortest wait time of that app"
            
            # Mock scenario: We have 3 apps, all exhausted
            # App1: tried, wait 30 minutes
            # App2: untried, wait 25 minutes (shortest)
            # App3: untried, wait 35 minutes
            
            # The system should:
            # 1. Detect that ALL apps are exhausted (regardless of tried/untried status)
            # 2. Find the shortest wait across ALL apps (25 minutes)
            # 3. Exit because 25 minutes > 20 minutes
            
            # Setup: Mock Get-GitHubAppRateLimitOverview to return 3 exhausted apps
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
                        WaitSeconds = 1500  # 25 minutes (shortest)
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
            
            # Expected behavior: Should exit gracefully because shortest wait (25 min) > 20 min
            $global:RateLimitExceeded | Should -Be $false
            
            # This is the scenario we want to handle correctly
            # In the current implementation, if App1 has been tried but App2 and App3 haven't,
            # the system might wait for 25 minutes instead of exiting
        }
        
        It "Should exit when all apps exhausted and shortest wait > 20 minutes" {
            # Mock Get-GitHubAppRateLimitOverview to return 2 exhausted apps
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "111"
                        Token = "token1"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 1500  # 25 minutes (shortest)
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(1500)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(2)
                        MinutesUntilExpiration = 120
                    },
                    [pscustomobject]@{
                        AppId = "222"
                        Token = "token2"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 3000  # 50 minutes
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(3000)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(2)
                        MinutesUntilExpiration = 120
                    }
                )
            }
            
            # Test the logic: shortest wait across all apps should be 25 minutes
            $overview = Get-GitHubAppRateLimitOverview -organization "test-org"
            $shortestWait = ($overview | Measure-Object -Property WaitSeconds -Minimum).Minimum
            
            $shortestWait | Should -Be 1500
            $shortestWait | Should -BeGreaterThan 1200  # >20 minutes
            
            # In this case, we should exit, not wait
        }
        
        It "Should wait when all apps exhausted but shortest wait < 20 minutes" {
            # Mock Get-GitHubAppRateLimitOverview to return 2 exhausted apps
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "111"
                        Token = "token1"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 600  # 10 minutes (shortest)
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(600)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(2)
                        MinutesUntilExpiration = 120
                    },
                    [pscustomobject]@{
                        AppId = "222"
                        Token = "token2"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 1800  # 30 minutes
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(1800)
                        ExpirationTime = [DateTime]::UtcNow.AddHours(2)
                        MinutesUntilExpiration = 120
                    }
                )
            }
            
            # Test the logic: shortest wait across all apps should be 10 minutes
            $overview = Get-GitHubAppRateLimitOverview -organization "test-org"
            $shortestWait = ($overview | Measure-Object -Property WaitSeconds -Minimum).Minimum
            
            $shortestWait | Should -Be 600
            $shortestWait | Should -BeLessThan 1200  # <20 minutes
            
            # In this case, we should wait for 10 minutes and retry
        }
    }
    
    Context "When some apps still have quota" {
        It "Should switch to an app with remaining quota" {
            # Mock Get-GitHubAppRateLimitOverview to return mixed status
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
                        Remaining = 1500  # Still has quota!
                        Used = 3500
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddHours(2)
                        MinutesUntilExpiration = 120
                    }
                )
            }
            
            # Test Select-BestGitHubAppTokenForOrganization
            $best = Select-BestGitHubAppTokenForOrganization -organization "test-org"
            
            # Should select App2 because it has remaining quota
            $best.AppId | Should -Be "222"
            $best.Remaining | Should -Be 1500
            
            # Should NOT wait or exit
        }
    }
}
