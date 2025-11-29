Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Blob Storage Helper Functions" {
    Context "Get-StatusFromBlobStorage function" {
        It "Should have function defined" {
            Get-Command Get-StatusFromBlobStorage -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have required sasToken parameter" {
            $params = (Get-Command Get-StatusFromBlobStorage).Parameters
            $params.Keys | Should -Contain 'sasToken'
        }

        It "Should fail with invalid SAS token URL" {
            # Mock an invalid URL that will fail
            $result = Get-StatusFromBlobStorage -sasToken "https://invalid.blob.core.windows.net/invalid/status.json?sv=invalid"
            $result | Should -Be $false
        }
    }

    Context "Set-StatusToBlobStorage function" {
        It "Should have function defined" {
            Get-Command Set-StatusToBlobStorage -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have required sasToken parameter" {
            $params = (Get-Command Set-StatusToBlobStorage).Parameters
            $params.Keys | Should -Contain 'sasToken'
        }

        It "Should fail when status.json does not exist" {
            # Temporarily rename status.json if it exists
            $tempRename = $false
            if (Test-Path $statusFile) {
                Rename-Item $statusFile "$statusFile.bak" -Force
                $tempRename = $true
            }
            
            try {
                $result = Set-StatusToBlobStorage -sasToken "https://test.blob.core.windows.net/test/status.json?sv=test"
                $result | Should -Be $false
            }
            finally {
                # Restore status.json if we renamed it
                if ($tempRename) {
                    Rename-Item "$statusFile.bak" $statusFile -Force
                }
            }
        }
    }

    Context "Blob storage URL handling" {
        It "Should use full URL when sasToken starts with https://" {
            # This test verifies the function accepts a full URL format
            # The actual download will fail but should not throw an exception
            { Get-StatusFromBlobStorage -sasToken "https://example.blob.core.windows.net/container/status.json?sv=test" } | Should -Not -Throw
        }
    }
}

Describe "Status file path configuration" {
    It "Should have statusFile variable defined" {
        $statusFile | Should -Not -BeNullOrEmpty
    }

    It "Should have statusBlobBaseUrl variable defined" {
        $script:statusBlobBaseUrl | Should -Not -BeNullOrEmpty
    }

    It "Should have correct blob storage base URL format" {
        $script:statusBlobBaseUrl | Should -Match "^https://.*\.blob\.core\.windows\.net/.*/status\.json$"
    }
}
