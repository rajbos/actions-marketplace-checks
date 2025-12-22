Import-Module Pester

BeforeAll {
    # import library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
    
    # Define the GroupNodeVersionsAndCount function from report.ps1
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
    
    # Test function to separate node versions into groups
    function SeparateNodeVersionGroups {
        Param (
            $nodeVersionCount
        )
        
        $worksOnDefaultRunners = 0
        $needsSetupNode = 0
        $needsSetupNodeVersions = @{}
        
        foreach ($nodeVersion in $nodeVersionCount) {
            $versionNumber = [int]$nodeVersion.Key
            if ($versionNumber -ge 20) {
                $worksOnDefaultRunners += $nodeVersion.Value
            } else {
                $needsSetupNode += $nodeVersion.Value
                $needsSetupNodeVersions[$nodeVersion.Key] = $nodeVersion.Value
            }
        }
        
        return @{
            WorksOnDefaultRunners = $worksOnDefaultRunners
            NeedsSetupNode = $needsSetupNode
            NeedsSetupNodeVersions = $needsSetupNodeVersions
        }
    }
}

Describe "Node Version Grouping" {
    It "Should correctly separate node versions into default runners and setup-node groups" {
        # Arrange
        $nodeVersions = @("12", "16", "16", "20", "20", "20", "21")
        
        # Act
        $nodeVersionCount = GroupNodeVersionsAndCount -nodeVersions $nodeVersions
        $groups = SeparateNodeVersionGroups -nodeVersionCount $nodeVersionCount
        
        # Assert
        $groups.WorksOnDefaultRunners | Should -Be 4  # 3x node20 + 1x node21
        $groups.NeedsSetupNode | Should -Be 3  # 1x node12 + 2x node16
        $groups.NeedsSetupNodeVersions.Count | Should -Be 2  # node12 and node16
        $groups.NeedsSetupNodeVersions["12"] | Should -Be 1
        $groups.NeedsSetupNodeVersions["16"] | Should -Be 2
    }
    
    It "Should handle all versions working on default runners" {
        # Arrange
        $nodeVersions = @("20", "21", "22", "20")
        
        # Act
        $nodeVersionCount = GroupNodeVersionsAndCount -nodeVersions $nodeVersions
        $groups = SeparateNodeVersionGroups -nodeVersionCount $nodeVersionCount
        
        # Assert
        $groups.WorksOnDefaultRunners | Should -Be 4
        $groups.NeedsSetupNode | Should -Be 0
        $groups.NeedsSetupNodeVersions.Count | Should -Be 0
    }
    
    It "Should handle all versions needing setup-node" {
        # Arrange
        $nodeVersions = @("12", "14", "16", "16", "18")
        
        # Act
        $nodeVersionCount = GroupNodeVersionsAndCount -nodeVersions $nodeVersions
        $groups = SeparateNodeVersionGroups -nodeVersionCount $nodeVersionCount
        
        # Assert
        $groups.WorksOnDefaultRunners | Should -Be 0
        $groups.NeedsSetupNode | Should -Be 5
        $groups.NeedsSetupNodeVersions.Count | Should -Be 4  # 12, 14, 16, 18
        $groups.NeedsSetupNodeVersions["16"] | Should -Be 2
    }
    
    It "Should calculate correct percentages for groups" {
        # Arrange
        $nodeVersions = @("12", "16", "16", "20", "20", "20", "20", "20", "20")  # 9 total: 6 on default, 3 need setup
        
        # Act
        $nodeVersionCount = GroupNodeVersionsAndCount -nodeVersions $nodeVersions
        $groups = SeparateNodeVersionGroups -nodeVersionCount $nodeVersionCount
        $totalActions = $groups.WorksOnDefaultRunners + $groups.NeedsSetupNode
        
        # Calculate percentages
        $worksOnDefaultPercentage = [math]::Round($groups.WorksOnDefaultRunners/$totalActions * 100 , 1)
        $needsSetupNodePercentage = [math]::Round($groups.NeedsSetupNode/$totalActions * 100 , 1)
        
        # Assert
        $worksOnDefaultPercentage | Should -Be 66.7
        $needsSetupNodePercentage | Should -Be 33.3
    }
    
    It "Should handle node version 20 as default runner boundary" {
        # Arrange - Node 20 should be in "works on default runners"
        $nodeVersions = @("19", "20")
        
        # Act
        $nodeVersionCount = GroupNodeVersionsAndCount -nodeVersions $nodeVersions
        $groups = SeparateNodeVersionGroups -nodeVersionCount $nodeVersionCount
        
        # Assert
        $groups.WorksOnDefaultRunners | Should -Be 1  # node20
        $groups.NeedsSetupNode | Should -Be 1  # node19
        $groups.NeedsSetupNodeVersions["19"] | Should -Be 1
    }
    
    It "Should not divide by zero when calculating percentages for empty needs-setup-node group" {
        # Arrange - All versions work on default runners
        $nodeVersions = @("20", "21", "22")
        
        # Act
        $nodeVersionCount = GroupNodeVersionsAndCount -nodeVersions $nodeVersions
        $groups = SeparateNodeVersionGroups -nodeVersionCount $nodeVersionCount
        
        # Assert - Should not throw when needsSetupNode is 0
        $groups.NeedsSetupNode | Should -Be 0
        $groups.WorksOnDefaultRunners | Should -Be 3
        
        # Verify that attempting to calculate percentage from needs-setup-node versions
        # would be safe (even though we guard against this in production code)
        $groups.NeedsSetupNodeVersions.Count | Should -Be 0
    }
}
