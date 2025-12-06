Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Rate Limit Formatting Tests" {
    Context "Format-WaitTime function" {
        It "Should format less than 1 minute correctly" {
            $result = Format-WaitTime -totalSeconds 45
            $result | Should -Be "45 seconds"
        }

        It "Should format 1 minute correctly" {
            $result = Format-WaitTime -totalSeconds 60
            $result | Should -Be "60 seconds (1 minute)"
        }

        It "Should format multiple minutes correctly" {
            $result = Format-WaitTime -totalSeconds 300
            $result | Should -Be "300 seconds (5 minutes)"
        }

        It "Should format 1 hour correctly" {
            $result = Format-WaitTime -totalSeconds 3600
            $result | Should -Be "3600 seconds (1 hour)"
        }

        It "Should format hours and minutes correctly" {
            $result = Format-WaitTime -totalSeconds 5400
            $result | Should -Be "5400 seconds (1 hour 30 minutes)"
        }

        It "Should format 20 minutes (1200 seconds) correctly" {
            $result = Format-WaitTime -totalSeconds 1200
            $result | Should -Be "1200 seconds (20 minutes)"
        }

        It "Should format 23 minutes (1386 seconds) correctly" {
            $result = Format-WaitTime -totalSeconds 1386
            $result | Should -Be "1386 seconds (23.1 minutes)"
        }
    }

    Context "Format-RateLimitErrorTable function" {
        It "Should format rate limit error table without errors" {
            $testDate = Get-Date "2025-12-06 13:47:12"
            { Format-RateLimitErrorTable -remaining 0 -used 12500 -waitSeconds 1386 -continueAt $testDate -errorType "Exceeded" } | 
                Should -Not -Throw
        }

        It "Should format rate limit warning table without errors" {
            $testDate = Get-Date "2025-12-06 13:30:00"
            { Format-RateLimitErrorTable -remaining 50 -used 12450 -waitSeconds 600 -continueAt $testDate -errorType "Warning" } | 
                Should -Not -Throw
        }
    }

    Context "Test-RateLimitExceeded function" {
        BeforeEach {
            # Reset the global flag before each test
            $global:RateLimitExceeded = $false
        }

        It "Should return false when rate limit is not exceeded" {
            $result = Test-RateLimitExceeded
            $result | Should -Be $false
        }

        It "Should return true when rate limit flag is set" {
            $global:RateLimitExceeded = $true
            $result = Test-RateLimitExceeded
            $result | Should -Be $true
        }

        It "Should reset to false for next test" {
            Test-RateLimitExceeded | Should -Be $false
        }
    }
}
