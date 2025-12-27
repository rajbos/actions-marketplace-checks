Import-Module Pester

BeforeAll {
    # Define the function to test
    function RemoveReposFromStatus {
        Param (
            $repos,
            $statusFile
        )
        
        Write-Host "Removing [$($repos.Count)] repos from status file"
        
        if (-not (Test-Path $statusFile)) {
            Write-Error "Status file not found at [$statusFile]"
            return 0
        }
        
        $status = Get-Content $statusFile | ConvertFrom-Json
        $repoNamesToRemove = $repos | ForEach-Object { $_.name }
        
        # Filter out the repos to cleanup
        $updatedStatus = $status | Where-Object { $repoNamesToRemove -notcontains $_.name }
        
        $removedCount = $status.Count - $updatedStatus.Count
        Write-Host "Status file updated: [$($status.Count)] repos -> [$($updatedStatus.Count)] repos (removed $removedCount actions)"
        
        # Save the updated status
        $updatedStatus | ConvertTo-Json -Depth 10 | Out-File -FilePath $statusFile -Encoding UTF8
        Write-Host "Status file saved to [$statusFile]"
        
        return $removedCount
    }
}

Describe "RemoveReposFromStatus" {
    BeforeEach {
        # Create a temporary status file for testing
        $script:tempStatusFile = Join-Path $TestDrive "test-status.json"
    }
    
    It "Should return the count of repos removed from status file" {
        # Arrange
        $initialStatus = @(
            @{ name = "repo1"; owner = "test" },
            @{ name = "repo2"; owner = "test" },
            @{ name = "repo3"; owner = "test" },
            @{ name = "repo4"; owner = "test" },
            @{ name = "repo5"; owner = "test" }
        )
        $initialStatus | ConvertTo-Json -Depth 10 | Out-File -FilePath $tempStatusFile -Encoding UTF8
        
        $reposToRemove = @(
            @{ name = "repo2" },
            @{ name = "repo4" }
        )
        
        # Act
        $removedCount = RemoveReposFromStatus -repos $reposToRemove -statusFile $tempStatusFile
        
        # Assert
        $removedCount | Should -Be 2
        
        # Verify the status file was updated correctly
        $updatedStatus = Get-Content $tempStatusFile | ConvertFrom-Json
        $updatedStatus.Count | Should -Be 3
        $updatedStatus.name | Should -Contain "repo1"
        $updatedStatus.name | Should -Contain "repo3"
        $updatedStatus.name | Should -Contain "repo5"
        $updatedStatus.name | Should -Not -Contain "repo2"
        $updatedStatus.name | Should -Not -Contain "repo4"
    }
    
    It "Should return 0 when status file does not exist" {
        # Arrange
        $nonExistentFile = Join-Path $TestDrive "non-existent.json"
        $reposToRemove = @(
            @{ name = "repo1" }
        )
        
        # Act - suppress error output
        $removedCount = RemoveReposFromStatus -repos $reposToRemove -statusFile $nonExistentFile -ErrorAction SilentlyContinue
        
        # Assert
        $removedCount | Should -Be 0
    }
    
    It "Should return 0 when no repos match the removal list" {
        # Arrange
        $initialStatus = @(
            @{ name = "repo1"; owner = "test" },
            @{ name = "repo2"; owner = "test" }
        )
        $initialStatus | ConvertTo-Json -Depth 10 | Out-File -FilePath $tempStatusFile -Encoding UTF8
        
        $reposToRemove = @(
            @{ name = "repo3" },
            @{ name = "repo4" }
        )
        
        # Act
        $removedCount = RemoveReposFromStatus -repos $reposToRemove -statusFile $tempStatusFile
        
        # Assert
        $removedCount | Should -Be 0
        
        # Verify the status file was not changed
        $updatedStatus = Get-Content $tempStatusFile | ConvertFrom-Json
        $updatedStatus.Count | Should -Be 2
    }
    
    It "Should handle removing all repos from status file" {
        # Arrange
        $initialStatus = @(
            @{ name = "repo1"; owner = "test" },
            @{ name = "repo2"; owner = "test" }
        )
        $initialStatus | ConvertTo-Json -Depth 10 | Out-File -FilePath $tempStatusFile -Encoding UTF8
        
        $reposToRemove = @(
            @{ name = "repo1" },
            @{ name = "repo2" }
        )
        
        # Act
        $removedCount = RemoveReposFromStatus -repos $reposToRemove -statusFile $tempStatusFile
        
        # Assert
        $removedCount | Should -Be 2
        
        # Verify the status file is empty
        $updatedStatus = Get-Content $tempStatusFile | ConvertFrom-Json
        $updatedStatus.Count | Should -Be 0
    }
    
    It "Should correctly count when more repos are requested to remove than actually exist" {
        # Arrange
        $initialStatus = @(
            @{ name = "repo1"; owner = "test" },
            @{ name = "repo2"; owner = "test" }
        )
        $initialStatus | ConvertTo-Json -Depth 10 | Out-File -FilePath $tempStatusFile -Encoding UTF8
        
        $reposToRemove = @(
            @{ name = "repo1" },
            @{ name = "repo2" },
            @{ name = "repo3" },  # Doesn't exist
            @{ name = "repo4" }   # Doesn't exist
        )
        
        # Act
        $removedCount = RemoveReposFromStatus -repos $reposToRemove -statusFile $tempStatusFile
        
        # Assert
        $removedCount | Should -Be 2  # Only 2 actually removed
        
        # Verify the status file is empty
        $updatedStatus = Get-Content $tempStatusFile | ConvertFrom-Json
        $updatedStatus.Count | Should -Be 0
    }
}
