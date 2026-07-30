BeforeAll {
    # PSGraphQL isn't installed in the test environment; define a stub so Pester has a
    # real command to intercept with Mock (the workflow installs the real module before
    # any of this code runs - see Install-ModuleWithRetry -ModuleName "PSGraphQL").
    function Invoke-GraphQLQuery {
        Param ($Query, $Variables, $Uri, $Headers, [switch] $Raw)
    }

    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Invoke-GraphQLRepoMetadataBatch" {
    Context "Empty input" {
        It "Returns an empty result without calling GraphQL" {
            Mock -CommandName Invoke-GraphQLQuery -MockWith { throw "should not be called" }

            $result = Invoke-GraphQLRepoMetadataBatch -RepoPairs @() -accessToken "token"

            $result.Results.Count | Should -Be 0
            $result.RateLimit | Should -BeNullOrEmpty
            $result.Failed | Should -Be $false
            Should -Invoke -CommandName Invoke-GraphQLQuery -Times 0
        }
    }

    Context "Successful batch with a partial per-alias error" {
        BeforeEach {
            # Mock + the call under test both live in BeforeEach (not BeforeAll) so each
            # It block gets its own tracked Invoke-GraphQLQuery call count - Pester resets
            # mock call history per test, so a call made once in a Context-level BeforeAll
            # would not be visible to "Should -Invoke" inside individual It blocks.
            $script:mockResponse = @{
                data = @{
                    r0 = @{
                        isArchived = $false
                        isDisabled = $false
                        pushedAt = "2024-01-01T00:00:00Z"
                        updatedAt = "2024-01-02T00:00:00Z"
                        diskUsage = 123
                        stargazerCount = 5
                        defaultBranchRef = @{ name = "main"; target = @{ oid = "abc123" } }
                        fundingLinks = @(@{ platform = "GITHUB"; url = "https://github.com/sponsors/ownerA" })
                        latestRelease = @{ tagName = "v1.0.0"; publishedAt = "2024-01-01T00:00:00Z" }
                        refs = @{ nodes = @(@{ name = "v1.0.0"; target = @{ oid = "abc123" } }) }
                    }
                    r1 = $null
                    rateLimit = @{ cost = 2; remaining = 4998; resetAt = "2024-01-01T01:00:00Z"; limit = 5000 }
                }
                errors = @(
                    @{
                        type = "NOT_FOUND"
                        path = @("r1")
                        message = "Could not resolve to a Repository with the name 'repoB'."
                    }
                )
            }
            $script:mockResponseJson = $script:mockResponse | ConvertTo-Json -Depth 10

            Mock -CommandName Invoke-GraphQLQuery -MockWith { $script:mockResponseJson }

            $script:repoPairs = @(
                @{ Owner = "ownerA"; Repo = "repoA"; Name = "ownerA_repoA" }
                @{ Owner = "ownerB"; Repo = "repoB"; Name = "ownerB_repoB" }
            )

            $script:result = Invoke-GraphQLRepoMetadataBatch -RepoPairs $script:repoPairs -accessToken "token"
        }

        It "Calls the GraphQL endpoint exactly once for the whole batch" {
            Should -Invoke -CommandName Invoke-GraphQLQuery -Times 1
        }

        It "Builds a query with one aliased repository field per repo" {
            Should -Invoke -CommandName Invoke-GraphQLQuery -ParameterFilter {
                $Query -match "r0: repository\(owner: \`$owner0, name: \`$name0\)" -and
                $Query -match "r1: repository\(owner: \`$owner1, name: \`$name1\)" -and
                $Query -match "rateLimit \{ cost remaining resetAt limit \}"
            }
        }

        It "Passes owner/name pairs as GraphQL variables" {
            Should -Invoke -CommandName Invoke-GraphQLQuery -ParameterFilter {
                $parsedVars = $Variables | ConvertFrom-Json
                $parsedVars.owner0 -eq "ownerA" -and $parsedVars.name0 -eq "repoA" -and
                $parsedVars.owner1 -eq "ownerB" -and $parsedVars.name1 -eq "repoB"
            }
        }

        It "Maps the found repo's data by fork name" {
            $entry = $script:result.Results["ownerA_repoA"]
            $entry | Should -Not -BeNullOrEmpty
            $entry.NotFound | Should -Be $false
            $entry.Data.isArchived | Should -Be $false
            # ConvertFrom-Json auto-parses ISO-8601-looking strings into [datetime], and a
            # bare [datetime] cast of a literal "Z" string can land in local Kind - compare
            # normalized UTC instants rather than exact string/Kind formatting.
            ([datetime]$entry.Data.updatedAt).ToUniversalTime() | Should -Be ([datetime]"2024-01-02T00:00:00Z").ToUniversalTime()
            ([datetime]$entry.Data.latestRelease.publishedAt).ToUniversalTime() | Should -Be ([datetime]"2024-01-01T00:00:00Z").ToUniversalTime()
        }

        It "Marks the missing/renamed repo as NotFound and attaches its error" {
            $entry = $script:result.Results["ownerB_repoB"]
            $entry | Should -Not -BeNullOrEmpty
            $entry.NotFound | Should -Be $true
            $entry.Data | Should -BeNullOrEmpty
            $entry.Errors.Count | Should -Be 1
            $entry.Errors[0].type | Should -Be "NOT_FOUND"
        }

        It "Does not let one alias's error affect the other alias's result" {
            $script:result.Results["ownerA_repoA"].NotFound | Should -Be $false
        }

        It "Surfaces the rateLimit cost/remaining/resetAt from the query" {
            $script:result.RateLimit.cost | Should -Be 2
            $script:result.RateLimit.remaining | Should -Be 4998
            ([datetime]$script:result.RateLimit.resetAt).ToUniversalTime() | Should -Be ([datetime]"2024-01-01T01:00:00Z").ToUniversalTime()
        }

        It "Does not mark the batch as Failed" {
            $script:result.Failed | Should -Be $false
        }
    }

    Context "Repo pairs with missing owner or repo are skipped" {
        It "Excludes entries with blank Owner/Repo from the query and results" {
            $mockResponse = @{
                data = @{
                    r0 = @{ isArchived = $false; isDisabled = $false; updatedAt = "2024-01-02T00:00:00Z" }
                    rateLimit = @{ cost = 1; remaining = 4999; resetAt = "2024-01-01T01:00:00Z"; limit = 5000 }
                }
            }
            $mockResponseJson = $mockResponse | ConvertTo-Json -Depth 10
            Mock -CommandName Invoke-GraphQLQuery -MockWith { $mockResponseJson }

            $repoPairs = @(
                @{ Owner = ""; Repo = ""; Name = "invalid_entry" }
                @{ Owner = "ownerA"; Repo = "repoA"; Name = "ownerA_repoA" }
            )

            $result = Invoke-GraphQLRepoMetadataBatch -RepoPairs $repoPairs -accessToken "token"

            $result.Results.ContainsKey("invalid_entry") | Should -Be $false
            $result.Results.ContainsKey("ownerA_repoA") | Should -Be $true
        }
    }

    Context "GraphQL request failure" {
        It "Returns Failed = true and an empty Results hashtable" {
            Mock -CommandName Invoke-GraphQLQuery -MockWith { throw "network error" }

            $repoPairs = @(@{ Owner = "ownerA"; Repo = "repoA"; Name = "ownerA_repoA" })
            $result = Invoke-GraphQLRepoMetadataBatch -RepoPairs $repoPairs -accessToken "token"

            $result.Failed | Should -Be $true
            $result.Results.Count | Should -Be 0
        }
    }
}
