Import-Module Pester

BeforeAll {
    # import library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Node Version Validation Tests" {
    It "Should successfully get default node version" {
        # Act
        $version = node --version
        
        # Assert
        $version | Should -Not -BeNullOrEmpty
        $version | Should -Match '^v\d+\.\d+\.\d+$'
    }

    It "Should find tools cache directory" {
        # Arrange
        $toolsCachePath = "$env:RUNNER_TOOL_CACHE/node"
        
        # Act & Assert
        if ($env:RUNNER_TOOL_CACHE) {
            # We're in a GitHub Actions runner environment
            Test-Path $env:RUNNER_TOOL_CACHE | Should -Be $true
            Write-Host "Tools cache found at: $env:RUNNER_TOOL_CACHE"
        }
        else {
            # We're in a local environment, skip this check
            Set-ItResult -Skipped -Because "Not running in GitHub Actions runner environment"
        }
    }

    It "Should list node versions from tools cache if available" {
        # Arrange
        $toolsCachePath = "$env:RUNNER_TOOL_CACHE/node"
        
        # Act
        if (Test-Path $toolsCachePath) {
            $nodeVersions = Get-ChildItem -Path $toolsCachePath -Directory | Select-Object -ExpandProperty Name | Sort-Object
            
            # Assert
            $nodeVersions | Should -Not -BeNullOrEmpty
            $nodeVersions.Count | Should -BeGreaterThan 0
            
            # Each version should match a version pattern
            foreach ($version in $nodeVersions) {
                $version | Should -Match '^\d+\.\d+\.\d+$'
            }
            
            Write-Host "Found $($nodeVersions.Count) Node.js versions in tools cache"
        }
        else {
            # Not in a runner environment with tools cache
            Set-ItResult -Skipped -Because "Tools cache not available at: $toolsCachePath"
        }
    }

    It "Should handle Write-Message with logToSummary parameter" {
        # Arrange
        $testMessage = "Test message for step summary"
        
        # Act - Write-Message is already defined in library.ps1
        # We can test that the function exists and accepts the right parameters
        { Write-Message -message $testMessage -logToSummary $false } | Should -Not -Throw
        { Write-Message -message $testMessage -logToSummary $true } | Should -Not -Throw
    }
}
