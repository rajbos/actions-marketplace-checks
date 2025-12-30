Import-Module Pester

BeforeAll {
    # Mock Write-Message function to avoid Step Summary issues during testing
    function Write-Message {
        Param (
            [string] $message,
            [bool] $logToSummary = $false
        )
        Write-Host $message
    }
    
    # Create sample test data with Docker actions
    $script:sampleForksWithDocker = @(
        @{ 
            name = "docker-local-1"
            actionType = @{
                actionType = "Docker"
                actionDockerType = "Dockerfile"
                fileFound = "action.yml"
            }
        },
        @{ 
            name = "docker-local-2"
            actionType = @{
                actionType = "Docker"
                actionDockerType = "Dockerfile"
                fileFound = "action.yml"
            }
        },
        @{ 
            name = "docker-remote-1"
            actionType = @{
                actionType = "Docker"
                actionDockerType = "Image"
                fileFound = "action.yml"
            }
        },
        @{ 
            name = "node-action"
            actionType = @{
                actionType = "Node"
                nodeVersion = "20"
                fileFound = "action.yml"
            }
        },
        @{ 
            name = "docker-no-info"
            actionType = @{
                actionType = "Docker"
                fileFound = "action.yml"
            }
        },
        @{ 
            name = "composite-action"
            actionType = @{
                actionType = "Composite"
                fileFound = "action.yml"
            }
        }
    )
}

Describe "Docker Composition Status Tracking" {
    It "Should correctly count total Docker actions" {
        # Arrange
        $forks = $script:sampleForksWithDocker
        
        # Act
        $dockerActionsTotal = 0
        foreach ($fork in $forks) {
            if ($fork.actionType -and $fork.actionType.actionType -eq "Docker") {
                $dockerActionsTotal++
            }
        }
        
        # Assert
        $dockerActionsTotal | Should -Be 4
    }
    
    It "Should correctly count Docker actions with composition info" {
        # Arrange
        $forks = $script:sampleForksWithDocker
        
        # Act
        $dockerWithCompositionInfo = 0
        foreach ($fork in $forks) {
            if ($fork.actionType -and $fork.actionType.actionType -eq "Docker") {
                if ($fork.actionType.actionDockerType) {
                    $dockerWithCompositionInfo++
                }
            }
        }
        
        # Assert
        $dockerWithCompositionInfo | Should -Be 3
    }
    
    It "Should correctly count local Dockerfile actions" {
        # Arrange
        $forks = $script:sampleForksWithDocker
        
        # Act
        $dockerLocalDockerfile = 0
        foreach ($fork in $forks) {
            if ($fork.actionType -and 
                $fork.actionType.actionType -eq "Docker" -and
                $fork.actionType.actionDockerType -eq "Dockerfile") {
                $dockerLocalDockerfile++
            }
        }
        
        # Assert
        $dockerLocalDockerfile | Should -Be 2
    }
    
    It "Should correctly count remote image actions" {
        # Arrange
        $forks = $script:sampleForksWithDocker
        
        # Act
        $dockerRemoteImage = 0
        foreach ($fork in $forks) {
            if ($fork.actionType -and 
                $fork.actionType.actionType -eq "Docker" -and
                $fork.actionType.actionDockerType -eq "Image") {
                $dockerRemoteImage++
            }
        }
        
        # Assert
        $dockerRemoteImage | Should -Be 1
    }
    
    It "Should calculate correct percentage of Docker actions with composition info" {
        # Arrange
        $dockerActionsTotal = 4
        $dockerWithCompositionInfo = 3
        
        # Act
        $percentWithInfo = [math]::Round(($dockerWithCompositionInfo / $dockerActionsTotal) * 100, 2)
        
        # Assert
        $percentWithInfo | Should -Be 75.00
    }
    
    It "Should handle zero Docker actions gracefully" {
        # Arrange
        $dockerActionsTotal = 0
        $dockerWithCompositionInfo = 0
        
        # Act
        $percentWithInfo = if ($dockerActionsTotal -gt 0) {
            [math]::Round(($dockerWithCompositionInfo / $dockerActionsTotal) * 100, 2)
        } else {
            0
        }
        
        # Assert
        $percentWithInfo | Should -Be 0
    }
    
    It "Should calculate correct breakdown percentages for composition types" {
        # Arrange
        $dockerWithCompositionInfo = 3
        $dockerLocalDockerfile = 2
        $dockerRemoteImage = 1
        
        # Act
        $percentLocalDockerfile = [math]::Round(($dockerLocalDockerfile / $dockerWithCompositionInfo) * 100, 2)
        $percentRemoteImage = [math]::Round(($dockerRemoteImage / $dockerWithCompositionInfo) * 100, 2)
        
        # Assert
        $percentLocalDockerfile | Should -Be 66.67
        $percentRemoteImage | Should -Be 33.33
    }
    
    It "Should not count non-Docker actions" {
        # Arrange
        $forks = $script:sampleForksWithDocker
        
        # Act
        $dockerActionsTotal = 0
        $nonDockerActions = 0
        foreach ($fork in $forks) {
            if ($fork.actionType -and $fork.actionType.actionType -eq "Docker") {
                $dockerActionsTotal++
            } else {
                $nonDockerActions++
            }
        }
        
        # Assert
        $dockerActionsTotal | Should -Be 4
        $nonDockerActions | Should -Be 2
    }
    
    It "Should handle Docker actions without actionType field" {
        # Arrange
        $forksWithMissingData = @(
            @{ name = "docker-1"; actionType = @{ actionType = "Docker"; actionDockerType = "Dockerfile" } },
            @{ name = "docker-2"; actionType = $null },
            @{ name = "docker-3" }
        )
        
        # Act
        $dockerActionsTotal = 0
        foreach ($fork in $forksWithMissingData) {
            if ($fork.actionType -and $fork.actionType.actionType -eq "Docker") {
                $dockerActionsTotal++
            }
        }
        
        # Assert
        $dockerActionsTotal | Should -Be 1
    }
}

Describe "Docker Composition Status Integration" {
    It "Should produce correct output structure" {
        # Arrange
        $forks = $script:sampleForksWithDocker
        $outputLines = @()
        
        # Simulate the logic from environment-state.ps1
        $dockerActionsTotal = 0
        $dockerWithCompositionInfo = 0
        $dockerLocalDockerfile = 0
        $dockerRemoteImage = 0
        
        foreach ($fork in $forks) {
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
        
        $percentWithInfo = if ($dockerActionsTotal -gt 0) {
            [math]::Round(($dockerWithCompositionInfo / $dockerActionsTotal) * 100, 2)
        } else {
            0
        }
        
        # Act & Assert
        $dockerActionsTotal | Should -Be 4
        $dockerWithCompositionInfo | Should -Be 3
        $dockerLocalDockerfile | Should -Be 2
        $dockerRemoteImage | Should -Be 1
        $percentWithInfo | Should -Be 75.00
    }
}
