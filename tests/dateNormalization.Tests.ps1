Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "ConvertTo-NormalizedDateTime" {
    Context "Handling DateTime objects" {
        It "Should return DateTime object as-is" {
            # Arrange
            $date = Get-Date "2022-11-04T20:15:45Z"
            
            # Act
            $result = ConvertTo-NormalizedDateTime -dateValue $date
            
            # Assert
            $result | Should -Be $date
            $result | Should -BeOfType [DateTime]
        }
    }

    Context "Handling ISO 8601 string formats" {
        It "Should parse ISO 8601 with Z suffix" {
            # Arrange
            $dateString = "2022-11-04T20:15:45Z"
            
            # Act
            $result = ConvertTo-NormalizedDateTime -dateValue $dateString
            
            # Assert
            $result | Should -BeOfType [DateTime]
            $result.Year | Should -Be 2022
            $result.Month | Should -Be 11
            $result.Day | Should -Be 4
            $result.Hour | Should -Be 20
            $result.Minute | Should -Be 15
            $result.Second | Should -Be 45
        }

        It "Should parse ISO 8601 with timezone offset" {
            # Arrange
            $dateString = "2025-12-29T20:02:15.6120475+00:00"
            
            # Act
            $result = ConvertTo-NormalizedDateTime -dateValue $dateString
            
            # Assert
            $result | Should -BeOfType [DateTime]
            $result.Year | Should -Be 2025
            $result.Month | Should -Be 12
            $result.Day | Should -Be 29
        }
    }

    Context "Handling culture-specific date string formats" {
        It "Should parse MM/DD/YYYY HH:MM:SS format" {
            # Arrange
            $dateString = "11/04/2022 20:15:45"
            
            # Act
            $result = ConvertTo-NormalizedDateTime -dateValue $dateString
            
            # Assert
            $result | Should -BeOfType [DateTime]
            $result.Year | Should -Be 2022
            $result.Month | Should -Be 11
            $result.Day | Should -Be 4
            $result.Hour | Should -Be 20
            $result.Minute | Should -Be 15
            $result.Second | Should -Be 45
        }

        It "Should parse M/D/YYYY HH:MM:SS format" {
            # Arrange
            $dateString = "1/5/2023 08:30:15"
            
            # Act
            $result = ConvertTo-NormalizedDateTime -dateValue $dateString
            
            # Assert
            $result | Should -BeOfType [DateTime]
            $result.Year | Should -Be 2023
            $result.Month | Should -Be 1
            $result.Day | Should -Be 5
        }
    }

    Context "Handling null and empty values" {
        It "Should return null for null input" {
            # Act
            $result = ConvertTo-NormalizedDateTime -dateValue $null
            
            # Assert
            $result | Should -BeNullOrEmpty
        }

        It "Should return null for empty string" {
            # Act
            $result = ConvertTo-NormalizedDateTime -dateValue ""
            
            # Assert
            $result | Should -BeNullOrEmpty
        }
    }

    Context "Handling invalid date strings" {
        It "Should return null and log warning for invalid date string" {
            # Arrange
            $dateString = "not a date"
            
            # Act
            $result = ConvertTo-NormalizedDateTime -dateValue $dateString
            
            # Assert
            $result | Should -BeNullOrEmpty
        }
    }
}

Describe "Normalize-ActionDates" {
    Context "Normalizing repoInfo dates" {
        It "Should normalize repoInfo.updated_at from ISO string" {
            # Arrange
            $actions = @(
                @{
                    name = "test_action"
                    repoInfo = @{
                        updated_at = "2022-11-04T20:15:45Z"
                        archived = $false
                    }
                }
            )
            
            # Act
            $result = Normalize-ActionDates -actions $actions
            
            # Assert
            $result[0].repoInfo.updated_at | Should -BeOfType [DateTime]
            $result[0].repoInfo.updated_at.Year | Should -Be 2022
        }

        It "Should normalize repoInfo.updated_at from culture-specific string" {
            # Arrange
            $actions = @(
                @{
                    name = "test_action"
                    repoInfo = @{
                        updated_at = "11/04/2022 20:15:45"
                        archived = $false
                    }
                }
            )
            
            # Act
            $result = Normalize-ActionDates -actions $actions
            
            # Assert
            $result[0].repoInfo.updated_at | Should -BeOfType [DateTime]
            $result[0].repoInfo.updated_at.Year | Should -Be 2022
            $result[0].repoInfo.updated_at.Month | Should -Be 11
        }

        It "Should normalize repoInfo.latest_release_published_at" {
            # Arrange
            $actions = @(
                @{
                    name = "test_action"
                    repoInfo = @{
                        updated_at = "2022-11-04T20:15:45Z"
                        latest_release_published_at = "10/15/2022 14:30:00"
                    }
                }
            )
            
            # Act
            $result = Normalize-ActionDates -actions $actions
            
            # Assert
            $result[0].repoInfo.latest_release_published_at | Should -BeOfType [DateTime]
            $result[0].repoInfo.latest_release_published_at.Year | Should -Be 2022
            $result[0].repoInfo.latest_release_published_at.Month | Should -Be 10
        }

        It "Should handle actions without repoInfo" {
            # Arrange
            $actions = @(
                @{
                    name = "test_action"
                    owner = "test_owner"
                }
            )
            
            # Act
            $result = Normalize-ActionDates -actions $actions
            
            # Assert
            $result[0].name | Should -Be "test_action"
        }

        It "Should handle repoInfo without dates" {
            # Arrange
            $actions = @(
                @{
                    name = "test_action"
                    repoInfo = @{
                        archived = $false
                    }
                }
            )
            
            # Act
            $result = Normalize-ActionDates -actions $actions
            
            # Assert
            $result[0].repoInfo.archived | Should -Be $false
        }
    }

    Context "Normalizing other date fields" {
        It "Should normalize mirrorLastUpdated" {
            # Arrange
            $actions = @(
                @{
                    name = "test_action"
                    mirrorLastUpdated = "09/15/2025 22:05:17"
                }
            )
            
            # Act
            $result = Normalize-ActionDates -actions $actions
            
            # Assert
            $result[0].mirrorLastUpdated | Should -BeOfType [DateTime]
            $result[0].mirrorLastUpdated.Year | Should -Be 2025
            $result[0].mirrorLastUpdated.Month | Should -Be 9
        }

        It "Should normalize dependents.dependentsLastUpdated" {
            # Arrange
            $actions = @(
                @{
                    name = "test_action"
                    dependents = @{
                        dependents = "1000"
                        dependentsLastUpdated = "06/02/2025 07:47:01"
                    }
                }
            )
            
            # Act
            $result = Normalize-ActionDates -actions $actions
            
            # Assert
            $result[0].dependents.dependentsLastUpdated | Should -BeOfType [DateTime]
            $result[0].dependents.dependentsLastUpdated.Year | Should -Be 2025
            $result[0].dependents.dependentsLastUpdated.Month | Should -Be 6
        }
    }

    Context "Handling multiple actions" {
        It "Should normalize dates in all actions" {
            # Arrange
            $actions = @(
                @{
                    name = "action1"
                    repoInfo = @{ updated_at = "11/04/2022 20:15:45" }
                }
                @{
                    name = "action2"
                    repoInfo = @{ updated_at = "2023-01-04T20:07:21Z" }
                }
                @{
                    name = "action3"
                    mirrorLastUpdated = "12/04/2025 21:30:39"
                }
            )
            
            # Act
            $result = Normalize-ActionDates -actions $actions
            
            # Assert
            $result[0].repoInfo.updated_at | Should -BeOfType [DateTime]
            $result[1].repoInfo.updated_at | Should -BeOfType [DateTime]
            $result[2].mirrorLastUpdated | Should -BeOfType [DateTime]
        }
    }

    Context "Handling null input" {
        It "Should return null for null input" {
            # Act
            $result = Normalize-ActionDates -actions $null
            
            # Assert
            $result | Should -BeNullOrEmpty
        }
    }

    Context "Date comparison after normalization" {
        It "Should allow date comparisons after normalization" {
            # Arrange
            $actions = @(
                @{
                    name = "old_action"
                    repoInfo = @{ updated_at = "01/04/2022 20:07:21" }
                }
                @{
                    name = "new_action"
                    repoInfo = @{ updated_at = "12/04/2025 21:30:39" }
                }
            )
            
            # Act
            $result = Normalize-ActionDates -actions $actions
            
            # Assert - older date should be less than newer date
            $result[0].repoInfo.updated_at | Should -BeLessThan $result[1].repoInfo.updated_at
            
            # Assert - should be able to compare with Get-Date
            $result[0].repoInfo.updated_at | Should -BeLessThan (Get-Date)
            $result[1].repoInfo.updated_at | Should -BeLessThan (Get-Date).AddYears(1)
        }

        It "Should support ToString formatting after normalization" {
            # Arrange
            $actions = @(
                @{
                    name = "test_action"
                    repoInfo = @{ updated_at = "11/04/2022 20:15:45" }
                }
            )
            
            # Act
            $result = Normalize-ActionDates -actions $actions
            
            # Assert - should be able to call ToString
            $formatted = $result[0].repoInfo.updated_at.ToString("yyyy-MM-dd")
            $formatted | Should -Be "2022-11-04"
        }
    }
}
