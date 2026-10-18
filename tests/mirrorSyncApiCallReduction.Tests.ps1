BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Get-RepositoryDefaultBranchCommit collapsed existence+pushed_at+default_branch call" {
    It "Should return pushed_at and branch from a single repo-info call plus one branch call" {
        Mock ApiCall {
            if ($url -eq "repos/upstreamOwner/upstreamRepo") {
                return [PSCustomObject]@{ default_branch = "main"; pushed_at = "2025-12-20T00:00:00Z" }
            }
            if ($url -eq "repos/upstreamOwner/upstreamRepo/branches/main") {
                return [PSCustomObject]@{ commit = [PSCustomObject]@{ sha = "abc123" } }
            }
            throw "Unexpected URL: $url"
        }

        $result = Get-RepositoryDefaultBranchCommit -owner "upstreamOwner" -repo "upstreamRepo" -access_token "test_token"

        $result.success | Should -Be $true
        $result.sha | Should -Be "abc123"
        $result.branch | Should -Be "main"
        $result.pushed_at | Should -Be "2025-12-20T00:00:00Z"
        Should -Invoke ApiCall -Times 2
    }

    It "Should skip the repo-info call when knownDefaultBranch is provided" {
        Mock ApiCall {
            if ($url -eq "repos/upstreamOwner/upstreamRepo/branches/develop") {
                return [PSCustomObject]@{ commit = [PSCustomObject]@{ sha = "def456" } }
            }
            throw "Unexpected URL: $url"
        }

        $result = Get-RepositoryDefaultBranchCommit -owner "upstreamOwner" -repo "upstreamRepo" -access_token "test_token" -knownDefaultBranch "develop"

        $result.success | Should -Be $true
        $result.sha | Should -Be "def456"
        Should -Invoke ApiCall -Times 1
    }

    It "Should report Repository not found without a branch call when the repo does not exist" {
        Mock ApiCall { return $null }

        $result = Get-RepositoryDefaultBranchCommit -owner "ghost" -repo "repo" -access_token "test_token"

        $result.success | Should -Be $false
        $result.error | Should -Be "Repository not found"
        Should -Invoke ApiCall -Times 1
    }
}

Describe "Compare-RepositoryCommitHashes with a cached mirror SHA" {
    It "Should report in_sync using only the source-side call when SHAs match" {
        Mock ApiCall {
            if ($url -eq "repos/upstreamOwner/upstreamRepo") {
                return [PSCustomObject]@{ default_branch = "main"; pushed_at = "2025-12-20T00:00:00Z" }
            }
            if ($url -eq "repos/upstreamOwner/upstreamRepo/branches/main") {
                return [PSCustomObject]@{ commit = [PSCustomObject]@{ sha = "same-sha" } }
            }
            throw "Unexpected URL called: $url (mirror side should not be queried)"
        }

        $result = Compare-RepositoryCommitHashes -sourceOwner "upstreamOwner" -sourceRepo "upstreamRepo" -mirrorOwner "mirrorOrg" -mirrorRepo "mirrorRepo" -access_token "test_token" -knownMirrorSha "same-sha"

        $result.can_compare | Should -Be $true
        $result.in_sync | Should -Be $true
        $result.used_cached_mirror_sha | Should -Be $true
        # Only the 2 upstream calls (repo-info + branch) should have happened
        Should -Invoke ApiCall -Times 2
    }

    It "Should report not in_sync using only the source-side call when SHAs differ" {
        Mock ApiCall {
            if ($url -eq "repos/upstreamOwner/upstreamRepo") {
                return [PSCustomObject]@{ default_branch = "main"; pushed_at = "2025-12-20T00:00:00Z" }
            }
            if ($url -eq "repos/upstreamOwner/upstreamRepo/branches/main") {
                return [PSCustomObject]@{ commit = [PSCustomObject]@{ sha = "new-upstream-sha" } }
            }
            throw "Unexpected URL called: $url (mirror side should not be queried)"
        }

        $result = Compare-RepositoryCommitHashes -sourceOwner "upstreamOwner" -sourceRepo "upstreamRepo" -mirrorOwner "mirrorOrg" -mirrorRepo "mirrorRepo" -access_token "test_token" -knownMirrorSha "stale-mirror-sha"

        $result.can_compare | Should -Be $true
        $result.in_sync | Should -Be $false
        $result.source_sha | Should -Be "new-upstream-sha"
        $result.mirror_sha | Should -Be "stale-mirror-sha"
        Should -Invoke ApiCall -Times 2
    }

    It "Should fall back to querying the mirror repo when no cached SHA is provided" {
        Mock ApiCall {
            if ($url -eq "repos/upstreamOwner/upstreamRepo") {
                return [PSCustomObject]@{ default_branch = "main"; pushed_at = "2025-12-20T00:00:00Z" }
            }
            if ($url -eq "repos/upstreamOwner/upstreamRepo/branches/main") {
                return [PSCustomObject]@{ commit = [PSCustomObject]@{ sha = "sha-1" } }
            }
            if ($url -eq "repos/mirrorOrg/mirrorRepo") {
                return [PSCustomObject]@{ default_branch = "main" }
            }
            if ($url -eq "repos/mirrorOrg/mirrorRepo/branches/main") {
                return [PSCustomObject]@{ commit = [PSCustomObject]@{ sha = "sha-1" } }
            }
            throw "Unexpected URL: $url"
        }

        $result = Compare-RepositoryCommitHashes -sourceOwner "upstreamOwner" -sourceRepo "upstreamRepo" -mirrorOwner "mirrorOrg" -mirrorRepo "mirrorRepo" -access_token "test_token"

        $result.can_compare | Should -Be $true
        $result.in_sync | Should -Be $true
        $result.used_cached_mirror_sha | Should -Be $false
        Should -Invoke ApiCall -Times 4
    }

    It "Should flag mirror_not_found when the mirror repo does not exist and no cached SHA is given" {
        Mock ApiCall {
            if ($url -eq "repos/upstreamOwner/upstreamRepo") {
                return [PSCustomObject]@{ default_branch = "main"; pushed_at = "2025-12-20T00:00:00Z" }
            }
            if ($url -eq "repos/upstreamOwner/upstreamRepo/branches/main") {
                return [PSCustomObject]@{ commit = [PSCustomObject]@{ sha = "sha-1" } }
            }
            if ($url -eq "repos/mirrorOrg/mirrorRepo") {
                return $null
            }
            throw "Unexpected URL: $url"
        }

        $result = Compare-RepositoryCommitHashes -sourceOwner "upstreamOwner" -sourceRepo "upstreamRepo" -mirrorOwner "mirrorOrg" -mirrorRepo "mirrorRepo" -access_token "test_token"

        $result.can_compare | Should -Be $false
        $result.mirror_not_found | Should -Be $true
    }

    It "Should flag source_not_found when the upstream repo does not exist" {
        Mock ApiCall {
            if ($url -eq "repos/upstreamOwner/upstreamRepo") {
                return $null
            }
            throw "Unexpected URL: $url"
        }

        $result = Compare-RepositoryCommitHashes -sourceOwner "upstreamOwner" -sourceRepo "upstreamRepo" -mirrorOwner "mirrorOrg" -mirrorRepo "mirrorRepo" -access_token "test_token" -knownMirrorSha "anything"

        $result.can_compare | Should -Be $false
        $result.source_not_found | Should -Be $true
        # Should not have attempted a second call for the branch
        Should -Invoke ApiCall -Times 1
    }
}

Describe "SyncMirrorWithUpstream API-call reduction" {
    It "Should have a storedMirrorSha parameter" {
        $command = Get-Command SyncMirrorWithUpstream
        $command.Parameters.Keys | Should -Contain "storedMirrorSha"
    }

    It "Should report Already up to date via cached SHA without ever calling the mirror repo" {
        Mock ApiCall {
            if ($url -eq "repos/upstreamOwner/upstreamRepo") {
                return [PSCustomObject]@{ default_branch = "main"; pushed_at = "2025-12-20T00:00:00Z" }
            }
            if ($url -eq "repos/upstreamOwner/upstreamRepo/branches/main") {
                return [PSCustomObject]@{ commit = [PSCustomObject]@{ sha = "matching-sha" } }
            }
            throw "Unexpected URL called: $url (mirror repo should not be queried when cached SHA matches)"
        }

        $result = SyncMirrorWithUpstream -owner "mirrorOrg" -repo "mirrorRepo" -upstreamOwner "upstreamOwner" -upstreamRepo "upstreamRepo" -access_token "test_token" -storedMirrorSha "matching-sha"

        $result.success | Should -Be $true
        $result.message | Should -Be "Already up to date"
        $result.mirror_sha | Should -Be "matching-sha"
        Should -Invoke ApiCall -Times 2
    }

    It "Should return upstream_not_found without any mirror-side call" {
        Mock ApiCall {
            if ($url -eq "repos/upstreamOwner/missingRepo") {
                return $null
            }
            throw "Unexpected URL: $url"
        }

        $result = SyncMirrorWithUpstream -owner "mirrorOrg" -repo "mirrorRepo" -upstreamOwner "upstreamOwner" -upstreamRepo "missingRepo" -access_token "test_token" -storedMirrorSha "some-sha"

        $result.success | Should -Be $false
        $result.error_type | Should -Be "upstream_not_found"
        Should -Invoke ApiCall -Times 1
    }

    It "Should return mirror_not_found via the API fallback when no cached SHA is available" {
        Mock ApiCall {
            if ($url -eq "repos/upstreamOwner/upstreamRepo") {
                return [PSCustomObject]@{ default_branch = "main"; pushed_at = "2025-12-20T00:00:00Z" }
            }
            if ($url -eq "repos/upstreamOwner/upstreamRepo/branches/main") {
                return [PSCustomObject]@{ commit = [PSCustomObject]@{ sha = "sha-1" } }
            }
            if ($url -eq "repos/mirrorOrg/missingMirror") {
                return $null
            }
            throw "Unexpected URL: $url"
        }

        $result = SyncMirrorWithUpstream -owner "mirrorOrg" -repo "missingMirror" -upstreamOwner "upstreamOwner" -upstreamRepo "upstreamRepo" -access_token "test_token"

        $result.success | Should -Be $false
        $result.error_type | Should -Be "mirror_not_found"
    }
}
