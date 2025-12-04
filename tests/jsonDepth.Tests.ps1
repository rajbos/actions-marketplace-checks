Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "JSON Serialization Depth" {
    Context "ConvertTo-Json depth parameter usage" {
        It "Should serialize complex nested objects without truncation" {
            # Create a deeply nested object structure similar to what secret scanning alerts would return
            $complexObject = @(
                @{
                    number = 1
                    state = "open"
                    secret_type = "github_token"
                    secret_type_display_name = "GitHub Token"
                    created_at = "2024-01-01T00:00:00Z"
                    repository = @{
                        name = "test-repo"
                        owner = @{
                            login = "test-owner"
                            type = "Organization"
                        }
                        visibility = "public"
                    }
                    locations = @(
                        @{
                            type = "commit"
                            details = @{
                                path = "/test/file.txt"
                                start_line = 1
                                end_line = 1
                                blob_sha = "abc123"
                                commit_sha = "def456"
                            }
                        }
                    )
                }
            )
            
            # Convert with depth 10 (as we fixed it)
            $jsonWithDepth = ConvertTo-Json $complexObject -Depth 10
            
            # The JSON should contain deeply nested fields without "..." truncation indicators
            $jsonWithDepth | Should -Not -Match '"\.\.\."'
            
            # Verify that deeply nested fields are preserved
            $jsonWithDepth | Should -Match '"commit_sha"'
            $jsonWithDepth | Should -Match '"blob_sha"'
            $jsonWithDepth | Should -Match '"login"'
            
            # Convert back to verify all data is intact
            $roundTrip = $jsonWithDepth | ConvertFrom-Json
            $roundTrip[0].locations[0].details.commit_sha | Should -Be "def456"
            $roundTrip[0].repository.owner.login | Should -Be "test-owner"
        }
        
        It "Should demonstrate truncation with insufficient depth" {
            # Create the same nested structure
            $complexObject = @{
                level1 = @{
                    level2 = @{
                        level3 = @{
                            level4 = "deep value"
                        }
                    }
                }
            }
            
            # With depth 2 (default), this should truncate at level 3
            $jsonWithDepth2 = ConvertTo-Json $complexObject -Depth 2 -WarningAction SilentlyContinue
            
            # The JSON should be truncated and not contain the deepest value
            $jsonWithDepth2 | Should -Not -Match '"level4"'
            
            # With depth 10, it should contain everything
            $jsonWithDepth10 = ConvertTo-Json $complexObject -Depth 10
            $jsonWithDepth10 | Should -Match '"level4"'
            $jsonWithDepth10 | Should -Match '"deep value"'
        }
        
        It "GetFoundSecretCount should use ConvertTo-Json with -Depth parameter" {
            # Get the function definition
            $functionDef = (Get-Command GetFoundSecretCount).Definition
            
            # Check that ConvertTo-Json is called with -Depth parameter
            # The fix should include "-Depth 10" or similar
            $functionDef | Should -Match 'ConvertTo-Json.*-Depth\s+\d+'
        }
    }
    
    Context "SaveStatus function depth parameter" {
        It "Should use sufficient depth for status.json" {
            $functionDef = (Get-Command SaveStatus).Definition
            
            # Verify that both ConvertTo-Json calls in SaveStatus use -Depth parameter
            $matches = [regex]::Matches($functionDef, 'ConvertTo-Json.*-Depth\s+\d+')
            $matches.Count | Should -BeGreaterOrEqual 2
        }
    }
}
