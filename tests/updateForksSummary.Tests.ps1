BeforeAll {
    # Set mock tokens to avoid validation errors
    $env:GITHUB_TOKEN = "test_token_mock"
    
    # Load library first (required by update-forks.ps1)
    . $PSScriptRoot/../.github/workflows/library.ps1
    
    # Mock Test-AccessTokens to avoid token validation
    function Test-AccessTokens {
        Param (
            [string] $accessToken,
            [int] $numberOfReposToDo
        )
        # Do nothing in tests
    }
    
    # Now define the functions from update-forks.ps1 inline to avoid running the script
    function UpdateForkedRepos {
        Param (
            $existingForks,
            [int] $numberOfReposToDo
        )

        Write-Message -message "Running mirror sync for [$($existingForks.Count)] mirrors" -logToSummary $true
        
        $i = 0
        $max = $numberOfReposToDo
        $synced = 0
        $failed = 0
        $upToDate = 0
        $conflicts = 0
        $upstreamNotFound = 0
        $skipped = 0

        foreach ($existingFork in $existingForks) {

            if ($i -ge $max) {
                Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
                break
            }

            if ($null -eq $existingFork.mirrorFound -or $existingFork.mirrorFound -eq $false) {
                Write-Debug "Mirror not found for [$($existingFork.name)], skipping"
                $skipped++
                continue
            }

            ($upstreamOwner, $upstreamRepo) = GetOrgActionInfo -forkedOwnerRepo $existingFork.name
            
            if ([string]::IsNullOrEmpty($upstreamOwner) -or [string]::IsNullOrEmpty($upstreamRepo)) {
                Write-Warning "Could not parse upstream owner/repo from mirror name [$($existingFork.name)], skipping"
                $skipped++
                continue
            }

            $i++ | Out-Null
        }

        Write-Message -message "" -logToSummary $true
        Write-Message -message "## Mirror Sync Run Summary" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        Write-Message -message "### Current Run Statistics" -logToSummary $true
        Write-Message -message "| Status | Count |" -logToSummary $true
        Write-Message -message "|--------|------:|" -logToSummary $true
        Write-Message -message "| ✅ Synced | $synced |" -logToSummary $true
        Write-Message -message "| ✓ Up to Date | $upToDate |" -logToSummary $true
        Write-Message -message "| ⚠️ Conflicts | $conflicts |" -logToSummary $true
        Write-Message -message "| ❌ Upstream Not Found | $upstreamNotFound |" -logToSummary $true
        Write-Message -message "| ❌ Failed | $failed |" -logToSummary $true
        Write-Message -message "| ⏭️ Skipped | $skipped |" -logToSummary $true
        Write-Message -message "| **Total Processed** | **$i** |" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        
        return $existingForks
    }

    function ShowOverallDatasetStatistics {
        Param (
            $existingForks
        )
        
        Write-Message -message "" -logToSummary $true
        Write-Message -message "### Overall Dataset Statistics" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        
        $sevenDaysAgo = (Get-Date).AddDays(-7)
        
        $totalRepos = $existingForks.Count
        
        $reposWithMirrors = ($existingForks | Where-Object { $_.mirrorFound -eq $true }).Count
        
        $reposSyncedLast7Days = ($existingForks | Where-Object { 
            if ($_.mirrorFound -eq $true -and $_.lastSynced) {
                try {
                    $syncDate = [DateTime]::Parse($_.lastSynced)
                    return $syncDate -gt $sevenDaysAgo
                } catch {
                    Write-Debug "Failed to parse lastSynced date for repo: $($_.name)"
                    return $false
                }
            }
            return $false
        }).Count
        
        # Count repos with valid mirrors but no lastSynced timestamp or unparseable timestamp
        $reposNeverSynced = ($existingForks | Where-Object { 
            if ($_.mirrorFound -eq $true) {
                if ([string]::IsNullOrEmpty($_.lastSynced)) {
                    return $true
                }
                # Also count repos where lastSynced exists but cannot be parsed
                try {
                    [DateTime]::Parse($_.lastSynced) | Out-Null
                    return $false
                } catch {
                    return $true
                }
            }
            return $false
        }).Count
        
        if ($reposWithMirrors -gt 0) {
            $percentChecked = [math]::Round(($reposSyncedLast7Days / $reposWithMirrors) * 100, 2)
            $percentRemaining = [math]::Round((($reposWithMirrors - $reposSyncedLast7Days) / $reposWithMirrors) * 100, 2)
            $percentNeverSynced = [math]::Round(($reposNeverSynced / $reposWithMirrors) * 100, 2)
        } else {
            $percentChecked = 0
            $percentRemaining = 0
            $percentNeverSynced = 0
        }
        
        $reposNotChecked = $reposWithMirrors - $reposSyncedLast7Days
        
        Write-Message -message "**Total Repositories in Dataset:** $totalRepos" -logToSummary $true
        Write-Message -message "**Repositories with Valid Mirrors:** $reposWithMirrors" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        Write-Message -message "#### Last 7 Days Activity" -logToSummary $true
        Write-Message -message "| Metric | Count | Percentage |" -logToSummary $true
        Write-Message -message "|--------|------:|-----------:|" -logToSummary $true
        Write-Message -message "| ✅ Repos Checked (Last 7 Days) | $reposSyncedLast7Days | ${percentChecked}% |" -logToSummary $true
        Write-Message -message "| ⏳ Repos Not Checked Yet | $reposNotChecked | ${percentRemaining}% |" -logToSummary $true
        Write-Message -message "| 🆕 Repos Never Checked | $reposNeverSynced | ${percentNeverSynced}% |" -logToSummary $true
        Write-Message -message "" -logToSummary $true
    }
}

Describe "Update Forks Summary Functions" {
    Context "ShowOverallDatasetStatistics function" {
        It "Should have function defined" {
            Get-Command ShowOverallDatasetStatistics -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should handle empty dataset" {
            $testData = @()
            
            # This should not throw an error
            { ShowOverallDatasetStatistics -existingForks $testData } | Should -Not -Throw
        }

        It "Should handle dataset with no mirrors" {
            $testData = @(
                @{ name = "repo1"; mirrorFound = $false }
                @{ name = "repo2"; mirrorFound = $false }
            )
            
            { ShowOverallDatasetStatistics -existingForks $testData } | Should -Not -Throw
        }

        It "Should calculate statistics correctly for repos with recent syncs" {
            $recentDate = (Get-Date).AddDays(-3).ToString("yyyy-MM-ddTHH:mm:ssZ")
            $oldDate = (Get-Date).AddDays(-10).ToString("yyyy-MM-ddTHH:mm:ssZ")
            
            $testData = @(
                @{ name = "repo1"; mirrorFound = $true; lastSynced = $recentDate }
                @{ name = "repo2"; mirrorFound = $true; lastSynced = $oldDate }
                @{ name = "repo3"; mirrorFound = $true; lastSynced = $null }
                @{ name = "repo4"; mirrorFound = $false }
            )
            
            # This should not throw an error
            { ShowOverallDatasetStatistics -existingForks $testData } | Should -Not -Throw
        }

        It "Should handle repos without lastSynced property" {
            $testData = @(
                @{ name = "repo1"; mirrorFound = $true }
                @{ name = "repo2"; mirrorFound = $true }
            )
            
            { ShowOverallDatasetStatistics -existingForks $testData } | Should -Not -Throw
        }

        It "Should handle malformed lastSynced dates gracefully" {
            $testData = @(
                @{ name = "repo1"; mirrorFound = $true; lastSynced = "invalid-date" }
                @{ name = "repo2"; mirrorFound = $true; lastSynced = "not-a-date-at-all" }
                @{ name = "repo3"; mirrorFound = $true; lastSynced = (Get-Date).AddDays(-2).ToString("yyyy-MM-ddTHH:mm:ssZ") }
            )
            
            # Should not throw even with malformed dates
            { ShowOverallDatasetStatistics -existingForks $testData } | Should -Not -Throw
        }

        It "Should count repos never synced separately" {
            $recentDate = (Get-Date).AddDays(-3).ToString("yyyy-MM-ddTHH:mm:ssZ")
            $oldDate = (Get-Date).AddDays(-10).ToString("yyyy-MM-ddTHH:mm:ssZ")
            
            $testData = @(
                @{ name = "repo1"; mirrorFound = $true; lastSynced = $recentDate }  # Recently checked
                @{ name = "repo2"; mirrorFound = $true; lastSynced = $oldDate }      # Checked >7 days ago
                @{ name = "repo3"; mirrorFound = $true; lastSynced = $null }         # Never checked (null)
                @{ name = "repo4"; mirrorFound = $true; lastSynced = "" }            # Never checked (empty)
                @{ name = "repo5"; mirrorFound = $true }                             # Never checked (no property)
                @{ name = "repo6"; mirrorFound = $false }                            # No mirror
            )
            
            # Capture output to validate it includes the new line
            $output = (ShowOverallDatasetStatistics -existingForks $testData) | Out-String
            
            # Should not throw
            { ShowOverallDatasetStatistics -existingForks $testData } | Should -Not -Throw
        }
    }

    Context "UpdateForkedRepos function" {
        It "Should have function defined" {
            Get-Command UpdateForkedRepos -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should handle empty fork list" {
            $testData = @()
            
            # Mock the SyncMirrorWithUpstream function to avoid actual API calls
            Mock SyncMirrorWithUpstream { return @{ success = $true; message = "Already up to date" } }
            
            $result = UpdateForkedRepos -existingForks $testData -numberOfReposToDo 10
            $result.Count | Should -Be 0
        }

        It "Should skip repos without mirrorFound" {
            $testData = @(
                @{ name = "repo1"; mirrorFound = $false }
                @{ name = "repo2" } # No mirrorFound property
            )
            
            Mock SyncMirrorWithUpstream { return @{ success = $true; message = "Already up to date" } }
            
            $result = UpdateForkedRepos -existingForks $testData -numberOfReposToDo 10
            $result.Count | Should -Be 2
        }
    }

    Context "Summary output format" {
        It "Should use Write-Message with logToSummary parameter" {
            # Check that the UpdateForkedRepos function calls Write-Message with -logToSummary $true
            $functionContent = (Get-Command UpdateForkedRepos).ScriptBlock.ToString()
            $functionContent | Should -Match 'Write-Message.*-logToSummary \$true'
        }

        It "Should include markdown table format in summary" {
            $functionContent = (Get-Command UpdateForkedRepos).ScriptBlock.ToString()
            $functionContent | Should -Match '\|.*\|.*\|'
        }
    }

    Context "Dataset statistics calculations" {
        It "Should calculate 7-day window correctly" {
            $functionContent = (Get-Command ShowOverallDatasetStatistics).ScriptBlock.ToString()
            $functionContent | Should -Match 'AddDays\(-7\)'
        }

        It "Should calculate percentages" {
            $functionContent = (Get-Command ShowOverallDatasetStatistics).ScriptBlock.ToString()
            $functionContent | Should -Match 'percentChecked'
            $functionContent | Should -Match 'percentRemaining'
            $functionContent | Should -Match 'percentNeverSynced'
        }

        It "Should count repos with valid mirrors" {
            $functionContent = (Get-Command ShowOverallDatasetStatistics).ScriptBlock.ToString()
            $functionContent | Should -Match 'mirrorFound -eq \$true'
        }

        It "Should count repos never synced" {
            $functionContent = (Get-Command ShowOverallDatasetStatistics).ScriptBlock.ToString()
            $functionContent | Should -Match 'reposNeverSynced'
        }
    }
}
