Import-Module Pester

BeforeAll {
    # Import library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Select-ForksToProcess" {
    Context "Basic filtering" {
        It "Should only select forks with mirrorFound = true" {
            $forks = @(
                [PSCustomObject]@{ name = "fork1"; mirrorFound = $true; lastSynced = $null }
                [PSCustomObject]@{ name = "fork2"; mirrorFound = $false; lastSynced = $null }
                [PSCustomObject]@{ name = "fork3"; mirrorFound = $true; lastSynced = $null }
            )
            
            $result = Select-ForksToProcess -existingForks $forks -numberOfRepos 10
            
            $result.Count | Should -Be 2
            $result[0].name | Should -Be "fork1"
            $result[1].name | Should -Be "fork3"
        }
        
        It "Should skip forks with upstreamAvailable = false" {
            $forks = @(
                [PSCustomObject]@{ name = "fork1"; mirrorFound = $true; upstreamAvailable = $true; lastSynced = $null }
                [PSCustomObject]@{ name = "fork2"; mirrorFound = $true; upstreamAvailable = $false; lastSynced = $null }
                [PSCustomObject]@{ name = "fork3"; mirrorFound = $true; lastSynced = $null }
            )
            
            $result = Select-ForksToProcess -existingForks $forks -numberOfRepos 10
            
            $result.Count | Should -Be 2
            $result.name | Should -Not -Contain "fork2"
        }
    }
    
    Context "Prioritization by last sync time" {
        It "Should prioritize forks that have never been synced" {
            $forks = @(
                [PSCustomObject]@{ name = "fork1"; mirrorFound = $true; lastSynced = "2025-12-15T10:00:00Z" }
                [PSCustomObject]@{ name = "fork2"; mirrorFound = $true; lastSynced = $null }
                [PSCustomObject]@{ name = "fork3"; mirrorFound = $true; lastSynced = "2025-12-15T12:00:00Z" }
            )
            
            $result = Select-ForksToProcess -existingForks $forks -numberOfRepos 1
            
            $result.Count | Should -Be 1
            $result[0].name | Should -Be "fork2"
        }
        
        It "Should prioritize forks with older lastSynced dates when no recent failures" {
            $forks = @(
                [PSCustomObject]@{ name = "fork1"; mirrorFound = $true; lastSynced = "2025-12-15T12:00:00Z" }
                [PSCustomObject]@{ name = "fork2"; mirrorFound = $true; lastSynced = "2025-12-15T10:00:00Z" }
                [PSCustomObject]@{ name = "fork3"; mirrorFound = $true; lastSynced = "2025-12-15T11:00:00Z" }
            )
            
            $result = Select-ForksToProcess -existingForks $forks -numberOfRepos 10
            
            $result.Count | Should -Be 3
            $result[0].name | Should -Be "fork2"  # Oldest
            $result[1].name | Should -Be "fork3"
            $result[2].name | Should -Be "fork1"  # Newest
        }
        
        It "Should deprioritize forks with recent repeated failures" {
            $now = Get-Date
            # Fork1: Never synced successfully, failed recently (high penalty)
            # Fork2: Old successful sync, no failures (high priority due to age)
            # Fork3: Recent successful sync (lower priority due to recency)
            $forks = @(
                [PSCustomObject]@{ 
                    name = "fork1"
                    mirrorFound = $true
                    lastSynced = $null
                    lastSyncError = "Error"
                    lastSyncAttempt = $now.AddHours(-25).ToString("yyyy-MM-ddTHH:mm:ssZ")  # Past cool-off but recent
                }
                [PSCustomObject]@{ 
                    name = "fork2"
                    mirrorFound = $true
                    lastSynced = $now.AddDays(-5).ToString("yyyy-MM-ddTHH:mm:ssZ")  # 5 days old
                }
                [PSCustomObject]@{ 
                    name = "fork3"
                    mirrorFound = $true
                    lastSynced = $now.AddHours(-2).ToString("yyyy-MM-ddTHH:mm:ssZ")  # Recent
                }
            )
            
            $result = Select-ForksToProcess -existingForks $forks -numberOfRepos 10 -coolOffHoursForFailedSync 24
            
            $result.Count | Should -Be 3
            # Fork2 should be first (old sync, no failures)
            # Fork3 should be second (recent sync but no failures)
            # Fork1 should be last (recent failure penalty)
            $result[0].name | Should -Be "fork2"
            $result[2].name | Should -Be "fork1"
        }
        
        It "Should prioritize successfully synced repos over repeatedly failing ones" {
            $now = Get-Date
            # Create scenario where a repo keeps failing and monopolizing the queue
            $forks = @(
                [PSCustomObject]@{ 
                    name = "failingRepo"
                    mirrorFound = $true
                    lastSynced = $now.AddDays(-8).ToString("yyyy-MM-ddTHH:mm:ssZ")  # Very old last success
                    lastSyncError = "Error"
                    lastSyncAttempt = $now.AddHours(-30).ToString("yyyy-MM-ddTHH:mm:ssZ")  # Failed after cool-off
                }
                [PSCustomObject]@{ 
                    name = "successfulRepo"
                    mirrorFound = $true
                    lastSynced = $now.AddDays(-6).ToString("yyyy-MM-ddTHH:mm:ssZ")  # 6 days old, never failed
                }
            )
            
            $result = Select-ForksToProcess -existingForks $forks -numberOfRepos 1 -coolOffHoursForFailedSync 24
            
            $result.Count | Should -Be 1
            # Even though failingRepo has older lastSynced, the penalty for recent failure
            # should push successfulRepo ahead
            $result[0].name | Should -Be "successfulRepo"
        }
    }
    
    Context "Cool-off period for failed syncs" {
        It "Should skip forks with recent failed sync attempts" {
            $now = Get-Date
            $recentFailure = $now.AddHours(-12).ToString("yyyy-MM-ddTHH:mm:ssZ")
            $oldFailure = $now.AddHours(-36).ToString("yyyy-MM-ddTHH:mm:ssZ")
            
            $forks = @(
                [PSCustomObject]@{ name = "fork1"; mirrorFound = $true; lastSyncError = "Error"; lastSyncAttempt = $recentFailure; lastSynced = $null }
                [PSCustomObject]@{ name = "fork2"; mirrorFound = $true; lastSyncError = "Error"; lastSyncAttempt = $oldFailure; lastSynced = $null }
                [PSCustomObject]@{ name = "fork3"; mirrorFound = $true; lastSynced = $null }
            )
            
            $result = Select-ForksToProcess -existingForks $forks -numberOfRepos 10 -coolOffHoursForFailedSync 24
            
            $result.Count | Should -Be 2
            $result.name | Should -Not -Contain "fork1"  # Recent failure, still in cool-off
            $result.name | Should -Contain "fork2"  # Old failure, past cool-off
            $result.name | Should -Contain "fork3"  # Never failed
        }
        
        It "Should include forks with lastSyncError but no lastSyncAttempt" {
            $forks = @(
                [PSCustomObject]@{ name = "fork1"; mirrorFound = $true; lastSyncError = "Error"; lastSynced = $null }
                [PSCustomObject]@{ name = "fork2"; mirrorFound = $true; lastSynced = $null }
            )
            
            $result = Select-ForksToProcess -existingForks $forks -numberOfRepos 10
            
            $result.Count | Should -Be 2
            $result.name | Should -Contain "fork1"
        }
    }
    
    Context "Limit enforcement" {
        It "Should respect the numberOfRepos limit" {
            $forks = @()
            for ($i = 1; $i -le 100; $i++) {
                $forks += [PSCustomObject]@{ name = "fork$i"; mirrorFound = $true; lastSynced = $null }
            }
            
            $result = Select-ForksToProcess -existingForks $forks -numberOfRepos 50
            
            $result.Count | Should -Be 50
        }
    }
    
    Context "Filtering statistics" {
        It "Should report detailed filtering statistics for all filter types" {
            $now = Get-Date
            $forks = @(
                # 3 forks with mirrorFound = false
                [PSCustomObject]@{ name = "noMirror1"; mirrorFound = $false }
                [PSCustomObject]@{ name = "noMirror2"; mirrorFound = $false }
                [PSCustomObject]@{ name = "noMirror3"; mirrorFound = $false }
                # 2 forks with upstreamAvailable = false
                [PSCustomObject]@{ name = "noUpstream1"; mirrorFound = $true; upstreamAvailable = $false }
                [PSCustomObject]@{ name = "noUpstream2"; mirrorFound = $true; upstreamAvailable = $false }
                # 4 forks in cool-off period
                [PSCustomObject]@{ name = "coolOff1"; mirrorFound = $true; lastSyncError = "Error"; lastSyncAttempt = $now.AddHours(-12).ToString("yyyy-MM-ddTHH:mm:ssZ") }
                [PSCustomObject]@{ name = "coolOff2"; mirrorFound = $true; lastSyncError = "Error"; lastSyncAttempt = $now.AddHours(-6).ToString("yyyy-MM-ddTHH:mm:ssZ") }
                [PSCustomObject]@{ name = "coolOff3"; mirrorFound = $true; lastSyncError = "Error"; lastSyncAttempt = $now.AddHours(-18).ToString("yyyy-MM-ddTHH:mm:ssZ") }
                [PSCustomObject]@{ name = "coolOff4"; mirrorFound = $true; lastSyncError = "Error"; lastSyncAttempt = $now.AddHours(-2).ToString("yyyy-MM-ddTHH:mm:ssZ") }
                # 5 eligible forks
                [PSCustomObject]@{ name = "eligible1"; mirrorFound = $true; lastSynced = $null }
                [PSCustomObject]@{ name = "eligible2"; mirrorFound = $true; lastSynced = $null }
                [PSCustomObject]@{ name = "eligible3"; mirrorFound = $true; lastSynced = $null }
                [PSCustomObject]@{ name = "eligible4"; mirrorFound = $true; lastSyncError = "Error"; lastSyncAttempt = $now.AddHours(-36).ToString("yyyy-MM-ddTHH:mm:ssZ") }
                [PSCustomObject]@{ name = "eligible5"; mirrorFound = $true; lastSynced = $now.AddDays(-2).ToString("yyyy-MM-ddTHH:mm:ssZ") }
            )
            
            # Capture output
            $output = Select-ForksToProcess -existingForks $forks -numberOfRepos 100 -coolOffHoursForFailedSync 24 | Out-String
            
            # Verify that only 5 eligible forks were selected
            $result = Select-ForksToProcess -existingForks $forks -numberOfRepos 100 -coolOffHoursForFailedSync 24
            $result.Count | Should -Be 5
            
            # Verify no ineligible forks were selected
            $result.name | Should -Not -Contain "noMirror1"
            $result.name | Should -Not -Contain "noUpstream1"
            $result.name | Should -Not -Contain "coolOff1"
            
            # Verify all eligible forks were selected
            $result.name | Should -Contain "eligible1"
            $result.name | Should -Contain "eligible2"
            $result.name | Should -Contain "eligible3"
            $result.name | Should -Contain "eligible4"
            $result.name | Should -Contain "eligible5"
        }
        
        It "Should warn when fewer eligible forks than requested" {
            $forks = @(
                [PSCustomObject]@{ name = "fork1"; mirrorFound = $true; lastSynced = $null }
                [PSCustomObject]@{ name = "fork2"; mirrorFound = $true; lastSynced = $null }
            )
            
            $result = Select-ForksToProcess -existingForks $forks -numberOfRepos 100
            
            # Should select all available eligible forks, not fail
            $result.Count | Should -Be 2
        }
    }
}
