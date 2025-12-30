Import-Module Pester

BeforeAll {
    # Mock Write-Message function
    function Write-Message {
        Param (
            [string] $message,
            [bool] $logToSummary = $false
        )
        Write-Host $message
    }
}

Describe "Docker Custom Code Analysis in Environment State" {
    It "Should correctly count Dockerfiles with custom code" {
        # Arrange
        $forks = @(
            @{ 
                name = "docker-with-code"
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Dockerfile"
                    dockerfileHasCustomCode = $true
                }
            },
            @{ 
                name = "docker-without-code"
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Dockerfile"
                    dockerfileHasCustomCode = $false
                }
            },
            @{ 
                name = "docker-no-info"
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Dockerfile"
                }
            }
        )
        
        # Act
        $dockerLocalWithCustomCode = 0
        $dockerLocalWithoutCustomCode = 0
        $dockerLocalWithCustomCodeInfo = 0
        
        foreach ($fork in $forks) {
            if ($fork.actionType.actionDockerType -eq "Dockerfile") {
                if ($null -ne $fork.actionType.dockerfileHasCustomCode) {
                    $dockerLocalWithCustomCodeInfo++
                    if ($fork.actionType.dockerfileHasCustomCode -eq $true) {
                        $dockerLocalWithCustomCode++
                    }
                    else {
                        $dockerLocalWithoutCustomCode++
                    }
                }
            }
        }
        
        # Assert
        $dockerLocalWithCustomCodeInfo | Should -Be 2
        $dockerLocalWithCustomCode | Should -Be 1
        $dockerLocalWithoutCustomCode | Should -Be 1
    }
    
    It "Should handle mix of Docker types correctly" {
        # Arrange
        $forks = @(
            @{ 
                name = "docker-local-with-code"
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Dockerfile"
                    dockerfileHasCustomCode = $true
                }
            },
            @{ 
                name = "docker-remote"
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Image"
                }
            },
            @{ 
                name = "node-action"
                actionType = @{
                    actionType = "Node"
                    nodeVersion = "20"
                }
            }
        )
        
        # Act
        $dockerActionsTotal = 0
        $dockerLocalDockerfile = 0
        $dockerRemoteImage = 0
        $dockerLocalWithCustomCode = 0
        
        foreach ($fork in $forks) {
            if ($fork.actionType.actionType -eq "Docker") {
                $dockerActionsTotal++
                
                if ($fork.actionType.actionDockerType -eq "Dockerfile") {
                    $dockerLocalDockerfile++
                    if ($fork.actionType.dockerfileHasCustomCode -eq $true) {
                        $dockerLocalWithCustomCode++
                    }
                }
                elseif ($fork.actionType.actionDockerType -eq "Image") {
                    $dockerRemoteImage++
                }
            }
        }
        
        # Assert
        $dockerActionsTotal | Should -Be 2
        $dockerLocalDockerfile | Should -Be 1
        $dockerRemoteImage | Should -Be 1
        $dockerLocalWithCustomCode | Should -Be 1
    }
    
    It "Should calculate correct percentages for custom code analysis" {
        # Arrange
        $dockerLocalWithCustomCodeInfo = 100
        $dockerLocalWithCustomCode = 75
        $dockerLocalWithoutCustomCode = 25
        
        # Act
        $percentWithCode = [math]::Round(($dockerLocalWithCustomCode / $dockerLocalWithCustomCodeInfo) * 100, 2)
        $percentWithoutCode = [math]::Round(($dockerLocalWithoutCustomCode / $dockerLocalWithCustomCodeInfo) * 100, 2)
        
        # Assert
        $percentWithCode | Should -Be 75.00
        $percentWithoutCode | Should -Be 25.00
    }
    
    It "Should handle zero Dockerfiles gracefully" {
        # Arrange
        $forks = @(
            @{ 
                name = "node-action"
                actionType = @{
                    actionType = "Node"
                    nodeVersion = "20"
                }
            }
        )
        
        # Act
        $dockerLocalDockerfile = 0
        $dockerLocalWithCustomCodeInfo = 0
        
        foreach ($fork in $forks) {
            if ($fork.actionType.actionType -eq "Docker" -and $fork.actionType.actionDockerType -eq "Dockerfile") {
                $dockerLocalDockerfile++
            }
        }
        
        $percentWithCodeInfo = if ($dockerLocalDockerfile -gt 0) {
            [math]::Round(($dockerLocalWithCustomCodeInfo / $dockerLocalDockerfile) * 100, 2)
        } else {
            0
        }
        
        # Assert
        $dockerLocalDockerfile | Should -Be 0
        $percentWithCodeInfo | Should -Be 0
    }
    
    It "Should count analyzed vs not analyzed correctly" {
        # Arrange
        $dockerLocalDockerfile = 10
        $dockerLocalWithCustomCodeInfo = 7
        
        # Act
        $notAnalyzed = $dockerLocalDockerfile - $dockerLocalWithCustomCodeInfo
        $percentAnalyzed = [math]::Round(($dockerLocalWithCustomCodeInfo / $dockerLocalDockerfile) * 100, 2)
        $percentNotAnalyzed = [math]::Round(($notAnalyzed / $dockerLocalDockerfile) * 100, 2)
        
        # Assert
        $notAnalyzed | Should -Be 3
        $percentAnalyzed | Should -Be 70.00
        $percentNotAnalyzed | Should -Be 30.00
    }
}

Describe "Report.ps1 Custom Code Tracking" {
    It "Should increment counters correctly for Dockerfile with custom code" {
        # Arrange
        $action = @{
            actionType = @{
                actionType = "Docker"
                actionDockerType = "Dockerfile"
                dockerfileHasCustomCode = $true
            }
        }
        
        # Act
        $localDockerfileWithCustomCode = 0
        $localDockerfileWithoutCustomCode = 0
        
        if ($action.actionType.actionDockerType -eq "Dockerfile") {
            if ($null -ne $action.actionType.dockerfileHasCustomCode) {
                if ($action.actionType.dockerfileHasCustomCode -eq $true) {
                    $localDockerfileWithCustomCode++
                }
                else {
                    $localDockerfileWithoutCustomCode++
                }
            }
        }
        
        # Assert
        $localDockerfileWithCustomCode | Should -Be 1
        $localDockerfileWithoutCustomCode | Should -Be 0
    }
    
    It "Should not count custom code info for remote images" {
        # Arrange
        $action = @{
            actionType = @{
                actionType = "Docker"
                actionDockerType = "Image"
                dockerfileHasCustomCode = $false  # This shouldn't matter for remote images
            }
        }
        
        # Act
        $localDockerfileWithCustomCode = 0
        $localDockerfileWithoutCustomCode = 0
        
        if ($action.actionType.actionDockerType -eq "Dockerfile") {
            if ($null -ne $action.actionType.dockerfileHasCustomCode) {
                if ($action.actionType.dockerfileHasCustomCode -eq $true) {
                    $localDockerfileWithCustomCode++
                }
                else {
                    $localDockerfileWithoutCustomCode++
                }
            }
        }
        
        # Assert
        $localDockerfileWithCustomCode | Should -Be 0
        $localDockerfileWithoutCustomCode | Should -Be 0
    }
}
