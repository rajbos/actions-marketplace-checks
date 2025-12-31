BeforeAll {
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe 'ShowOverallDatasetStatistics' {
    BeforeEach {
        # Capture Write-Message calls
        Mock Write-Message { }
    }

    It 'Should calculate correct totals with mixed mirror status' {
        # Arrange - Create test data with mix of repos with and without mirrors
        $testForks = @(
            @{ name = "repo1"; mirrorFound = $true; lastSynced = (Get-Date).AddDays(-2).ToString("yyyy-MM-ddTHH:mm:ssZ") }
            @{ name = "repo2"; mirrorFound = $true; lastSynced = (Get-Date).AddDays(-3).ToString("yyyy-MM-ddTHH:mm:ssZ") }
            @{ name = "repo3"; mirrorFound = $true; lastSynced = (Get-Date).AddDays(-10).ToString("yyyy-MM-ddTHH:mm:ssZ") }
            @{ name = "repo4"; mirrorFound = $true; lastSynced = $null }
            @{ name = "repo5"; mirrorFound = $false }
            @{ name = "repo6"; mirrorFound = $false }
            @{ name = "repo7"; mirrorFound = $false }
        )

        # Act
        ShowOverallDatasetStatistics -existingForks $testForks

        # Assert - Check that correct messages were logged
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Total Repositories in Dataset** | **7**" 
        }
        
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Repositories with Valid Mirrors | 4 |*" 
        }
        
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Repositories without Mirrors | 3 |*" 
        }
        
        # Should show 2 repos checked in last 7 days (repo1 and repo2)
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Repos Checked (Last 7 Days) | 2 |*" 
        }
        
        # Should show 2 repos not checked (repo3 synced >7 days ago, repo4 never synced)
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Repos Not Checked Yet | 2 |*" 
        }
    }

    It 'Should handle all repos with mirrors' {
        # Arrange
        $testForks = @(
            @{ name = "repo1"; mirrorFound = $true; lastSynced = (Get-Date).AddDays(-2).ToString("yyyy-MM-ddTHH:mm:ssZ") }
            @{ name = "repo2"; mirrorFound = $true; lastSynced = (Get-Date).AddDays(-3).ToString("yyyy-MM-ddTHH:mm:ssZ") }
        )

        # Act
        ShowOverallDatasetStatistics -existingForks $testForks

        # Assert
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Total Repositories in Dataset** | **2**" 
        }
        
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Repositories with Valid Mirrors | 2 | 100%*" 
        }
        
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Repositories without Mirrors | 0 | 0%*" 
        }
    }

    It 'Should handle all repos without mirrors' {
        # Arrange
        $testForks = @(
            @{ name = "repo1"; mirrorFound = $false }
            @{ name = "repo2"; mirrorFound = $false }
            @{ name = "repo3"; mirrorFound = $false }
        )

        # Act
        ShowOverallDatasetStatistics -existingForks $testForks

        # Assert
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Total Repositories in Dataset** | **3**" 
        }
        
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Repositories with Valid Mirrors | 0 | 0%*" 
        }
        
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Repositories without Mirrors | 3 | 100%*" 
        }
    }

    It 'Should only count repos with mirrorFound=true when calculating sync statistics' {
        # Arrange - Mix of repos, some synced recently, some without mirrors
        $testForks = @(
            @{ name = "repo1"; mirrorFound = $true; lastSynced = (Get-Date).AddDays(-2).ToString("yyyy-MM-ddTHH:mm:ssZ") }
            @{ name = "repo2"; mirrorFound = $false; lastSynced = (Get-Date).AddDays(-2).ToString("yyyy-MM-ddTHH:mm:ssZ") }  # Has lastSynced but no mirror - should be ignored
            @{ name = "repo3"; mirrorFound = $true; lastSynced = $null }
        )

        # Act
        ShowOverallDatasetStatistics -existingForks $testForks

        # Assert - Only repo1 should be counted as synced (repo2 has no mirror, so shouldn't count)
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Repos Checked (Last 7 Days) | 1 |*" 
        }
        
        # repo3 has mirror but not synced
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Repos Not Checked Yet | 1 |*" 
        }
    }

    It 'Should calculate percentages correctly' {
        # Arrange - Create data where percentages are easy to verify
        $testForks = @(
            # 10 total repos
            @{ name = "repo1"; mirrorFound = $true; lastSynced = (Get-Date).AddDays(-2).ToString("yyyy-MM-ddTHH:mm:ssZ") }
            @{ name = "repo2"; mirrorFound = $true; lastSynced = (Get-Date).AddDays(-3).ToString("yyyy-MM-ddTHH:mm:ssZ") }
            @{ name = "repo3"; mirrorFound = $true; lastSynced = (Get-Date).AddDays(-4).ToString("yyyy-MM-ddTHH:mm:ssZ") }
            @{ name = "repo4"; mirrorFound = $true; lastSynced = (Get-Date).AddDays(-5).ToString("yyyy-MM-ddTHH:mm:ssZ") }
            @{ name = "repo5"; mirrorFound = $true; lastSynced = (Get-Date).AddDays(-10).ToString("yyyy-MM-ddTHH:mm:ssZ") }
            @{ name = "repo6"; mirrorFound = $true; lastSynced = $null }
            @{ name = "repo7"; mirrorFound = $false }
            @{ name = "repo8"; mirrorFound = $false }
            @{ name = "repo9"; mirrorFound = $false }
            @{ name = "repo10"; mirrorFound = $false }
        )

        # Act
        ShowOverallDatasetStatistics -existingForks $testForks

        # Assert
        # 6 repos with mirrors (60% of 10 total)
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Repositories with Valid Mirrors | 6 | 60%*" 
        }
        
        # 4 repos without mirrors (40% of 10 total)
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Repositories without Mirrors | 4 | 40%*" 
        }
        
        # 4 repos checked in last 7 days (66.67% of 6 with mirrors)
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Repos Checked (Last 7 Days) | 4 | 66.67%*" 
        }
        
        # 2 repos not checked (33.33% of 6 with mirrors)
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Repos Not Checked Yet | 2 | 33.33%*" 
        }
    }

    It 'Should include explanatory note about repos without mirrors' {
        # Arrange
        $testForks = @(
            @{ name = "repo1"; mirrorFound = $true; lastSynced = (Get-Date).AddDays(-2).ToString("yyyy-MM-ddTHH:mm:ssZ") }
            @{ name = "repo2"; mirrorFound = $false }
        )

        # Act
        ShowOverallDatasetStatistics -existingForks $testForks

        # Assert - Check for explanatory note
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Repositories without mirrors cannot be synced*" 
        }
        
        # Assert - Check for context about "Valid Mirrors Only"
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Last 7 Days Sync Activity (Valid Mirrors Only)*" 
        }
    }

    It 'Should handle invalid lastSynced dates gracefully' {
        # Arrange
        $testForks = @(
            @{ name = "repo1"; mirrorFound = $true; lastSynced = "invalid-date" }
            @{ name = "repo2"; mirrorFound = $true; lastSynced = (Get-Date).AddDays(-2).ToString("yyyy-MM-ddTHH:mm:ssZ") }
        )

        # Act - Should not throw
        { ShowOverallDatasetStatistics -existingForks $testForks } | Should -Not -Throw

        # Assert - repo1 with invalid date should be counted as not checked
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Repos Checked (Last 7 Days) | 1 |*" 
        }
        
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "*Repos Not Checked Yet | 1 |*" 
        }
    }

    It 'Should display top 10 repositories without mirrors in collapsible section' {
        # Arrange - Create test data with repos without mirrors
        $testForks = @(
            @{ name = "owner1_repo1"; mirrorFound = $false }
            @{ name = "owner2_repo2"; mirrorFound = $false }
            @{ name = "owner3_repo3"; mirrorFound = $false }
            @{ name = "owner4_repo4"; mirrorFound = $true; lastSynced = (Get-Date).AddDays(-2).ToString("yyyy-MM-ddTHH:mm:ssZ") }
        )

        # Act
        ShowOverallDatasetStatistics -existingForks $testForks

        # Assert - Check that collapsible section is created
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -eq "<details>" 
        }
        
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "<summary>Top 3 Repositories without Mirrors</summary>" 
        }
        
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -eq "</details>" 
        }
        
        # Check that table headers are present
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -eq "| Mirror | Upstream |" 
        }
        
        # Check that at least one repo link is created
        Should -Invoke Write-Message -ParameterFilter { 
            $message -like "*owner1_repo1*" -and $message -like "*github.com*" 
        }
    }

    It 'Should show top 10 when more than 10 repos without mirrors exist' {
        # Arrange - Create 15 repos without mirrors
        $testForks = @()
        for ($i = 1; $i -le 15; $i++) {
            $testForks += @{ name = "owner${i}_repo${i}"; mirrorFound = $false }
        }

        # Act
        ShowOverallDatasetStatistics -existingForks $testForks

        # Assert - Should say "Top 10" not "Top 15"
        Should -Invoke Write-Message -Times 1 -ParameterFilter { 
            $message -like "<summary>Top 10 Repositories without Mirrors</summary>" 
        }
    }

    It 'Should not show collapsible section when all repos have mirrors' {
        # Arrange
        $testForks = @(
            @{ name = "repo1"; mirrorFound = $true; lastSynced = (Get-Date).AddDays(-2).ToString("yyyy-MM-ddTHH:mm:ssZ") }
            @{ name = "repo2"; mirrorFound = $true; lastSynced = (Get-Date).AddDays(-3).ToString("yyyy-MM-ddTHH:mm:ssZ") }
        )

        # Act
        ShowOverallDatasetStatistics -existingForks $testForks

        # Assert - Should not have the collapsible section
        Should -Invoke Write-Message -Times 0 -ParameterFilter { 
            $message -eq "<details>" 
        }
    }
}
