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
            $startTime,
            $existingObservations
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
                releaseId              = $_.id
                tagName                = $_.tag_name
                publishedAt            = $_.published_at
                releaseTargetCommitish = $_.target_commitish
            }
        })

        # Resolve the peeled commit SHA for only the newest releases (issue #267),
        # bounded to limit extra API calls - mirrors repoInfo.ps1. Further bounded
        # to releases that don't already have a resolvedCommitSha recorded, so the
        # routine #266 30-day refresh doesn't re-resolve already-known tags.
        $releaseTagShaResolutionLimit = 10
        $latestExistingObservationByReleaseId = @{}
        foreach ($existingObservation in @($existingObservations)) {
            if ($null -eq $existingObservation) { continue }
            $existingRid = $existingObservation.releaseId
            if (-not $latestExistingObservationByReleaseId.ContainsKey($existingRid)) {
                $latestExistingObservationByReleaseId[$existingRid] = $existingObservation
            }
            else {
                $currentLatest = $latestExistingObservationByReleaseId[$existingRid]
                $isNewer = $false
                try {
                    $isNewer = [datetime]$existingObservation.observedAt -gt [datetime]$currentLatest.observedAt
                }
                catch { $isNewer = $false }
                if ($isNewer) {
                    $latestExistingObservationByReleaseId[$existingRid] = $existingObservation
                }
            }
        }

        $releaseIdsWithKnownSha = New-Object System.Collections.Generic.HashSet[object]
        foreach ($latestExistingObservation in $latestExistingObservationByReleaseId.Values) {
            if ($latestExistingObservation.status -eq "deleted") { continue }
            if (-not [string]::IsNullOrWhiteSpace($latestExistingObservation.resolvedCommitSha)) {
                [void]$releaseIdsWithKnownSha.Add($latestExistingObservation.releaseId)
            }
        }

        $releasesNewestFirst = @($releases | Sort-Object -Property { try { [datetime]$_.publishedAt } catch { [datetime]::MinValue } } -Descending)
        $releaseIdsToResolve = New-Object System.Collections.Generic.HashSet[object]
        foreach ($r in ($releasesNewestFirst | Select-Object -First $releaseTagShaResolutionLimit)) {
            if ($releaseIdsWithKnownSha.Contains($r.releaseId)) { continue }
            [void]$releaseIdsToResolve.Add($r.releaseId)
        }

        foreach ($release in $releases) {
            if (-not $releaseIdsToResolve.Contains($release.releaseId)) { continue }
            if ($null -eq $release.tagName -or $release.tagName.Length -eq 0) { continue }

            $shaResult = Resolve-ReleaseTagCommitSha -owner $owner -repo $repo -tagName $release.tagName -accessToken $accessToken -startTime $startTime
            if ($shaResult.Error) {
                continue
            }

            $release.resolvedCommitSha = $shaResult.Sha

            if ($release.releaseTargetCommitish -match '^[0-9a-f]{40}$') {
                $release.tagReleaseMismatch = ($release.releaseTargetCommitish -ne $shaResult.Sha)
            }
        }

        return @{
            Releases  = $releases
            CheckedAt = $checkedAt
            Source    = $source
            Error     = $false
            Reason    = $null
        }
    }

    # Define Resolve-ReleaseTagCommitSha inline (mirrors .github/workflows/repoInfo.ps1)
    # for the same reason as GetImmutableReleaseObservations above.
    function Resolve-ReleaseTagCommitSha {
        Param (
            $owner,
            $repo,
            $tagName,
            [Alias('access_token')]
            $accessToken,
            $startTime
        )

        function New-ResolveReleaseTagCommitShaErrorResult {
            Param ([string] $reason)
            return @{ Sha = $null; Error = $true; Reason = $reason }
        }

        if ($null -eq $owner -or $owner.Length -eq 0 -or $null -eq $repo -or $repo.Length -eq 0 -or $null -eq $tagName -or $tagName.Length -eq 0) {
            return New-ResolveReleaseTagCommitShaErrorResult -reason "missing_owner_repo_or_tag"
        }

        $timeSpan = (Get-Date) - $startTime
        if ($timeSpan.TotalMinutes -gt 50) {
            return New-ResolveReleaseTagCommitShaErrorResult -reason "run_time_budget_exceeded"
        }

        $encodedTag = [uri]::EscapeDataString($tagName)
        $refUrl = "/repos/$owner/$repo/git/ref/tags/$encodedTag"
        $refResponse = $null
        try {
            $refResponse = ApiCall -method GET -url $refUrl -hideFailedCall $true -returnErrorInfo $true -access_token $accessToken
        }
        catch {
            return New-ResolveReleaseTagCommitShaErrorResult -reason "transient_error"
        }

        $isRefError = ($refResponse -is [hashtable] -and $refResponse.ContainsKey('Error') -and $refResponse.Error)
        if ($isRefError) {
            $reason = "api_error"
            if ($refResponse.ContainsKey('StatusCode')) {
                switch ($refResponse.StatusCode) {
                    403 { $reason = "forbidden_or_rate_limited" }
                    404 { $reason = "tag_ref_not_found" }
                    default { $reason = "api_error_status_$($refResponse.StatusCode)" }
                }
            }
            return New-ResolveReleaseTagCommitShaErrorResult -reason $reason
        }

        if ($null -eq $refResponse -or $null -eq $refResponse.object) {
            return New-ResolveReleaseTagCommitShaErrorResult -reason "no_response"
        }

        $objectType = $refResponse.object.type
        $objectSha = $refResponse.object.sha

        if ($objectType -ne "tag") {
            return @{ Sha = $objectSha; Error = $false; Reason = $null }
        }

        $tagObjectUrl = "/repos/$owner/$repo/git/tags/$objectSha"
        $tagObjectResponse = $null
        try {
            $tagObjectResponse = ApiCall -method GET -url $tagObjectUrl -hideFailedCall $true -returnErrorInfo $true -access_token $accessToken
        }
        catch {
            return New-ResolveReleaseTagCommitShaErrorResult -reason "transient_error"
        }

        $isTagObjectError = ($tagObjectResponse -is [hashtable] -and $tagObjectResponse.ContainsKey('Error') -and $tagObjectResponse.Error)
        if ($isTagObjectError) {
            $reason = "api_error"
            if ($tagObjectResponse.ContainsKey('StatusCode')) {
                switch ($tagObjectResponse.StatusCode) {
                    403 { $reason = "forbidden_or_rate_limited" }
                    404 { $reason = "tag_object_not_found" }
                    default { $reason = "api_error_status_$($tagObjectResponse.StatusCode)" }
                }
            }
            return New-ResolveReleaseTagCommitShaErrorResult -reason $reason
        }

        if ($null -eq $tagObjectResponse -or $null -eq $tagObjectResponse.object) {
            return New-ResolveReleaseTagCommitShaErrorResult -reason "no_response"
        }

        return @{ Sha = $tagObjectResponse.object.sha; Error = $false; Reason = $null }
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

    It 'Should resolve a lightweight tag''s commit SHA and flag no mismatch when target_commitish is a matching SHA (issue #267)' {
        $sha = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
        Mock ApiCall {
            Param($method, $url)
            if ($url -like "*/releases") {
                return @(@{ id = 1; tag_name = "v1.0.0"; draft = $false; published_at = "2024-01-01T00:00:00Z"; target_commitish = $sha })
            }
            if ($url -like "*/git/ref/tags/*") {
                return @{ object = @{ sha = $sha; type = "commit" } }
            }
            return $null
        }

        $result = GetImmutableReleaseObservations -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.Releases[0].resolvedCommitSha | Should -Be $sha
        $result.Releases[0].tagReleaseMismatch | Should -Be $false
    }

    It 'Should peel an annotated tag to its target commit before comparing (issue #267)' {
        $tagObjectSha = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        $commitSha = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
        Mock ApiCall {
            Param($method, $url)
            if ($url -like "*/releases") {
                return @(@{ id = 1; tag_name = "v1.0.0"; draft = $false; published_at = "2024-01-01T00:00:00Z"; target_commitish = $commitSha })
            }
            if ($url -like "*/git/ref/tags/*") {
                # Annotated tag: the ref points at a tag object, not the commit
                return @{ object = @{ sha = $tagObjectSha; type = "tag" } }
            }
            if ($url -like "*/git/tags/*") {
                # Peeling the tag object resolves to the actual target commit
                return @{ object = @{ sha = $commitSha } }
            }
            return $null
        }

        $result = GetImmutableReleaseObservations -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.Releases[0].resolvedCommitSha | Should -Be $commitSha
        $result.Releases[0].tagReleaseMismatch | Should -Be $false
    }

    It 'Should flag a mismatch when the resolved commit differs from a full-SHA target_commitish (issue #267)' {
        $resolvedSha = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
        $recordedTarget = "111111111111111111111111111111111111111a"
        Mock ApiCall {
            Param($method, $url)
            if ($url -like "*/releases") {
                return @(@{ id = 1; tag_name = "v1.0.0"; draft = $false; published_at = "2024-01-01T00:00:00Z"; target_commitish = $recordedTarget })
            }
            if ($url -like "*/git/ref/tags/*") {
                return @{ object = @{ sha = $resolvedSha; type = "commit" } }
            }
            return $null
        }

        $result = GetImmutableReleaseObservations -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.Releases[0].resolvedCommitSha | Should -Be $resolvedSha
        $result.Releases[0].tagReleaseMismatch | Should -Be $true
    }

    It 'Should leave tagReleaseMismatch unset when target_commitish is a branch name, never guessing a verdict (issue #267)' {
        $resolvedSha = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
        Mock ApiCall {
            Param($method, $url)
            if ($url -like "*/releases") {
                return @(@{ id = 1; tag_name = "v1.0.0"; draft = $false; published_at = "2024-01-01T00:00:00Z"; target_commitish = "main" })
            }
            if ($url -like "*/git/ref/tags/*") {
                return @{ object = @{ sha = $resolvedSha; type = "commit" } }
            }
            return $null
        }

        $result = GetImmutableReleaseObservations -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.Releases[0].resolvedCommitSha | Should -Be $resolvedSha
        $result.Releases[0].tagReleaseMismatch | Should -BeNullOrEmpty
    }

    It 'Should not resolve a SHA for releases older than the 10 newest, to bound extra API calls (issue #267)' {
        $releases = @(1..12 | ForEach-Object {
            @{ id = $_; tag_name = "v$_.0.0"; draft = $false; published_at = (Get-Date "2024-01-01").AddDays($_).ToString("o"); target_commitish = "main" }
        })
        Mock ApiCall {
            Param($method, $url)
            if ($url -like "*/releases") {
                return $releases
            }
            if ($url -like "*/git/ref/tags/*") {
                return @{ object = @{ sha = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"; type = "commit" } }
            }
            return $null
        }

        $result = GetImmutableReleaseObservations -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        # Releases 3..12 (the ten newest by publishedAt) get resolved; 1 and 2 (oldest) do not.
        $oldest = $result.Releases | Where-Object { $_.releaseId -eq 1 -or $_.releaseId -eq 2 }
        foreach ($release in $oldest) {
            $release.resolvedCommitSha | Should -BeNullOrEmpty
        }
        $newest = $result.Releases | Where-Object { $_.releaseId -ge 3 }
        foreach ($release in $newest) {
            $release.resolvedCommitSha | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not re-resolve a SHA for a release that already has one recorded in existingObservations, to keep the routine 30-day refresh cheap (issue #267 cost concern)' {
        $shaResolutionCalls = 0
        Mock ApiCall {
            Param($method, $url)
            if ($url -like "*/releases") {
                return @(@{ id = 1; tag_name = "v1.0.0"; draft = $false; published_at = "2024-01-01T00:00:00Z"; target_commitish = "main" })
            }
            if ($url -like "*/git/ref/tags/*") {
                $script:shaResolutionCalls++
                return @{ object = @{ sha = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"; type = "commit" } }
            }
            return $null
        }

        $existingObservations = @(
            @{ releaseId = 1; tagName = "v1.0.0"; status = "present"; resolvedCommitSha = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2" }
        )

        $result = GetImmutableReleaseObservations -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date) -existingObservations $existingObservations

        $shaResolutionCalls | Should -Be 0
        $result.Releases[0].resolvedCommitSha | Should -BeNullOrEmpty
    }

    It 'Should still resolve a SHA for a release whose prior observation has no resolvedCommitSha yet' {
        Mock ApiCall {
            Param($method, $url)
            if ($url -like "*/releases") {
                return @(@{ id = 1; tag_name = "v1.0.0"; draft = $false; published_at = "2024-01-01T00:00:00Z"; target_commitish = "main" })
            }
            if ($url -like "*/git/ref/tags/*") {
                return @{ object = @{ sha = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"; type = "commit" } }
            }
            return $null
        }

        # Known before, but never successfully resolved (e.g. a prior attempt failed).
        $existingObservations = @(
            @{ releaseId = 1; tagName = "v1.0.0"; status = "present"; resolvedCommitSha = $null }
        )

        $result = GetImmutableReleaseObservations -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date) -existingObservations $existingObservations

        $result.Releases[0].resolvedCommitSha | Should -Be "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
    }

    It 'Should ignore a deleted prior observation''s resolvedCommitSha and still resolve if the release reappears' {
        Mock ApiCall {
            Param($method, $url)
            if ($url -like "*/releases") {
                return @(@{ id = 1; tag_name = "v1.0.0"; draft = $false; published_at = "2024-01-01T00:00:00Z"; target_commitish = "main" })
            }
            if ($url -like "*/git/ref/tags/*") {
                return @{ object = @{ sha = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"; type = "commit" } }
            }
            return $null
        }

        $existingObservations = @(
            @{ releaseId = 1; tagName = "v1.0.0"; status = "deleted"; resolvedCommitSha = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2" }
        )

        $result = GetImmutableReleaseObservations -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date) -existingObservations $existingObservations

        $result.Releases[0].resolvedCommitSha | Should -Be "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
    }

    It 'Should resolve a reappeared release even when an older superseded observation for it still has a resolvedCommitSha' {
        # History: present+resolved (old) -> deleted (newer) -> now reappearing.
        # Only the LATEST observation (the "deleted" one) should decide whether
        # to skip resolution - the old, superseded "present+resolved" entry must
        # not cause the reappearance to be wrongly skipped, since the
        # reappearance itself carries no SHA context of its own yet.
        Mock ApiCall {
            Param($method, $url)
            if ($url -like "*/releases") {
                return @(@{ id = 1; tag_name = "v1.0.0"; draft = $false; published_at = "2024-01-01T00:00:00Z"; target_commitish = "main" })
            }
            if ($url -like "*/git/ref/tags/*") {
                return @{ object = @{ sha = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"; type = "commit" } }
            }
            return $null
        }

        $existingObservations = @(
            @{ releaseId = 1; tagName = "v1.0.0"; status = "present"; observedAt = (Get-Date).AddDays(-20); resolvedCommitSha = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2" }
            @{ releaseId = 1; tagName = "v1.0.0"; status = "deleted"; observedAt = (Get-Date).AddDays(-10); resolvedCommitSha = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2" }
        )

        $result = GetImmutableReleaseObservations -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date) -existingObservations $existingObservations

        $result.Releases[0].resolvedCommitSha | Should -Be "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
    }
}

Describe 'Resolve-ReleaseTagCommitSha' {
    It 'Should return an error result with missing_owner_repo_or_tag when tagName is null' {
        $result = Resolve-ReleaseTagCommitSha -owner "test-owner" -repo "test-repo" -tagName $null -accessToken "token" -startTime (Get-Date)

        $result.Error | Should -Be $true
        $result.Reason | Should -Be "missing_owner_repo_or_tag"
    }

    It 'Should return an error result with run_time_budget_exceeded when nearing the 50-minute mark' {
        $startTime = (Get-Date).AddMinutes(-51)

        $result = Resolve-ReleaseTagCommitSha -owner "test-owner" -repo "test-repo" -tagName "v1.0.0" -accessToken "token" -startTime $startTime

        $result.Error | Should -Be $true
        $result.Reason | Should -Be "run_time_budget_exceeded"
    }

    It 'Should return the ref object SHA directly for a lightweight tag (type "commit")' {
        $sha = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
        Mock ApiCall { return @{ object = @{ sha = $sha; type = "commit" } } }

        $result = Resolve-ReleaseTagCommitSha -owner "test-owner" -repo "test-repo" -tagName "v1.0.0" -accessToken "token" -startTime (Get-Date)

        $result.Error | Should -Be $false
        $result.Sha | Should -Be $sha
    }

    It 'Should peel an annotated tag (type "tag") to its target commit SHA' {
        $tagObjectSha = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        $commitSha = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
        Mock ApiCall {
            Param($method, $url)
            if ($url -like "*/git/ref/tags/*") {
                return @{ object = @{ sha = $tagObjectSha; type = "tag" } }
            }
            return @{ object = @{ sha = $commitSha } }
        }

        $result = Resolve-ReleaseTagCommitSha -owner "test-owner" -repo "test-repo" -tagName "v1.0.0" -accessToken "token" -startTime (Get-Date)

        $result.Error | Should -Be $false
        $result.Sha | Should -Be $commitSha
    }

    It 'Should return tag_ref_not_found on a 404 resolving the tag ref' {
        Mock ApiCall { return @{ Error = $true; StatusCode = 404 } }

        $result = Resolve-ReleaseTagCommitSha -owner "test-owner" -repo "test-repo" -tagName "v1.0.0" -accessToken "token" -startTime (Get-Date)

        $result.Error | Should -Be $true
        $result.Reason | Should -Be "tag_ref_not_found"
    }

    It 'Should return forbidden_or_rate_limited on a 403 resolving the tag ref' {
        Mock ApiCall { return @{ Error = $true; StatusCode = 403 } }

        $result = Resolve-ReleaseTagCommitSha -owner "test-owner" -repo "test-repo" -tagName "v1.0.0" -accessToken "token" -startTime (Get-Date)

        $result.Error | Should -Be $true
        $result.Reason | Should -Be "forbidden_or_rate_limited"
    }

    It 'Should return transient_error when ApiCall throws' {
        Mock ApiCall { throw "boom" }

        $result = Resolve-ReleaseTagCommitSha -owner "test-owner" -repo "test-repo" -tagName "v1.0.0" -accessToken "token" -startTime (Get-Date)

        $result.Error | Should -Be $true
        $result.Reason | Should -Be "transient_error"
    }

    It 'Should return an error when peeling an annotated tag object fails' {
        Mock ApiCall {
            Param($method, $url)
            if ($url -like "*/git/ref/tags/*") {
                return @{ object = @{ sha = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"; type = "tag" } }
            }
            return @{ Error = $true; StatusCode = 404 }
        }

        $result = Resolve-ReleaseTagCommitSha -owner "test-owner" -repo "test-repo" -tagName "v1.0.0" -accessToken "token" -startTime (Get-Date)

        $result.Error | Should -Be $true
        $result.Reason | Should -Be "tag_object_not_found"
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

    It 'Should carry through resolvedCommitSha/releaseTargetCommitish/tagReleaseMismatch on a first observation (issue #267)' {
        $current = @(@{
            releaseId              = 1
            tagName                = "v1.0.0"
            publishedAt            = "2024-01-01T00:00:00Z"
            releaseTargetCommitish = "111111111111111111111111111111111111111a"
            resolvedCommitSha      = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
            tagReleaseMismatch     = $true
        })

        $merged = Merge-ImmutableReleaseObservations -existingObservations $null -currentReleases $current -observedAt (Get-Date) -source "src"

        $merged[0].resolvedCommitSha | Should -Be "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
        $merged[0].releaseTargetCommitish | Should -Be "111111111111111111111111111111111111111a"
        $merged[0].tagReleaseMismatch | Should -Be $true
    }

    It 'Should leave resolvedCommitSha/tagReleaseMismatch as $null when the caller could not resolve them' {
        $current = @(@{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z" })

        $merged = Merge-ImmutableReleaseObservations -existingObservations $null -currentReleases $current -observedAt (Get-Date) -source "src"

        $merged[0].resolvedCommitSha | Should -BeNullOrEmpty
        $merged[0].tagReleaseMismatch | Should -BeNullOrEmpty
    }

    It 'Should carry through the release-integrity fields on a reappearance after deletion' {
        $existing = @(
            @{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "unknown"; status = "deleted"; observedAt = (Get-Date).AddDays(-5); source = "src" }
        )
        $current = @(@{
            releaseId              = 1
            tagName                = "v1.0.0"
            publishedAt            = "2024-01-01T00:00:00Z"
            releaseTargetCommitish = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
            resolvedCommitSha      = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
            tagReleaseMismatch     = $false
        })

        $merged = Merge-ImmutableReleaseObservations -existingObservations $existing -currentReleases $current -observedAt (Get-Date) -source "src"

        $reappeared = $merged | Where-Object { $_.status -eq "present" }
        $reappeared.resolvedCommitSha | Should -Be "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
        $reappeared.tagReleaseMismatch | Should -Be $false
    }

    It 'Should append a metadata-only backfill entry when a still-present release newly gains release-integrity context' {
        # The release was already known (e.g. from #265, before #267's SHA
        # resolution existed) with no integrity metadata at all. A later pass
        # resolves it - that metadata must not be silently discarded just
        # because the release itself was already known and still present.
        $existing = @(
            @{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "unknown"; status = "present"; observedAt = (Get-Date).AddDays(-10); source = "src" }
        )
        $current = @(@{
            releaseId              = 1
            tagName                = "v1.0.0"
            publishedAt            = "2024-01-01T00:00:00Z"
            releaseTargetCommitish = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
            resolvedCommitSha      = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
            tagReleaseMismatch     = $false
        })

        $merged = Merge-ImmutableReleaseObservations -existingObservations $existing -currentReleases $current -observedAt (Get-Date) -source "src"

        # Append-only: the original entry must still be there, untouched...
        $merged.Count | Should -Be 2
        $original = @($merged | Where-Object { $null -eq $_.resolvedCommitSha })
        $original.Count | Should -Be 1
        $original[0].immutabilityState | Should -Be "unknown"

        # ...and a new entry carries the newly resolved metadata forward,
        # preserving (never guessing a different) immutabilityState.
        $backfilled = @($merged | Where-Object { $null -ne $_.resolvedCommitSha })
        $backfilled.Count | Should -Be 1
        $backfilled[0].immutabilityState | Should -Be "unknown"
        $backfilled[0].status | Should -Be "present"
        $backfilled[0].resolvedCommitSha | Should -Be "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
    }

    It 'Should not append anything for a still-present release when neither side has new integrity metadata' {
        $existing = @(
            @{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "immutable"; status = "present"; observedAt = (Get-Date).AddDays(-10); source = "src" }
        )
        $current = @(@{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z" })

        $merged = Merge-ImmutableReleaseObservations -existingObservations $existing -currentReleases $current -observedAt (Get-Date) -source "src"

        $merged.Count | Should -Be 1
    }

    It 'Should not re-append when the prior entry already has release-integrity metadata' {
        $existing = @(
            @{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "unknown"; status = "present"; observedAt = (Get-Date).AddDays(-10); source = "src"; resolvedCommitSha = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"; releaseTargetCommitish = "main"; tagReleaseMismatch = $null }
        )
        # This pass didn't re-resolve the SHA (e.g. it's already known - see
        # GetImmutableReleaseObservations bounding), so the current release
        # carries no integrity fields at all this time.
        $current = @(@{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z" })

        $merged = Merge-ImmutableReleaseObservations -existingObservations $existing -currentReleases $current -observedAt (Get-Date) -source "src"

        $merged.Count | Should -Be 1
    }

    It 'Should append a backfill entry with the newly resolved SHA even when releaseTargetCommitish was already recorded' {
        # First attempt: releaseTargetCommitish recorded, but the tag could not
        # be resolved (resolvedCommitSha never set). A combined "any field
        # present" check would see releaseTargetCommitish alone as "already has
        # metadata" and discard a resolvedCommitSha that becomes available on a
        # later, successful attempt - each field must be compared individually.
        $existing = @(
            @{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "unknown"; status = "present"; observedAt = (Get-Date).AddDays(-10); source = "src"; resolvedCommitSha = $null; releaseTargetCommitish = "main"; tagReleaseMismatch = $null }
        )
        $current = @(@{
            releaseId              = 1
            tagName                = "v1.0.0"
            publishedAt            = "2024-01-01T00:00:00Z"
            releaseTargetCommitish = "main"
            resolvedCommitSha      = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
        })

        $merged = Merge-ImmutableReleaseObservations -existingObservations $existing -currentReleases $current -observedAt (Get-Date) -source "src"

        $merged.Count | Should -Be 2
        $backfilled = @($merged | Where-Object { $null -ne $_.resolvedCommitSha })
        $backfilled.Count | Should -Be 1
        $backfilled[0].resolvedCommitSha | Should -Be "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
        $backfilled[0].releaseTargetCommitish | Should -Be "main"
        $backfilled[0].immutabilityState | Should -Be "unknown"
    }

    It 'Should NOT append a backfill entry for releaseTargetCommitish alone, even for many pre-#267 releases at once' {
        # releaseTargetCommitish is supplied by GetImmutableReleaseObservations
        # for every current release (it comes straight off the releases list,
        # not from bounded SHA-resolution calls) - unlike resolvedCommitSha,
        # which is bounded to the newest-10 resolution window. On a pre-#267
        # migration, every still-present release in a repo's entire history
        # would otherwise gain releaseTargetCommitish at once and each get a
        # metadata-only entry appended, ballooning the append-only history far
        # beyond the bounded newest-10 SHA resolutions and risking the Azure
        # Table per-property size limit for repos with many releases.
        $existing = @(1..30 | ForEach-Object {
            @{ releaseId = $_; tagName = "v$_.0.0"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "unknown"; status = "present"; observedAt = (Get-Date).AddDays(-10); source = "src" }
        })
        # Every release now carries releaseTargetCommitish (unbounded), but
        # none have a resolvedCommitSha this pass (none were in the bounded
        # newest-10 resolution window, or none resolved successfully).
        $current = @(1..30 | ForEach-Object {
            @{ releaseId = $_; tagName = "v$_.0.0"; publishedAt = "2024-01-01T00:00:00Z"; releaseTargetCommitish = "main" }
        })

        $merged = Merge-ImmutableReleaseObservations -existingObservations $existing -currentReleases $current -observedAt (Get-Date) -source "src"

        # No new entries at all - releaseTargetCommitish alone must never trigger a backfill.
        $merged.Count | Should -Be 30
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
