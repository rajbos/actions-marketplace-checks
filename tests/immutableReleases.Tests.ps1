BeforeAll {
    . $PSScriptRoot/../.github/workflows/library.ps1

    # Extract and execute the real GetImmutableReleasesInfo function body from
    # repoInfo.ps1 via its AST (mirrors the GetImmutableReleasePolicy pattern in
    # tests/immutableReleasePolicy.Tests.ps1), rather than redefining a local test
    # double. A test double can drift from, or keep passing despite a regression in,
    # the actual production collector - extracting the real function's text and
    # Invoke-Expression'ing it here means these tests exercise the same code that
    # repoInfo.ps1 runs. Only ApiCall is mocked.
    $repoInfoPath = "$PSScriptRoot/../.github/workflows/repoInfo.ps1"
    $src = Get-Content $repoInfoPath -Raw
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
    $fnAst = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'GetImmutableReleasesInfo' }, $true)
    if ($fnAst.Count -ne 1) { throw "Expected exactly 1 GetImmutableReleasesInfo function in repoInfo.ps1, found $($fnAst.Count)" }
    Invoke-Expression $fnAst[0].Extent.Text
}

Describe 'GetImmutableReleasesInfo' {
    BeforeEach {
        Mock ApiCall { }
    }

    It 'Should return object with enabled and enforced_by_owner properties' {
        Mock ApiCall {
            return @{
                enabled = $true
                enforced_by_owner = $false
            }
        }

        $result = GetImmutableReleasesInfo -owner "actions" -repo "checkout" -accessToken "token" -startTime (Get-Date)

        $result | Should -Not -BeNullOrEmpty
        $result | Should -BeOfType [hashtable]
        $result.enabled | Should -Be $true
        $result.enforced_by_owner | Should -Be $false
        $result.ContainsKey("enabled") | Should -Be $true
        $result.ContainsKey("enforced_by_owner") | Should -Be $true
    }

    It 'Should query the upstream owner/repo endpoint' {
        Mock ApiCall {
            Param ($method, $url)
            $url | Should -Be "repos/actions/checkout/immutable-releases"
            return @{ enabled = $true; enforced_by_owner = $false }
        }

        $result = GetImmutableReleasesInfo -owner "actions" -repo "checkout" -accessToken "token" -startTime (Get-Date)

        $result.enabled | Should -Be $true
        Should -Invoke ApiCall -Times 1 -Exactly
    }

    It 'Should return null when owner is null or empty' {
        GetImmutableReleasesInfo -owner $null -repo "checkout" -accessToken "token" -startTime (Get-Date) | Should -BeNullOrEmpty
        GetImmutableReleasesInfo -owner "" -repo "checkout" -accessToken "token" -startTime (Get-Date) | Should -BeNullOrEmpty
    }

    It 'Should return null on 404 so the field stays absent and is retried next run' {
        Mock ApiCall {
            return @{
                Error = $true
                StatusCode = 404
            }
        }

        GetImmutableReleasesInfo -owner "actions" -repo "checkout" -accessToken "token" -startTime (Get-Date) | Should -BeNullOrEmpty
    }

    It 'Should return null on other error status codes' {
        Mock ApiCall {
            return @{
                Error = $true
                StatusCode = 500
            }
        }

        GetImmutableReleasesInfo -owner "actions" -repo "checkout" -accessToken "token" -startTime (Get-Date) | Should -BeNullOrEmpty
    }

    It 'Should return null when the API returns no response' {
        Mock ApiCall { return $null }

        GetImmutableReleasesInfo -owner "actions" -repo "checkout" -accessToken "token" -startTime (Get-Date) | Should -BeNullOrEmpty
    }

    It 'Should preserve enabled being false' {
        Mock ApiCall {
            return @{
                enabled = $false
                enforced_by_owner = $null
            }
        }

        $result = GetImmutableReleasesInfo -owner "actions" -repo "checkout" -accessToken "token" -startTime (Get-Date)

        $result | Should -Not -BeNullOrEmpty
        $result.enabled | Should -Be $false
    }

    It 'Should return null when we are nearing the 50-minute mark' {
        $startTime = (Get-Date).AddMinutes(-51)

        GetImmutableReleasesInfo -owner "actions" -repo "checkout" -accessToken "token" -startTime $startTime | Should -BeNullOrEmpty
    }

    It 'Should still run when we are just below the 50-minute mark' {
        Mock ApiCall { return @{ enabled = $true; enforced_by_owner = $false } }

        $startTime = (Get-Date).AddMinutes(-49)

        $result = GetImmutableReleasesInfo -owner "actions" -repo "checkout" -accessToken "token" -startTime $startTime

        $result | Should -Not -BeNullOrEmpty
        $result.enabled | Should -Be $true
    }
}

Describe 'Test-ImmutableReleasesNeedsRefresh' {
    It 'Should need a refresh when the field is missing entirely' {
        $action = [pscustomobject]@{
            owner = "actions"
            name = "checkout"
        }

        Test-ImmutableReleasesNeedsRefresh -action $action | Should -Be $true
    }

    It 'Should need a refresh when immutableReleasesCheckedAt is missing' {
        $action = [pscustomobject]@{
            immutableReleases = @{ enabled = $true }
        }

        Test-ImmutableReleasesNeedsRefresh -action $action | Should -Be $true
    }

    It 'Should need a refresh when immutableReleasesCheckedAt is null' {
        $action = [pscustomobject]@{
            immutableReleases = @{ enabled = $true }
            immutableReleasesCheckedAt = $null
        }

        Test-ImmutableReleasesNeedsRefresh -action $action | Should -Be $true
    }

    It 'Should need a refresh when the setting is null even with a recent checked-at timestamp' {
        # Regression test: a null setting is not a collected setting - it must not be
        # treated as fresh for up to 30 days just because immutableReleasesCheckedAt
        # happens to be recent.
        $action = [pscustomobject]@{
            immutableReleases = $null
            immutableReleasesCheckedAt = Get-Date
        }

        Test-ImmutableReleasesNeedsRefresh -action $action | Should -Be $true
    }

    It 'Should keep a collected disabled setting (enabled = $false) valid without refresh' {
        $action = [pscustomobject]@{
            immutableReleases = @{ enabled = $false }
            immutableReleasesCheckedAt = (Get-Date).AddDays(-1)
        }

        Test-ImmutableReleasesNeedsRefresh -action $action | Should -Be $false
    }

    It 'Should not need a refresh when the last check is within 30 days' {
        $action = [pscustomobject]@{
            immutableReleases = @{ enabled = $false }
            immutableReleasesCheckedAt = (Get-Date).AddDays(-29)
        }

        Test-ImmutableReleasesNeedsRefresh -action $action | Should -Be $false
    }

    It 'Should need a refresh when the last check is older than 30 days' {
        $action = [pscustomobject]@{
            immutableReleases = @{ enabled = $false }
            immutableReleasesCheckedAt = (Get-Date).AddDays(-31)
        }

        Test-ImmutableReleasesNeedsRefresh -action $action | Should -Be $true
    }

    It 'Should need a refresh when the checked-at timestamp is malformed' {
        $action = [pscustomobject]@{
            immutableReleases = @{ enabled = $true }
            immutableReleasesCheckedAt = "not-a-date"
        }

        Test-ImmutableReleasesNeedsRefresh -action $action | Should -Be $true
    }
}

Describe 'Immutable releases refresh picks up upstream changes' {
    # Regression test for the review comment: after the first successful fetch the
    # collector must not be guarded off forever (including when enabled is false) -
    # once immutableReleasesCheckedAt is stale, the next check must re-fetch and
    # replace the stored value with the changed upstream response.
    It 'Should re-fetch and replace a stale stored setting with the changed upstream response' {
        $action = [pscustomobject]@{
            owner = "actions"
            name = "checkout"
            immutableReleases = @{ enabled = $true; enforced_by_owner = $false }
            immutableReleasesCheckedAt = (Get-Date).AddDays(-31)
        }

        # The stored setting is stale, so the collector runs again
        Test-ImmutableReleasesNeedsRefresh -action $action | Should -Be $true

        # The upstream response changed between checks: enabled flipped to false
        Mock ApiCall {
            return @{
                enabled = $false
                enforced_by_owner = $null
            }
        }
        $freshInfo = GetImmutableReleasesInfo -owner "actions" -repo "checkout" -accessToken "token" -startTime (Get-Date)

        # Mirrors the loop's update path: an existing field is overwritten, and the
        # checked-at timestamp is bumped so the new value holds for the next 30 days
        $action.immutableReleases = $freshInfo
        $action.immutableReleasesCheckedAt = Get-Date

        $action.immutableReleases.enabled | Should -Be $false
        Test-ImmutableReleasesNeedsRefresh -action $action | Should -Be $false
    }

    It 'Should not re-fetch a fresh stored setting' {
        $action = [pscustomobject]@{
            immutableReleases = @{ enabled = $true; enforced_by_owner = $false }
            immutableReleasesCheckedAt = (Get-Date).AddDays(-1)
        }

        Test-ImmutableReleasesNeedsRefresh -action $action | Should -Be $false
    }
}

Describe 'Immutable releases - data structure in status.json' {
    It 'Should store immutable releases with enabled and enforced_by_owner' {
        $immutableReleases = @{
            enabled = $true
            enforced_by_owner = $false
        }

        $immutableReleases.enabled | Should -Be $true
        $immutableReleases.enforced_by_owner | Should -Be $false
        $immutableReleases.ContainsKey("enabled") | Should -Be $true
        $immutableReleases.ContainsKey("enforced_by_owner") | Should -Be $true
    }

    It 'Should support enabled with a null enforced_by_owner' {
        $immutableReleases = @{
            enabled = $false
            enforced_by_owner = $null
        }

        $immutableReleases.enabled | Should -Be $false
        $null | Should -Be $immutableReleases.enforced_by_owner
    }

    It 'Should distinguish absent field from disabled setting' {
        # The field is absent (never fetched or endpoint not available) when the action has no immutableReleases property
        $actionWithoutField = [pscustomobject]@{
            owner = "actions"
            name = "checkout"
        }
        ($null -eq $actionWithoutField.PSObject.Properties['immutableReleases']) | Should -Be $true

        # The field is present but disabled when the endpoint returned enabled: false
        $actionDisabled = [pscustomobject]@{
            owner = "actions"
            name = "checkout"
            immutableReleases = @{ enabled = $false }
        }
        ($null -ne $actionDisabled.PSObject.Properties['immutableReleases']) | Should -Be $true
        $actionDisabled.immutableReleases.enabled | Should -Be $false
    }
}
