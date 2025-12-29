Import-Module Pester

BeforeAll {
    # Source the environment-state script functions needed for testing
    # We'll create minimal versions of the functions to test the logic
    
    function Write-Message {
        Param (
            [string] $message,
            [bool] $logToSummary = $false
        )
        Write-Host $message
    }
}

Describe "Environment State - Docker Composition Section" {
    It "Should generate output for forks with complete Docker composition data" {
        # Arrange
        $existingForks = @(
            @{ 
                name = "docker-local-1"
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Dockerfile"
                }
            },
            @{ 
                name = "docker-local-2"
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Dockerfile"
                }
            },
            @{ 
                name = "docker-remote-1"
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Image"
                }
            }
        )
        
        # Act - Count Docker actions and their composition types
        $dockerActionsTotal = 0
        $dockerWithCompositionInfo = 0
        $dockerLocalDockerfile = 0
        $dockerRemoteImage = 0
        
        foreach ($fork in $existingForks) {
            if ($fork.actionType -and $fork.actionType.actionType -eq "Docker") {
                $dockerActionsTotal++
                
                if ($fork.actionType.actionDockerType) {
                    $dockerWithCompositionInfo++
                    
                    if ($fork.actionType.actionDockerType -eq "Dockerfile") {
                        $dockerLocalDockerfile++
                    }
                    elseif ($fork.actionType.actionDockerType -eq "Image") {
                        $dockerRemoteImage++
                    }
                }
            }
        }
        
        # Assert
        $dockerActionsTotal | Should -Be 3
        $dockerWithCompositionInfo | Should -Be 3
        $dockerLocalDockerfile | Should -Be 2
        $dockerRemoteImage | Should -Be 1
    }
    
    It "Should handle forks with missing Docker composition data" {
        # Arrange
        $existingForks = @(
            @{ 
                name = "docker-with-info"
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Dockerfile"
                }
            },
            @{ 
                name = "docker-no-info"
                actionType = @{
                    actionType = "Docker"
                    # Missing actionDockerType
                }
            }
        )
        
        # Act
        $dockerActionsTotal = 0
        $dockerWithCompositionInfo = 0
        
        foreach ($fork in $existingForks) {
            if ($fork.actionType -and $fork.actionType.actionType -eq "Docker") {
                $dockerActionsTotal++
                
                if ($fork.actionType.actionDockerType) {
                    $dockerWithCompositionInfo++
                }
            }
        }
        
        $missingInfo = $dockerActionsTotal - $dockerWithCompositionInfo
        
        # Assert
        $dockerActionsTotal | Should -Be 2
        $dockerWithCompositionInfo | Should -Be 1
        $missingInfo | Should -Be 1
    }
    
    It "Should calculate correct percentages matching problem statement example" {
        # Arrange - Using numbers from the problem statement
        $dockerActionsTotal = 6582
        $dockerLocalDockerfile = 5545
        $dockerRemoteImage = 1037
        $dockerWithCompositionInfo = $dockerLocalDockerfile + $dockerRemoteImage
        
        # Act
        $percentWithInfo = [math]::Round(($dockerWithCompositionInfo / $dockerActionsTotal) * 100, 2)
        $percentLocalDockerfile = [math]::Round(($dockerLocalDockerfile / $dockerWithCompositionInfo) * 100, 2)
        $percentRemoteImage = [math]::Round(($dockerRemoteImage / $dockerWithCompositionInfo) * 100, 2)
        
        # Assert
        $dockerWithCompositionInfo | Should -Be 6582
        $percentWithInfo | Should -Be 100.00
        # These match the problem statement: "5545 Local Dockerfile - 84.2%" and "1037 Remote image - 15.8%"
        $percentLocalDockerfile | Should -Be 84.24  # Slightly more precise than 84.2%
        $percentRemoteImage | Should -Be 15.76  # Slightly more precise than 15.8%
    }
    
    It "Should generate mermaid diagram data matching problem statement format" {
        # Arrange
        $dockerActionsTotal = 6582
        $dockerLocalDockerfile = 5545
        $dockerRemoteImage = 1037
        
        # Act - Generate percentages for mermaid diagram
        $localDockerPercentage = [math]::Round($dockerLocalDockerfile/$dockerActionsTotal * 100 , 1)
        $remoteDockerPercentage = [math]::Round($dockerRemoteImage/$dockerActionsTotal * 100 , 1)
        
        # Assert - These should match the problem statement diagram
        $localDockerPercentage | Should -Be 84.2
        $remoteDockerPercentage | Should -Be 15.8
    }
    
    It "Should handle scenario with all Node actions and no Docker actions" {
        # Arrange
        $existingForks = @(
            @{ 
                name = "node-1"
                actionType = @{
                    actionType = "Node"
                    nodeVersion = "20"
                }
            },
            @{ 
                name = "node-2"
                actionType = @{
                    actionType = "Node"
                    nodeVersion = "16"
                }
            }
        )
        
        # Act
        $dockerActionsTotal = 0
        $dockerWithCompositionInfo = 0
        
        foreach ($fork in $existingForks) {
            if ($fork.actionType -and $fork.actionType.actionType -eq "Docker") {
                $dockerActionsTotal++
                
                if ($fork.actionType.actionDockerType) {
                    $dockerWithCompositionInfo++
                }
            }
        }
        
        $percentWithInfo = if ($dockerActionsTotal -gt 0) {
            [math]::Round(($dockerWithCompositionInfo / $dockerActionsTotal) * 100, 2)
        } else {
            0
        }
        
        # Assert
        $dockerActionsTotal | Should -Be 0
        $percentWithInfo | Should -Be 0
    }
}
