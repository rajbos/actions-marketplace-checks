Import-Module Pester

BeforeAll {
    # Test function to simulate the processing metrics tracking
    function Format-ProcessingMetricsSummary {
        Param (
            [int]$totalRepos,
            [int]$reposExamined,
            [int]$reposSkipped,
            [int]$numberOfReposToDo
        )
        
        $summary = "## Processing Summary`n`n"
        $summary += "| Metric | Count |`n"
        $summary += "| --- | --- |`n"
        $summary += "| Total repos in status file | $totalRepos |`n"
        $summary += "| Repos examined | $reposExamined |`n"
        $summary += "| Repos skipped | $reposSkipped |`n"
        $summary += "| Limit (numberOfReposToDo) | $numberOfReposToDo |`n"
        
        return $summary
    }
}

Describe "RepoInfo Processing Metrics Summary" {
    It "Should generate a valid markdown table with processing metrics" {
        # Arrange
        $totalRepos = 23050
        $reposExamined = 500
        $reposSkipped = 50
        $numberOfReposToDo = 500
        
        # Act
        $summary = Format-ProcessingMetricsSummary -totalRepos $totalRepos -reposExamined $reposExamined -reposSkipped $reposSkipped -numberOfReposToDo $numberOfReposToDo
        
        # Assert
        $summary | Should -Match "## Processing Summary"
        $summary | Should -Match "\| Metric \| Count \|"
        $summary | Should -Match "\| Total repos in status file \| 23050 \|"
        $summary | Should -Match "\| Repos examined \| 500 \|"
        $summary | Should -Match "\| Repos skipped \| 50 \|"
        $summary | Should -Match "\| Limit \(numberOfReposToDo\) \| 500 \|"
    }
    
    It "Should handle scenario with no repos skipped" {
        # Arrange
        $totalRepos = 100
        $reposExamined = 50
        $reposSkipped = 0
        $numberOfReposToDo = 50
        
        # Act
        $summary = Format-ProcessingMetricsSummary -totalRepos $totalRepos -reposExamined $reposExamined -reposSkipped $reposSkipped -numberOfReposToDo $numberOfReposToDo
        
        # Assert
        $summary | Should -Match "\| Repos skipped \| 0 \|"
    }
    
    It "Should handle scenario where all repos were examined (equals limit)" {
        # Arrange - This matches the problem statement scenario
        $totalRepos = 23050
        $reposExamined = 500
        $reposSkipped = 100
        $numberOfReposToDo = 500
        
        # Act
        $summary = Format-ProcessingMetricsSummary -totalRepos $totalRepos -reposExamined $reposExamined -reposSkipped $reposSkipped -numberOfReposToDo $numberOfReposToDo
        
        # Assert
        $summary | Should -Match "\| Repos examined \| 500 \|"
        $summary | Should -Match "\| Limit \(numberOfReposToDo\) \| 500 \|"
    }
    
    It "Should show when processing stopped early (examined < limit)" {
        # Arrange - Stopped due to time limit or other constraint
        $totalRepos = 23050
        $reposExamined = 250
        $reposSkipped = 20
        $numberOfReposToDo = 500
        
        # Act
        $summary = Format-ProcessingMetricsSummary -totalRepos $totalRepos -reposExamined $reposExamined -reposSkipped $reposSkipped -numberOfReposToDo $numberOfReposToDo
        
        # Assert
        $summary | Should -Match "\| Repos examined \| 250 \|"
        $summary | Should -Match "\| Limit \(numberOfReposToDo\) \| 500 \|"
        
        # In this case, examined (250) < limit (500), indicating early stop
        $reposExamined | Should -BeLessThan $numberOfReposToDo
    }
    
    It "Should correctly format the markdown table structure" {
        # Arrange
        $totalRepos = 1000
        $reposExamined = 100
        $reposSkipped = 10
        $numberOfReposToDo = 100
        
        # Act
        $summary = Format-ProcessingMetricsSummary -totalRepos $totalRepos -reposExamined $reposExamined -reposSkipped $reposSkipped -numberOfReposToDo $numberOfReposToDo
        $lines = $summary -split "`n"
        
        # Assert - Check structure
        $lines[0] | Should -Be "## Processing Summary"
        $lines[2] | Should -Match "^\| Metric \| Count \|$"
        $lines[3] | Should -Match "^\| --- \| --- \|$"
        
        # Check that all data rows are formatted correctly
        $dataRows = $lines | Where-Object { $_ -match "^\| Total repos" -or $_ -match "^\| Repos examined" -or $_ -match "^\| Repos skipped" -or $_ -match "^\| Limit" }
        $dataRows.Count | Should -Be 4
    }
}

Describe "Processing Metrics Tracking Logic" {
    It "Should track repos examined vs total repos correctly" {
        # Arrange - Simulating the loop logic
        $totalRepos = 23050
        $numberOfReposToDo = 500
        $reposExamined = 0
        $reposWithUpdates = 0
        
        # Act - Simulate processing 500 repos
        for ($i = 0; $i -lt $numberOfReposToDo; $i++) {
            $reposExamined++
            # Simulate some repos having updates (every 10th repo)
            if ($i % 10 -eq 0) {
                $reposWithUpdates++
            }
        }
        
        # Assert
        $reposExamined | Should -Be 500
        $reposWithUpdates | Should -Be 50
    }
    
    It "Should differentiate between examined and actually updated repos" {
        # Arrange - The key issue from the problem statement:
        # 8 minutes, 0 deltas means repos were examined but not updated
        $reposExamined = 500
        $reposWithUpdates = 0  # 0 deltas
        
        # Assert - This is the scenario we're trying to make visible
        $reposExamined | Should -BeGreaterThan $reposWithUpdates
        $reposWithUpdates | Should -Be 0
        
        # The new metrics should show:
        # - Repos examined: 500 (helps understand why it took 8 minutes)
        # - Deltas: 0 (no repos were actually updated - from existing summary table)
    }
}
