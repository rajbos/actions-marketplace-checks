BeforeAll {
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe 'Get-ImmutableReleaseCoverage' {
    It 'Should order releases by publishedAt descending and select only the ten newest' {
        # 12 known-immutable releases, oldest two should be dropped entirely (not just uncounted)
        $observations = @(1..12 | ForEach-Object {
            @{ releaseId = $_; tagName = "v$_.0.0"; publishedAt = (Get-Date "2024-01-01").AddDays($_); immutabilityState = "immutable"; status = "present"; observedAt = (Get-Date); source = "src" }
        })

        $result = Get-ImmutableReleaseCoverage -observations $observations

        $result.releasesConsidered | Should -Be 10
        $result.immutableCount | Should -Be 10
        $result.knownCount | Should -Be 10
        # The newest release (id 12, latest publishedAt) drives latestReleaseImmutable
        $result.latestReleaseImmutable | Should -Be "immutable"
    }

    It 'Should pick the single newest release (by publishedAt) as latestReleaseImmutable, not insertion order' {
        $observations = @(
            @{ releaseId = 1; tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "immutable"; status = "present"; observedAt = (Get-Date); source = "src" }
            @{ releaseId = 2; tagName = "v2.0.0"; publishedAt = "2024-03-01T00:00:00Z"; immutabilityState = "notImmutable"; status = "present"; observedAt = (Get-Date); source = "src" }
            @{ releaseId = 3; tagName = "v1.5.0"; publishedAt = "2024-02-01T00:00:00Z"; immutabilityState = "unknown"; status = "present"; observedAt = (Get-Date); source = "src" }
        )

        $result = Get-ImmutableReleaseCoverage -observations $observations

        $result.latestReleaseImmutable | Should -Be "notImmutable"
    }

    It 'Should not pad the denominator when fewer than ten releases are known (acceptance: no 7/10 for 8 known)' {
        # Exactly the issue's example scenario: 10 releases total, 8 with a known
        # state (7 immutable + 1 notImmutable), 2 unknown.
        $observations = @()
        for ($i = 1; $i -le 7; $i++) {
            $observations += @{ releaseId = $i; tagName = "v$i"; publishedAt = (Get-Date "2024-01-01").AddDays($i); immutabilityState = "immutable"; status = "present"; observedAt = (Get-Date); source = "src" }
        }
        $observations += @{ releaseId = 8; tagName = "v8"; publishedAt = (Get-Date "2024-01-01").AddDays(8); immutabilityState = "notImmutable"; status = "present"; observedAt = (Get-Date); source = "src" }
        $observations += @{ releaseId = 9; tagName = "v9"; publishedAt = (Get-Date "2024-01-01").AddDays(9); immutabilityState = "unknown"; status = "present"; observedAt = (Get-Date); source = "src" }
        $observations += @{ releaseId = 10; tagName = "v10"; publishedAt = (Get-Date "2024-01-01").AddDays(10); immutabilityState = "unknown"; status = "present"; observedAt = (Get-Date); source = "src" }

        $result = Get-ImmutableReleaseCoverage -observations $observations

        $result.releasesConsidered | Should -Be 10
        $result.immutableCount | Should -Be 7
        $result.notImmutableCount | Should -Be 1
        $result.unknownCount | Should -Be 2
        $result.knownCount | Should -Be 8
        # Must never report "7/10" - the denominator is knownCount (8), not releasesConsidered (10)
        $result.summary | Should -Be "7 of 8 known releases immutable (last 10; 2 unknown)"
    }

    It 'Should handle fewer than ten releases without padding or treating absence as failure' {
        $observations = @(
            @{ releaseId = 1; tagName = "v1"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "immutable"; status = "present"; observedAt = (Get-Date); source = "src" }
            @{ releaseId = 2; tagName = "v2"; publishedAt = "2024-02-01T00:00:00Z"; immutabilityState = "unknown"; status = "present"; observedAt = (Get-Date); source = "src" }
        )

        $result = Get-ImmutableReleaseCoverage -observations $observations

        $result.releasesConsidered | Should -Be 2
        $result.immutableCount | Should -Be 1
        $result.unknownCount | Should -Be 1
        $result.knownCount | Should -Be 1
        $result.summary | Should -Be "1 of 1 known releases immutable (last 2; 1 unknown)"
    }

    It 'Should return a fully unknown, zero-count summary when there are no observations at all' {
        $result = Get-ImmutableReleaseCoverage -observations $null

        $result.releasesConsidered | Should -Be 0
        $result.immutableCount | Should -Be 0
        $result.notImmutableCount | Should -Be 0
        $result.unknownCount | Should -Be 0
        $result.knownCount | Should -Be 0
        $result.latestReleaseImmutable | Should -Be "unknown"
        $result.summary | Should -Be "0 of 0 known releases immutable (last 0; 0 unknown)"
    }

    It 'Should exclude a deleted release from the count instead of treating its absence as failure' {
        $observations = @(
            @{ releaseId = 1; tagName = "v1"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "immutable"; status = "present"; observedAt = (Get-Date).AddDays(-5); source = "src" }
            @{ releaseId = 1; tagName = "v1"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "immutable"; status = "deleted"; observedAt = (Get-Date); source = "src" }
            @{ releaseId = 2; tagName = "v2"; publishedAt = "2024-02-01T00:00:00Z"; immutabilityState = "notImmutable"; status = "present"; observedAt = (Get-Date); source = "src" }
        )

        $result = Get-ImmutableReleaseCoverage -observations $observations

        # Only release 2 remains "present" - release 1 is excluded entirely, not
        # counted as unknown/failing and not padding the ten-release window.
        $result.releasesConsidered | Should -Be 1
        $result.notImmutableCount | Should -Be 1
        $result.immutableCount | Should -Be 0
        $result.latestReleaseImmutable | Should -Be "notImmutable"
    }

    It 'Should only consider the latest observation per release id (policy-change / re-observation scenario)' {
        # Simulates a release first recorded as "unknown", later re-observed by a
        # future immutability-determining collector as "immutable" - the append-only
        # history keeps both entries, but coverage must reflect only the latest one.
        $observations = @(
            @{ releaseId = 1; tagName = "v1"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "unknown"; status = "present"; observedAt = (Get-Date).AddDays(-10); source = "src" }
            @{ releaseId = 1; tagName = "v1"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "immutable"; status = "present"; observedAt = (Get-Date); source = "src" }
        )

        $result = Get-ImmutableReleaseCoverage -observations $observations

        $result.releasesConsidered | Should -Be 1
        $result.immutableCount | Should -Be 1
        $result.unknownCount | Should -Be 0
        $result.latestReleaseImmutable | Should -Be "immutable"
    }

    It 'Should treat a reappeared release (status flips deleted -> present) using its latest observation' {
        $observations = @(
            @{ releaseId = 1; tagName = "v1"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "immutable"; status = "present"; observedAt = (Get-Date).AddDays(-20); source = "src" }
            @{ releaseId = 1; tagName = "v1"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "immutable"; status = "deleted"; observedAt = (Get-Date).AddDays(-10); source = "src" }
            @{ releaseId = 1; tagName = "v1"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "immutable"; status = "present"; observedAt = (Get-Date); source = "src" }
        )

        $result = Get-ImmutableReleaseCoverage -observations $observations

        $result.releasesConsidered | Should -Be 1
        $result.immutableCount | Should -Be 1
    }

    It 'Should respect a custom releaseLimit' {
        $observations = @(1..5 | ForEach-Object {
            @{ releaseId = $_; tagName = "v$_"; publishedAt = (Get-Date "2024-01-01").AddDays($_); immutabilityState = "immutable"; status = "present"; observedAt = (Get-Date); source = "src" }
        })

        $result = Get-ImmutableReleaseCoverage -observations $observations -releaseLimit 3

        $result.releasesConsidered | Should -Be 3
        $result.summary | Should -Be "3 of 3 known releases immutable (last 3; 0 unknown)"
    }

    It 'Should not care about prerelease flags - a prerelease observation counts like any other release' {
        # Prerelease/full-release distinction happens (if at all) at collection time in
        # GetImmutableReleaseObservations; observations carry no prerelease flag, so this
        # function must treat every observation the same regardless of that upstream detail.
        $observations = @(
            @{ releaseId = 1; tagName = "v1.0.0-rc1"; publishedAt = "2024-01-01T00:00:00Z"; immutabilityState = "immutable"; status = "present"; observedAt = (Get-Date); source = "src" }
        )

        $result = Get-ImmutableReleaseCoverage -observations $observations

        $result.releasesConsidered | Should -Be 1
        $result.immutableCount | Should -Be 1
    }

    It 'Should reject a releaseLimit above 10 instead of allowing releasesConsidered to exceed the documented/schema maximum' {
        { Get-ImmutableReleaseCoverage -observations @() -releaseLimit 11 } | Should -Throw
    }

    It 'Should reject a negative releaseLimit' {
        { Get-ImmutableReleaseCoverage -observations @() -releaseLimit -1 } | Should -Throw
    }
}

Describe 'Get-ImmutableReleasePolicyChangedAt' {
    It 'Should return checkedAt for the very first observation (no existing changedAt)' {
        $checkedAt = Get-Date

        $result = Get-ImmutableReleasePolicyChangedAt -previousStatus $null -newStatus "enabled" -checkedAt $checkedAt -existingChangedAt $null

        $result | Should -Be $checkedAt
    }

    It 'Should return checkedAt when the status actually changed' {
        $checkedAt = Get-Date
        $existingChangedAt = (Get-Date).AddDays(-60)

        $result = Get-ImmutableReleasePolicyChangedAt -previousStatus "unknown" -newStatus "enabled" -checkedAt $checkedAt -existingChangedAt $existingChangedAt

        $result | Should -Be $checkedAt
    }

    It 'Should keep the existing changedAt when the status is unchanged' {
        $checkedAt = Get-Date
        $existingChangedAt = (Get-Date).AddDays(-60)

        $result = Get-ImmutableReleasePolicyChangedAt -previousStatus "enabled" -newStatus "enabled" -checkedAt $checkedAt -existingChangedAt $existingChangedAt

        $result | Should -Be $existingChangedAt
    }

    It 'Should not treat repeated "unknown" as a transition once it has already been recorded' {
        $checkedAt = Get-Date
        $existingChangedAt = (Get-Date).AddDays(-5)

        $result = Get-ImmutableReleasePolicyChangedAt -previousStatus "unknown" -newStatus "unknown" -checkedAt $checkedAt -existingChangedAt $existingChangedAt

        $result | Should -Be $existingChangedAt
    }

    It 'Should record a transition from enabled back to disabled' {
        $checkedAt = Get-Date
        $existingChangedAt = (Get-Date).AddDays(-90)

        $result = Get-ImmutableReleasePolicyChangedAt -previousStatus "enabled" -newStatus "disabled" -checkedAt $checkedAt -existingChangedAt $existingChangedAt

        $result | Should -Be $checkedAt
    }

    It 'Should not claim a policy transition on the first post-migration check when the status has not actually changed' {
        # A repo migrated from #264 already has immutableReleasePolicy = "enabled"
        # (or disabled/unknown) recorded, but immutableReleasePolicyChangedAt did
        # not exist yet before this function did. A missing existingChangedAt must
        # not by itself be treated as "first observation ever" when previousStatus
        # is already known and unchanged - that would falsely claim today as the
        # transition date for a policy that could have been unchanged for years.
        $checkedAt = Get-Date

        $result = Get-ImmutableReleasePolicyChangedAt -previousStatus "enabled" -newStatus "enabled" -checkedAt $checkedAt -existingChangedAt $null

        $result | Should -Be $null
    }
}
