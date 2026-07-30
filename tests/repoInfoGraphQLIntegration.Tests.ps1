BeforeAll {
    # Duplicates the "apply a GraphQL batch result (or fall back to REST) to an action's
    # repoInfo" decision from GetMoreInfo in repoInfo.ps1, so it can be tested without
    # executing the full script (which has top-level params/side effects). Keep this in
    # sync with the block in repoInfo.ps1 around the repoInfo staleness check.
    function Resolve-RepoInfoFromGraphQLOrRest {
        Param (
            $action,
            [hashtable] $graphqlResultsByName,
            [scriptblock] $restFallback
        )

        $graphqlEntry = $null
        if ($graphqlResultsByName.ContainsKey($action.name)) {
            $graphqlEntry = $graphqlResultsByName[$action.name]
        }

        if ($null -ne $graphqlEntry) {
            if ($graphqlEntry.NotFound) {
                return @{ UpstreamFound = $false; RepoInfo = $null; Source = "GraphQL" }
            }

            $repoData = $graphqlEntry.Data
            $latestReleasePublishedAt = $null
            if ($repoData.latestRelease) {
                $latestReleasePublishedAt = $repoData.latestRelease.publishedAt
            }

            return @{
                UpstreamFound = $true
                Source = "GraphQL"
                RepoInfo = @{
                    archived = $repoData.isArchived
                    disabled = $repoData.isDisabled
                    updated_at = $repoData.updatedAt
                    latest_release_published_at = $latestReleasePublishedAt
                }
            }
        }

        # No GraphQL result for this repo (batch failed, or it wasn't a candidate) - fall
        # back to REST, exactly like the pre-GraphQL code path did.
        return (& $restFallback)
    }
}

Describe "repoInfo.ps1 GraphQL-first repoInfo refresh" {
    Context "Repo found in the GraphQL batch" {
        It "Uses the GraphQL data instead of calling REST" {
            $restCalled = $false
            $restFallback = { $restCalled = $true; return @{ UpstreamFound = $true; RepoInfo = @{}; Source = "REST" } }.GetNewClosure()

            $graphqlResults = @{
                "ownerA_repoA" = @{
                    NotFound = $false
                    Data = @{
                        isArchived = $false
                        isDisabled = $false
                        updatedAt = "2024-03-01T00:00:00Z"
                        latestRelease = @{ tagName = "v2.0.0"; publishedAt = "2024-02-15T00:00:00Z" }
                    }
                }
            }

            $action = [PSCustomObject]@{ name = "ownerA_repoA" }
            $result = Resolve-RepoInfoFromGraphQLOrRest -action $action -graphqlResultsByName $graphqlResults -restFallback $restFallback

            $result.Source | Should -Be "GraphQL"
            $result.UpstreamFound | Should -Be $true
            $result.RepoInfo.updated_at | Should -Be "2024-03-01T00:00:00Z"
            $result.RepoInfo.latest_release_published_at | Should -Be "2024-02-15T00:00:00Z"
            $restCalled | Should -Be $false
        }
    }

    Context "Repo reported as not found by the GraphQL batch (partial-error case)" {
        It "Marks upstreamFound = false without falling back to REST" {
            $restCalled = $false
            $restFallback = { $restCalled = $true; return @{ UpstreamFound = $true; RepoInfo = @{}; Source = "REST" } }.GetNewClosure()

            $graphqlResults = @{
                "ownerB_repoB" = @{
                    NotFound = $true
                    Data = $null
                    Errors = @(@{ type = "NOT_FOUND"; path = @("r1") })
                }
            }

            $action = [PSCustomObject]@{ name = "ownerB_repoB" }
            $result = Resolve-RepoInfoFromGraphQLOrRest -action $action -graphqlResultsByName $graphqlResults -restFallback $restFallback

            $result.Source | Should -Be "GraphQL"
            $result.UpstreamFound | Should -Be $false
            $result.RepoInfo | Should -BeNullOrEmpty
            $restCalled | Should -Be $false
        }
    }

    Context "Repo missing from the GraphQL batch (batch failed or not a candidate)" {
        It "Falls back to REST" {
            # Use a shared ArrayList (mutated in place) rather than reassigning a plain
            # variable inside the scriptblock - a scriptblock invoked via "&" runs in a new
            # child scope, so plain variable assignments inside it don't propagate back out.
            $callLog = New-Object System.Collections.ArrayList
            $restFallback = { $callLog.Add($true) | Out-Null; return @{ UpstreamFound = $true; RepoInfo = @{ archived = $false }; Source = "REST" } }.GetNewClosure()

            $graphqlResults = @{}

            $action = [PSCustomObject]@{ name = "ownerC_repoC" }
            $result = Resolve-RepoInfoFromGraphQLOrRest -action $action -graphqlResultsByName $graphqlResults -restFallback $restFallback

            $result.Source | Should -Be "REST"
            $callLog.Count | Should -Be 1
        }
    }

    Context "Mixed batch: one hit, one not-found, one REST fallback" {
        It "Resolves each action independently from a single shared GraphQL results map" {
            $graphqlResults = @{
                "ownerA_repoA" = @{
                    NotFound = $false
                    Data = @{ isArchived = $false; isDisabled = $false; updatedAt = "2024-03-01T00:00:00Z" }
                }
                "ownerB_repoB" = @{
                    NotFound = $true
                    Data = $null
                }
            }

            $actions = @(
                [PSCustomObject]@{ name = "ownerA_repoA" }
                [PSCustomObject]@{ name = "ownerB_repoB" }
                [PSCustomObject]@{ name = "ownerC_repoC" }
            )

            $results = foreach ($action in $actions) {
                Resolve-RepoInfoFromGraphQLOrRest -action $action -graphqlResultsByName $graphqlResults -restFallback { return @{ UpstreamFound = $true; RepoInfo = @{ archived = $false }; Source = "REST" } }
            }

            $results[0].Source | Should -Be "GraphQL"
            $results[0].UpstreamFound | Should -Be $true

            $results[1].Source | Should -Be "GraphQL"
            $results[1].UpstreamFound | Should -Be $false

            $results[2].Source | Should -Be "REST"
        }
    }
}
