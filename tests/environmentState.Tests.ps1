Import-Module Pester

BeforeAll {
    # Mock Write-Message function to avoid Step Summary issues during testing
    function Write-Message {
        Param (
            [string] $message,
            [bool] $logToSummary = $false
        )
        Write-Host $message
    }
    
    # Create sample test data
    $script:sampleActions = @(
        @{ name = "action1"; repoUrl = "https://github.com/owner1/repo1" },
        @{ name = "action2"; repoUrl = "https://github.com/owner2/repo2" },
        @{ name = "action3"; repoUrl = "https://github.com/owner3/repo3" },
        @{ name = "action4"; repoUrl = "https://github.com/owner4/repo4" }
    )
    
    $script:sampleForks = @(
        @{ 
            name = "action1"
            mirrorFound = $true
            forkFound = $true
            lastSynced = (Get-Date).AddDays(-3).ToString("yyyy-MM-ddTHH:mm:ssZ")
            actionType = "Node"
            tagInfo = @("v1.0.0")
            releaseInfo = @("v1.0.0")
            repoInfo = @{ size = 100 }
        },
        @{ 
            name = "action2"
            mirrorFound = $true
            forkFound = $true
            lastSynced = (Get-Date).AddDays(-10).ToString("yyyy-MM-ddTHH:mm:ssZ")
            actionType = "Docker"
            tagInfo = @()
            releaseInfo = @()
            repoInfo = @{ size = 200 }
        },
        @{ 
            name = "action3"
            mirrorFound = $false
            forkFound = $true
            lastSynced = $null
            actionType = "No file found"
            tagInfo = $null
            releaseInfo = $null
            repoInfo = $null
        },
        @{ 
            name = "action5"
            mirrorFound = $true
            forkFound = $true
            lastSynced = (Get-Date).AddDays(-2).ToString("yyyy-MM-ddTHH:mm:ssZ")
            actionType = "Composite"
            tagInfo = @("v2.0.0")
            releaseInfo = @("v2.0.0")
            repoInfo = @{ size = 150 }
        }
    )
}

Describe "Environment State - Delta Analysis" {
    It "Should correctly identify actions not yet tracked" {
        # Arrange
        $marketplaceActions = $script:sampleActions
        $trackedForks = $script:sampleForks
        
        # Get action names from marketplace
        $marketplaceNames = @{}
        foreach ($action in $marketplaceActions) {
            if ($action.name) {
                $marketplaceNames[$action.name] = $true
            }
        }
        
        # Get action names from status
        $trackedNames = @{}
        foreach ($fork in $trackedForks) {
            if ($fork.name) {
                $trackedNames[$fork.name] = $true
            }
        }
        
        # Find actions in marketplace but not tracked
        $actionsNotTracked = @()
        foreach ($action in $marketplaceActions) {
            if ($action.name -and -not $trackedNames.ContainsKey($action.name)) {
                $actionsNotTracked += $action
            }
        }
        
        # Act & Assert
        $actionsNotTracked.Count | Should -Be 1
        $actionsNotTracked[0].name | Should -Be "action4"
    }
    
    It "Should correctly identify actions tracked but no longer in marketplace" {
        # Arrange
        $marketplaceActions = $script:sampleActions
        $trackedForks = $script:sampleForks
        
        # Get action names from marketplace
        $marketplaceNames = @{}
        foreach ($action in $marketplaceActions) {
            if ($action.name) {
                $marketplaceNames[$action.name] = $true
            }
        }
        
        # Find actions tracked but not in marketplace
        $actionsNoLongerInMarketplace = @()
        foreach ($fork in $trackedForks) {
            if ($fork.name -and -not $marketplaceNames.ContainsKey($fork.name)) {
                $actionsNoLongerInMarketplace += $fork
            }
        }
        
        # Act & Assert
        $actionsNoLongerInMarketplace.Count | Should -Be 1
        $actionsNoLongerInMarketplace[0].name | Should -Be "action5"
    }
}

Describe "Environment State - Mirror Status" {
    It "Should correctly count repos with valid mirrors" {
        # Arrange
        $trackedForks = $script:sampleForks
        
        # Act
        $reposWithMirrors = ($trackedForks | Where-Object { $_.mirrorFound -eq $true }).Count
        
        # Assert
        $reposWithMirrors | Should -Be 3
    }
    
    It "Should correctly count repos without mirrors" {
        # Arrange
        $trackedForks = $script:sampleForks
        
        # Act
        $reposWithoutMirrors = @($trackedForks | Where-Object { $_.mirrorFound -eq $false -or $null -eq $_.mirrorFound }).Count
        
        # Assert
        $reposWithoutMirrors | Should -Be 1
    }
    
    It "Should correctly count repos with forks" {
        # Arrange
        $trackedForks = $script:sampleForks
        
        # Act
        $reposWithForks = ($trackedForks | Where-Object { $_.forkFound -eq $true }).Count
        
        # Assert
        $reposWithForks | Should -Be 4
    }
}

Describe "Environment State - Sync Activity" {
    It "Should correctly count repos synced in last 7 days" {
        # Arrange
        $trackedForks = $script:sampleForks
        $sevenDaysAgo = (Get-Date).AddDays(-7)
        
        # Act
        $reposSyncedLast7Days = ($trackedForks | Where-Object { 
            if ($_.lastSynced) {
                try {
                    $syncDate = [DateTime]::Parse($_.lastSynced)
                    return $syncDate -gt $sevenDaysAgo
                } catch {
                    return $false
                }
            }
            return $false
        }).Count
        
        # Assert
        $reposSyncedLast7Days | Should -Be 2
    }
    
    It "Should correctly count repos never synced" {
        # Arrange
        $trackedForks = $script:sampleForks
        
        # Act
        $reposNeverSynced = @($trackedForks | Where-Object { 
            $null -eq $_.lastSynced -or $_.lastSynced -eq ""
        }).Count
        
        # Assert
        $reposNeverSynced | Should -Be 1
    }
    
    It "Should correctly calculate repos needing update" {
        # Arrange
        $trackedForks = $script:sampleForks
        $sevenDaysAgo = (Get-Date).AddDays(-7)
        
        $reposWithMirrors = ($trackedForks | Where-Object { $_.mirrorFound -eq $true }).Count
        $reposSyncedLast7Days = ($trackedForks | Where-Object { 
            if ($_.lastSynced) {
                try {
                    $syncDate = [DateTime]::Parse($_.lastSynced)
                    return $syncDate -gt $sevenDaysAgo
                } catch {
                    return $false
                }
            }
            return $false
        }).Count
        
        # Act
        $reposNeedingUpdate = $reposWithMirrors - $reposSyncedLast7Days
        
        # Assert
        $reposNeedingUpdate | Should -Be 1
    }
}

Describe "Environment State - Repo Info Status" {
    It "Should correctly count repos with tags" {
        # Arrange
        $trackedForks = $script:sampleForks
        
        # Act
        $reposWithTags = ($trackedForks | Where-Object { 
            $_.tagInfo -and $_.tagInfo.Count -gt 0 
        }).Count
        
        # Assert
        $reposWithTags | Should -Be 2
    }
    
    It "Should correctly count repos with releases" {
        # Arrange
        $trackedForks = $script:sampleForks
        
        # Act
        $reposWithReleases = ($trackedForks | Where-Object { 
            $_.releaseInfo -and $_.releaseInfo.Count -gt 0 
        }).Count
        
        # Assert
        $reposWithReleases | Should -Be 2
    }
    
    It "Should correctly count repos with repo info" {
        # Arrange
        $trackedForks = $script:sampleForks
        
        # Act
        $reposWithRepoInfo = ($trackedForks | Where-Object { 
            $_.repoInfo -ne $null 
        }).Count
        
        # Assert
        $reposWithRepoInfo | Should -Be 3
    }
    
    It "Should correctly count repos with valid action type" {
        # Arrange
        $trackedForks = $script:sampleForks
        
        # Act
        $reposWithActionType = ($trackedForks | Where-Object { 
            $_.actionType -and $_.actionType -ne "" -and $_.actionType -ne "No file found" 
        }).Count
        
        # Assert
        $reposWithActionType | Should -Be 3
    }
}

Describe "Environment State - Action Type Breakdown" {
    It "Should correctly count action types" {
        # Arrange
        $trackedForks = $script:sampleForks
        
        # Act
        $actionTypeCount = @{}
        foreach ($fork in $trackedForks) {
            $type = if ($fork.actionType) { $fork.actionType } else { "Unknown" }
            if ($actionTypeCount.ContainsKey($type)) {
                $actionTypeCount[$type]++
            } else {
                $actionTypeCount[$type] = 1
            }
        }
        
        # Assert
        $actionTypeCount["Node"] | Should -Be 1
        $actionTypeCount["Docker"] | Should -Be 1
        $actionTypeCount["Composite"] | Should -Be 1
        $actionTypeCount["No file found"] | Should -Be 1
        $actionTypeCount.Count | Should -Be 4
    }
}

Describe "Environment State - Health Metrics" {
    It "Should correctly calculate coverage percentage" {
        # Arrange
        $totalActionsInMarketplace = $script:sampleActions.Count
        $totalTrackedActions = $script:sampleForks.Count
        
        # Act
        $coveragePercentage = if ($totalActionsInMarketplace -gt 0) { 
            [math]::Round(($totalTrackedActions / $totalActionsInMarketplace) * 100, 2) 
        } else { 
            0 
        }
        
        # Assert
        $coveragePercentage | Should -Be 100.00
    }
    
    It "Should correctly calculate freshness percentage" {
        # Arrange
        $trackedForks = $script:sampleForks
        $sevenDaysAgo = (Get-Date).AddDays(-7)
        
        $reposWithMirrors = ($trackedForks | Where-Object { $_.mirrorFound -eq $true }).Count
        $reposSyncedLast7Days = ($trackedForks | Where-Object { 
            if ($_.lastSynced) {
                try {
                    $syncDate = [DateTime]::Parse($_.lastSynced)
                    return $syncDate -gt $sevenDaysAgo
                } catch {
                    return $false
                }
            }
            return $false
        }).Count
        
        # Act
        $freshnessPercentage = if ($reposWithMirrors -gt 0) { 
            [math]::Round(($reposSyncedLast7Days / $reposWithMirrors) * 100, 2) 
        } else { 
            0 
        }
        
        # Assert
        $freshnessPercentage | Should -Be 66.67
    }
    
    It "Should correctly calculate completion percentage" {
        # Arrange
        $trackedForks = $script:sampleForks
        $totalTrackedActions = $trackedForks.Count
        
        $reposWithActionType = ($trackedForks | Where-Object { 
            $_.actionType -and $_.actionType -ne "" -and $_.actionType -ne "No file found" 
        }).Count
        
        # Act
        $completionPercentage = if ($totalTrackedActions -gt 0) { 
            [math]::Round(($reposWithActionType / $totalTrackedActions) * 100, 2) 
        } else { 
            0 
        }
        
        # Assert
        $completionPercentage | Should -Be 75.00
    }
}
