BeforeAll {
    # Import the validation script functions
    . $PSScriptRoot/../.github/workflows/validate-status-schema.ps1 -statusFilePath "$TestDrive/dummy.json" -ErrorAction SilentlyContinue
    
    # Create a dummy file so the script doesn't exit
    '[]' | Out-File -FilePath "$TestDrive/dummy.json" -Encoding UTF8
}

Describe "Status JSON Schema Validation" {
    Context "StatusJsonSchema class" {
        It "Should have StatusJsonSchema class defined" {
            [StatusJsonSchema] | Should -Not -BeNullOrEmpty
        }
        
        It "Should allow creating instance with properties" {
            $schema = [StatusJsonSchema]::new()
            $schema.owner = "testowner"
            $schema.name = "testname"
            $schema.owner | Should -Be "testowner"
            $schema.name | Should -Be "testname"
        }
    }
    
    Context "Test-ActionSchema function with valid objects" {
        It "Should validate minimal valid object" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                forkFound = $true
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
            $result.Errors.Count | Should -Be 0
        }
        
        It "Should validate complete object with all fields" {
            $action = @{
                owner = "nhedger"
                name = "nhedger_setup-sops"
                dependabot = $null
                forkFound = $true
                mirrorLastUpdated = $null
                repoSize = $null
                actionType = @{
                    fileFound = "No file found"
                    actionDockerType = "No file found"
                    actionType = "No file found"
                    nodeVersion = $null
                }
                repoInfo = @{
                    disabled = $false
                    archived = $false
                    updated_at = "2023-05-01T16:10:08Z"
                    latest_release_published_at = "2023-05-01T16:13:20Z"
                }
                tagInfo = "v1"
                secretScanningEnabled = $true
                releaseInfo = "v1"
                dependabotEnabled = $true
                vulnerabilityStatus = @{
                    critical = 0
                    high = 0
                    lastUpdated = "2023-05-01T22:42:34.4794677Z"
                }
                ossfDateLastUpdate = "2024-01-15"
                dependents = @{
                    dependentsLastUpdated = "2025-10-30T12:51:13.2241389+00:00"
                    dependents = "53"
                }
                verified = $false
                ossf = $true
                ossfScore = 4.4
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
            $result.Errors.Count | Should -Be 0
        }
        
        It "Should validate object with array tagInfo and releaseInfo" {
            $action = @{
                owner = "appleboy"
                name = "appleboy_ssh-action"
                dependabot = $null
                dependabotEnabled = $true
                vulnerabilityStatus = @{
                    lastUpdated = "2023-04-02T18:51:02.8315481Z"
                    critical = 0
                    high = 0
                }
                ossf = $true
                ossfScore = 4.6
                ossfDateLastUpdate = "2023-03-27"
                forkFound = $true
                mirrorLastUpdated = $null
                repoSize = $null
                actionType = @{
                    actionType = "Docker"
                    fileFound = "action.yml"
                    nodeVersion = "12"
                    actionDockerType = "Dockerfile"
                    dockerBaseImage = "appleboy/drone-ssh:1.6.10"
                }
                repoInfo = @{
                    updated_at = "2023-04-01T09:28:31Z"
                    archived = $false
                    disabled = $false
                    latest_release_published_at = "2023-02-28T09:26:50Z"
                }
                tagInfo = @("v0.0.1", "v0.0.2", "v0.0.3")
                secretScanningEnabled = $true
                releaseInfo = @("v0.1.8", "v0.1.7", "v0.1.6")
                dependents = @{
                    dependentsLastUpdated = "2025-10-18T04:12:41.1780823+00:00"
                    dependents = "127,914"
                }
                verified = $false
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
            $result.Errors.Count | Should -Be 0
        }
        
        It "Should validate Docker action with containerScan field" {
            $action = @{
                owner = "testowner"
                name = "testowner_testaction"
                forkFound = $true
                actionType = @{
                    actionType = "Docker"
                    fileFound = "action.yml"
                    actionDockerType = "Dockerfile"
                    dockerBaseImage = "ubuntu:22.04"
                    dockerfileHasCustomCode = $true
                    containerScan = @{
                        critical = 2
                        high = 5
                        lastScanned = "2025-01-10T16:00:00.000Z"
                        scanError = $null
                    }
                }
                repoInfo = @{
                    updated_at = "2023-04-01T09:28:31Z"
                    archived = $false
                    disabled = $false
                    latest_release_published_at = "2023-02-28T09:26:50Z"
                }
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
            $result.Errors.Count | Should -Be 0
        }
    }
    
    Context "Test-ActionSchema function with warnings" {
        It "Should warn when owner field is missing" {
            $action = @{
                name = "test_repo"
                forkFound = $true
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings | Should -Contain "Object 0: Missing 'owner' field"
        }
        
        It "Should warn when name field is missing" {
            $action = @{
                owner = "test-owner"
                forkFound = $true
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings | Should -Contain "Object 0: Missing 'name' field"
        }
        
        It "Should warn when vulnerabilityStatus missing critical field" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                vulnerabilityStatus = @{
                    high = 0
                    lastUpdated = "2023-05-01T22:42:34.4794677Z"
                }
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Match "vulnerabilityStatus missing 'critical' field"
        }
        
        It "Should warn when dependents missing required fields" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                dependents = @{
                    dependentsLastUpdated = "2025-10-30T12:51:13.2241389+00:00"
                }
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Match "dependents missing 'dependents' field"
        }
        
        It "Should warn when repoInfo.updated_at has wrong format" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                repoInfo = @{
                    updated_at = "not-a-date"
                    archived = $false
                    disabled = $false
                }
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Match "repoInfo.updated_at has unexpected format"
        }
        
        It "Should warn when containerScan missing critical field" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                forkFound = $true
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Dockerfile"
                    containerScan = @{
                        high = 5
                        lastScanned = "2025-01-10T16:00:00.000Z"
                    }
                }
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Match "containerScan missing 'critical' field"
        }
        
        It "Should warn when containerScan missing high field" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                forkFound = $true
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Dockerfile"
                    containerScan = @{
                        critical = 2
                        lastScanned = "2025-01-10T16:00:00.000Z"
                    }
                }
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Match "containerScan missing 'high' field"
        }
        
        It "Should warn when containerScan missing lastScanned field" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                forkFound = $true
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Dockerfile"
                    containerScan = @{
                        critical = 2
                        high = 5
                    }
                }
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Match "containerScan missing 'lastScanned' field"
        }
    }
    
    Context "immutableReleasePolicy field (issue #264)" {
        It "Should validate a repo with policy enabled" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleasePolicy = "enabled"
                immutableReleasePolicyCheckedAt = "2025-01-10T16:00:00.000Z"
                immutableReleasePolicyReason = $null
                immutableReleasePolicySource = "GET /repos/{owner}/{repo}"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
            $result.Errors.Count | Should -Be 0
        }

        It "Should validate a repo with policy unknown and a reason" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleasePolicy = "unknown"
                immutableReleasePolicyCheckedAt = "2025-01-10T16:00:00.000Z"
                immutableReleasePolicyReason = "field_not_present_in_api_response"
                immutableReleasePolicySource = "GET /repos/{owner}/{repo}"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
            $result.Warnings -join " " | Should -Not -Match "immutableReleasePolicy"
        }

        It "Should error when immutableReleasePolicy has an invalid value" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleasePolicy = "disabled_but_typo"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $false
            $result.Errors -join " " | Should -Match "immutableReleasePolicy should be one of"
        }

        It "Should never accept 'disabled' being silently produced from a missing value (only explicit strings are valid)" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleasePolicy = $null
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
            $result.Warnings.Count | Should -Be 0
        }

        It "Should warn when status is unknown but reason is missing" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleasePolicy = "unknown"
                immutableReleasePolicyCheckedAt = "2025-01-10T16:00:00.000Z"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Match "missing 'immutableReleasePolicyReason'"
        }

        It "Should warn when immutableReleasePolicyCheckedAt is missing" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleasePolicy = "enabled"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Match "missing 'immutableReleasePolicyCheckedAt'"
        }

        It "Should warn when immutableReleasePolicyCheckedAt has an unparsable format" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleasePolicy = "enabled"
                immutableReleasePolicyCheckedAt = "not-a-date"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Match "immutableReleasePolicyCheckedAt has unexpected format"
        }

        It "Should warn when immutableReleasePolicyChangedAt has an unparsable format" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleasePolicy = "enabled"
                immutableReleasePolicyCheckedAt = "2025-01-10T16:00:00.000Z"
                immutableReleasePolicyChangedAt = "not-a-date"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Match "immutableReleasePolicyChangedAt has unexpected format"
        }

        It "Should not warn when immutableReleasePolicyChangedAt is a well-formed date string" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleasePolicy = "enabled"
                immutableReleasePolicyCheckedAt = "2025-01-10T16:00:00.000Z"
                immutableReleasePolicyChangedAt = "2025-01-01T00:00:00.000Z"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Not -Match "immutableReleasePolicyChangedAt"
        }

        It "Should warn on an unparsable immutableReleasePolicyChangedAt even when immutableReleasePolicy itself is absent" {
            # A backwards-compatible record can carry immutableReleasePolicyChangedAt
            # while its policy is absent/null (e.g. a cleared/legacy record) - this
            # validation must not be skipped just because the policy block above
            # never runs for such a record.
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleasePolicyChangedAt = "not-a-date"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Match "immutableReleasePolicyChangedAt has unexpected format"
        }
    }

    Context "immutableReleaseObservations field (issue #265)" {
        It "Should validate a repo with a well-formed observation history" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseObservations = @(
                    @{
                        releaseId = 1
                        tagName = "v1.0.0"
                        publishedAt = "2025-01-10T16:00:00.000Z"
                        immutabilityState = "unknown"
                        status = "present"
                        observedAt = "2025-01-10T16:05:00.000Z"
                        source = "GET /repos/{owner}/{repo}/releases"
                    }
                )
                immutableReleaseObservationsCheckedAt = "2025-01-10T16:05:00.000Z"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
            $result.Errors.Count | Should -Be 0
        }

        It "Should validate multiple observations for the same release id (append-only history)" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseObservations = @(
                    @{
                        releaseId = 1
                        tagName = "v1.0.0"
                        publishedAt = "2025-01-10T16:00:00.000Z"
                        immutabilityState = "immutable"
                        status = "present"
                        observedAt = "2025-01-10T16:05:00.000Z"
                        source = "GET /repos/{owner}/{repo}/releases"
                    }
                    @{
                        releaseId = 1
                        tagName = "v1.0.0"
                        publishedAt = "2025-01-10T16:00:00.000Z"
                        immutabilityState = "immutable"
                        status = "deleted"
                        observedAt = "2025-02-10T16:05:00.000Z"
                        source = "GET /repos/{owner}/{repo}/releases"
                    }
                )
                immutableReleaseObservationsCheckedAt = "2025-02-10T16:05:00.000Z"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
        }

        It "Should error when an observation has an invalid immutabilityState" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseObservations = @(
                    @{
                        releaseId = 1
                        tagName = "v1.0.0"
                        immutabilityState = "definitely-immutable"
                        status = "present"
                        observedAt = "2025-01-10T16:05:00.000Z"
                    }
                )
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $false
            $result.Errors -join " " | Should -Match "immutabilityState should be one of"
        }

        It "Should error when an observation has an invalid status" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseObservations = @(
                    @{
                        releaseId = 1
                        tagName = "v1.0.0"
                        immutabilityState = "unknown"
                        status = "removed"
                        observedAt = "2025-01-10T16:05:00.000Z"
                    }
                )
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $false
            $result.Errors -join " " | Should -Match "status should be one of 'present', 'deleted'"
        }

        It "Should warn when an observation is missing releaseId or tagName" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseObservations = @(
                    @{
                        immutabilityState = "unknown"
                        status = "present"
                        observedAt = "2025-01-10T16:05:00.000Z"
                    }
                )
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Match "missing 'releaseId'"
            $result.Warnings -join " " | Should -Match "missing 'tagName'"
        }

        It "Should warn when immutableReleaseObservationsCheckedAt is missing" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseObservations = @(
                    @{
                        releaseId = 1
                        tagName = "v1.0.0"
                        immutabilityState = "unknown"
                        status = "present"
                        observedAt = "2025-01-10T16:05:00.000Z"
                    }
                )
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Match "missing 'immutableReleaseObservationsCheckedAt'"
        }

        It "Should warn when an observation's observedAt has an unparsable format" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseObservations = @(
                    @{
                        releaseId = 1
                        tagName = "v1.0.0"
                        immutabilityState = "unknown"
                        status = "present"
                        observedAt = "not-a-date"
                    }
                )
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Match "observedAt has unexpected format"
        }

        It "Should not require immutableReleaseObservations to be present at all (backwards compatible)" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
            $result.Warnings.Count | Should -Be 0
        }
    }

    Context "immutableReleaseCoverage field (issue #266)" {
        It "Should validate a well-formed coverage summary" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseCoverage = @{
                    releasesConsidered     = 10
                    immutableCount         = 7
                    notImmutableCount      = 1
                    unknownCount           = 2
                    knownCount             = 8
                    latestReleaseImmutable = "immutable"
                    summary                = "7 of 8 known releases immutable (last 10; 2 unknown)"
                }
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
            $result.Errors.Count | Should -Be 0
        }

        It "Should error when latestReleaseImmutable has an invalid value" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseCoverage = @{
                    releasesConsidered     = 1
                    immutableCount         = 1
                    notImmutableCount      = 0
                    unknownCount           = 0
                    knownCount             = 1
                    latestReleaseImmutable = "definitely-immutable"
                    summary                = "1 of 1 known releases immutable (last 1; 0 unknown)"
                }
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $false
            $result.Errors -join " " | Should -Match "latestReleaseImmutable should be one of"
        }

        It "Should error when releasesConsidered exceeds 10" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseCoverage = @{
                    releasesConsidered     = 12
                    immutableCount         = 12
                    notImmutableCount      = 0
                    unknownCount           = 0
                    knownCount             = 12
                    latestReleaseImmutable = "immutable"
                    summary                = "12 of 12 known releases immutable (last 12; 0 unknown)"
                }
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $false
            $result.Errors -join " " | Should -Match "should never exceed 10"
        }

        It "Should error when knownCount does not equal immutableCount + notImmutableCount" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseCoverage = @{
                    releasesConsidered     = 10
                    immutableCount         = 7
                    notImmutableCount      = 1
                    unknownCount           = 2
                    knownCount             = 5
                    latestReleaseImmutable = "immutable"
                    summary                = "7 of 5 known releases immutable (last 10; 2 unknown)"
                }
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $false
            $result.Errors -join " " | Should -Match "knownCount should equal immutableCount \+ notImmutableCount"
        }

        It "Should error when releasesConsidered is negative even if all counts are zero" {
            # Get-ImmutableReleaseCoverage can never produce a negative
            # releasesConsidered - this must be rejected outright rather than
            # only checked for exceeding 10.
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseCoverage = @{
                    releasesConsidered     = -1
                    immutableCount         = 0
                    notImmutableCount      = 0
                    unknownCount           = 0
                    knownCount             = 0
                    latestReleaseImmutable = "unknown"
                    summary                = "0 of 0 known releases immutable (last 0; 0 unknown)"
                }
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $false
            $result.Errors -join " " | Should -Match "releasesConsidered should be a non-negative integer"
        }

        It "Should error (not silently skip the consistency check) when a counter is missing entirely" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseCoverage = @{
                    releasesConsidered     = 10
                    immutableCount         = 7
                    notImmutableCount      = 1
                    latestReleaseImmutable = "immutable"
                    summary                = "7 of 8 known releases immutable (last 10; 2 unknown)"
                }
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $false
            $result.Errors -join " " | Should -Match "missing 'unknownCount'"
            $result.Errors -join " " | Should -Match "missing 'knownCount'"
        }

        It "Should error when releasesConsidered does not equal immutableCount + notImmutableCount + unknownCount" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseCoverage = @{
                    releasesConsidered     = 5
                    immutableCount         = 7
                    notImmutableCount      = 1
                    unknownCount           = 2
                    knownCount             = 8
                    latestReleaseImmutable = "immutable"
                    summary                = "7 of 8 known releases immutable (last 5; 2 unknown)"
                }
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $false
            $result.Errors -join " " | Should -Match "releasesConsidered should equal immutableCount \+ notImmutableCount \+ unknownCount"
        }

        It "Should error when a counter is a non-numeric type" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseCoverage = @{
                    releasesConsidered     = "10"
                    immutableCount         = 7
                    notImmutableCount      = 1
                    unknownCount           = 2
                    knownCount             = 8
                    latestReleaseImmutable = "immutable"
                    summary                = "7 of 8 known releases immutable (last 10; 2 unknown)"
                }
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $false
            $result.Errors -join " " | Should -Match "releasesConsidered should be a non-negative integer"
        }

        It "Should error when summary is a non-string value" {
            # [string]::IsNullOrWhiteSpace coerces a non-string argument before
            # checking it, so a numeric/object summary must be rejected
            # explicitly rather than relying on that check alone.
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseCoverage = @{
                    releasesConsidered     = 10
                    immutableCount         = 7
                    notImmutableCount      = 1
                    unknownCount           = 2
                    knownCount             = 8
                    latestReleaseImmutable = "immutable"
                    summary                = 12345
                }
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $false
            $result.Errors -join " " | Should -Match "immutableReleaseCoverage.summary should be a string"
        }

        It "Should not require immutableReleaseCoverage to be present at all (backwards compatible)" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
            $result.Warnings.Count | Should -Be 0
        }
    }

    Context "immutableReleaseSummary field (issue #267)" {
        It "Should validate an 'Enabled' summary with known coverage" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseSummary = "Enabled; 7 of 8 known releases immutable (last 10; 2 unknown)"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
            $result.Warnings -join " " | Should -Not -Match "immutableReleaseSummary"
        }

        It "Should validate a 'Disabled' summary" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseSummary = "Disabled; 0 of 3 known releases immutable (last 3; 0 unknown)"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
            $result.Warnings -join " " | Should -Not -Match "immutableReleaseSummary"
        }

        It "Should validate an 'Unknown' summary with no release history yet" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseSummary = "Unknown; no release history available"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
            $result.Warnings -join " " | Should -Not -Match "immutableReleaseSummary"
        }

        It "Should warn when immutableReleaseSummary does not start with a recognized policy label" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseSummary = "7 of 8 known releases immutable"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Match "does not start with a recognized policy label"
        }

        It "Should error when immutableReleaseSummary is not a string" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseSummary = @{ not = "a string" }
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $false
            $result.Errors -join " " | Should -Match "immutableReleaseSummary should be a string"
        }

        It "Should not require immutableReleaseSummary to be present at all (backwards compatible)" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
            $result.Warnings.Count | Should -Be 0
        }
    }

    Context "immutableReleaseObservations release-integrity fields (issue #267)" {
        It "Should validate an observation with a resolved commit SHA and no mismatch" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseObservations = @(
                    @{
                        releaseId              = 1
                        tagName                = "v1.0.0"
                        publishedAt            = "2025-01-01T00:00:00Z"
                        immutabilityState      = "unknown"
                        status                 = "present"
                        observedAt             = "2025-01-10T00:00:00Z"
                        source                 = "GET /repos/{owner}/{repo}/releases"
                        releaseTargetCommitish = "main"
                        resolvedCommitSha      = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
                        tagReleaseMismatch     = $null
                    }
                )
                immutableReleaseObservationsCheckedAt = "2025-01-10T00:00:00Z"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
            $result.Warnings -join " " | Should -Not -Match "resolvedCommitSha|tagReleaseMismatch"
        }

        It "Should warn when tagReleaseMismatch is set without a resolvedCommitSha" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseObservations = @(
                    @{
                        releaseId          = 1
                        tagName            = "v1.0.0"
                        publishedAt        = "2025-01-01T00:00:00Z"
                        immutabilityState  = "unknown"
                        status             = "present"
                        observedAt         = "2025-01-10T00:00:00Z"
                        source             = "GET /repos/{owner}/{repo}/releases"
                        tagReleaseMismatch = $true
                    }
                )
                immutableReleaseObservationsCheckedAt = "2025-01-10T00:00:00Z"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Match "tagReleaseMismatch is set without a 'resolvedCommitSha'"
        }

        It "Should warn when resolvedCommitSha has an unexpected format" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseObservations = @(
                    @{
                        releaseId         = 1
                        tagName           = "v1.0.0"
                        publishedAt       = "2025-01-01T00:00:00Z"
                        immutabilityState = "unknown"
                        status            = "present"
                        observedAt        = "2025-01-10T00:00:00Z"
                        source            = "GET /repos/{owner}/{repo}/releases"
                        resolvedCommitSha = "not-a-sha"
                    }
                )
                immutableReleaseObservationsCheckedAt = "2025-01-10T00:00:00Z"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Match "resolvedCommitSha has unexpected format"
        }

        It "Should warn when releaseTargetCommitish is not a string" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseObservations = @(
                    @{
                        releaseId              = 1
                        tagName                = "v1.0.0"
                        publishedAt            = "2025-01-01T00:00:00Z"
                        immutabilityState      = "unknown"
                        status                 = "present"
                        observedAt             = "2025-01-10T00:00:00Z"
                        source                 = "GET /repos/{owner}/{repo}/releases"
                        releaseTargetCommitish = @{ not = "a string" }
                    }
                )
                immutableReleaseObservationsCheckedAt = "2025-01-10T00:00:00Z"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Match "releaseTargetCommitish should be a string or null"
        }

        It "Should warn when tagReleaseMismatch is the string 'false' instead of a boolean" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseObservations = @(
                    @{
                        releaseId          = 1
                        tagName            = "v1.0.0"
                        publishedAt        = "2025-01-01T00:00:00Z"
                        immutabilityState  = "unknown"
                        status             = "present"
                        observedAt         = "2025-01-10T00:00:00Z"
                        source             = "GET /repos/{owner}/{repo}/releases"
                        resolvedCommitSha  = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
                        tagReleaseMismatch = "false"
                    }
                )
                immutableReleaseObservationsCheckedAt = "2025-01-10T00:00:00Z"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Match "tagReleaseMismatch should be a boolean or null"
        }

        It "Should not warn for a well-formed releaseTargetCommitish/tagReleaseMismatch pair" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseObservations = @(
                    @{
                        releaseId              = 1
                        tagName                = "v1.0.0"
                        publishedAt            = "2025-01-01T00:00:00Z"
                        immutabilityState      = "unknown"
                        status                 = "present"
                        observedAt             = "2025-01-10T00:00:00Z"
                        source                 = "GET /repos/{owner}/{repo}/releases"
                        releaseTargetCommitish = "main"
                        resolvedCommitSha      = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
                        tagReleaseMismatch     = $false
                    }
                )
                immutableReleaseObservationsCheckedAt = "2025-01-10T00:00:00Z"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Not -Match "releaseTargetCommitish|tagReleaseMismatch"
        }

        It "Should not require release-integrity fields to be present at all (backwards compatible)" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                immutableReleaseObservations = @(
                    @{
                        releaseId         = 1
                        tagName           = "v1.0.0"
                        publishedAt       = "2025-01-01T00:00:00Z"
                        immutabilityState = "unknown"
                        status            = "present"
                        observedAt        = "2025-01-10T00:00:00Z"
                        source            = "GET /repos/{owner}/{repo}/releases"
                    }
                )
                immutableReleaseObservationsCheckedAt = "2025-01-10T00:00:00Z"
            }

            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
            $result.Warnings -join " " | Should -Not -Match "resolvedCommitSha|tagReleaseMismatch"
        }
    }

    Context "Test-ActionSchema function with errors" {
        It "Should error when vulnerabilityStatus is not an object" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                vulnerabilityStatus = "invalid"
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $false
            $result.Errors.Count | Should -BeGreaterThan 0
            $result.Errors -join " " | Should -Match "vulnerabilityStatus should be object"
        }
        
        It "Should error when dependents is not an object" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                dependents = "invalid"
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $false
            $result.Errors -join " " | Should -Match "dependents should be object"
        }
        
        It "Should error when containerScan is not an object" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                forkFound = $true
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Dockerfile"
                    containerScan = "invalid"
                }
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $false
            $result.Errors -join " " | Should -Match "containerScan should be object"
        }
    }
    
    Context "Test-StatusJsonSchema function with arrays" {
        It "Should validate array of objects" {
            $statusData = @(
                @{
                    owner = "owner1"
                    name = "repo1"
                    forkFound = $true
                    vulnerabilityStatus = @{
                        critical = 0
                        high = 0
                        lastUpdated = "2023-05-01T22:42:34.4794677Z"
                    }
                },
                @{
                    owner = "owner2"
                    name = "repo2"
                    forkFound = $false
                    vulnerabilityStatus = @{
                        critical = 1
                        high = 2
                        lastUpdated = "2023-05-02T22:42:34.4794677Z"
                    }
                }
            )
            
            $result = Test-StatusJsonSchema -statusData $statusData
            $result.Success | Should -Be $true
            $result.TotalObjects | Should -Be 2
            $result.TotalErrors | Should -Be 0
        }
        
        It "Should count warnings across multiple objects" {
            $statusData = @(
                @{
                    name = "repo1"  # Missing owner
                    forkFound = $true
                },
                @{
                    owner = "owner2"  # Missing name
                    forkFound = $false
                }
            )
            
            $result = Test-StatusJsonSchema -statusData $statusData
            $result.TotalWarnings | Should -BeGreaterThan 0
        }
        
        It "Should fail when objects have critical errors" {
            $statusData = @(
                @{
                    owner = "owner1"
                    name = "repo1"
                    vulnerabilityStatus = "invalid"  # Should be object
                }
            )
            
            $result = Test-StatusJsonSchema -statusData $statusData
            $result.Success | Should -Be $false
            $result.TotalErrors | Should -BeGreaterThan 0
        }
        
        It "Should handle large arrays efficiently" {
            $statusData = @()
            for ($i = 0; $i -lt 1000; $i++) {
                $statusData += @{
                    owner = "owner$i"
                    name = "repo$i"
                    forkFound = $true
                }
            }
            
            $result = Test-StatusJsonSchema -statusData $statusData
            $result.TotalObjects | Should -Be 1000
            $result.Success | Should -Be $true
        }
    }
    
    Context "Field type validation" {
        It "Should accept null values for optional boolean fields" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                forkFound = $null
                secretScanningEnabled = $null
                dependabotEnabled = $null
                verified = $null
                ossf = $null
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
        }
        
        It "Should accept both true and false for boolean fields" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                forkFound = $true
                secretScanningEnabled = $false
                verified = $true
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
        }
        
        It "Should accept integer for ossfScore" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                ossfScore = 5
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
            $result.Warnings.Count | Should -Be 0
        }
        
        It "Should accept int64 for ossfScore (from JSON parsing)" {
            # Simulate what happens when JSON is parsed with ConvertFrom-Json
            # Integer values in JSON become Int64 in PowerShell
            $json = '{"owner":"test-owner","name":"test_repo","ossfScore":5}'
            $action = $json | ConvertFrom-Json
            
            # Verify it's actually Int64
            $action.ossfScore.GetType().Name | Should -Be "Int64"
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
            $result.Warnings.Count | Should -Be 0
        }
        
        It "Should accept decimal for ossfScore" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                ossfScore = 4.5
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
            $result.Warnings.Count | Should -Be 0
        }
        
        It "Should warn when ossfScore is not numeric" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                ossfScore = "4.5"
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Warnings -join " " | Should -Match "ossfScore should be numeric"
        }
    }
    
    Context "Nested object validation" {
        It "Should validate actionType with dockerBaseImage" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                actionType = @{
                    actionType = "Docker"
                    fileFound = "action.yml"
                    nodeVersion = "12"
                    actionDockerType = "Dockerfile"
                    dockerBaseImage = "ubuntu:latest"
                }
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
        }
        
        It "Should allow actionType to be string" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                actionType = "Composite"
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
        }
        
        It "Should validate repoInfo with all standard fields" {
            $action = @{
                owner = "test-owner"
                name = "test_repo"
                repoInfo = @{
                    disabled = $false
                    archived = $false
                    updated_at = "2023-05-01T16:10:08Z"
                    latest_release_published_at = "2023-05-01T16:13:20Z"
                }
            }
            
            $result = Test-ActionSchema -action $action -index 0
            $result.Valid | Should -Be $true
        }
    }
}

Describe "Schema Validation Integration" {
    Context "End-to-end validation flow" {
        It "Should validate a real-world sample file" {
            $testFile = Join-Path $TestDrive "sample-status.json"
            $sampleData = @(
                @{
                    owner = "nhedger"
                    name = "nhedger_setup-sops"
                    dependabot = $null
                    forkFound = $true
                    mirrorLastUpdated = $null
                    repoSize = $null
                    actionType = @{
                        fileFound = "No file found"
                        actionDockerType = "No file found"
                        actionType = "No file found"
                        nodeVersion = $null
                    }
                    repoInfo = @{
                        disabled = $false
                        archived = $false
                        updated_at = "2023-05-01T16:10:08Z"
                        latest_release_published_at = "2023-05-01T16:13:20Z"
                    }
                    tagInfo = "v1"
                    secretScanningEnabled = $true
                    releaseInfo = "v1"
                    dependabotEnabled = $true
                    vulnerabilityStatus = @{
                        critical = 0
                        high = 0
                        lastUpdated = "2023-05-01T22:42:34.4794677Z"
                    }
                    ossfDateLastUpdate = "2024-01-15"
                    dependents = @{
                        dependentsLastUpdated = "2025-10-30T12:51:13.2241389+00:00"
                        dependents = "53"
                    }
                    verified = $false
                    ossf = $true
                    ossfScore = 4.4
                }
            )
            
            $sampleData | ConvertTo-Json -Depth 10 | Out-File -FilePath $testFile -Encoding UTF8
            
            # Parse and validate
            $jsonContent = Get-Content $testFile -Raw
            $statusData = $jsonContent | ConvertFrom-Json
            
            $result = Test-StatusJsonSchema -statusData $statusData
            $result.Success | Should -Be $true
        }
    }
}
