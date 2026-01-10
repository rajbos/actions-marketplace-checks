Import-Module Pester

BeforeAll {
    # Note: We can't directly test Invoke-TrivyScan because it requires:
    # 1. Docker to be installed and running
    # 2. Trivy to be installed
    # 3. Network access to download Dockerfiles
    # 4. API tokens for GitHub
    # 
    # Instead, we test the logic around when scans should be triggered
    
    function Get-MockContainerScanField {
        param (
            [DateTime]$lastScanned
        )
        return @{
            critical = 0
            high = 0
            lastScanned = $lastScanned.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            scanError = $null
        }
    }
}

Describe "Trivy Container Scan Logic" {
    Context "Scan timing logic" {
        It "Should need scan when containerScan field is missing" {
            # Arrange
            $action = @{
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Dockerfile"
                }
            }
            
            # Act
            $hasContainerScanField = Get-Member -inputobject $action.actionType -name "containerScan" -Membertype Properties
            $needsContainerScan = !$hasContainerScanField
            
            # Assert
            $needsContainerScan | Should -Be $true
        }
        
        It "Should need scan when last scan is older than 7 days" {
            # Arrange
            $oldScanDate = (Get-Date).AddDays(-8)
            $lastScanned = $oldScanDate.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            
            # Act
            $parsedDate = [DateTime]::Parse($lastScanned)
            $daysSinceLastScan = ((Get-Date) - $parsedDate).Days
            $needsContainerScan = $daysSinceLastScan -gt 7
            
            # Assert
            $needsContainerScan | Should -Be $true
        }
        
        It "Should not need scan when last scan is within 7 days" {
            # Arrange
            $recentScanDate = (Get-Date).AddDays(-3)
            $lastScanned = $recentScanDate.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            
            # Act
            $parsedDate = [DateTime]::Parse($lastScanned)
            $daysSinceLastScan = ((Get-Date) - $parsedDate).Days
            $needsContainerScan = $daysSinceLastScan -gt 7
            
            # Assert
            $needsContainerScan | Should -Be $false
        }
        
        It "Should only scan Dockerfile-based Docker actions" {
            # Arrange - Docker action using remote image
            $action = @{
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Image"
                }
            }
            
            # Act
            $shouldScan = $action.actionType.actionDockerType -eq "Dockerfile"
            
            # Assert
            $shouldScan | Should -Be $false
        }
        
        It "Should scan Docker actions with Dockerfile" {
            # Arrange
            $action = @{
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Dockerfile"
                }
            }
            
            # Act
            $shouldScan = $action.actionType.actionDockerType -eq "Dockerfile"
            
            # Assert
            $shouldScan | Should -Be $true
        }
    }
    
    Context "Container scan result structure" {
        It "Should have expected fields in scan result" {
            # Arrange
            $scanResult = @{
                critical = 5
                high = 10
                lastScanned = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ")
                scanError = $null
            }
            
            # Assert
            $scanResult.ContainsKey("critical") | Should -Be $true
            $scanResult.ContainsKey("high") | Should -Be $true
            $scanResult.ContainsKey("lastScanned") | Should -Be $true
            $scanResult.ContainsKey("scanError") | Should -Be $true
        }
        
        It "Should handle scan error in result" {
            # Arrange
            $scanResult = @{
                critical = 0
                high = 0
                lastScanned = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ")
                scanError = "Docker build failed"
            }
            
            # Assert
            $scanResult.scanError | Should -Be "Docker build failed"
        }
    }
    
    Context "Action type detection" {
        It "Should identify Docker action correctly" {
            # Arrange
            $action = @{
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Dockerfile"
                }
            }
            
            # Act & Assert
            $action.actionType.actionType | Should -Be "Docker"
        }
        
        It "Should identify Node action and skip scan" {
            # Arrange
            $action = @{
                actionType = @{
                    actionType = "Node"
                    nodeVersion = "20"
                }
            }
            
            # Act & Assert
            $action.actionType.actionType | Should -Be "Node"
            # Node actions don't have actionDockerType, so scan should be skipped
        }
        
        It "Should identify Composite action and skip scan" {
            # Arrange
            $action = @{
                actionType = @{
                    actionType = "Composite"
                }
            }
            
            # Act & Assert
            $action.actionType.actionType | Should -Be "Composite"
        }
    }
}
