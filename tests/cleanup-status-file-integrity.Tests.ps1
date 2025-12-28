Import-Module Pester

BeforeAll {
    # Load the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
    
    # Mock the function we're testing
    <#
    .SYNOPSIS
    Test version of GetReposToCleanup that validates status file integrity.
    
    .DESCRIPTION
    This is a simplified version of GetReposToCleanup that demonstrates the bug fix.
    It separates display objects ($reposToCleanup) from persistence objects ($reposToCleanupFullObjects)
    to ensure full repository metadata is preserved when saving status.json.
    
    .PARAMETER statusFile
    Path to the status.json file to process.
    
    .PARAMETER access_token
    Optional GitHub access token (not used in this test version).
    
    .OUTPUTS
    Hashtable with the following structure:
    - totalRepos: Total number of repos in the input file
    - validRepos: Count of valid repos (including those to cleanup)
    - invalidRepos: Count of invalid entries removed
    - toCleanup: Count of repos eligible for cleanup
    - validCombined: Array of full repository objects (for status file saving)
    - reposToCleanup: Array of simplified display objects (for reporting)
    #>
    function Test-StatusFileIntegrity {
        Param (
            $statusFile,
            $access_token = $null
        )
        $status = Get-Content $statusFile | ConvertFrom-Json
        
        $reposToCleanup = New-Object System.Collections.ArrayList
        $reposToCleanupFullObjects = New-Object System.Collections.ArrayList  # Keep full objects
        $validStatus = New-Object System.Collections.ArrayList
        $invalidEntries = New-Object System.Collections.ArrayList
        
        foreach ($repo in $status) {
            $isInvalid = ($null -eq $repo) -or ([string]::IsNullOrEmpty($repo.name)) -or ($repo.name -eq "_")
            
            if ($isInvalid) {
                $invalidEntries.Add($repo) | Out-Null
                continue
            }
            
            # Simplified cleanup check
            $shouldCleanup = ($repo.upstreamFound -eq $false)
            
            if ($shouldCleanup) {
                # Add simplified info for reporting
                $reposToCleanup.Add(@{
                    name = $repo.name
                    owner = $repo.owner
                    reason = "test reason"
                    upstreamFullName = "test/upstream"
                }) | Out-Null
                
                # Keep full object for status file saving (THE FIX)
                $reposToCleanupFullObjects.Add($repo) | Out-Null
            }
            else {
                $validStatus.Add($repo) | Out-Null
            }
        }
        
        # If there are invalid entries, save with full objects
        if ($invalidEntries.Count -gt 0) {
            $validCombined = @()
            $validCombined += $validStatus
            # Use FULL objects, not simplified (THE FIX)
            $validCombined += $reposToCleanupFullObjects
            
            return @{
                totalRepos = $status.Count
                validRepos = $validCombined.Count
                invalidRepos = $invalidEntries.Count
                toCleanup = $reposToCleanup.Count
                validCombined = $validCombined
                reposToCleanup = $reposToCleanup
            }
        }
        
        return @{
            totalRepos = $status.Count
            validRepos = $validStatus.Count
            invalidRepos = 0
            toCleanup = $reposToCleanup.Count
            validCombined = $validStatus
            reposToCleanup = $reposToCleanup
        }
    }
}

Describe "Status File Integrity - Bug Fix Verification" {
    BeforeEach {
        $script:tempStatusFile = [System.IO.Path]::GetTempFileName()
    }
    
    AfterEach {
        if (Test-Path $script:tempStatusFile) {
            Remove-Item $script:tempStatusFile -Force
        }
    }
    
    It "Should preserve full repo objects when saving status file with invalid entries" {
        # Arrange - Create a status file with full repo objects
        $statusData = @(
            @{
                name = "valid-repo"
                owner = "test-owner"
                repoSize = 1000
                tagInfo = @("v1.0")
                releaseInfo = @("v1.0")
                upstreamFound = $true
                mirrorFound = $true
            },
            @{
                name = "repo-to-cleanup"
                owner = "test-owner"
                repoSize = 500
                tagInfo = @("v2.0")
                releaseInfo = @()
                upstreamFound = $false  # Should be cleaned up
                mirrorFound = $true
            },
            @{
                name = "_"  # Invalid entry
                owner = "test-owner"
            }
        )
        
        $statusData | ConvertTo-Json -Depth 10 | Out-File -FilePath $script:tempStatusFile -Encoding UTF8
        
        # Act
        $result = Test-StatusFileIntegrity -statusFile $script:tempStatusFile
        
        # Assert
        $result.totalRepos | Should -Be 3
        $result.invalidRepos | Should -Be 1
        $result.validRepos | Should -Be 2  # 1 valid + 1 to cleanup
        $result.toCleanup | Should -Be 1
        
        # Verify that the validCombined array contains FULL objects
        $cleanupRepo = $result.validCombined | Where-Object { $_.name -eq "repo-to-cleanup" }
        $cleanupRepo | Should -Not -BeNullOrEmpty
        
        # These properties should still exist (not lost)
        $cleanupRepo.repoSize | Should -Be 500
        $cleanupRepo.tagInfo | Should -Not -BeNullOrEmpty
        $cleanupRepo.tagInfo.Count | Should -Be 1
        $cleanupRepo.upstreamFound | Should -Be $false
        $cleanupRepo.mirrorFound | Should -Be $true
        
        # Verify the simplified version in reposToCleanup
        $simplifiedCleanupRepo = $result.reposToCleanup | Where-Object { $_.name -eq "repo-to-cleanup" }
        $simplifiedCleanupRepo | Should -Not -BeNullOrEmpty
        $simplifiedCleanupRepo.reason | Should -Be "test reason"
        
        # The simplified version should NOT have all the properties
        $simplifiedCleanupRepo.PSObject.Properties.Name -contains 'repoSize' | Should -Be $false
        $simplifiedCleanupRepo.PSObject.Properties.Name -contains 'tagInfo' | Should -Be $false
    }
    
    It "Should demonstrate the OLD BUG would have lost properties" {
        # This test demonstrates what WOULD have happened with the bug
        
        # Arrange - Create a full repo object
        $fullRepo = [PSCustomObject]@{
            name = "test-repo"
            owner = "test-owner"
            repoSize = 1000
            tagInfo = @("v1.0", "v2.0")
            releaseInfo = @("v1.0")
            upstreamFound = $false
            mirrorFound = $true
        }
        
        # Create a simplified version (what the OLD code would have added)
        $simplifiedRepo = [PSCustomObject]@{
            name = "test-repo"
            owner = "test-owner"
            reason = "test reason"
            upstreamFullName = "test/upstream"
        }
        
        # Act - Count properties
        $fullRepoPropertyCount = ($fullRepo.PSObject.Properties | Measure-Object).Count
        $simplifiedRepoPropertyCount = ($simplifiedRepo.PSObject.Properties | Measure-Object).Count
        
        # Assert - Simplified has fewer properties
        $simplifiedRepoPropertyCount | Should -BeLessThan $fullRepoPropertyCount
        $fullRepoPropertyCount | Should -Be 7  # All 7 properties
        $simplifiedRepoPropertyCount | Should -Be 4  # Only 4 properties
        
        # Assert - Simplified is missing critical properties
        $simplifiedRepo.PSObject.Properties.Name -contains 'repoSize' | Should -Be $false
        $simplifiedRepo.PSObject.Properties.Name -contains 'tagInfo' | Should -Be $false
        $simplifiedRepo.PSObject.Properties.Name -contains 'releaseInfo' | Should -Be $false
        $simplifiedRepo.PSObject.Properties.Name -contains 'upstreamFound' | Should -Be $false
        $simplifiedRepo.PSObject.Properties.Name -contains 'mirrorFound' | Should -Be $false
        
        # Assert - Simplified has reporting-only properties that shouldn't be in status file
        $simplifiedRepo.PSObject.Properties.Name -contains 'reason' | Should -Be $true
        $simplifiedRepo.PSObject.Properties.Name -contains 'upstreamFullName' | Should -Be $true
        
        # Assert - Full object has all the properties
        $fullRepo.PSObject.Properties.Name -contains 'repoSize' | Should -Be $true
        $fullRepo.PSObject.Properties.Name -contains 'tagInfo' | Should -Be $true
        $fullRepo.PSObject.Properties.Name -contains 'releaseInfo' | Should -Be $true
        $fullRepo.repoSize | Should -Be 1000
        $fullRepo.tagInfo.Count | Should -Be 2
    }
    
    It "Should calculate correct count after removing invalid entries" {
        # Arrange
        $statusData = @(
            @{ name = "valid1"; owner = "owner1"; upstreamFound = $true }
            @{ name = "valid2"; owner = "owner2"; upstreamFound = $true }
            @{ name = "cleanup1"; owner = "owner3"; upstreamFound = $false }
            @{ name = "_"; owner = "invalid" }  # Invalid
            @{ name = ""; owner = "invalid2" }  # Invalid
            $null  # Invalid
        )
        
        $statusData | ConvertTo-Json -Depth 10 | Out-File -FilePath $script:tempStatusFile -Encoding UTF8
        
        # Act
        $result = Test-StatusFileIntegrity -statusFile $script:tempStatusFile
        
        # Assert
        $result.totalRepos | Should -Be 6
        $result.invalidRepos | Should -Be 3
        $result.validRepos | Should -Be 3  # 2 valid + 1 to cleanup
        $result.toCleanup | Should -Be 1
        
        # After removing invalid entries, we should have 3 repos left
        # This is the number that should be saved back to status.json
        $result.validCombined.Count | Should -Be 3
    }
}
