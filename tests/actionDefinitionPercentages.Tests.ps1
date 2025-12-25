Import-Module Pester

BeforeAll {
    # import library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
    
    # Define the RepoInformation class (same as in report.ps1)
    class RepoInformation {
        [int]$highAlerts
        [int]$criticalAlerts
        [int]$maxHighAlerts
        [int]$maxCriticalAlerts
        [int]$vulnerableRepos
        [int]$reposAnalyzed
    }
    
    # Function to calculate action definition percentages
    function Calculate-ActionDefinitionPercentages {
        Param (
            [int]$actionYmlFile,
            [int]$actionYamlFile,
            [int]$actionDockerFile,
            [int]$actiondDockerFile
        )
        
        # Calculate total actions with action definition files
        $totalActionsWithDefinition = $actionYmlFile + $actionYamlFile + $actionDockerFile + $actiondDockerFile
        
        if ($totalActionsWithDefinition -eq 0) {
            return @{
                Total = 0
                YmlPercentage = 0
                YamlPercentage = 0
                DockerPercentage = 0
                dDockerPercentage = 0
            }
        }
        
        return @{
            Total = $totalActionsWithDefinition
            YmlPercentage = [math]::Round($actionYmlFile/$totalActionsWithDefinition * 100 , 1)
            YamlPercentage = [math]::Round($actionYamlFile/$totalActionsWithDefinition * 100 , 1)
            DockerPercentage = [math]::Round($actionDockerFile/$totalActionsWithDefinition * 100 , 1)
            dDockerPercentage = [math]::Round($actiondDockerFile/$totalActionsWithDefinition * 100 , 1)
        }
    }
}

Describe "Action Definition Percentages" {
    It "Should calculate percentages that sum to 100% or less (with rounding)" {
        # Arrange - Simulating the scenario from the bug report
        $actionYmlFile = 20519
        $actionYamlFile = 975
        $actionDockerFile = 161
        $actiondDockerFile = 1
        
        # Act
        $result = Calculate-ActionDefinitionPercentages `
            -actionYmlFile $actionYmlFile `
            -actionYamlFile $actionYamlFile `
            -actionDockerFile $actionDockerFile `
            -actiondDockerFile $actiondDockerFile
        
        # Assert
        $result.YmlPercentage | Should -BeLessOrEqual 100
        $result.YamlPercentage | Should -BeLessOrEqual 100
        $result.DockerPercentage | Should -BeLessOrEqual 100
        $result.dDockerPercentage | Should -BeLessOrEqual 100
        
        # Total should be the sum of all file counts
        $result.Total | Should -Be ($actionYmlFile + $actionYamlFile + $actionDockerFile + $actiondDockerFile)
        
        # Sum of percentages should be approximately 100 (accounting for rounding)
        $sumPercentages = $result.YmlPercentage + $result.YamlPercentage + $result.DockerPercentage + $result.dDockerPercentage
        $sumPercentages | Should -BeGreaterThan 99.5
        $sumPercentages | Should -BeLessThan 100.5
    }
    
    It "Should not use reposAnalyzed as denominator when it differs from file counts" {
        # Arrange - Bug scenario: reposAnalyzed (19259) < total file counts (21656)
        $actionYmlFile = 20519
        $actionYamlFile = 975
        $actionDockerFile = 161
        $actiondDockerFile = 1
        $reposAnalyzed = 19259  # This should NOT be used as denominator
        
        # Act
        $result = Calculate-ActionDefinitionPercentages `
            -actionYmlFile $actionYmlFile `
            -actionYamlFile $actionYamlFile `
            -actionDockerFile $actionDockerFile `
            -actiondDockerFile $actiondDockerFile
        
        # Assert - Total should be file counts, not reposAnalyzed
        $result.Total | Should -Not -Be $reposAnalyzed
        $result.Total | Should -Be 21656  # Sum of all file counts
        
        # Percentages should be based on total file counts, not reposAnalyzed
        $expectedYmlPercentage = [math]::Round($actionYmlFile/21656 * 100, 1)
        $result.YmlPercentage | Should -Be $expectedYmlPercentage
    }
    
    It "Should handle equal distribution" {
        # Arrange
        $actionYmlFile = 25
        $actionYamlFile = 25
        $actionDockerFile = 25
        $actiondDockerFile = 25
        
        # Act
        $result = Calculate-ActionDefinitionPercentages `
            -actionYmlFile $actionYmlFile `
            -actionYamlFile $actionYamlFile `
            -actionDockerFile $actionDockerFile `
            -actiondDockerFile $actiondDockerFile
        
        # Assert
        $result.Total | Should -Be 100
        $result.YmlPercentage | Should -Be 25.0
        $result.YamlPercentage | Should -Be 25.0
        $result.DockerPercentage | Should -Be 25.0
        $result.dDockerPercentage | Should -Be 25.0
    }
    
    It "Should handle zero counts" {
        # Arrange
        $actionYmlFile = 0
        $actionYamlFile = 0
        $actionDockerFile = 0
        $actiondDockerFile = 0
        
        # Act
        $result = Calculate-ActionDefinitionPercentages `
            -actionYmlFile $actionYmlFile `
            -actionYamlFile $actionYamlFile `
            -actionDockerFile $actionDockerFile `
            -actiondDockerFile $actiondDockerFile
        
        # Assert
        $result.Total | Should -Be 0
        $result.YmlPercentage | Should -Be 0
        $result.YamlPercentage | Should -Be 0
        $result.DockerPercentage | Should -Be 0
        $result.dDockerPercentage | Should -Be 0
    }
    
    It "Should handle single file type with 100%" {
        # Arrange
        $actionYmlFile = 1000
        $actionYamlFile = 0
        $actionDockerFile = 0
        $actiondDockerFile = 0
        
        # Act
        $result = Calculate-ActionDefinitionPercentages `
            -actionYmlFile $actionYmlFile `
            -actionYamlFile $actionYamlFile `
            -actionDockerFile $actionDockerFile `
            -actiondDockerFile $actiondDockerFile
        
        # Assert
        $result.Total | Should -Be 1000
        $result.YmlPercentage | Should -Be 100.0
        $result.YamlPercentage | Should -Be 0
        $result.DockerPercentage | Should -Be 0
        $result.dDockerPercentage | Should -Be 0
    }
    
    It "Should round percentages to one decimal place" {
        # Arrange - 3 yml files out of 7 = 42.857...%
        $actionYmlFile = 3
        $actionYamlFile = 4
        $actionDockerFile = 0
        $actiondDockerFile = 0
        
        # Act
        $result = Calculate-ActionDefinitionPercentages `
            -actionYmlFile $actionYmlFile `
            -actionYamlFile $actionYamlFile `
            -actionDockerFile $actionDockerFile `
            -actiondDockerFile $actiondDockerFile
        
        # Assert
        $result.Total | Should -Be 7
        $result.YmlPercentage | Should -Be 42.9  # 42.857... rounds to 42.9
        $result.YamlPercentage | Should -Be 57.1  # 57.142... rounds to 57.1
    }
}
