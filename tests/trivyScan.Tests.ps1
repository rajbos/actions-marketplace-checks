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

Describe "Trivy scan result handling" {
    It "Should store successful scan results" {
        # Arrange
        $action = @{
            owner = "test-owner"
            name = "test-repo"
            actionType = @{
                actionType = "Docker"
                actionDockerType = "Dockerfile"
            }
        }
        $scanResult = @{
            critical = 2
            high = 5
            lastScanned = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ")
            scanError = $null
        }

        # Act
        $hasContainerScanField = Get-Member -inputobject $action.actionType -name "containerScan" -Membertype Properties
        if ($null -ne $scanResult -and $null -eq $scanResult.scanError) {
            if (!$hasContainerScanField) {
                $action.actionType | Add-Member -Name containerScan -Value $scanResult -MemberType NoteProperty
            }
            else {
                $action.actionType.containerScan = $scanResult
            }
        }

        # Assert
        $action.actionType.containerScan.critical | Should -Be 2
        $action.actionType.containerScan.high | Should -Be 5
    }

    It "Should not store failed scan results so they can be retried" {
        # Arrange
        $action = @{
            owner = "test-owner"
            name = "test-repo"
            actionType = @{
                actionType = "Docker"
                actionDockerType = "Dockerfile"
                fileFound = "action.yml"
            }
        }
        $scanResult = @{
            critical = 0
            high = 0
            lastScanned = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ")
            scanError = "Trivy installation failed"
        }
        $trivyScanFailures = @()

        # Act
        $hasContainerScanField = Get-Member -inputobject $action.actionType -name "containerScan" -Membertype Properties
        if ($null -ne $scanResult -and $null -eq $scanResult.scanError) {
            if (!$hasContainerScanField) {
                $action.actionType | Add-Member -Name containerScan -Value $scanResult -MemberType NoteProperty
            }
            else {
                $action.actionType.containerScan = $scanResult
            }
        }
        elseif ($null -ne $scanResult -and $null -ne $scanResult.scanError) {
            $dockerSource = if ($action.actionType.fileFound) { $action.actionType.fileFound } else { $action.actionType.actionDockerType }
            $trivyScanFailures += @{
                ownerRepo = "$($action.owner)/$($action.name)"
                dockerSource = $dockerSource
                error = $scanResult.scanError
                timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ")
            }
        }

        # Assert
        $action.actionType.PSObject.Properties.Name | Should -Not -Contain "containerScan"
        $trivyScanFailures.Count | Should -Be 1
        $trivyScanFailures[0].ownerRepo | Should -Be "test-owner/test-repo"
        $trivyScanFailures[0].dockerSource | Should -Be "action.yml"
        $trivyScanFailures[0].error | Should -Be "Trivy installation failed"
    }
}

Describe "Trivy scan failure artifact" {
    It "Should write failures to JSON file" {
        # Arrange
        $tempDir = [System.IO.Path]::GetTempPath()
        $testFile = Join-Path $tempDir "trivy-scan-failures-test.json"
        if (Test-Path $testFile) {
            Remove-Item $testFile -Force
        }

        $trivyScanFailures = @(
            @{
                ownerRepo = "owner/repo"
                dockerSource = "action.yml"
                error = "Trivy installation failed"
                timestamp = "2026-07-26T22:00:00.000Z"
            }
        )

        # Act
        $trivyScanFailures | ConvertTo-Json -Depth 5 | Out-File -FilePath $testFile -Encoding UTF8

        # Assert
        Test-Path $testFile | Should -Be $true
        $content = Get-Content $testFile -Raw | ConvertFrom-Json
        $content.Count | Should -Be 1
        $content[0].ownerRepo | Should -Be "owner/repo"
        $content[0].dockerSource | Should -Be "action.yml"
        $content[0].error | Should -Be "Trivy installation failed"

        # Cleanup
        Remove-Item $testFile -Force
    }
}
