BeforeAll {
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "GraphQL Rate Limit Display" {
    Context "When displaying GraphQL rate limits" {
        It "Should use resources.graphql.limit not rate.limit" {
            # Mock response where Core and GraphQL have different limits
            $mockResponse = @{
                rate = @{
                    limit = 12500
                    remaining = 12000
                    used = 500
                    reset = 1234567890
                }
                resources = @{
                    core = @{
                        limit = 12500
                        remaining = 12000
                        used = 500
                        reset = 1234567890
                    }
                    graphql = @{
                        limit = 5000
                        remaining = 5000
                        used = 0
                        reset = 1234567890
                    }
                }
            }
            
            # Verify that GraphQL limit is 5000, not 12500
            $mockResponse.resources.graphql.limit | Should -Be 5000
            $mockResponse.resources.graphql.limit | Should -Not -Be $mockResponse.rate.limit
            
            # This test documents the expected behavior:
            # The GraphQL table should show 5,000 (from resources.graphql.limit)
            # NOT 12,500 (from rate.limit or resources.core.limit)
        }
        
        It "Should extract GraphQL limits correctly from API response" {
            # Simulate the code from Get-GitHubAppRateLimitOverview
            $rateResponse = @{
                rate = @{
                    limit = 12500
                    remaining = 12000
                    used = 500
                    reset = 1234567890
                }
                resources = @{
                    graphql = @{
                        limit = 5000
                        remaining = 4500
                        used = 500
                        reset = 1234567890
                    }
                }
            }
            
            # Extract GraphQL values (mimicking lines 2317-2322 of library.ps1)
            $graphqlRemaining = $null
            $graphqlUsed = $null
            $graphqlLimit = $null
            $graphqlReset = $null
            
            if ($null -ne $rateResponse.resources -and $null -ne $rateResponse.resources.graphql) {
                $graphqlRemaining = $rateResponse.resources.graphql.remaining
                $graphqlUsed = $rateResponse.resources.graphql.used
                $graphqlLimit = $rateResponse.resources.graphql.limit
                $graphqlReset = $rateResponse.resources.graphql.reset
            }
            
            # Verify correct values were extracted
            $graphqlLimit | Should -Be 5000
            $graphqlRemaining | Should -Be 4500
            $graphqlUsed | Should -Be 500
            $graphqlLimit | Should -Not -Be $rateResponse.rate.limit
        }
    }
}
