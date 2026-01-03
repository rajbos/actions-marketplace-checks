Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Token Rate Limit Fallback" {
    
    Context "Test-TokenRateLimit" {
        It "Should return CanUse=true when token has sufficient rate limit" {
            # Mock Invoke-WebRequest to return a good rate limit response
            Mock Invoke-WebRequest {
                $resetTime = ([DateTimeOffset]::UtcNow.AddHours(1)).ToUnixTimeSeconds()
                return @{
                    Content = @{
                        rate = @{
                            limit = 5000
                            remaining = 4500
                            reset = $resetTime
                            used = 500
                        }
                    } | ConvertTo-Json
                }
            }
            
            $result = Test-TokenRateLimit -access_token "test_token"
            
            $result.CanUse | Should -Be $true
            $result.Remaining | Should -Be 4500
            $result.WaitMinutes | Should -BeLessOrEqual 60
        }
        
        It "Should return CanUse=false when token is rate limited with long wait" {
            # Mock Invoke-WebRequest to return a rate limited response
            Mock Invoke-WebRequest {
                $resetTime = ([DateTimeOffset]::UtcNow.AddMinutes(30)).ToUnixTimeSeconds()
                return @{
                    Content = @{
                        rate = @{
                            limit = 5000
                            remaining = 0
                            reset = $resetTime
                            used = 5000
                        }
                    } | ConvertTo-Json
                }
            }
            
            $result = Test-TokenRateLimit -access_token "test_token" -maxWaitMinutes 20
            
            $result.CanUse | Should -Be $false
            $result.Remaining | Should -Be 0
            $result.WaitMinutes | Should -BeGreaterThan 20
        }
        
        It "Should return CanUse=true when rate limit is low but reset time is acceptable" {
            # Mock Invoke-WebRequest to return low remaining but short wait
            Mock Invoke-WebRequest {
                $resetTime = ([DateTimeOffset]::UtcNow.AddMinutes(5)).ToUnixTimeSeconds()
                return @{
                    Content = @{
                        rate = @{
                            limit = 5000
                            remaining = 50
                            reset = $resetTime
                            used = 4950
                        }
                    } | ConvertTo-Json
                }
            }
            
            $result = Test-TokenRateLimit -access_token "test_token" -minRemainingCalls 100 -maxWaitMinutes 20
            
            $result.CanUse | Should -Be $true
            $result.Remaining | Should -Be 50
            $result.WaitMinutes | Should -BeLessThan 10
        }
        
        It "Should handle API errors gracefully" {
            # Mock Invoke-WebRequest to throw an error
            Mock Invoke-WebRequest {
                throw "API Error"
            }
            
            $result = Test-TokenRateLimit -access_token "test_token"
            
            $result.CanUse | Should -Be $false
            $result.Remaining | Should -Be 0
        }
    }
    
    Context "Select-BestAvailableToken - Primary Token Good" {
        It "Should select primary token when it has good rate limit" {
            Mock Test-TokenRateLimit {
                param($access_token)
                return @{
                    CanUse = $true
                    Remaining = 4000
                    WaitMinutes = 0
                    ResetTime = [DateTime]::UtcNow.AddHours(1)
                }
            }
            
            $result = Select-BestAvailableToken -primary_token "primary_token" -secondary_token "secondary_token"
            
            $result.TokenAvailable | Should -Be $true
            $result.Token | Should -Be "primary_token"
            $result.TokenType | Should -Be "Primary"
            $result.Message | Should -Match "Using primary token"
        }
    }
    
    Context "Select-BestAvailableToken - Fallback to Secondary" {
        It "Should fall back to secondary token when primary is rate limited" {
            Mock Test-TokenRateLimit {
                param($access_token, $minRemainingCalls, $maxWaitMinutes)
                if ($access_token -eq "primary_token") {
                    return @{
                        CanUse = $false
                        Remaining = 0
                        WaitMinutes = 25
                        ResetTime = [DateTime]::UtcNow.AddMinutes(25)
                    }
                }
                else {
                    return @{
                        CanUse = $true
                        Remaining = 4500
                        WaitMinutes = 0
                        ResetTime = [DateTime]::UtcNow.AddHours(1)
                    }
                }
            }
            
            $result = Select-BestAvailableToken -primary_token "primary_token" -secondary_token "secondary_token"
            
            $result.TokenAvailable | Should -Be $true
            $result.Token | Should -Be "secondary_token"
            $result.TokenType | Should -Be "Secondary"
            $result.Message | Should -Match "Fell back to secondary token"
            $result.PrimaryStatus.CanUse | Should -Be $false
            $result.SecondaryStatus.CanUse | Should -Be $true
        }
    }
    
    Context "Select-BestAvailableToken - No Secondary Configured" {
        It "Should return TokenAvailable=false when primary is rate limited and no secondary" {
            Mock Test-TokenRateLimit {
                return @{
                    CanUse = $false
                    Remaining = 5
                    WaitMinutes = 30
                    ResetTime = [DateTime]::UtcNow.AddMinutes(30)
                }
            }
            
            $result = Select-BestAvailableToken -primary_token "primary_token" -secondary_token ""
            
            $result.TokenAvailable | Should -Be $false
            $result.TokenType | Should -Be "None"
            $result.Message | Should -Match "No secondary token configured"
            $result.PrimaryStatus.CanUse | Should -Be $false
            $result.SecondaryStatus | Should -Be $null
        }
    }
    
    Context "Select-BestAvailableToken - Both Tokens Rate Limited" {
        It "Should return TokenAvailable=false when both tokens are rate limited" {
            Mock Test-TokenRateLimit {
                param($access_token)
                if ($access_token -eq "primary_token") {
                    return @{
                        CanUse = $false
                        Remaining = 10
                        WaitMinutes = 25
                        ResetTime = [DateTime]::UtcNow.AddMinutes(25)
                    }
                }
                else {
                    return @{
                        CanUse = $false
                        Remaining = 15
                        WaitMinutes = 35
                        ResetTime = [DateTime]::UtcNow.AddMinutes(35)
                    }
                }
            }
            
            $result = Select-BestAvailableToken -primary_token "primary_token" -secondary_token "secondary_token"
            
            $result.TokenAvailable | Should -Be $false
            $result.TokenType | Should -Be "None"
            $result.Message | Should -Match "Both tokens rate limited"
            $result.Message | Should -Match "Primary: wait 25"
            $result.Message | Should -Match "Secondary: wait 35"
            $result.PrimaryStatus.CanUse | Should -Be $false
            $result.SecondaryStatus.CanUse | Should -Be $false
        }
    }
    
    Context "Integration with Step Summary" {
        It "Should generate appropriate step summary messages for token selection" {
            Mock Test-TokenRateLimit {
                param($access_token)
                if ($access_token -eq "primary_token") {
                    return @{
                        CanUse = $false
                        Remaining = 20
                        WaitMinutes = 22
                        ResetTime = [DateTime]::UtcNow.AddMinutes(22)
                    }
                }
                else {
                    return @{
                        CanUse = $true
                        Remaining = 3500
                        WaitMinutes = 0
                        ResetTime = [DateTime]::UtcNow.AddHours(1)
                    }
                }
            }
            
            $result = Select-BestAvailableToken -primary_token "primary_token" -secondary_token "secondary_token"
            
            # Verify message contains useful information
            $result.Message | Should -Match "Fell back to secondary token"
            $result.Message | Should -Match "primary wait: 22"
            $result.Message | Should -Match "secondary remaining: 3500"
            
            # Verify both statuses are available for reporting
            $result.PrimaryStatus | Should -Not -Be $null
            $result.SecondaryStatus | Should -Not -Be $null
            $result.PrimaryStatus.Remaining | Should -Be 20
            $result.SecondaryStatus.Remaining | Should -Be 3500
        }
    }
}
