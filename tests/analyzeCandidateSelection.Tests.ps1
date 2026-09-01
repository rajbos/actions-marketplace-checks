BeforeAll {
    $script:analyzeWorkflowPath = Join-Path $PSScriptRoot "../.github/workflows/analyze.yml"
    $script:analyzeWorkflowContent = Get-Content $script:analyzeWorkflowPath -Raw

    $script:libraryPath = Join-Path $PSScriptRoot "../.github/workflows/library.ps1"
    $script:libraryContent = Get-Content $script:libraryPath -Raw

    $script:repoInfoPath = Join-Path $PSScriptRoot "../.github/workflows/repoInfo.ps1"
    $script:repoInfoContent = Get-Content $script:repoInfoPath -Raw
}

Describe "analyze.yml candidate selection uses the shared priority score" {
    # Root cause: analyze.yml's "prepare" job used to sort candidates by repoInfo.updated_at
    # (GitHub's "when was this upstream repo last pushed" timestamp) instead of the
    # staleness/missing-data priority score that repoInfo.ps1's direct run path already used
    # via Get-PrioritizedReposToProcess. That meant none of the Get-RepoPriorityScore factors
    # (repoSize/dependents/fundingInfo/tagInfo/releaseInfo/containerScan staleness) had any
    # effect on analyze.yml's selection - the dominant, 600-repo/hour refresh path - and a
    # repo with no repoInfo.updated_at (or a rarely-pushed-upstream one) sorted to the front
    # forever, never rotating out.
    It "Should call Get-PrioritizedReposToProcess in the prepare job's selection step" {
        $script:analyzeWorkflowContent | Should -Match 'Get-PrioritizedReposToProcess\s+-existingForks\s+\$forkCandidates\s+-numberOfReposToDo\s+\$numberOfReposRepoInfo'
    }

    It "Should still restrict candidates to forkFound -eq `$true before scoring" {
        $script:analyzeWorkflowContent | Should -Match '\$forkCandidates\s*=\s*\$existingForks\s*\|\s*Where-Object\s*\{\s*\$_\.forkFound\s+-eq\s+\$true\s*\}'
    }

    It "Should no longer sort candidates by repoInfo.updated_at ticks" {
        $script:analyzeWorkflowContent | Should -Not -Match '\[DateTime\]::Parse\(\$_\.repoInfo\.updated_at\)\.Ticks'
    }

    It "Should dot-source library.ps1 in the prepare job so Get-PrioritizedReposToProcess is available" {
        # The "Split work into chunks" step already dot-sources library.ps1 for
        # Split-ForksIntoChunks/Write-Message; this just confirms that stays true after the change.
        $script:analyzeWorkflowContent | Should -Match '\.\s*/\.github/workflows/library\.ps1'
    }
}

Describe "Prioritization functions live in library.ps1, not repoInfo.ps1" {
    # repoInfo.ps1 dot-sources library.ps1 at its top, and its top-level code (Test-AccessTokens,
    # GitHub App token setup) has side effects that make it unsafe to dot-source from a job like
    # analyze.yml's "prepare" job that never sets up API tokens. Moving the scoring functions to
    # library.ps1 (side-effect-free besides Write-Host) lets analyze.yml reuse them without
    # duplicating the logic or paying for repoInfo.ps1's token setup.
    It "Should define Get-RepoPriorityScore in library.ps1" {
        $script:libraryContent | Should -Match 'function Get-RepoPriorityScore\s*\{'
    }

    It "Should define Get-PrioritizedReposToProcess in library.ps1" {
        $script:libraryContent | Should -Match 'function Get-PrioritizedReposToProcess\s*\{'
    }

    It "Should not redefine Get-RepoPriorityScore in repoInfo.ps1" {
        $script:repoInfoContent | Should -Not -Match 'function Get-RepoPriorityScore\s*\{'
    }

    It "Should not redefine Get-PrioritizedReposToProcess in repoInfo.ps1" {
        $script:repoInfoContent | Should -Not -Match 'function Get-PrioritizedReposToProcess\s*\{'
    }

    It "Should have repoInfo.ps1 dot-source library.ps1 so it still has access to the moved functions" {
        $script:repoInfoContent | Should -Match '\.\s*\$PSScriptRoot/library\.ps1'
    }
}

Describe "Get-PrioritizedReposToProcess selection matches analyze.yml's fork-filtering behavior" {
    BeforeAll {
        $env:GITHUB_TOKEN = "test_token_mock"
        . $script:libraryPath
    }

    It "Should only ever be asked to score forkFound repos, mirroring analyze.yml's pre-filter" {
        # This exercises the same two-step shape analyze.yml's prepare step now uses:
        # filter to forkFound -eq $true, then hand the result to Get-PrioritizedReposToProcess.
        $repos = @(
            [PSCustomObject]@{ name = "not-forked"; forkFound = $false }
            [PSCustomObject]@{ name = "forked-missing-owner"; forkFound = $true }
            [PSCustomObject]@{
                name = "forked-fully-fresh"
                forkFound = $true
                owner = "test"
                mirrorFound = $true
                actionType = [PSCustomObject]@{ actionType = "Node" }
                repoInfo = [PSCustomObject]@{ updated_at = (Get-Date).AddYears(-3); lastFetched = (Get-Date -Format 'o') }
                repoSize = 100
                dependents = [PSCustomObject]@{ dependents = 50; dependentsLastUpdated = Get-Date }
                fundingInfo = [PSCustomObject]@{ lastChecked = Get-Date }
            }
        )

        $forkCandidates = $repos | Where-Object { $_.forkFound -eq $true }
        $selected = Get-PrioritizedReposToProcess -existingForks $forkCandidates -numberOfReposToDo 10

        # "not-forked" must never be selected even though it has no repoInfo at all (which would
        # otherwise score very high) - the forkFound filter runs before scoring.
        $selected.name | Should -Not -Contain "not-forked"
        # "forked-fully-fresh" has repoInfo.updated_at 3 years old (would have sorted first under
        # the old logic) but scores 0 under Get-RepoPriorityScore because lastFetched is recent -
        # it must not be selected, proving selection no longer keys off updated_at.
        $selected.name | Should -Not -Contain "forked-fully-fresh"
        $selected.name | Should -Contain "forked-missing-owner"
    }
}
