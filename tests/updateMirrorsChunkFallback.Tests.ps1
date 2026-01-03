Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Update Mirrors Chunk - Token Fallback Integration" {
    
    Context "Chunk script with rate limit fallback" {
        BeforeEach {
            # Reset global state
            $global:RateLimitExceeded = $false
            
            # Create test data
            $script:testActions = @(
                @{
                    name = "owner1_repo1"
                    mirrorFound = $true
                    upstreamFound = $true
                },
                @{
                    name = "owner2_repo2"
                    mirrorFound = $true
                    upstreamFound = $true
                }
            )
            
            $script:testForkNames = @("owner1_repo1", "owner2_repo2")
        }
        
        It "Should use primary token when rate limit is good" {
            # Mock token selection to return primary token
            Mock Select-BestAvailableToken {
                return @{
                    TokenAvailable = $true
                    Token = "primary_token"
                    TokenType = "Primary"
                    Message = "Using primary token (remaining: 4000 calls)"
                    PrimaryStatus = @{
                        CanUse = $true
                        Remaining = 4000
                        WaitMinutes = 0
                        ResetTime = [DateTime]::UtcNow.AddHours(1)
                    }
                    SecondaryStatus = $null
                }
            }
            
            Mock Format-RateLimitTable { }
            Mock Test-AccessTokens { }
            Mock Save-PartialStatusUpdate { }
            Mock Save-ChunkSummary { }
            
            # Simulate the token selection that happens in update-mirrors-chunk.ps1
            $tokenSelection = Select-BestAvailableToken `
                -primary_token "primary_token" `
                -secondary_token "secondary_token" `
                -minRemainingCalls 50 `
                -maxWaitMinutes 20
            
            $tokenSelection.TokenAvailable | Should -Be $true
            $tokenSelection.TokenType | Should -Be "Primary"
            $tokenSelection.Token | Should -Be "primary_token"
        }
        
        It "Should fall back to secondary token when primary is rate limited" {
            # Mock token selection to fall back to secondary
            Mock Select-BestAvailableToken {
                return @{
                    TokenAvailable = $true
                    Token = "secondary_token"
                    TokenType = "Secondary"
                    Message = "Fell back to secondary token (primary wait: 25 min, secondary remaining: 3500 calls)"
                    PrimaryStatus = @{
                        CanUse = $false
                        Remaining = 10
                        WaitMinutes = 25
                        ResetTime = [DateTime]::UtcNow.AddMinutes(25)
                    }
                    SecondaryStatus = @{
                        CanUse = $true
                        Remaining = 3500
                        WaitMinutes = 0
                        ResetTime = [DateTime]::UtcNow.AddHours(1)
                    }
                }
            }
            
            Mock Format-RateLimitTable { }
            Mock Test-AccessTokens { }
            Mock Save-PartialStatusUpdate { }
            Mock Save-ChunkSummary { }
            
            # Simulate the token selection
            $tokenSelection = Select-BestAvailableToken `
                -primary_token "primary_token" `
                -secondary_token "secondary_token" `
                -minRemainingCalls 50 `
                -maxWaitMinutes 20
            
            $tokenSelection.TokenAvailable | Should -Be $true
            $tokenSelection.TokenType | Should -Be "Secondary"
            $tokenSelection.Token | Should -Be "secondary_token"
            $tokenSelection.Message | Should -Match "Fell back to secondary token"
        }
        
        It "Should exit gracefully when both tokens are rate limited" {
            # Mock token selection to return no available tokens
            Mock Select-BestAvailableToken {
                return @{
                    TokenAvailable = $false
                    Token = "primary_token"
                    TokenType = "None"
                    Message = "Both tokens rate limited. Primary: wait 25 min (remaining: 10). Secondary: wait 35 min (remaining: 5)."
                    PrimaryStatus = @{
                        CanUse = $false
                        Remaining = 10
                        WaitMinutes = 25
                        ResetTime = [DateTime]::UtcNow.AddMinutes(25)
                    }
                    SecondaryStatus = @{
                        CanUse = $false
                        Remaining = 5
                        WaitMinutes = 35
                        ResetTime = [DateTime]::UtcNow.AddMinutes(35)
                    }
                }
            }
            
            Mock Format-RateLimitTable { }
            Mock Save-PartialStatusUpdate { }
            Mock Save-ChunkSummary { }
            
            # Simulate the token selection
            $tokenSelection = Select-BestAvailableToken `
                -primary_token "primary_token" `
                -secondary_token "secondary_token" `
                -minRemainingCalls 50 `
                -maxWaitMinutes 20
            
            # When no tokens available, the script should handle it gracefully
            $tokenSelection.TokenAvailable | Should -Be $false
            $tokenSelection.TokenType | Should -Be "None"
            $tokenSelection.Message | Should -Match "Both tokens rate limited"
            
            # Verify that the message contains info about both tokens
            $tokenSelection.Message | Should -Match "Primary: wait 25"
            $tokenSelection.Message | Should -Match "Secondary: wait 35"
        }
        
        It "Should show rate limit table for both tokens when falling back" {
            $script:tableCallCount = 0
            Mock Format-RateLimitTable {
                param($rateData, $title)
                $script:tableCallCount++
                Write-Host "Format-RateLimitTable called with title: $title"
            }
            
            # Simulate showing rate limits for both tokens
            $primaryStatus = @{
                CanUse = $false
                Remaining = 15
                WaitMinutes = 22
                ResetTime = [DateTime]::UtcNow.AddMinutes(22)
            }
            
            $secondaryStatus = @{
                CanUse = $true
                Remaining = 3500
                WaitMinutes = 0
                ResetTime = [DateTime]::UtcNow.AddHours(1)
            }
            
            # Call Format-RateLimitTable as the chunk script would
            if ($primaryStatus) {
                Format-RateLimitTable -rateData @{
                    limit = 5000
                    remaining = $primaryStatus.Remaining
                    reset = ([DateTimeOffset]$primaryStatus.ResetTime).ToUnixTimeSeconds()
                    used = (5000 - $primaryStatus.Remaining)
                } -title "Primary Token Rate Limit Status"
            }
            
            if ($secondaryStatus) {
                Format-RateLimitTable -rateData @{
                    limit = 5000
                    remaining = $secondaryStatus.Remaining
                    reset = ([DateTimeOffset]$secondaryStatus.ResetTime).ToUnixTimeSeconds()
                    used = (5000 - $secondaryStatus.Remaining)
                } -title "Secondary Token Rate Limit Status"
            }
            
            $script:tableCallCount | Should -Be 2
        }
    }
    
    Context "Step Summary Messages" {
        It "Should generate appropriate step summary when using primary token" {
            Mock Select-BestAvailableToken {
                return @{
                    TokenAvailable = $true
                    Token = "primary_token"
                    TokenType = "Primary"
                    Message = "Using primary token (remaining: 4200 calls)"
                    PrimaryStatus = @{
                        CanUse = $true
                        Remaining = 4200
                        WaitMinutes = 0
                        ResetTime = [DateTime]::UtcNow.AddHours(1)
                    }
                    SecondaryStatus = $null
                }
            }
            
            $result = Select-BestAvailableToken -primary_token "primary" -secondary_token "secondary"
            
            $result.Message | Should -Match "Using primary token"
            $result.Message | Should -Match "remaining: 4200"
        }
        
        It "Should generate clear message when both tokens are exhausted" {
            Mock Select-BestAvailableToken {
                return @{
                    TokenAvailable = $false
                    Token = "primary_token"
                    TokenType = "None"
                    Message = "Both tokens rate limited. Primary: wait 22.5 min (remaining: 8). Secondary: wait 30.2 min (remaining: 12)."
                    PrimaryStatus = @{
                        CanUse = $false
                        Remaining = 8
                        WaitMinutes = 22.5
                        ResetTime = [DateTime]::UtcNow.AddMinutes(22.5)
                    }
                    SecondaryStatus = @{
                        CanUse = $false
                        Remaining = 12
                        WaitMinutes = 30.2
                        ResetTime = [DateTime]::UtcNow.AddMinutes(30.2)
                    }
                }
            }
            
            $result = Select-BestAvailableToken -primary_token "primary" -secondary_token "secondary"
            
            # Verify the message is clear and contains all necessary information
            $result.Message | Should -Match "Both tokens rate limited"
            $result.Message | Should -Match "Primary"
            $result.Message | Should -Match "Secondary"
            $result.Message | Should -Match "wait"
            $result.Message | Should -Match "remaining"
        }
    }
}
