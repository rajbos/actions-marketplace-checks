Import-Module Pester

BeforeAll {
    # import functions.ps1
    . $PSScriptRoot/../.github/workflows/library.ps1

    $actions = $null
    $global:status = $null
    $global:failedForks = $null

    $actionsFile = "actions.json"
    $statusFile = "status.json"
    $failedForksFile = "failedForks.json"

    # load actions
    $actions = (Get-Content $actionsFile | ConvertFrom-Json)
    # load status
    $status = (Get-Content $statusFile | ConvertFrom-Json)
    # load failed forks
    $failedForks = (Get-Content $failedForksFile | ConvertFrom-Json)
}

Describe "FilterActionsToProcess" {
    It "Should filter the list " {
        $command = { $actionsToProcess = FilterActionsToProcess -actions $actions -existingForks $status }
        $measureResult = (Measure-Command $command).TotalSeconds
        Write-Host "FilterActionsToProcess call duration in seconds[$measureResult] with [$($actions.Count)] actions filtered to [$($actionsToProcess.Count)]"
        $actionsToProcess.Count | Should -BeLessThan $actions.Count
    }
}

Describe "FlattenActionsList" {

    Describe "FlattenActionsList" {
        It "Should return the same count of items" {
            # Act
            $command = { $actionsResult = FlattenActionsList -actions $actions }
            $measureResult = (Measure-Command $command).TotalSeconds
            Write-Host "Flatten call duration in seconds [$measureResult]"
            $actionsResult.Count | Should -Be $actions.Count

            $expectedAction = $actions[0]
            # prep for expected result
            ($expectedowner, $expectedRepo) = SplitUrl -url $expectedAction.RepoUrl

            # Assert
            $actionsResult[0].owner | Should -Be $expectedOwner
            $actionsResult[0].repo | Should -Be $expectedRepo
            $actionsResult[0].forkedRepoName | Should -Be "$($expectedOwner)_$($expectedRepo)"
        }
    }

    Describe "FlattenActionsList-Improved" {
        It "Should return the same count of items" {
            # Act
            $command = { $actionsResult = FlattenActionsListImproved -actions $actions }
            $measureResult = (Measure-Command $command).TotalSeconds
            Write-Host "Flatten improved call duration in seconds [$measureResult]"
            $actionsResult.Count | Should -Be $actions.Count

            $expectedAction = $actions[0]
            # prep for expected result
            ($expectedowner, $expectedRepo) = SplitUrl -url $expectedAction.RepoUrl

            # Assert
            $actionsResult[0].owner | Should -Be $expectedOwner
            $actionsResult[0].repo | Should -Be $expectedRepo
            $actionsResult[0].forkedRepoName | Should -Be "$($expectedOwner)_$($expectedRepo)"
        }
    }

    Describe "FlattenActionsList-Improved2" {
        It "Should return the same count of items" {
            # Act
            $command = { $actionsResult = FlattenActionsListImproved2 -actions $actions }
            $measureResult = (Measure-Command $command).TotalSeconds
            Write-Host "Flatten improved2 call duration in seconds [$measureResult]"
            $actionsResult.Count | Should -Be $actions.Count

            $expectedAction = $actions[0]
            # prep for expected result
            ($expectedowner, $expectedRepo) = SplitUrl -url $expectedAction.RepoUrl

            # Assert
            $actionsResult[0].owner | Should -Be $expectedOwner
            $actionsResult[0].repo | Should -Be $expectedRepo
            $actionsResult[0].forkedRepoName | Should -Be "$($expectedOwner)_$($expectedRepo)"
        }
    }
}
