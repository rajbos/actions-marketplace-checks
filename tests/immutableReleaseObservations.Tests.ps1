BeforeAll {
    . $PSScriptRoot/../.github/workflows/library.ps1

    # Define GetImmutableReleaseObservations inline (mirrors .github/workflows/repoInfo.ps1)
    # to avoid loading repoInfo.ps1's script-level code, matching the pattern used by
    # tests/immutableReleasePolicy.Tests.ps1 and tests/fundingInfo.Tests.ps1.
    function GetImmutableReleaseObservations {
        Param (
            $owner,
            $repo,
            [Alias('access_token')]
            $accessToken,
            $startTime
        )

        $checkedAt = Get-Date
        $source = "GET /repos/{owner}/{repo}/releases"

        function New-ImmutableReleaseObservationsErrorResult {
            Param ([string] $reason)
            return @{
                Releases  = @()
                CheckedAt = $checkedAt
                Source    = $source
                Error     = $true
                Reason    = $reason
            }
        }

        if ($null -eq $owner -or $owner.Length -eq 0 -or $null -eq $repo -or $repo.Length -eq 0) {
            return New-ImmutableReleaseObservationsErrorResult -reason "missing_owner_or_repo"
        }

        $timeSpan = (Get-Date) - $startTime
        if ($timeSpan.TotalMinutes -gt 50) {
            Write-Host "Stopping the run, since we are nearing the 50-minute mark"
            return New-ImmutableReleaseObservationsErrorResult -reason "run_time_budget_exceeded"
        }

        $url = "/repos/$owner/$repo/releases"
        $response = $null
        try {
            $response = ApiCall -method GET -url $url -hideFailedCall $true -returnErrorInfo $true -access_token $accessToken
        }
        catch {
            Write-Debug "Failed to fetch releases for immutable-release observations for [$owner/$repo]: $($_.Exception.Message)"
            return New-ImmutableReleaseObservationsErrorResult -reason "transient_error"
        }

        $isErrorResult = ($response -is [hashtable] -and $response.ContainsKey('Error') -and $response.Error)
        if ($isErrorResult) {
            $reason = "api_error"
            if ($response.ContainsKey('StatusCode')) {
                switch ($response.StatusCode) {
                    403 { $reason = "forbidden_or_rate_limited" }
                    404 { $reason = "repo_not_found" }
                    default { $reason = "api_error_status_$($response.StatusCode)" }
                }
            }
            return New-ImmutableReleaseObservationsErrorResult -reason $reason
        }

        $rawReleases = @($response)
        $publishedReleases = $rawReleases | Where-Object { $null -ne $_ -and $_.draft -ne $true }

        $releases = @($publishedReleases | ForEach-Object {
            @{
                releaseId   = $_.id
                tagName     = $_.tag_name
                publishedAt = $_.published_at
            }
        })

        return @{
            Releases  = $releases
            CheckedAt = $checkedAt
            Source    = $source
            Error     = $false
            Reason    = $null
        }
    }
}

Describe 'GetImmutableReleaseObservations' {
    BeforeEach {
        Mock ApiCall { }
    }

    It 'Should return an error result with missing_owner_or_repo when owner is null' {
        $result = GetImmutableReleaseObservations -owner $null -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.Error | Should -Be $true
        $result.Reason | Should -Be "missing_owner_or_repo"
        $result.Releases.Count | Should -Be 0
    }

    It 'Should return an error result with run_time_budget_exceeded when nearing the 50-minute mark' {
        $startTime = (Get-Date).AddMinutes(-51)

        $result = GetImmutableReleaseObservations -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime $startTime

        $result.Error | Should -Be $true
        $result.Reason | Should -Be "run_time_budget_exceeded"
    }

    It 'Should exclude draft releases from the returned set' {
        Mock ApiCall {
            return @(
                @{ id = 1; tag_name = "v1.0.0"; draft = $false; prerelease = $false; published_at = "2024-01-01T00:00:00Z" }
                @{ id = 2; tag_name = "v1.1.0-draft"; draft = $true; prerelease = $false; published_at = $null }
            )
        }

        $result = GetImmutableReleaseObservations -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.Error | Should -Be $false
        $result.Releases.Count | Should -Be 1
        $result.Releases[0].releaseId | Should -Be 1
        $result.Releases[0].tagName | Should -Be "v1.0.0"
    }

    It 'Should include prerelease releases the same as regular published releases (issue #266 draft/prerelease coverage)' {
        # Only drafts are excluded by this collector - a prerelease is still a
        # published release and must be counted normally, not silently dropped.
        Mock ApiCall {
            return @(
                @{ id = 1; tag_name = "v1.0.0"; draft = $false; prerelease = $false; published_at = "2024-01-01T00:00:00Z" }
                @{ id = 2; tag_name = "v2.0.0-rc1"; draft = $false; prerelease = $true; published_at = "2024-02-01T00:00:00Z" }
            )
        }

        $result = GetImmutableReleaseObservations -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.Error | Should -Be $false
        $result.Releases.Count | Should -Be 2
        (@($result.Releases | Where-Object { $_.releaseId -eq 2 })).Count | Should -Be 1
    }

    It 'Should map id/tag_name/published_at into releaseId/tagName/publishedAt' {
        Mock ApiCall {
            return @(
                @{ id = 42; tag_name = "v2.0.0"; draft = $false; published_at = "2024-05-01T12:00:00Z" }
            )
        }

        $result = GetImmutableReleaseObservations -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.Releases[0].releaseId | Should -Be 42
        $result.Releases[0].tagName | Should -Be "v2.0.0"
        $result.Releases[0].publishedAt | Should -Be "2024-05-01T12:00:00Z"
    }

    It 'Should return an error result with repo_not_found on a 404 from ApiCall' {
        Mock ApiCall {
            return @{ Error = $true; StatusCode = 404; Message = "Not Found" }
        }

        $result = GetImmutableReleaseObservations -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.Error | Should -Be $true
        $result.Reason | Should -Be "repo_not_found"
    }

    It 'Should return an error result with forbidden_or_rate_limited on a 403 from ApiCall' {
        Mock ApiCall {
            return @{ Error = $true; StatusCode = 403; Message = "Forbidden" }
        }

        $result = GetImmutableReleaseObservations -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.Error | Should -Be $true
        $result.Reason | Should -Be "forbidden_or_rate_limited"
    }

    It 'Should return an error result with transient_error when ApiCall throws' {
        Mock ApiCall { throw "boom" }

        $result = GetImmutableReleaseObservations -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.Error | Should -Be $true
        $result.Reason | Should -Be "transient_error"
    }

    It 'Should return an empty releases array (not an error) when ApiCall returns null' {
        # A repo with zero releases comes back from the real API as an empty array,
        # which PowerShell collapses to $null once it passes through a function
        # return - this must be treated the same as "no releases", not as a failure.
        Mock ApiCall { return $null }

        $result = GetImmutableReleaseObservations -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.Error | Should -Be $false
        $result.Releases.Count | Should -Be 0
    }

    It 'Should return an empty releases array (not an error) when the repo has no releases' {
        Mock ApiCall { return @() }

        $result = GetImmutableReleaseObservations -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.Error | Should -Be $false
        $result.Releases.Count | Should -Be 0
    }
}

Describe 'Merge-ImmutableReleaseObservations' {
    It 'Should append a new "unknown" observation for a release seen for the first time' {
        $current = @(@{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z" })

        $merged = Merge-ImmutableReleaseObservations -existingObservations $null -currentReleases $current -observedAt (Get-Date) -source "GET /repos/{owner}/{repo}/releases"

        $merged.Count | Should -Be 1
        $merged[0].releaseId | Should -Be 1
        $merged[0].tagName | Should -Be "v1.0.0"
        $merged[0].immutabilityState | Should -Be "unknown"
        $merged[0].status | Should -Be "present"
    }

    It 'Should never invent immutable/notImmutable for a newly observed release' {
        $current = @(@{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z" })

        $merged = Merge-ImmutableReleaseObservations -existingObservations $null -currentReleases $current -observedAt (Get-Date) -source "src"

        $merged[0].immutabilityState | Should -Not -Be "immutable"
        $merged[0].immutabilityState | Should -Not -Be "notImmutable"
    }

    It 'Should not touch or duplicate an existing observation for a release that is still present' {
        $existing = @(
            @{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "immutable"; status = "present"; observedAt = (Get-Date).AddDays(-10); source = "src" }
        )
        $current = @(@{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z" })

        $merged = Merge-ImmutableReleaseObservations -existingObservations $existing -currentReleases $current -observedAt (Get-Date) -source "src"

        # Still present, still already known -> no new entry appended, existing untouched
        $merged.Count | Should -Be 1
        $merged[0].immutabilityState | Should -Be "immutable"
        $merged[0].status | Should -Be "present"
    }

    It 'Should never rewrite a prior immutabilityState when re-observed (append-only)' {
        $observedLongAgo = (Get-Date).AddDays(-40)
        $existing = @(
            @{ releaseId = 5; tagName = "v5.0.0"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "notImmutable"; status = "present"; observedAt = $observedLongAgo; source = "src" }
        )
        $current = @(@{ releaseId = 5; tagName = "v5.0.0"; publishedAt = "2024-01-01T00:00:00Z" })

        $merged = Merge-ImmutableReleaseObservations -existingObservations $existing -currentReleases $current -observedAt (Get-Date) -source "src"

        $merged.Count | Should -Be 1
        $merged[0].immutabilityState | Should -Be "notImmutable"
        $merged[0].observedAt | Should -Be $observedLongAgo
    }

    It 'Should append a "deleted" observation when a previously known release disappears, without erasing the prior entry' {
        $existing = @(
            @{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "immutable"; status = "present"; observedAt = (Get-Date).AddDays(-5); source = "src" }
        )
        $current = @()  # release no longer present upstream

        $merged = Merge-ImmutableReleaseObservations -existingObservations $existing -currentReleases $current -observedAt (Get-Date) -source "src"

        $merged.Count | Should -Be 2
        (@($merged | Where-Object { $_.status -eq "present" })).Count | Should -Be 1
        (@($merged | Where-Object { $_.status -eq "deleted" })).Count | Should -Be 1
        $deleted = @($merged | Where-Object { $_.status -eq "deleted" })[0]
        $deleted.releaseId | Should -Be 1
        $deleted.immutabilityState | Should -Be "immutable"
    }

    It 'Should not append a duplicate deletion observation once a release is already marked deleted' {
        $existing = @(
            @{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "immutable"; status = "present"; observedAt = (Get-Date).AddDays(-10); source = "src" }
            @{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "immutable"; status = "deleted"; observedAt = (Get-Date).AddDays(-5); source = "src" }
        )
        $current = @()

        $merged = Merge-ImmutableReleaseObservations -existingObservations $existing -currentReleases $current -observedAt (Get-Date) -source "src"

        # No new entries should be appended - already recorded as deleted
        $merged.Count | Should -Be 2
    }

    It 'Should append a new "present" observation carrying forward the last known state when a deleted release reappears' {
        $existing = @(
            @{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "immutable"; status = "present"; observedAt = (Get-Date).AddDays(-10); source = "src" }
            @{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "immutable"; status = "deleted"; observedAt = (Get-Date).AddDays(-5); source = "src" }
        )
        $current = @(@{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z" })

        $merged = Merge-ImmutableReleaseObservations -existingObservations $existing -currentReleases $current -observedAt (Get-Date) -source "src"

        $merged.Count | Should -Be 3
        $latest = $merged | Sort-Object { [datetime]$_.observedAt } | Select-Object -Last 1
        $latest.status | Should -Be "present"
        $latest.immutabilityState | Should -Be "immutable"
    }

    It 'Should keep unrelated releases untouched when only one release changes' {
        $existing = @(
            @{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "immutable"; status = "present"; observedAt = (Get-Date).AddDays(-10); source = "src" }
            @{ releaseId = 2; tagName = "v2.0.0"; publishedAt = "2024-02-01T00:00:00Z"; immutabilityState = "unknown"; status = "present"; observedAt = (Get-Date).AddDays(-10); source = "src" }
        )
        # Release 1 disappears, release 2 stays, release 3 is new
        $current = @(
            @{ releaseId = 2; tagName = "v2.0.0"; publishedAt = "2024-02-01T00:00:00Z" }
            @{ releaseId = 3; tagName = "v3.0.0"; publishedAt = "2024-03-01T00:00:00Z" }
        )

        $merged = Merge-ImmutableReleaseObservations -existingObservations $existing -currentReleases $current -observedAt (Get-Date) -source "src"

        $merged.Count | Should -Be 4  # 2 existing + 1 new "deleted" for release 1 + 1 new "unknown" for release 3
        (@($merged | Where-Object { $_.releaseId -eq 2 })).Count | Should -Be 1
        (@($merged | Where-Object { $_.releaseId -eq 3 -and $_.status -eq "present" })).Count | Should -Be 1
        (@($merged | Where-Object { $_.releaseId -eq 1 -and $_.status -eq "deleted" })).Count | Should -Be 1
    }

    It 'Should handle an empty existing history and an empty current release set without error' {
        $merged = Merge-ImmutableReleaseObservations -existingObservations $null -currentReleases @() -observedAt (Get-Date) -source "src"

        $merged.Count | Should -Be 0
    }

    It 'Should never remove or mutate any existing array element (append-only)' {
        $existingEntry = @{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "immutable"; status = "present"; observedAt = (Get-Date).AddDays(-10); source = "src" }
        $existing = @($existingEntry)
        $current = @()

        $merged = Merge-ImmutableReleaseObservations -existingObservations $existing -currentReleases $current -observedAt (Get-Date) -source "src"

        # The original hashtable reference should be present, completely unchanged
        (@($merged | Where-Object { $_.status -eq "present" }))[0] | Should -Be $existingEntry
        $existingEntry.status | Should -Be "present"
    }
}

Describe 'Get-RepoPriorityScore for immutableReleaseObservations staleness' {
    It 'Should score a repo missing immutableReleaseObservationsCheckedAt entirely' {
        $action = [PSCustomObject]@{
            owner = "test-owner"
            name = "test-owner_test-repo"
            mirrorFound = $true
            actionType = @{ actionType = "Node" }
            repoInfo = @{ updated_at = (Get-Date).ToString("o"); lastFetched = (Get-Date) }
            repoSize = 100
            dependents = @{ dependents = "1"; dependentsLastUpdated = (Get-Date) }
        }

        $score = Get-RepoPriorityScore -action $action
        $score | Should -BeGreaterOrEqual 15
    }

    It 'Should score a repo whose immutableReleaseObservationsCheckedAt is older than 30 days' {
        $action = [PSCustomObject]@{
            owner = "test-owner"
            name = "test-owner_test-repo"
            mirrorFound = $true
            actionType = @{ actionType = "Node" }
            repoInfo = @{ updated_at = (Get-Date).ToString("o"); lastFetched = (Get-Date) }
            repoSize = 100
            dependents = @{ dependents = "1"; dependentsLastUpdated = (Get-Date) }
            immutableReleaseObservationsCheckedAt = (Get-Date).AddDays(-31)
        }

        $score = Get-RepoPriorityScore -action $action
        $score | Should -BeGreaterOrEqual 15
    }

    It 'Should not add immutableReleaseObservations staleness score when recently checked' {
        $recentAction = [PSCustomObject]@{
            owner = "test-owner"
            name = "test-owner_test-repo"
            mirrorFound = $true
            actionType = @{ actionType = "Node" }
            repoInfo = @{ updated_at = (Get-Date).ToString("o"); lastFetched = (Get-Date) }
            repoSize = 100
            dependents = @{ dependents = "1"; dependentsLastUpdated = (Get-Date) }
            immutableReleaseObservationsCheckedAt = (Get-Date).AddDays(-1)
        }

        $staleAction = $recentAction | Select-Object *
        $staleAction.immutableReleaseObservationsCheckedAt = (Get-Date).AddDays(-31)

        $recentScore = Get-RepoPriorityScore -action $recentAction
        $staleScore = Get-RepoPriorityScore -action $staleAction

        $staleScore | Should -BeGreaterThan $recentScore
    }

    It 'Should score a repo with fresh policy/observation timestamps but missing immutableReleaseCoverage (issue #266 migration gap)' {
        # This is the "complete repo" case: everything else is fresh (so no
        # other staleness signal fires), but coverage was never backfilled -
        # e.g. the repo was checked by #264/#265 before #266 existed. Without
        # a dedicated score, this repo would never be selected by
        # Get-PrioritizedReposToProcess and would never reach GetInfo's local
        # backfill, even though computing it needs no API call at all.
        $withoutCoverage = [PSCustomObject]@{
            owner = "test-owner"
            name = "test-owner_test-repo"
            mirrorFound = $true
            actionType = @{ actionType = "Node" }
            repoInfo = @{ updated_at = (Get-Date).ToString("o"); lastFetched = (Get-Date) }
            repoSize = 100
            dependents = @{ dependents = "1"; dependentsLastUpdated = (Get-Date) }
            immutableReleasePolicy = "enabled"
            immutableReleasePolicyCheckedAt = (Get-Date)
            immutableReleaseObservationsCheckedAt = (Get-Date)
            immutableReleaseObservations = @(
                @{ releaseId = 1; tagName = "v1.0.0"; publishedAt = (Get-Date); immutabilityState = "unknown"; status = "present"; observedAt = (Get-Date); source = "src" }
            )
        }

        $withCoverage = $withoutCoverage | Select-Object *
        $withCoverage | Add-Member -Name immutableReleaseCoverage -Value @{ releasesConsidered = 1; immutableCount = 0; notImmutableCount = 0; unknownCount = 1; knownCount = 0; latestReleaseImmutable = "unknown"; summary = "0 of 0 known releases immutable (last 1; 1 unknown)" } -MemberType NoteProperty

        $scoreWithout = Get-RepoPriorityScore -action $withoutCoverage
        $scoreWith = Get-RepoPriorityScore -action $withCoverage

        $scoreWithout | Should -BeGreaterThan $scoreWith
    }

    It 'Should not score the coverage gap when there is no observation history at all yet' {
        # A brand-new repo with no immutableReleaseObservations property at all
        # is already scored via the observationsCheckedAt staleness signal
        # above - it must not also be double-scored by the coverage-gap check,
        # which only applies once observation history actually exists.
        $action = [PSCustomObject]@{
            owner = "test-owner"
            name = "test-owner_test-repo"
            mirrorFound = $true
            actionType = @{ actionType = "Node" }
            repoInfo = @{ updated_at = (Get-Date).ToString("o"); lastFetched = (Get-Date) }
            repoSize = 100
            dependents = @{ dependents = "1"; dependentsLastUpdated = (Get-Date) }
        }

        $scoreWithoutHistory = Get-RepoPriorityScore -action $action

        $actionWithEmptyHistory = $action | Select-Object *
        $actionWithEmptyHistory | Add-Member -Name immutableReleaseObservations -Value @() -MemberType NoteProperty -Force
        $scoreWithEmptyHistory = Get-RepoPriorityScore -action $actionWithEmptyHistory

        # An empty-but-present history with no coverage should still be flagged
        # (Get-ImmutableReleaseCoverage handles empty input just fine), so this
        # score must be at least as high as the no-history-yet case, not lower.
        $scoreWithEmptyHistory | Should -BeGreaterOrEqual $scoreWithoutHistory
    }

    It 'Should score the coverage gap for a schema-valid present-but-null immutableReleaseObservations' {
        # The coverage-gap score must use the same property-presence condition
        # as the backfill itself (repoInfo.ps1), not require non-null: a
        # present-but-null immutableReleaseObservations is schema-valid and the
        # backfill explicitly handles it (Get-ImmutableReleaseCoverage returns
        # the zero-count summary for null input), so it must still be scored
        # here or it would never be selected to receive that backfill.
        $action = [PSCustomObject]@{
            owner = "test-owner"
            name = "test-owner_test-repo"
            mirrorFound = $true
            actionType = @{ actionType = "Node" }
            repoInfo = @{ updated_at = (Get-Date).ToString("o"); lastFetched = (Get-Date) }
            repoSize = 100
            dependents = @{ dependents = "1"; dependentsLastUpdated = (Get-Date) }
            immutableReleasePolicy = "enabled"
            immutableReleasePolicyCheckedAt = (Get-Date)
            immutableReleaseObservationsCheckedAt = (Get-Date)
        }
        $action | Add-Member -Name immutableReleaseObservations -Value $null -MemberType NoteProperty -Force

        $withNullCoverage = $action | Select-Object *
        $withNullCoverage | Add-Member -Name immutableReleaseCoverage -Value $null -MemberType NoteProperty -Force

        $scoreWithNullObservations = Get-RepoPriorityScore -action $action
        $scoreWithNullCoverageToo = Get-RepoPriorityScore -action $withNullCoverage

        $scoreWithNullObservations | Should -BeGreaterThan 0
        $scoreWithNullCoverageToo | Should -Be $scoreWithNullObservations
    }
}
