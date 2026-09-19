BeforeAll {
    . $PSScriptRoot/../.github/workflows/library.ps1

    # Define GetImmutableReleasePolicy inline (mirrors .github/workflows/repoInfo.ps1)
    # to avoid loading repoInfo.ps1's script-level code, matching the pattern used by
    # tests/fundingInfo.Tests.ps1.
    function GetImmutableReleasePolicy {
        Param (
            $owner,
            $repo,
            [Alias('access_token')]
            $accessToken,
            $startTime
        )

        $checkedAt = Get-Date
        $source = "GET /repos/{owner}/{repo}"

        function New-UnknownImmutableReleasePolicyResult {
            Param ([string] $reason)
            return @{
                status    = "unknown"
                checkedAt = $checkedAt
                reason    = $reason
                source    = $source
            }
        }

        if ($null -eq $owner -or $owner.Length -eq 0 -or $null -eq $repo -or $repo.Length -eq 0) {
            return New-UnknownImmutableReleasePolicyResult -reason "missing_owner_or_repo"
        }

        $timeSpan = (Get-Date) - $startTime
        if ($timeSpan.TotalMinutes -gt 50) {
            Write-Host "Stopping the run, since we are nearing the 50-minute mark"
            return New-UnknownImmutableReleasePolicyResult -reason "run_time_budget_exceeded"
        }

        $url = "/repos/$owner/$repo"
        $response = $null
        try {
            $response = ApiCall -method GET -url $url -hideFailedCall $true -returnErrorInfo $true -access_token $accessToken
        }
        catch {
            Write-Debug "Failed to check immutable release policy for [$owner/$repo]: $($_.Exception.Message)"
            return New-UnknownImmutableReleasePolicyResult -reason "transient_error"
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
            return New-UnknownImmutableReleasePolicyResult -reason $reason
        }

        if ($null -eq $response) {
            return New-UnknownImmutableReleasePolicyResult -reason "no_response"
        }

        $hasPolicyField = $false
        if ($response -is [System.Collections.IDictionary]) {
            $hasPolicyField = $response.ContainsKey('immutable_releases_enabled')
        }
        else {
            $hasPolicyField = $null -ne $response.PSObject.Properties['immutable_releases_enabled']
        }
        if (!$hasPolicyField) {
            return New-UnknownImmutableReleasePolicyResult -reason "field_not_present_in_api_response"
        }

        $policyValue = $response.immutable_releases_enabled
        if ($null -eq $policyValue) {
            return New-UnknownImmutableReleasePolicyResult -reason "field_null_in_api_response"
        }

        $status = if ($policyValue) { "enabled" } else { "disabled" }
        return @{
            status    = $status
            checkedAt = $checkedAt
            reason    = $null
            source    = $source
        }
    }
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
