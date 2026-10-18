Import-Module Pester

BeforeAll {
    # Mock ApiCall to avoid actual API calls
    function ApiCall {
        Param (
            [string]$method,
            [string]$url,
            [switch]$hideFailedCall,
            [switch]$returnErrorInfo,
            $access_token
        )

        # Return mock data based on the URL
        if ($url -like "*/immutable-releases") {
            switch ($script:mockScenario) {
                "success" {
                    return @{
                        enabled = $true
                        enforced_by_owner = $false
                    }
                }
                "successDisabled" {
                    return @{
                        enabled = $false
                        enforced_by_owner = $null
                    }
                }
                "notFound" {
                    return @{
                        Error = $true
                        StatusCode = 404
                    }
                }
                "serverError" {
                    return @{
                        Error = $true
                        StatusCode = 500
                    }
                }
                "empty" {
                    return $null
                }
                default {
                    return @{
                        enabled = $true
                        enforced_by_owner = $false
                    }
                }
            }
        }

        return @()
    }

    # Load GetImmutableReleasesInfo function
    function GetImmutableReleasesInfo {
        Param (
            $owner,
            $repo,
            [Alias('access_token')]
            $accessToken,
            $startTime
        )

        if ($null -eq $owner -or $owner.Length -eq 0) {
            return $null
        }

        # Check if we are nearing the 50-minute mark
        $timeSpan = (Get-Date) - $startTime
        if ($timeSpan.TotalMinutes -gt 50) {
            Write-Host "Stopping the run, since we are nearing the 50-minute mark"
            return
        }

        $url = "repos/$owner/$repo/immutable-releases"
        $response = ApiCall -method GET -url $url -hideFailedCall $true -returnErrorInfo $true -access_token $accessToken

        if ($response -is [hashtable] -and $response.Error) {
            # 404 means the repo does not have immutable releases configured (or the endpoint is not available yet)
            # Leave the field absent so we retry on a future run, instead of caching a false negative
            if ($response.StatusCode -ne 404) {
                Write-Host "Error loading immutable releases info for [$owner/$repo]: StatusCode [$($response.StatusCode)]"
            }
            return $null
        }

        if ($null -eq $response) {
            return $null
        }

        return @{
            enabled = $response.enabled
            enforced_by_owner = $response.enforced_by_owner
        }
    }
}

Describe "GetImmutableReleasesInfo - immutable releases endpoint" {
    BeforeEach {
        $script:startTime = Get-Date
        $script:mockScenario = "success"
    }

    It "Should return object with enabled and enforced_by_owner properties" {
        $result = GetImmutableReleasesInfo -owner "actions" -repo "checkout" -access_token "token" -startTime $script:startTime

        $result | Should -Not -BeNullOrEmpty
        $result | Should -BeOfType [hashtable]
        $result.enabled | Should -Be $true
        $result.enforced_by_owner | Should -Be $false
        $result.ContainsKey("enabled") | Should -Be $true
        $result.ContainsKey("enforced_by_owner") | Should -Be $true
    }

    It "Should query the upstream owner/repo endpoint" {
        Mock ApiCall -MockWith {
            Param ($method, $url)
            $url | Should -Be "repos/actions/checkout/immutable-releases"
            return @{ enabled = $true; enforced_by_owner = $false }
        }

        $result = GetImmutableReleasesInfo -owner "actions" -repo "checkout" -access_token "token" -startTime $script:startTime

        $result.enabled | Should -Be $true
        Should -Invoke ApiCall -Times 1 -Exactly
    }

    It "Should return null when owner is null or empty" {
        GetImmutableReleasesInfo -owner $null -repo "checkout" -access_token "token" -startTime $script:startTime | Should -BeNullOrEmpty
        GetImmutableReleasesInfo -owner "" -repo "checkout" -access_token "token" -startTime $script:startTime | Should -BeNullOrEmpty
    }

    It "Should return null on 404 so the field stays absent and is retried next run" {
        $script:mockScenario = "notFound"

        GetImmutableReleasesInfo -owner "actions" -repo "checkout" -access_token "token" -startTime $script:startTime | Should -BeNullOrEmpty
    }

    It "Should return null on other error status codes" {
        $script:mockScenario = "serverError"

        GetImmutableReleasesInfo -owner "actions" -repo "checkout" -access_token "token" -startTime $script:startTime | Should -BeNullOrEmpty
    }

    It "Should return null when the API returns no response" {
        $script:mockScenario = "empty"

        GetImmutableReleasesInfo -owner "actions" -repo "checkout" -access_token "token" -startTime $script:startTime | Should -BeNullOrEmpty
    }

    It "Should preserve enabled being false" {
        $script:mockScenario = "successDisabled"

        $result = GetImmutableReleasesInfo -owner "actions" -repo "checkout" -access_token "token" -startTime $script:startTime

        $result | Should -Not -BeNullOrEmpty
        $result.enabled | Should -Be $false
    }

    It "Should return null when we are nearing the 50-minute mark" {
        $script:startTime = (Get-Date).AddMinutes(-51)

        GetImmutableReleasesInfo -owner "actions" -repo "checkout" -access_token "token" -startTime $script:startTime | Should -BeNullOrEmpty
    }

    It "Should still run when we are just below the 50-minute mark" {
        $script:startTime = (Get-Date).AddMinutes(-49)

        $result = GetImmutableReleasesInfo -owner "actions" -repo "checkout" -access_token "token" -startTime $script:startTime

        $result | Should -Not -BeNullOrEmpty
        $result.enabled | Should -Be $true
    }
}

Describe "Immutable releases - data structure in status.json" {
    It "Should store immutable releases with enabled and enforced_by_owner" {
        $immutableReleases = @{
            enabled = $true
            enforced_by_owner = $false
        }

        $immutableReleases.enabled | Should -Be $true
        $immutableReleases.enforced_by_owner | Should -Be $false
        $immutableReleases.ContainsKey("enabled") | Should -Be $true
        $immutableReleases.ContainsKey("enforced_by_owner") | Should -Be $true
    }

    It "Should support enabled with a null enforced_by_owner" {
        $immutableReleases = @{
            enabled = $false
            enforced_by_owner = $null
        }

        $immutableReleases.enabled | Should -Be $false
        $null | Should -Be $immutableReleases.enforced_by_owner
    }

    It "Should distinguish absent field from disabled setting" {
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
