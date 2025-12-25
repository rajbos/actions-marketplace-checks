Import-Module Pester

BeforeAll {
    # import library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
    
    # Define the GroupNodeVersionsAndCount function inline since we can't source report.ps1 without executing it
    function GroupNodeVersionsAndCount {
        Param (
            $nodeVersions
        )

        # count items per node version
        $nodeVersionCount = @{}
        foreach ($nodeVersion in $nodeVersions) {
            if ($nodeVersionCount.ContainsKey($nodeVersion)) {
                $nodeVersionCount[$nodeVersion]++
            }
            else {
                $nodeVersionCount.Add($nodeVersion, 1)
            }
        }
        $nodeVersionCount = ($nodeVersionCount.GetEnumerator() | Sort-Object Key)
        return $nodeVersionCount
    }
}

Describe "Mermaid Diagram Node Version Breakdown" {
    It "Should properly separate versions into >= 20 and < 20 groups" {
        # Arrange
        $nodeVersions = @("12", "16", "18", "20", "21", "22")
        $nodeVersionCount = GroupNodeVersionsAndCount -nodeVersions $nodeVersions
        
        # Act - Separate into groups
        $worksOnDefaultRunners = 0
        $needsSetupNode = 0
        $worksOnDefaultRunnersVersions = @{}
        $needsSetupNodeVersions = @{}
        
        foreach ($nodeVersion in $nodeVersionCount) {
            $versionNumber = [int]$nodeVersion.Key
            if ($versionNumber -ge 20) {
                $worksOnDefaultRunners += $nodeVersion.Value
                $worksOnDefaultRunnersVersions[$nodeVersion.Key] = $nodeVersion.Value
            } else {
                $needsSetupNode += $nodeVersion.Value
                $needsSetupNodeVersions[$nodeVersion.Key] = $nodeVersion.Value
            }
        }
        
        # Assert
        $worksOnDefaultRunners | Should -Be 3  # 20, 21, 22
        $needsSetupNode | Should -Be 3  # 12, 16, 18
        $worksOnDefaultRunnersVersions.Keys.Count | Should -Be 3
        $needsSetupNodeVersions.Keys.Count | Should -Be 3
    }
    
    It "Should track individual versions in worksOnDefaultRunnersVersions hashtable" {
        # Arrange
        $nodeVersions = @("20", "20", "21", "21", "21", "22")
        $nodeVersionCount = GroupNodeVersionsAndCount -nodeVersions $nodeVersions
        
        # Act
        $worksOnDefaultRunnersVersions = @{}
        
        foreach ($nodeVersion in $nodeVersionCount) {
            $versionNumber = [int]$nodeVersion.Key
            if ($versionNumber -ge 20) {
                $worksOnDefaultRunnersVersions[$nodeVersion.Key] = $nodeVersion.Value
            }
        }
        
        # Assert
        $worksOnDefaultRunnersVersions.Keys.Count | Should -Be 3
        $worksOnDefaultRunnersVersions["20"] | Should -Be 2
        $worksOnDefaultRunnersVersions["21"] | Should -Be 3
        $worksOnDefaultRunnersVersions["22"] | Should -Be 1
    }
    
    It "Should calculate correct node labels without conflicts" {
        # Arrange - Simulate 3 versions >= 20 and 5 versions < 20
        $worksOnDefaultRunnersCount = 3
        $needsSetupNodeCount = 5
        
        # Act - Generate node labels for "works on default runners"
        $defaultRunnersLabels = @()
        for ($i = 0; $i -lt $worksOnDefaultRunnersCount; $i++) {
            $label = [char]([int][char]'D' + $i)
            $defaultRunnersLabels += $label
        }
        
        # Generate node labels for "needs setup-node"
        $startingOffset = $worksOnDefaultRunnersCount
        $needsSetupLabels = @()
        for ($i = 0; $i -lt $needsSetupNodeCount; $i++) {
            $label = [char]([int][char]'D' + $startingOffset + $i)
            $needsSetupLabels += $label
        }
        
        # Assert - No conflicts between labels
        $defaultRunnersLabels | Should -Contain 'D'
        $defaultRunnersLabels | Should -Contain 'E'
        $defaultRunnersLabels | Should -Contain 'F'
        
        $needsSetupLabels | Should -Contain 'G'
        $needsSetupLabels | Should -Contain 'H'
        $needsSetupLabels | Should -Contain 'I'
        $needsSetupLabels | Should -Contain 'J'
        $needsSetupLabels | Should -Contain 'K'
        
        # Ensure no overlap
        $allLabels = $defaultRunnersLabels + $needsSetupLabels
        $uniqueLabels = $allLabels | Select-Object -Unique
        $uniqueLabels.Count | Should -Be $allLabels.Count
    }
    
    It "Should handle case with only >= 20 versions" {
        # Arrange
        $nodeVersions = @("20", "21", "22", "23")
        $nodeVersionCount = GroupNodeVersionsAndCount -nodeVersions $nodeVersions
        
        # Act
        $worksOnDefaultRunners = 0
        $needsSetupNode = 0
        $worksOnDefaultRunnersVersions = @{}
        $needsSetupNodeVersions = @{}
        
        foreach ($nodeVersion in $nodeVersionCount) {
            $versionNumber = [int]$nodeVersion.Key
            if ($versionNumber -ge 20) {
                $worksOnDefaultRunners += $nodeVersion.Value
                $worksOnDefaultRunnersVersions[$nodeVersion.Key] = $nodeVersion.Value
            } else {
                $needsSetupNode += $nodeVersion.Value
                $needsSetupNodeVersions[$nodeVersion.Key] = $nodeVersion.Value
            }
        }
        
        # Assert
        $worksOnDefaultRunners | Should -Be 4
        $needsSetupNode | Should -Be 0
        $worksOnDefaultRunnersVersions.Keys.Count | Should -Be 4
        $needsSetupNodeVersions.Keys.Count | Should -Be 0
    }
    
    It "Should handle case with only < 20 versions" {
        # Arrange
        $nodeVersions = @("12", "14", "16", "18")
        $nodeVersionCount = GroupNodeVersionsAndCount -nodeVersions $nodeVersions
        
        # Act
        $worksOnDefaultRunners = 0
        $needsSetupNode = 0
        $worksOnDefaultRunnersVersions = @{}
        $needsSetupNodeVersions = @{}
        
        foreach ($nodeVersion in $nodeVersionCount) {
            $versionNumber = [int]$nodeVersion.Key
            if ($versionNumber -ge 20) {
                $worksOnDefaultRunners += $nodeVersion.Value
                $worksOnDefaultRunnersVersions[$nodeVersion.Key] = $nodeVersion.Value
            } else {
                $needsSetupNode += $nodeVersion.Value
                $needsSetupNodeVersions[$nodeVersion.Key] = $nodeVersion.Value
            }
        }
        
        # Assert
        $worksOnDefaultRunners | Should -Be 0
        $needsSetupNode | Should -Be 4
        $worksOnDefaultRunnersVersions.Keys.Count | Should -Be 0
        $needsSetupNodeVersions.Keys.Count | Should -Be 4
    }
    
    It "Should correctly calculate percentages for breakdown" {
        # Arrange
        $nodeVersions = @("20") * 80 + @("21") * 20
        $nodeVersionCount = GroupNodeVersionsAndCount -nodeVersions $nodeVersions
        $nodeBasedActions = 100
        
        # Act
        $worksOnDefaultRunners = 0
        $worksOnDefaultRunnersVersions = @{}
        
        foreach ($nodeVersion in $nodeVersionCount) {
            $versionNumber = [int]$nodeVersion.Key
            if ($versionNumber -ge 20) {
                $worksOnDefaultRunners += $nodeVersion.Value
                $worksOnDefaultRunnersVersions[$nodeVersion.Key] = $nodeVersion.Value
            }
        }
        
        $worksOnDefaultPercentage = [math]::Round($worksOnDefaultRunners/$nodeBasedActions * 100, 1)
        $node20Percentage = [math]::Round($worksOnDefaultRunnersVersions["20"]/$worksOnDefaultRunners * 100, 1)
        $node21Percentage = [math]::Round($worksOnDefaultRunnersVersions["21"]/$worksOnDefaultRunners * 100, 1)
        
        # Assert
        $worksOnDefaultPercentage | Should -Be 100.0
        $node20Percentage | Should -Be 80.0
        $node21Percentage | Should -Be 20.0
    }
}
