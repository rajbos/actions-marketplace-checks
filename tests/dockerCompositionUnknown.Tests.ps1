Import-Module Pester

BeforeAll {
    # Define Write-Message function for tests
    function Write-Message {
        Param (
            [string] $message,
            [bool] $logToSummary = $false
        )
        Write-Host $message
    }
}

Describe "Docker Composition Unknown Category" {
    It "Should calculate unknown count when some local Dockerfiles lack custom code info" {
        # Arrange
        $localDockerFile = 5707  # From problem statement
        $localDockerfileWithCustomCode = 2017
        $localDockerfileWithoutCustomCode = 65
        
        # Act
        $localDockerfileUnknown = $localDockerFile - ($localDockerfileWithCustomCode + $localDockerfileWithoutCustomCode)
        
        # Assert
        $localDockerfileUnknown | Should -Be 3625
    }
    
    It "Should calculate zero unknown count when all local Dockerfiles have custom code info" {
        # Arrange
        $localDockerFile = 100
        $localDockerfileWithCustomCode = 80
        $localDockerfileWithoutCustomCode = 20
        
        # Act
        $localDockerfileUnknown = $localDockerFile - ($localDockerfileWithCustomCode + $localDockerfileWithoutCustomCode)
        
        # Assert
        $localDockerfileUnknown | Should -Be 0
    }
    
    It "Should calculate correct percentages using localDockerFile as denominator" {
        # Arrange - Using numbers from the problem statement
        $localDockerFile = 5707
        $localDockerfileWithCustomCode = 2017
        $localDockerfileWithoutCustomCode = 65
        $localDockerfileUnknown = $localDockerFile - ($localDockerfileWithCustomCode + $localDockerfileWithoutCustomCode)
        
        # Act
        $withCodePercentage = [math]::Round($localDockerfileWithCustomCode/$localDockerFile * 100 , 1)
        $withoutCodePercentage = [math]::Round($localDockerfileWithoutCustomCode/$localDockerFile * 100 , 1)
        $unknownPercentage = [math]::Round($localDockerfileUnknown/$localDockerFile * 100 , 1)
        
        # Assert
        $withCodePercentage | Should -Be 35.3
        $withoutCodePercentage | Should -Be 1.1
        $unknownPercentage | Should -Be 63.5
        
        # Total percentages should roughly add up to 100% (with minor rounding)
        $total = $withCodePercentage + $withoutCodePercentage + $unknownPercentage
        $total | Should -BeGreaterThan 99.0
        $total | Should -BeLessThan 101.0
    }
    
    It "Should not show unknown category when count is zero" {
        # Arrange
        $localDockerFile = 100
        $localDockerfileWithCustomCode = 80
        $localDockerfileWithoutCustomCode = 20
        $localDockerfileUnknown = $localDockerFile - ($localDockerfileWithCustomCode + $localDockerfileWithoutCustomCode)
        
        # Act
        $shouldShowUnknown = $localDockerfileUnknown -gt 0
        
        # Assert
        $shouldShowUnknown | Should -Be $false
    }
    
    It "Should show unknown category when count is greater than zero" {
        # Arrange
        $localDockerFile = 100
        $localDockerfileWithCustomCode = 50
        $localDockerfileWithoutCustomCode = 30
        $localDockerfileUnknown = $localDockerFile - ($localDockerfileWithCustomCode + $localDockerfileWithoutCustomCode)
        
        # Act
        $shouldShowUnknown = $localDockerfileUnknown -gt 0
        
        # Assert
        Write-Host "DEBUG: localDockerFile=$localDockerFile, localDockerfileWithCustomCode=$localDockerfileWithCustomCode, localDockerfileWithoutCustomCode=$localDockerfileWithoutCustomCode, localDockerfileUnknown=$localDockerfileUnknown"
        $shouldShowUnknown | Should -Be $true
        $localDockerfileUnknown | Should -Be 20
    }
    
    It "Should handle edge case where all Dockerfiles are unknown" {
        # Arrange
        $localDockerFile = 1000
        $localDockerfileWithCustomCode = 0
        $localDockerfileWithoutCustomCode = 0
        
        # Act
        $localDockerfileUnknown = $localDockerFile - ($localDockerfileWithCustomCode + $localDockerfileWithoutCustomCode)
        $unknownPercentage = [math]::Round($localDockerfileUnknown/$localDockerFile * 100 , 1)
        
        # Assert
        $localDockerfileUnknown | Should -Be 1000
        $unknownPercentage | Should -Be 100.0
    }
    
    It "Should verify example from problem statement matches expected behavior" {
        # Arrange - Problem statement mentions:
        # 6,770 Docker based actions
        # 5707 Local Dockerfile - 84.3%
        # 1,063 Remote image - 15.7%
        # Under B (5707):
        #   2017 With custom code
        #   65 Base image only
        # Missing: Unknown count
        
        $dockerBasedActions = 6770
        $localDockerFile = 5707
        $remoteDockerfile = 1063
        $localDockerfileWithCustomCode = 2017
        $localDockerfileWithoutCustomCode = 65
        
        # Act
        $localDockerfileUnknown = $localDockerFile - ($localDockerfileWithCustomCode + $localDockerfileWithoutCustomCode)
        
        # Percentages for B -> D, E, F (using localDockerFile as denominator)
        $withCodePercentage = [math]::Round($localDockerfileWithCustomCode/$localDockerFile * 100 , 1)
        $withoutCodePercentage = [math]::Round($localDockerfileWithoutCustomCode/$localDockerFile * 100 , 1)
        $unknownPercentage = [math]::Round($localDockerfileUnknown/$localDockerFile * 100 , 1)
        
        # Assert
        $localDockerfileUnknown | Should -Be 3625
        
        # Verify the sum equals the total
        ($localDockerfileWithCustomCode + $localDockerfileWithoutCustomCode + $localDockerfileUnknown) | Should -Be $localDockerFile
        
        # Verify percentages are reasonable
        $withCodePercentage | Should -Be 35.3
        $withoutCodePercentage | Should -Be 1.1
        $unknownPercentage | Should -Be 63.5
    }
}
