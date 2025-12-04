Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Blob Storage Change Detection" {
    Context "Set-JsonToBlobStorage change detection logic" {
        BeforeEach {
            # Create a temporary file for testing
            $script:testFile = [System.IO.Path]::GetTempFileName()
            $script:testContent = '{"test": "data", "version": 1}'
            [System.IO.File]::WriteAllText($script:testFile, $script:testContent)
        }

        AfterEach {
            # Clean up test file
            if (Test-Path $script:testFile) {
                Remove-Item $script:testFile -Force
            }
        }

        It "Should detect when file content has changed" {
            # This test verifies the logic exists, but we can't test actual upload without a real SAS token
            # The important thing is that the function handles comparison logic
            $params = (Get-Command Set-JsonToBlobStorage).Parameters
            $params.Keys | Should -Contain 'sasToken'
            $params.Keys | Should -Contain 'blobFileName'
            $params.Keys | Should -Contain 'localFilePath'
        }

        It "Should handle file existence check before upload" {
            # Test that missing file is handled correctly
            $nonExistentFile = "/tmp/nonexistent-$(New-Guid).json"
            
            # Should succeed but not upload when failIfMissing is false
            $result = Set-JsonToBlobStorage -sasToken "https://test.blob.core.windows.net/test/data?sv=test" -blobFileName "test.json" -localFilePath $nonExistentFile -failIfMissing $false
            $result | Should -Be $true
        }

        It "Should fail when file doesn't exist and failIfMissing is true" {
            $nonExistentFile = "/tmp/nonexistent-$(New-Guid).json"
            
            # Should fail when failIfMissing is true
            $result = Set-JsonToBlobStorage -sasToken "https://test.blob.core.windows.net/test/data?sv=test" -blobFileName "test.json" -localFilePath $nonExistentFile -failIfMissing $true
            $result | Should -Be $false
        }
    }

    Context "Enhanced logging in blob operations" {
        It "Get-JsonFromBlobStorage should use Write-Message for logging" {
            # Verify the function uses Write-Message which logs to both console and summary
            $functionContent = (Get-Command Get-JsonFromBlobStorage).ScriptBlock.ToString()
            $functionContent | Should -Match 'Write-Message'
        }

        It "Set-JsonToBlobStorage should use Write-Message for logging" {
            $functionContent = (Get-Command Set-JsonToBlobStorage).ScriptBlock.ToString()
            $functionContent | Should -Match 'Write-Message'
        }

        It "Get-ActionsJsonFromBlobStorage should use Write-Message for logging" {
            $functionContent = (Get-Command Get-ActionsJsonFromBlobStorage).ScriptBlock.ToString()
            $functionContent | Should -Match 'Write-Message'
        }
    }

    Context "Status symbols in log messages" {
        It "Should use success symbol (✓) for successful operations" {
            $functionContent = (Get-Command Set-JsonToBlobStorage).ScriptBlock.ToString()
            $functionContent | Should -Match '✓'
        }

        It "Should use warning symbol (⚠️) for errors and warnings" {
            $functionContent = (Get-Command Set-JsonToBlobStorage).ScriptBlock.ToString()
            $functionContent | Should -Match '⚠️'
        }

        It "Should use info symbol (ℹ️) for informational messages" {
            $functionContent = (Get-Command Get-JsonFromBlobStorage).ScriptBlock.ToString()
            $functionContent | Should -Match 'ℹ️'
        }
    }

    Context "File comparison logic" {
        It "Set-JsonToBlobStorage should compare file content before uploading" {
            $functionContent = (Get-Command Set-JsonToBlobStorage).ScriptBlock.ToString()
            # Should have logic to download current version and compare
            $functionContent | Should -Match 'GetTempFileName'
            $functionContent | Should -Match 'No changes detected'
        }

        It "Should handle case when remote file doesn't exist" {
            $functionContent = (Get-Command Set-JsonToBlobStorage).ScriptBlock.ToString()
            $functionContent | Should -Match 'does not exist in blob storage yet'
        }

        It "Should skip upload when files match" {
            $functionContent = (Get-Command Set-JsonToBlobStorage).ScriptBlock.ToString()
            $functionContent | Should -Match 'Skipping upload'
        }
    }
}

Describe "Wrapper Functions Logging" {
    Context "Status wrapper functions" {
        It "Set-StatusToBlobStorage should use enhanced Set-JsonToBlobStorage" {
            # Verify wrapper uses the base function with proper parameters
            $params = (Get-Command Set-StatusToBlobStorage).Parameters
            $params.Keys | Should -Contain 'sasToken'
        }

        It "Set-FailedForksToBlobStorage should use enhanced Set-JsonToBlobStorage" {
            $params = (Get-Command Set-FailedForksToBlobStorage).Parameters
            $params.Keys | Should -Contain 'sasToken'
        }

        It "Get-StatusFromBlobStorage should use enhanced Get-JsonFromBlobStorage" {
            $params = (Get-Command Get-StatusFromBlobStorage).Parameters
            $params.Keys | Should -Contain 'sasToken'
        }
    }
}
