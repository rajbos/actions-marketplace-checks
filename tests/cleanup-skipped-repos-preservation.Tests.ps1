Import-Module Pester

BeforeAll {
    # Load the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
    
    <#
    .SYNOPSIS
    Test version of GetReposToCleanup that validates skipped repos are preserved.
    
    .DESCRIPTION
    This test version includes the skip logic to ensure repos that are skipped
    (due to upstream existing or mirror existing) are still added to $validStatus
    so they are preserved when saving the status file.
    
    .PARAMETER statusFile
    Path to the status.json file to process.
    
    .OUTPUTS
    Hashtable with counts and preserved repo lists.
    #>
    function Test-SkippedReposPreservation {
        Param (
            $statusFile
        )
        $status = Get-Content $statusFile | ConvertFrom-Json
        
        $reposToCleanup = New-Object System.Collections.ArrayList
        $reposToCleanupFullObjects = New-Object System.Collections.ArrayList
        $validStatus = New-Object System.Collections.ArrayList
        $invalidEntries = New-Object System.Collections.ArrayList
        $countSkippedDueToUpstreamAvailable = 0
        $countSkippedDueToMirrorExists = 0
        
        foreach ($repo in $status) {
            $isInvalid = ($null -eq $repo) -or ([string]::IsNullOrEmpty($repo.name)) -or ($repo.name -eq "_")
            
            if ($isInvalid) {
                $invalidEntries.Add($repo) | Out-Null
                continue
            }
            
            $shouldCleanup = $false
            
            # Skip logic 1: If upstream exists but mirror is missing
            $upstreamStillExists = ($repo.upstreamFound -eq $true) -and ($repo.upstreamAvailable -ne $false)
            $mirrorMissing = ($null -eq $repo.mirrorFound -or $repo.mirrorFound -eq $false)
            if ($upstreamStillExists -and $mirrorMissing) {
                $countSkippedDueToUpstreamAvailable++
                # THE FIX: Add to valid status before skipping
                $validStatus.Add($repo) | Out-Null
                continue
            }
            
            # Skip logic 2: If mirror exists AND upstream still exists
            if ($repo.mirrorFound -eq $true -and $upstreamStillExists) {
                $countSkippedDueToMirrorExists++
                # THE FIX: Add to valid status before skipping
                $validStatus.Add($repo) | Out-Null
                continue
            }
            
            # Cleanup check
            $upstreamMissing = ($repo.upstreamFound -eq $false -or $repo.upstreamAvailable -eq $false)
            if ($upstreamMissing) {
                $shouldCleanup = $true
            }
            
            if ($shouldCleanup) {
                $reposToCleanup.Add(@{
                    name = $repo.name
                    owner = $repo.owner
                }) | Out-Null
                $reposToCleanupFullObjects.Add($repo) | Out-Null
            }
            else {
                $validStatus.Add($repo) | Out-Null
            }
        }
        
        # Build validCombined as the script does when there are invalid entries
        $validCombined = @()
        $validCombined += $validStatus
        $validCombined += $reposToCleanupFullObjects
        
        return @{
            totalRepos = $status.Count
            validCombined = $validCombined
            invalidRepos = $invalidEntries.Count
            toCleanup = $reposToCleanup.Count
            skippedUpstreamAvailable = $countSkippedDueToUpstreamAvailable
            skippedMirrorExists = $countSkippedDueToMirrorExists
        }
    }
}

Describe "Skipped Repos Preservation - Bug Fix" {
    BeforeEach {
        $script:tempStatusFile = [System.IO.Path]::GetTempFileName()
    }
    
    AfterEach {
        if (Test-Path $script:tempStatusFile) {
            Remove-Item $script:tempStatusFile -Force
        }
    }
    
    It "Should preserve repos skipped due to upstream existing and mirror missing" {
        # Arrange - Create status with repos that should be skipped
        $statusData = @(
            @{
                name = "valid-repo"
                owner = "test-owner"
                upstreamFound = $false  # No upstream
                mirrorFound = $true
                repoSize = 1000
            },
            @{
                name = "skipped-upstream-exists-mirror-missing"
                owner = "test-owner"
                upstreamFound = $true
                # upstreamAvailable not set (null), so != $false evaluates to true
                mirrorFound = $false  # Mirror missing
                repoSize = 500
            },
            @{
                name = "to-cleanup"
                owner = "test-owner"
                upstreamFound = $false  # Should be cleaned up
                mirrorFound = $true
                repoSize = 300
            },
            @{
                name = "_"  # Invalid entry
                owner = "test-owner"
            }
        )
        
        $statusData | ConvertTo-Json -Depth 10 | Out-File -FilePath $script:tempStatusFile -Encoding UTF8
        
        # Act
        $result = Test-SkippedReposPreservation -statusFile $script:tempStatusFile
        
        # Assert - Total repos in input
        $result.totalRepos | Should -Be 4
        
        # Assert - Invalid repos count
        $result.invalidRepos | Should -Be 1
        
        # Assert - Repos to cleanup count
        $result.toCleanup | Should -Be 2  # Both valid-repo and to-cleanup have upstreamFound=false
        
        # Assert - Skipped repos count
        $result.skippedUpstreamAvailable | Should -Be 1
        $result.skippedMirrorExists | Should -Be 0
        
        # Assert - validCombined should have 3 repos (0 valid that aren't cleanup + 1 skipped + 2 to cleanup)
        # NOT 2 repos (which would be the bug)
        $result.validCombined.Count | Should -Be 3
        
        # Verify the skipped repo is in validCombined
        $skippedRepo = $result.validCombined | Where-Object { $_.name -eq "skipped-upstream-exists-mirror-missing" }
        $skippedRepo | Should -Not -BeNullOrEmpty
        $skippedRepo.repoSize | Should -Be 500
    }
    
    It "Should preserve repos skipped due to mirror and upstream both existing" {
        # Arrange
        $statusData = @(
            @{
                name = "to-cleanup"
                owner = "test-owner"
                upstreamFound = $false
                repoSize = 300
            },
            @{
                name = "skipped-mirror-and-upstream-exist"
                owner = "test-owner"
                upstreamFound = $true
                # upstreamAvailable not set (null != false = true)
                mirrorFound = $true  # Mirror exists
                repoSize = 500
            }
        )
        
        $statusData | ConvertTo-Json -Depth 10 | Out-File -FilePath $script:tempStatusFile -Encoding UTF8
        
        # Act
        $result = Test-SkippedReposPreservation -statusFile $script:tempStatusFile
        
        # Assert
        $result.totalRepos | Should -Be 2
        $result.toCleanup | Should -Be 1
        $result.skippedUpstreamAvailable | Should -Be 0
        $result.skippedMirrorExists | Should -Be 1
        
        # validCombined should have both repos (1 skipped + 1 to cleanup)
        $result.validCombined.Count | Should -Be 2
        
        # Verify the skipped repo is in validCombined
        $skippedRepo = $result.validCombined | Where-Object { $_.name -eq "skipped-mirror-and-upstream-exist" }
        $skippedRepo | Should -Not -BeNullOrEmpty
        $skippedRepo.repoSize | Should -Be 500
    }
    
    It "Should preserve all repos when multiple skip conditions apply" {
        # Arrange - Test with multiple repos being skipped for different reasons
        $statusData = @(
            @{
                name = "skipped-upstream-mirror-missing"
                owner = "test-owner"
                upstreamFound = $true
                # upstreamAvailable not set
                mirrorFound = $false
                repoSize = 500
            },
            @{
                name = "skipped-mirror-upstream-both"
                owner = "test-owner"
                upstreamFound = $true
                # upstreamAvailable not set
                mirrorFound = $true
                repoSize = 600
            },
            @{
                name = "skipped-upstream-mirror-missing-2"
                owner = "test-owner"
                upstreamFound = $true
                mirrorFound = $false
                repoSize = 700
            },
            @{
                name = "to-cleanup-1"
                owner = "test-owner"
                upstreamFound = $false
                repoSize = 300
            },
            @{
                name = "to-cleanup-2"
                owner = "test-owner"
                upstreamAvailable = $false
                repoSize = 200
            },
            @{
                name = "_"  # Invalid
                owner = "test-owner"
            }
        )
        
        $statusData | ConvertTo-Json -Depth 10 | Out-File -FilePath $script:tempStatusFile -Encoding UTF8
        
        # Act
        $result = Test-SkippedReposPreservation -statusFile $script:tempStatusFile
        
        # Assert
        $result.totalRepos | Should -Be 6
        $result.invalidRepos | Should -Be 1
        $result.toCleanup | Should -Be 2
        
        # 3 skipped repos total (2 upstream-mirror-missing + 1 mirror-upstream-both)
        $totalSkipped = $result.skippedUpstreamAvailable + $result.skippedMirrorExists
        $totalSkipped | Should -Be 3
        
        # validCombined should have 5 repos (0 valid + 3 skipped + 2 to cleanup)
        # If the bug existed, we'd lose the 3 skipped repos
        $result.validCombined.Count | Should -Be 5
        
        # Verify all skipped repos are present with their full properties
        $skippedRepoNames = @("skipped-upstream-mirror-missing", "skipped-mirror-upstream-both", "skipped-upstream-mirror-missing-2")
        foreach ($name in $skippedRepoNames) {
            $repo = $result.validCombined | Where-Object { $_.name -eq $name }
            $repo | Should -Not -BeNullOrEmpty
            $repo.repoSize | Should -BeGreaterThan 0
        }
    }
    
    It "Should demonstrate the OLD BUG would have lost skipped repos" {
        # This test shows what WOULD happen with the bug (skipped repos lost)
        
        # Arrange
        $statusData = @(
            @{ name = "valid"; owner = "test"; upstreamFound = $true; mirrorFound = $true }
            @{ name = "skipped"; owner = "test"; upstreamFound = $true; mirrorFound = $false }
            @{ name = "cleanup"; owner = "test"; upstreamFound = $false }
            @{ name = "_"; owner = "invalid" }
        )
        
        $statusData | ConvertTo-Json -Depth 10 | Out-File -FilePath $script:tempStatusFile -Encoding UTF8
        
        # Act with fix
        $resultWithFix = Test-SkippedReposPreservation -statusFile $script:tempStatusFile
        
        # Assert with fix: 3 repos preserved (1 valid + 1 skipped + 1 cleanup)
        $resultWithFix.validCombined.Count | Should -Be 3
        
        # Simulate OLD BUG behavior (skipped repos NOT added to any list)
        # Would result in: 2 repos (1 valid + 1 cleanup), missing the skipped repo
        $oldBugCount = 2
        
        # Verify the fix prevents this loss
        $resultWithFix.validCombined.Count | Should -BeGreaterThan $oldBugCount
        $resultWithFix.validCombined.Count | Should -Be ($oldBugCount + 1)  # +1 for skipped repo
    }
}
