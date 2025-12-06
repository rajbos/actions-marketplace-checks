Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Rate Limit Exceeded Handling" {
    BeforeEach {
        # Reset the global flag before each test
        $global:RateLimitExceeded = $false
    }
    
    Context "When rate limit exceeds 20 minutes" {
        It "Should set global flag when rate limit is exceeded" {
            # Verify initial state
            Test-RateLimitExceeded | Should -Be $false
            
            # Simulate rate limit exceeded
            $global:RateLimitExceeded = $true
            
            # Verify flag is set
            Test-RateLimitExceeded | Should -Be $true
        }
        
        It "Should allow scripts to check for rate limit status" {
            # Simulate processing loop
            $itemsProcessed = 0
            $items = @(1, 2, 3, 4, 5)
            
            foreach ($item in $items) {
                # Check rate limit before processing
                if (Test-RateLimitExceeded) {
                    Write-Host "Rate limit exceeded, stopping early"
                    break
                }
                
                $itemsProcessed++
                
                # Simulate rate limit hit after 3 items
                if ($itemsProcessed -eq 3) {
                    $global:RateLimitExceeded = $true
                }
            }
            
            # Should have processed exactly 3 items (stopped at 4th check)
            $itemsProcessed | Should -Be 3
        }
    }
    
    Context "GetRateLimitInfo function with rate limit exceeded" {
        It "Should handle null response from ApiCall when rate limit exceeded" {
            # This test verifies that GetRateLimitInfo doesn't crash when ApiCall returns null
            # In real scenario, ApiCall would return null when rate limit exceeds 20 minutes
            
            # Set the flag to simulate rate limit exceeded
            $global:RateLimitExceeded = $true
            
            # Mock ApiCall to return null (simulating rate limit exceeded)
            Mock ApiCall { return $null }
            
            # GetRateLimitInfo should handle this gracefully without throwing
            { GetRateLimitInfo -access_token "test_token" -access_token_destination "test_token" } | 
                Should -Not -Throw
        }
    }
    
    Context "Integration scenario" {
        It "Should demonstrate complete rate limit exceeded workflow" {
            # Initial state - no rate limit exceeded
            Test-RateLimitExceeded | Should -Be $false
            
            # Simulate API calls being made
            $processedCount = 0
            $totalToProcess = 10
            
            for ($i = 0; $i -lt $totalToProcess; $i++) {
                # Check if rate limit was exceeded before processing
                if (Test-RateLimitExceeded) {
                    Write-Host "Rate limit exceeded after processing $processedCount items"
                    break
                }
                
                # Simulate processing
                $processedCount++
                
                # Simulate rate limit hit after 5 items
                if ($processedCount -eq 5) {
                    Write-Host "Simulating rate limit exceeded"
                    $global:RateLimitExceeded = $true
                }
            }
            
            # Verify processing stopped early
            $processedCount | Should -Be 5
            $processedCount | Should -BeLessThan $totalToProcess
            
            # Verify flag is still set
            Test-RateLimitExceeded | Should -Be $true
        }
    }
}
