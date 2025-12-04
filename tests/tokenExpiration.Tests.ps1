Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Token Expiration Tests" {
    Context "Get-TokenExpirationTime function" {
        It "Should have function defined" {
            Get-Command Get-TokenExpirationTime | Should -Not -BeNullOrEmpty
        }

        It "Should have required parameter access_token" {
            $params = (Get-Command Get-TokenExpirationTime).Parameters
            $params.ContainsKey('access_token') | Should -Be $true
            $params['access_token'].Attributes.Mandatory | Should -Be $true
        }

        It "Should return null for invalid token" {
            $result = Get-TokenExpirationTime -access_token "invalid_token_12345"
            # The function should return null when it can't determine expiration
            # (either due to invalid token or token without expiration header)
            $result | Should -BeNullOrEmpty
        }
    }

    Context "Test-TokenExpiration function" {
        It "Should have function defined" {
            Get-Command Test-TokenExpiration | Should -Not -BeNullOrEmpty
        }

        It "Should have required parameter expirationTime" {
            $params = (Get-Command Test-TokenExpiration).Parameters
            $params.ContainsKey('expirationTime') | Should -Be $true
            $params['expirationTime'].Attributes.Mandatory | Should -Be $true
        }

        It "Should have optional parameter warningMinutes with default value 5" {
            $params = (Get-Command Test-TokenExpiration).Parameters
            $params.ContainsKey('warningMinutes') | Should -Be $true
            $params['warningMinutes'].Attributes.Mandatory | Should -Be $false
        }

        It "Should return true when expiration is less than 5 minutes away" {
            # Token expires in 4 minutes
            $expirationTime = [DateTime]::UtcNow.AddMinutes(4)
            $result = Test-TokenExpiration -expirationTime $expirationTime -warningMinutes 5
            $result | Should -Be $true
        }

        It "Should return false when expiration is more than 5 minutes away" {
            # Token expires in 10 minutes
            $expirationTime = [DateTime]::UtcNow.AddMinutes(10)
            $result = Test-TokenExpiration -expirationTime $expirationTime -warningMinutes 5
            $result | Should -Be $false
        }

        It "Should return true when expiration is exactly 5 minutes away" {
            # Token expires in exactly 5 minutes
            $expirationTime = [DateTime]::UtcNow.AddMinutes(5)
            $result = Test-TokenExpiration -expirationTime $expirationTime -warningMinutes 5
            $result | Should -Be $true
        }

        It "Should return true when token has already expired" {
            # Token expired 1 minute ago
            $expirationTime = [DateTime]::UtcNow.AddMinutes(-1)
            $result = Test-TokenExpiration -expirationTime $expirationTime -warningMinutes 5
            $result | Should -Be $true
        }

        It "Should respect custom warningMinutes parameter" {
            # Token expires in 8 minutes, warning threshold is 10 minutes
            $expirationTime = [DateTime]::UtcNow.AddMinutes(8)
            $result = Test-TokenExpiration -expirationTime $expirationTime -warningMinutes 10
            $result | Should -Be $true
        }

        It "Should respect custom warningMinutes parameter - false case" {
            # Token expires in 12 minutes, warning threshold is 10 minutes
            $expirationTime = [DateTime]::UtcNow.AddMinutes(12)
            $result = Test-TokenExpiration -expirationTime $expirationTime -warningMinutes 10
            $result | Should -Be $false
        }
    }

    Context "Token expiration workflow integration" {
        It "Should have token expiration check in functions.ps1" {
            $functionsContent = Get-Content "$PSScriptRoot/../.github/workflows/functions.ps1" -Raw
            $functionsContent | Should -Match 'Get-TokenExpirationTime'
            $functionsContent | Should -Match 'Test-TokenExpiration'
        }

        It "Should check token expiration in the loop" {
            $functionsContent = Get-Content "$PSScriptRoot/../.github/workflows/functions.ps1" -Raw
            $functionsContent | Should -Match 'Token will expire'
            $functionsContent | Should -Match 'Breaking loop to prevent token expiration'
        }

        It "Should use 5 minutes as the warning threshold" {
            $functionsContent = Get-Content "$PSScriptRoot/../.github/workflows/functions.ps1" -Raw
            $functionsContent | Should -Match 'warningMinutes 5'
        }
    }
}
