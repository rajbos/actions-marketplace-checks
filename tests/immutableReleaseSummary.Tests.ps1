BeforeAll {
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe 'Get-ImmutableReleaseSummary' {
    Context 'Policy state rendering (issue #267)' {
        It 'Should render "Enabled" for an enabled policy' {
            $coverage = @{ releasesConsidered = 10; immutableCount = 7; notImmutableCount = 1; unknownCount = 2; knownCount = 8; latestReleaseImmutable = "immutable"; summary = "7 of 8 known releases immutable (last 10; 2 unknown)" }

            $result = Get-ImmutableReleaseSummary -policyStatus "enabled" -coverage $coverage

            $result | Should -Be "Enabled; 7 of 8 known releases immutable (last 10; 2 unknown)"
        }

        It 'Should render "Disabled" for a disabled policy' {
            $coverage = @{ releasesConsidered = 3; immutableCount = 0; notImmutableCount = 3; unknownCount = 0; knownCount = 3; latestReleaseImmutable = "notImmutable"; summary = "0 of 3 known releases immutable (last 3; 0 unknown)" }

            $result = Get-ImmutableReleaseSummary -policyStatus "disabled" -coverage $coverage

            $result | Should -Be "Disabled; 0 of 3 known releases immutable (last 3; 0 unknown)"
        }

        It 'Should render "Unknown" when the policy has never been checked ($null)' {
            $coverage = @{ releasesConsidered = 5; immutableCount = 2; notImmutableCount = 0; unknownCount = 3; knownCount = 2; latestReleaseImmutable = "unknown"; summary = "2 of 2 known releases immutable (last 5; 3 unknown)" }

            $result = Get-ImmutableReleaseSummary -policyStatus $null -coverage $coverage

            $result | Should -Be "Unknown; 2 of 2 known releases immutable (last 5; 3 unknown)"
        }

        It 'Should render "Unknown" when the policy status is explicitly "unknown"' {
            $coverage = @{ releasesConsidered = 1; immutableCount = 0; notImmutableCount = 0; unknownCount = 1; knownCount = 0; latestReleaseImmutable = "unknown"; summary = "0 of 0 known releases immutable (last 1; 1 unknown)" }

            $result = Get-ImmutableReleaseSummary -policyStatus "unknown" -coverage $coverage

            $result | Should -Be "Unknown; 0 of 0 known releases immutable (last 1; 1 unknown)"
        }

        It 'Should not collapse an unrecognized policy value into enabled/disabled' {
            $coverage = @{ releasesConsidered = 1; immutableCount = 1; notImmutableCount = 0; unknownCount = 0; knownCount = 1; latestReleaseImmutable = "immutable"; summary = "1 of 1 known releases immutable (last 1; 0 unknown)" }

            $result = Get-ImmutableReleaseSummary -policyStatus "some-future-value" -coverage $coverage

            $result | Should -Be "Unknown; 1 of 1 known releases immutable (last 1; 0 unknown)"
        }
    }

    Context 'No release history available yet' {
        It 'Should render a placeholder when coverage is $null' {
            $result = Get-ImmutableReleaseSummary -policyStatus "enabled" -coverage $null

            $result | Should -Be "Enabled; no release history available"
        }

        It 'Should render a placeholder when coverage has zero releases considered' {
            $coverage = @{ releasesConsidered = 0; immutableCount = 0; notImmutableCount = 0; unknownCount = 0; knownCount = 0; latestReleaseImmutable = "unknown"; summary = "0 of 0 known releases immutable (last 0; 0 unknown)" }

            $result = Get-ImmutableReleaseSummary -policyStatus "disabled" -coverage $coverage

            $result | Should -Be "Disabled; no release history available"
        }
    }

    Context 'Mixed historical coverage never overclaims' {
        It 'Should never collapse unknown counts into the known/immutable numerator' {
            $coverage = @{ releasesConsidered = 10; immutableCount = 3; notImmutableCount = 2; unknownCount = 5; knownCount = 5; latestReleaseImmutable = "unknown"; summary = "3 of 5 known releases immutable (last 10; 5 unknown)" }

            $result = Get-ImmutableReleaseSummary -policyStatus "enabled" -coverage $coverage

            # The rendered string must still show the "5 unknown" bucket explicitly,
            # not just "3 of 5" as if that were the whole picture.
            $result | Should -Match "5 unknown"
            $result | Should -Be "Enabled; 3 of 5 known releases immutable (last 10; 5 unknown)"
        }
    }
}
