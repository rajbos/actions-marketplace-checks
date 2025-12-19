Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Chunk Processing Rate Limit Check" {
    BeforeEach {
        # Reset the global flag before each test
        $global:RateLimitExceeded = $false
    }
    
    Context "When processing forks in a chunk" {
        It "Should stop processing when rate limit is exceeded" {
            # Create mock forks to process
            $forksToProcess = @(
                @{ name = "fork1"; mirrorFound = $true }
                @{ name = "fork2"; mirrorFound = $true }
                @{ name = "fork3"; mirrorFound = $true }
                @{ name = "fork4"; mirrorFound = $true }
                @{ name = "fork5"; mirrorFound = $true }
            )
            
            $processedCount = 0
            
            foreach ($fork in $forksToProcess) {
                # This is the pattern used in update-forks-chunk.ps1
                if (Test-RateLimitExceeded) {
                    Write-Host "Rate limit exceeded, stopping chunk processing"
                    break
                }
                
                # Simulate processing
                $processedCount++
                
                # Simulate rate limit hit after 2 forks
                if ($processedCount -eq 2) {
                    $global:RateLimitExceeded = $true
                }
            }
            
            # Should have processed exactly 2 forks (stopped at 3rd check)
            $processedCount | Should -Be 2
            $processedCount | Should -BeLessThan $forksToProcess.Count
        }
        
        It "Should process all forks when rate limit is not exceeded" {
            # Create mock forks to process
            $forksToProcess = @(
                @{ name = "fork1"; mirrorFound = $true }
                @{ name = "fork2"; mirrorFound = $true }
                @{ name = "fork3"; mirrorFound = $true }
            )
            
            $processedCount = 0
            
            foreach ($fork in $forksToProcess) {
                # Check rate limit before processing
                if (Test-RateLimitExceeded) {
                    Write-Host "Rate limit exceeded, stopping chunk processing"
                    break
                }
                
                # Simulate processing
                $processedCount++
            }
            
            # Should have processed all forks
            $processedCount | Should -Be $forksToProcess.Count
            Test-RateLimitExceeded | Should -Be $false
        }
    }
}
