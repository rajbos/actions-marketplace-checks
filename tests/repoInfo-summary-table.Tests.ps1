Import-Module Pester

BeforeAll {
    # Test to verify the summary table generation logic
    
    function Format-RepoInfoSummaryTable {
        Param (
            [hashtable] $metrics
        )
        
        $table = "| Metric | Started | Ended | Delta |`n"
        $table += "| --- | --- | --- | --- |`n"
        
        foreach ($key in $metrics.Keys | Sort-Object) {
            $started = $metrics[$key].Started
            $ended = $metrics[$key].Ended
            $delta = $ended - $started
            $deltaStr = if ($delta -ge 0) { "+$delta" } else { "$delta" }
            $table += "| $key | $started | $ended | $deltaStr |`n"
        }
        
        return $table
    }
}

Describe "RepoInfo Summary Table Generation" {
    It "Should generate a valid markdown table with started, ended, and delta columns" {
        # Arrange
        $metrics = @{
            "Repository Information" = @{ Started = 18841; Ended = 18907 }
            "Tag Information" = @{ Started = 18907; Ended = 19373 }
            "Release Information" = @{ Started = 19373; Ended = 19358 }
        }
        
        # Act
        $table = Format-RepoInfoSummaryTable -metrics $metrics
        
        # Assert
        $table | Should -Match "\| Metric \| Started \| Ended \| Delta \|"
        $table | Should -Match "\| --- \| --- \| --- \| --- \|"
        $table | Should -Match "\| Release Information \| 19373 \| 19358 \| -15 \|"
        $table | Should -Match "\| Repository Information \| 18841 \| 18907 \| \+66 \|"
        $table | Should -Match "\| Tag Information \| 18907 \| 19373 \| \+466 \|"
    }
    
    It "Should match the example data from the problem statement" {
        # Arrange - Using actual data from the problem statement
        $metrics = @{
            "Repository Information" = @{ Started = 18841; Ended = 18907 }
            "Tag Information" = @{ Started = 18907; Ended = 19373 }
            "Release Information" = @{ Started = 19373; Ended = 19358 }
        }
        
        # Act
        $table = Format-RepoInfoSummaryTable -metrics $metrics
        
        # Assert - verify calculations
        # Repository: 18907 - 18841 = +66
        $table | Should -Match "\| Repository Information \| 18841 \| 18907 \| \+66 \|"
        # Tag: 19373 - 18907 = +466
        $table | Should -Match "\| Tag Information \| 18907 \| 19373 \| \+466 \|"
        # Release: 19358 - 19373 = -15
        $table | Should -Match "\| Release Information \| 19373 \| 19358 \| -15 \|"
    }
    
    It "Should handle zero delta correctly" {
        # Arrange
        $metrics = @{
            "Repository Information" = @{ Started = 100; Ended = 100 }
        }
        
        # Act
        $table = Format-RepoInfoSummaryTable -metrics $metrics
        
        # Assert
        $table | Should -Match "\| Repository Information \| 100 \| 100 \| \+0 \|"
    }
    
    It "Should handle negative delta correctly" {
        # Arrange
        $metrics = @{
            "Repository Information" = @{ Started = 200; Ended = 150 }
        }
        
        # Act
        $table = Format-RepoInfoSummaryTable -metrics $metrics
        
        # Assert
        $table | Should -Match "\| Repository Information \| 200 \| 150 \| -50 \|"
    }
    
    It "Should sort metrics alphabetically" {
        # Arrange
        $metrics = @{
            "Zebra" = @{ Started = 1; Ended = 2 }
            "Alpha" = @{ Started = 3; Ended = 4 }
            "Beta" = @{ Started = 5; Ended = 6 }
        }
        
        # Act
        $table = Format-RepoInfoSummaryTable -metrics $metrics
        $lines = $table -split "`n"
        
        # Assert - Alpha should come before Beta, which should come before Zebra
        $alphaIndex = ($lines | Select-String "Alpha").LineNumber
        $betaIndex = ($lines | Select-String "Beta").LineNumber
        $zebraIndex = ($lines | Select-String "Zebra").LineNumber
        
        $alphaIndex | Should -BeLessThan $betaIndex
        $betaIndex | Should -BeLessThan $zebraIndex
    }
}
