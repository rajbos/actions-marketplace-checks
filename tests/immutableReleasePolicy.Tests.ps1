BeforeAll {
    . $PSScriptRoot/../.github/workflows/library.ps1

    # Extract and execute the real GetImmutableReleasePolicy function body from
    # repoInfo.ps1 via its AST (mirrors the "Ensure-TrivyInstalled (real implementation)"
    # pattern in tests/trivyScan.Tests.ps1), rather than redefining a local test double.
    # A test double can drift from, or keep passing despite a regression in, the actual
    # production collector - extracting the real function's text and Invoke-Expression'ing
    # it here means these tests exercise the same code that repoInfo.ps1 runs.
    $repoInfoPath = "$PSScriptRoot/../.github/workflows/repoInfo.ps1"
    $src = Get-Content $repoInfoPath -Raw
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
    $fnAst = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'GetImmutableReleasePolicy' }, $true)
    if ($fnAst.Count -ne 1) { throw "Expected exactly 1 GetImmutableReleasePolicy function in repoInfo.ps1, found $($fnAst.Count)" }
    Invoke-Expression $fnAst[0].Extent.Text
}

Describe 'GetImmutableReleasePolicy' {
    BeforeEach {
        Mock ApiCall { }
    }

    It 'Should return unknown with missing_owner_or_repo when owner is null' {
        $result = GetImmutableReleasePolicy -owner $null -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.status | Should -Be "unknown"
        $result.reason | Should -Be "missing_owner_or_repo"
    }

    It 'Should return unknown with missing_owner_or_repo when owner is empty' {
        $result = GetImmutableReleasePolicy -owner "" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.status | Should -Be "unknown"
        $result.reason | Should -Be "missing_owner_or_repo"
    }

    It 'Should return unknown with missing_owner_or_repo when repo is empty' {
        $result = GetImmutableReleasePolicy -owner "test-owner" -repo "" -accessToken "token" -startTime (Get-Date)

        $result.status | Should -Be "unknown"
        $result.reason | Should -Be "missing_owner_or_repo"
    }

    It 'Should return unknown with run_time_budget_exceeded when nearing the 50-minute mark' {
        $startTime = (Get-Date).AddMinutes(-51)

        $result = GetImmutableReleasePolicy -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime $startTime

        $result.status | Should -Be "unknown"
        $result.reason | Should -Be "run_time_budget_exceeded"
    }

    It 'Should never report disabled when the API response is missing the policy field' {
        Mock ApiCall {
            # Simulates a normal repo response that simply does not carry the field yet
            return @{
                name = "test-repo"
                full_name = "test-owner/test-repo"
            }
        }

        $result = GetImmutableReleasePolicy -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.status | Should -Be "unknown"
        $result.status | Should -Not -Be "disabled"
        $result.reason | Should -Be "field_not_present_in_api_response"
    }

    It 'Should return unknown when the policy field is present but null' {
        Mock ApiCall {
            return @{
                name = "test-repo"
                immutable_releases_enabled = $null
            }
        }

        $result = GetImmutableReleasePolicy -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.status | Should -Be "unknown"
        $result.reason | Should -Be "field_null_in_api_response"
    }

    It 'Should return enabled when the API reports the policy is turned on' {
        Mock ApiCall {
            return @{
                name = "test-repo"
                immutable_releases_enabled = $true
            }
        }

        $result = GetImmutableReleasePolicy -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.status | Should -Be "enabled"
        $result.reason | Should -Be $null
    }

    It 'Should return disabled when the API reports the policy is turned off' {
        Mock ApiCall {
            return @{
                name = "test-repo"
                immutable_releases_enabled = $false
            }
        }

        $result = GetImmutableReleasePolicy -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.status | Should -Be "disabled"
        $result.reason | Should -Be $null
    }

    It 'Should return unknown with repo_not_found on a 404 from ApiCall' {
        Mock ApiCall {
            return @{
                Error = $true
                StatusCode = 404
                Message = "Not Found"
                Url = "/repos/test-owner/test-repo"
            }
        }

        $result = GetImmutableReleasePolicy -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.status | Should -Be "unknown"
        $result.reason | Should -Be "repo_not_found"
    }

    It 'Should return unknown with forbidden_or_rate_limited on a 403 from ApiCall' {
        Mock ApiCall {
            return @{
                Error = $true
                StatusCode = 403
                Message = "Forbidden"
                Url = "/repos/test-owner/test-repo"
            }
        }

        $result = GetImmutableReleasePolicy -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.status | Should -Be "unknown"
        $result.reason | Should -Be "forbidden_or_rate_limited"
    }

    It 'Should return unknown with a status-coded reason for other API errors' {
        Mock ApiCall {
            return @{
                Error = $true
                StatusCode = 500
                Message = "Internal Server Error"
                Url = "/repos/test-owner/test-repo"
            }
        }

        $result = GetImmutableReleasePolicy -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.status | Should -Be "unknown"
        $result.reason | Should -Be "api_error_status_500"
    }

    It 'Should return unknown with transient_error when ApiCall throws' {
        Mock ApiCall {
            throw "boom"
        }

        $result = GetImmutableReleasePolicy -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.status | Should -Be "unknown"
        $result.reason | Should -Be "transient_error"
    }

    It 'Should return unknown with no_response when ApiCall returns null' {
        Mock ApiCall { return $null }

        $result = GetImmutableReleasePolicy -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.status | Should -Be "unknown"
        $result.reason | Should -Be "no_response"
    }

    It 'Should always include checkedAt and source for auditing regardless of outcome' {
        Mock ApiCall {
            return @{
                immutable_releases_enabled = $true
            }
        }

        $result = GetImmutableReleasePolicy -owner "test-owner" -repo "test-repo" -accessToken "token" -startTime (Get-Date)

        $result.checkedAt | Should -Not -Be $null
        $result.source | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-RepoPriorityScore for immutableReleasePolicy staleness' {
    It 'Should score a repo missing immutableReleasePolicy entirely' {
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
        $score | Should -BeGreaterOrEqual 20
    }

    It 'Should score a repo whose immutableReleasePolicyCheckedAt is older than 30 days' {
        $action = [PSCustomObject]@{
            owner = "test-owner"
            name = "test-owner_test-repo"
            mirrorFound = $true
            actionType = @{ actionType = "Node" }
            repoInfo = @{ updated_at = (Get-Date).ToString("o"); lastFetched = (Get-Date) }
            repoSize = 100
            dependents = @{ dependents = "1"; dependentsLastUpdated = (Get-Date) }
            immutableReleasePolicy = "unknown"
            immutableReleasePolicyCheckedAt = (Get-Date).AddDays(-31)
        }

        $score = Get-RepoPriorityScore -action $action
        $score | Should -BeGreaterOrEqual 20
    }

    It 'Should not add immutableReleasePolicy staleness score when recently checked' {
        $recentAction = [PSCustomObject]@{
            owner = "test-owner"
            name = "test-owner_test-repo"
            mirrorFound = $true
            actionType = @{ actionType = "Node" }
            repoInfo = @{ updated_at = (Get-Date).ToString("o"); lastFetched = (Get-Date) }
            repoSize = 100
            dependents = @{ dependents = "1"; dependentsLastUpdated = (Get-Date) }
            immutableReleasePolicy = "enabled"
            immutableReleasePolicyCheckedAt = (Get-Date).AddDays(-1)
        }

        $staleAction = $recentAction | Select-Object *
        $staleAction.immutableReleasePolicyCheckedAt = (Get-Date).AddDays(-31)

        $recentScore = Get-RepoPriorityScore -action $recentAction
        $staleScore = Get-RepoPriorityScore -action $staleAction

        $staleScore | Should -BeGreaterThan $recentScore
    }
}
