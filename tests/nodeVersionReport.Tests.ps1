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

Describe "GroupNodeVersionsAndCount" {
    It "Should count node versions correctly" {
        # Arrange
        $nodeVersions = @("16", "16", "12", "20", "16", "12")
        
        # Act
        $result = GroupNodeVersionsAndCount -nodeVersions $nodeVersions
        
        # Assert
        $result.Count | Should -Be 3
        
        # Find the entry for version 16
        $version16 = $result | Where-Object { $_.Key -eq "16" }
        $version16.Value | Should -Be 3
        
        # Find the entry for version 12
        $version12 = $result | Where-Object { $_.Key -eq "12" }
        $version12.Value | Should -Be 2
        
        # Find the entry for version 20
        $version20 = $result | Where-Object { $_.Key -eq "20" }
        $version20.Value | Should -Be 1
    }

    It "Should handle empty array" {
        # Arrange
        $nodeVersions = @()
        
        # Act
        $result = GroupNodeVersionsAndCount -nodeVersions $nodeVersions
        
        # Assert
        $result.Count | Should -Be 0
    }

    It "Should handle single version" {
        # Arrange
        $nodeVersions = @("20")
        
        # Act
        $result = GroupNodeVersionsAndCount -nodeVersions $nodeVersions
        
        # Assert
        $result.Count | Should -Be 1
        $version20 = $result | Where-Object { $_.Key -eq "20" }
        $version20.Value | Should -Be 1
    }
    
    It "Should sort versions correctly" {
        # Arrange
        $nodeVersions = @("20", "12", "16", "12", "20", "16")
        
        # Act
        $result = GroupNodeVersionsAndCount -nodeVersions $nodeVersions
        
        # Assert - The function sorts by Key (version number), not by Count
        # This is intentional as the function is used in the mermaid flowchart
        # The report section re-sorts by Count when displaying the list
        $result.Count | Should -Be 3
        $result[0].Key | Should -Be "12"
        $result[1].Key | Should -Be "16"
        $result[2].Key | Should -Be "20"
    }
}
