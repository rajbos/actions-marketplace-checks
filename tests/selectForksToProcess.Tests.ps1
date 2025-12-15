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
        
        It "Should prioritize forks with older lastSynced dates" {
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
}
