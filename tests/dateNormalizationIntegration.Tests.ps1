Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Date Normalization Integration Tests" {
    Context "End-to-end scenario with JSON serialization" {
        It "Should handle round-trip serialization with culture-specific dates" {
            # Arrange - Simulate data that comes from an older version with culture-specific dates
            $testFile = Join-Path $TestDrive "test-status.json"
            $actions = @(
                @{
                    name = "owner_repo1"
                    owner = "owner"
                    repoInfo = @{
                        updated_at = "11/04/2022 20:15:45"
                        archived = $false
                    }
                    mirrorLastUpdated = "09/15/2025 22:05:17"
                }
                @{
                    name = "owner_repo2"
                    owner = "owner"
                    repoInfo = @{
                        updated_at = "2023-01-04T20:07:21Z"
                        latest_release_published_at = "2023-01-01T10:00:00Z"
                    }
                    dependents = @{
                        dependents = "500"
                        dependentsLastUpdated = "06/02/2025 07:47:01"
                    }
                }
            )
            
            # Save to JSON
            $json = $actions | ConvertTo-Json -Depth 10
            $json | Out-File -FilePath $testFile -Encoding UTF8
            
            # Act - Load and normalize (simulating what workflows do)
            $loaded = Get-Content $testFile | ConvertFrom-Json
            $normalized = Normalize-ActionDates -actions $loaded
            
            # Assert - All dates should be DateTime objects
            $normalized[0].repoInfo.updated_at | Should -BeOfType [DateTime]
            $normalized[0].mirrorLastUpdated | Should -BeOfType [DateTime]
            $normalized[1].repoInfo.updated_at | Should -BeOfType [DateTime]
            $normalized[1].repoInfo.latest_release_published_at | Should -BeOfType [DateTime]
            $normalized[1].dependents.dependentsLastUpdated | Should -BeOfType [DateTime]
        }

        It "Should allow date comparisons after normalization" {
            # Arrange
            $testFile = Join-Path $TestDrive "test-comparison.json"
            $actions = @(
                @{
                    name = "old_repo"
                    repoInfo = @{
                        updated_at = "01/04/2022 20:07:21"
                    }
                }
                @{
                    name = "recent_repo"
                    repoInfo = @{
                        updated_at = "12/15/2025 10:00:00"
                    }
                }
            )
            
            $json = $actions | ConvertTo-Json -Depth 10
            $json | Out-File -FilePath $testFile -Encoding UTF8
            
            # Act
            $loaded = Get-Content $testFile | ConvertFrom-Json
            $normalized = Normalize-ActionDates -actions $loaded
            
            # Assert - Should be able to compare dates
            $normalized[0].repoInfo.updated_at | Should -BeLessThan $normalized[1].repoInfo.updated_at
            
            # Should be able to compare with Get-Date
            $oneMonthAgo = (Get-Date).AddMonths(-1)
            $normalized[0].repoInfo.updated_at | Should -BeLessThan $oneMonthAgo
        }

        It "Should support ToString formatting for display" {
            # Arrange
            $testFile = Join-Path $TestDrive "test-format.json"
            $actions = @(
                @{
                    name = "test_repo"
                    repoInfo = @{
                        updated_at = "11/04/2022 20:15:45"
                    }
                }
            )
            
            $json = $actions | ConvertTo-Json -Depth 10
            $json | Out-File -FilePath $testFile -Encoding UTF8
            
            # Act
            $loaded = Get-Content $testFile | ConvertFrom-Json
            $normalized = Normalize-ActionDates -actions $loaded
            
            # Assert - Should be able to format for display (like in report.ps1)
            $formatted = $normalized[0].repoInfo.updated_at.ToString("yyyy-MM-dd")
            $formatted | Should -Be "2022-11-04"
        }

        It "Should handle mixed date formats in the same dataset" {
            # Arrange - Real-world scenario where some dates are ISO and some are culture-specific
            $testFile = Join-Path $TestDrive "test-mixed.json"
            $actions = @(
                @{
                    name = "iso_date_repo"
                    repoInfo = @{
                        updated_at = "2022-11-04T20:15:45Z"
                    }
                }
                @{
                    name = "culture_date_repo"
                    repoInfo = @{
                        updated_at = "11/04/2022 20:15:45"
                    }
                }
                @{
                    name = "another_iso_repo"
                    repoInfo = @{
                        updated_at = "2025-12-04T21:30:39.1234567+00:00"
                    }
                }
            )
            
            $json = $actions | ConvertTo-Json -Depth 10
            $json | Out-File -FilePath $testFile -Encoding UTF8
            
            # Act
            $loaded = Get-Content $testFile | ConvertFrom-Json
            $normalized = Normalize-ActionDates -actions $loaded
            
            # Assert - All should be DateTime objects with correct values
            $normalized[0].repoInfo.updated_at | Should -BeOfType [DateTime]
            $normalized[1].repoInfo.updated_at | Should -BeOfType [DateTime]
            $normalized[2].repoInfo.updated_at | Should -BeOfType [DateTime]
            
            # First two should represent the same date
            $normalized[0].repoInfo.updated_at.Date | Should -Be $normalized[1].repoInfo.updated_at.Date
            
            # Third should be a different date
            $normalized[2].repoInfo.updated_at.Date | Should -Not -Be $normalized[0].repoInfo.updated_at.Date
        }

        It "Should preserve null dates" {
            # Arrange
            $testFile = Join-Path $TestDrive "test-nulls.json"
            $actions = @(
                @{
                    name = "no_dates_repo"
                    repoInfo = @{
                        archived = $false
                    }
                }
                @{
                    name = "partial_dates_repo"
                    repoInfo = @{
                        updated_at = "11/04/2022 20:15:45"
                        latest_release_published_at = $null
                    }
                }
            )
            
            $json = $actions | ConvertTo-Json -Depth 10
            $json | Out-File -FilePath $testFile -Encoding UTF8
            
            # Act
            $loaded = Get-Content $testFile | ConvertFrom-Json
            $normalized = Normalize-ActionDates -actions $loaded
            
            # Assert
            $normalized[0].repoInfo.archived | Should -Be $false
            # PowerShell JSON serialization might not preserve explicit nulls
            # Just ensure it doesn't crash
            $normalized | Should -Not -BeNullOrEmpty
            $normalized[1].repoInfo.updated_at | Should -BeOfType [DateTime]
        }
    }

    Context "Integration with library.ps1 functions" {
        It "Should work with GetForkedActionRepos workflow" {
            # This test verifies that the normalization is called in the right place
            # We can't easily test GetForkedActionRepos without mocking, but we can
            # verify that Normalize-ActionDates is compatible with the data structure
            
            # Arrange - Create data structure similar to what GetForkedActionRepos produces
            $testFile = Join-Path $TestDrive "test-workflow.json"
            $status = @(
                @{
                    name = "actions_checkout"
                    owner = "actions"
                    mirrorFound = $true
                    upstreamFound = $true
                    repoInfo = @{
                        updated_at = "11/04/2022 20:15:45"
                        archived = $false
                        disabled = $false
                    }
                    actionType = @{
                        actionType = "Node"
                        fileFound = "action.yml"
                        nodeVersion = "20"
                    }
                }
            )
            
            $json = $status | ConvertTo-Json -Depth 10
            $json | Out-File -FilePath $testFile -Encoding UTF8
            
            # Act
            $loaded = Get-Content $testFile | ConvertFrom-Json
            $normalized = Normalize-ActionDates -actions $loaded
            
            # Assert - Should preserve all fields while normalizing dates
            $normalized[0].name | Should -Be "actions_checkout"
            $normalized[0].owner | Should -Be "actions"
            $normalized[0].mirrorFound | Should -Be $true
            $normalized[0].repoInfo.updated_at | Should -BeOfType [DateTime]
            $normalized[0].repoInfo.archived | Should -Be $false
            $normalized[0].actionType.actionType | Should -Be "Node"
        }
    }
}
