Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Select-BestGitHubAppTokenForOrganization with triedAppIds filtering" {
    Context "When apps have already been tried" {
        It "Should filter out apps in triedAppIds HashSet" {
            # Mock the overview to return three apps
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "111"
                        Token = "token1"
                        Remaining = 5000
                        Used = 0
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddMinutes(45)
                        MinutesUntilExpiration = 45.0
                    },
                    [pscustomobject]@{
                        AppId = "222"
                        Token = "token2"
                        Remaining = 4000
                        Used = 0
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddMinutes(40)
                        MinutesUntilExpiration = 40.0
                    },
                    [pscustomobject]@{
                        AppId = "333"
                        Token = "token3"
                        Remaining = 3000
                        Used = 0
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddMinutes(35)
                        MinutesUntilExpiration = 35.0
                    }
                )
            }

            # Create a HashSet with app 111 already tried
            $triedAppIds = New-Object 'System.Collections.Generic.HashSet[string]'
            $triedAppIds.Add("111") | Out-Null

            $result = Select-BestGitHubAppTokenForOrganization -organization "test-org" -triedAppIds $triedAppIds

            # Should select app 222 (highest remaining among untried apps)
            $result | Should -Not -BeNullOrEmpty
            $result.AppId | Should -Be "222"
            $result.Remaining | Should -Be 4000
        }

        It "Should return null when all apps have been tried" {
            # Mock the overview to return two apps
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "111"
                        Token = "token1"
                        Remaining = 5000
                        Used = 0
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddMinutes(45)
                        MinutesUntilExpiration = 45.0
                    },
                    [pscustomobject]@{
                        AppId = "222"
                        Token = "token2"
                        Remaining = 4000
                        Used = 0
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddMinutes(40)
                        MinutesUntilExpiration = 40.0
                    }
                )
            }

            # Create a HashSet with both apps already tried
            $triedAppIds = New-Object 'System.Collections.Generic.HashSet[string]'
            $triedAppIds.Add("111") | Out-Null
            $triedAppIds.Add("222") | Out-Null

            $result = Select-BestGitHubAppTokenForOrganization -organization "test-org" -triedAppIds $triedAppIds

            # Should return null because all apps have been tried
            $result | Should -BeNullOrEmpty
        }

        It "Should work without triedAppIds parameter (backwards compatibility)" {
            # Mock the overview to return two apps
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "111"
                        Token = "token1"
                        Remaining = 5000
                        Used = 0
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddMinutes(45)
                        MinutesUntilExpiration = 45.0
                    },
                    [pscustomobject]@{
                        AppId = "222"
                        Token = "token2"
                        Remaining = 4000
                        Used = 0
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddMinutes(40)
                        MinutesUntilExpiration = 40.0
                    }
                )
            }

            # Call without triedAppIds parameter
            $result = Select-BestGitHubAppTokenForOrganization -organization "test-org"

            # Should return the app with highest remaining (backwards compatible behavior)
            $result | Should -Not -BeNullOrEmpty
            $result.AppId | Should -Be "111"
            $result.Remaining | Should -Be 5000
        }

        It "Should select next best app when first is tried and second has quota" {
            # Mock the overview to return three apps with different remaining
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "111"
                        Token = "token1"
                        Remaining = 5000
                        Used = 0
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddMinutes(45)
                        MinutesUntilExpiration = 45.0
                    },
                    [pscustomobject]@{
                        AppId = "222"
                        Token = "token2"
                        Remaining = 4500
                        Used = 500
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddMinutes(40)
                        MinutesUntilExpiration = 40.0
                    },
                    [pscustomobject]@{
                        AppId = "333"
                        Token = "token3"
                        Remaining = 4000
                        Used = 1000
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddMinutes(35)
                        MinutesUntilExpiration = 35.0
                    }
                )
            }

            # Create a HashSet with app 111 and 222 already tried
            $triedAppIds = New-Object 'System.Collections.Generic.HashSet[string]'
            $triedAppIds.Add("111") | Out-Null
            $triedAppIds.Add("222") | Out-Null

            $result = Select-BestGitHubAppTokenForOrganization -organization "test-org" -triedAppIds $triedAppIds

            # Should select app 333 (only untried app)
            $result | Should -Not -BeNullOrEmpty
            $result.AppId | Should -Be "333"
            $result.Remaining | Should -Be 4000
        }

        It "Should return exhausted untried app when only exhausted apps remain" {
            # Mock the overview to return apps where tried ones have quota but untried are exhausted
            Mock Get-GitHubAppRateLimitOverview {
                return @(
                    [pscustomobject]@{
                        AppId = "111"
                        Token = "token1"
                        Remaining = 5000
                        Used = 0
                        WaitSeconds = 0
                        ContinueAt = [DateTime]::UtcNow
                        ExpirationTime = [DateTime]::UtcNow.AddMinutes(45)
                        MinutesUntilExpiration = 45.0
                    },
                    [pscustomobject]@{
                        AppId = "222"
                        Token = "token2"
                        Remaining = 0
                        Used = 5000
                        WaitSeconds = 300
                        ContinueAt = [DateTime]::UtcNow.AddSeconds(300)
                        ExpirationTime = [DateTime]::UtcNow.AddMinutes(40)
                        MinutesUntilExpiration = 40.0
                    }
                )
            }

            # Create a HashSet with app 111 already tried
            $triedAppIds = New-Object 'System.Collections.Generic.HashSet[string]'
            $triedAppIds.Add("111") | Out-Null

            $result = Select-BestGitHubAppTokenForOrganization -organization "test-org" -triedAppIds $triedAppIds

            # Should return app 222 even though it's exhausted (it's the only untried app)
            $result | Should -Not -BeNullOrEmpty
            $result.AppId | Should -Be "222"
            $result.Remaining | Should -Be 0
            $result.WaitSeconds | Should -Be 300
        }
    }
}
