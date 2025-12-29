Import-Module Pester

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
