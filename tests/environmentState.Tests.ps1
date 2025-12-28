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
            tags = @("v1.0.0")
            releases = @("v1.0.0")
            repoInfo = @{ size = 100 }
            repoUrl = "https://github.com/original/action1"
            forkedRepoUrl = "https://github.com/actions-marketplace-validations/action1"
        },
        @{ 
            name = "action2"
            mirrorFound = $true
            forkFound = $true
            lastSynced = (Get-Date).AddDays(-10).ToString("yyyy-MM-ddTHH:mm:ssZ")
            actionType = "Docker"
            tags = @()
            releases = @()
            repoInfo = @{ size = 200 }
            repoUrl = "https://github.com/original/action2"
            forkedRepoUrl = "https://github.com/actions-marketplace-validations/action2"
        },
        @{ 
            name = "action3"
            mirrorFound = $false
            forkFound = $true
            lastSynced = $null
            actionType = "No file found"
            tags = $null
            releases = $null
            repoInfo = $null
            repoUrl = "https://github.com/original/action3"
        },
        @{ 
            name = "action5"
            mirrorFound = $true
            forkFound = $true
            lastSynced = (Get-Date).AddDays(-2).ToString("yyyy-MM-ddTHH:mm:ssZ")
            actionType = "Composite"
            tags = @("v2.0.0")
            releases = @("v2.0.0")
            repoInfo = @{ size = 150 }
            repoUrl = "https://github.com/original/action5"
            forkedRepoUrl = "https://github.com/actions-marketplace-validations/action5"
        },
        @{ 
            name = "action6"
            mirrorFound = $true
            forkFound = $true
            lastSynced = $null
            actionType = "Node"
            tags = @()
            releases = @()
            repoInfo = @{ size = 50 }
            repoUrl = "https://github.com/original/action6"
            forkedRepoUrl = "https://github.com/actions-marketplace-validations/action6"
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
        # action5 and action6 are tracked but not in marketplace
        $actionsNoLongerInMarketplace.Count | Should -Be 2
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
        # action1, action2, action5, and action6 have mirrors
        $reposWithMirrors | Should -Be 4
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
        # All 5 test repos have forks
        $reposWithForks | Should -Be 5
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
        
        # Act - Only count repos WITH mirrors that have never been synced
        $reposNeverSynced = @($trackedForks | Where-Object { 
            $_.mirrorFound -eq $true -and ($null -eq $_.lastSynced -or $_.lastSynced -eq "")
        }).Count
        
        # Assert
        # From sample data: action3 has mirrorFound=false with no lastSynced (not counted)
        # action6 has mirrorFound=true with no lastSynced (counted)
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
        # 4 repos with mirrors - 2 synced in last 7 days = 2 needing update
        $reposNeedingUpdate | Should -Be 2
    }
}

Describe "Environment State - Repo Info Status" {
    It "Should correctly count repos with tags" {
        # Arrange
        $trackedForks = $script:sampleForks
        
        # Act
        $reposWithTags = ($trackedForks | Where-Object { 
            $_.tags -and $_.tags.Count -gt 0 
        }).Count
        
        # Assert
        $reposWithTags | Should -Be 2
    }
    
    It "Should correctly count repos with releases" {
        # Arrange
        $trackedForks = $script:sampleForks
        
        # Act
        $reposWithReleases = ($trackedForks | Where-Object { 
            $_.releases -and $_.releases.Count -gt 0 
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
        # action1, action2, action5, and action6 have repoInfo
        $reposWithRepoInfo | Should -Be 4
    }
    
    It "Should correctly count repos with valid action type" {
        # Arrange
        $trackedForks = $script:sampleForks
        
        # Act
        $reposWithActionType = ($trackedForks | Where-Object { 
            $_.actionType -and $_.actionType -ne "" -and $_.actionType -ne "No file found" 
        }).Count
        
        # Assert
        # action1 (Node), action2 (Docker), action5 (Composite), action6 (Node) have valid types
        $reposWithActionType | Should -Be 4
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
        # action1 and action6 are Node
        $actionTypeCount["Node"] | Should -Be 2
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
        # 5 tracked / 4 in marketplace = 125%
        $coveragePercentage | Should -Be 125.00
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
        # 2 synced in last 7 days / 4 with mirrors = 50%
        $freshnessPercentage | Should -Be 50.00
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
        # 4 with valid action type / 5 total = 80%
        $completionPercentage | Should -Be 80.00
    }
}
