Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Blob Storage Common Functions" {
    Context "Get-JsonFromBlobStorage function" {
        It "Should have function defined" {
            Get-Command Get-JsonFromBlobStorage -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have required parameters" {
            $params = (Get-Command Get-JsonFromBlobStorage).Parameters
            $params.Keys | Should -Contain 'sasToken'
            $params.Keys | Should -Contain 'blobFileName'
            $params.Keys | Should -Contain 'localFilePath'
        }
    }

    Context "Set-JsonToBlobStorage function" {
        It "Should have function defined" {
            Get-Command Set-JsonToBlobStorage -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have required parameters" {
            $params = (Get-Command Set-JsonToBlobStorage).Parameters
            $params.Keys | Should -Contain 'sasToken'
            $params.Keys | Should -Contain 'blobFileName'
            $params.Keys | Should -Contain 'localFilePath'
            $params.Keys | Should -Contain 'failIfMissing'
        }
    }
}

Describe "Blob Storage Wrapper Functions" {
    Context "Get-ActionsJsonFromBlobStorage function" {
        It "Should have function defined" {
            Get-Command Get-ActionsJsonFromBlobStorage -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have required sasToken parameter" {
            $params = (Get-Command Get-ActionsJsonFromBlobStorage).Parameters
            $params.Keys | Should -Contain 'sasToken'
        }

        It "Should have optional localFilePath parameter" {
            $params = (Get-Command Get-ActionsJsonFromBlobStorage).Parameters
            $params.Keys | Should -Contain 'localFilePath'
        }

        It "Should fail with invalid SAS token URL" {
            # SAS URL should point to a folder (e.g., 'data'), not a specific blob
            $result = Get-ActionsJsonFromBlobStorage -sasToken "https://invalid.blob.core.windows.net/container/data?sv=invalid" -ErrorAction SilentlyContinue
            $result | Should -Be $false
        }
    }

    Context "Get-StatusFromBlobStorage function" {
        It "Should have function defined" {
            Get-Command Get-StatusFromBlobStorage -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have required sasToken parameter" {
            $params = (Get-Command Get-StatusFromBlobStorage).Parameters
            $params.Keys | Should -Contain 'sasToken'
        }

        It "Should fail with invalid SAS token URL" {
            # SAS URL should point to a folder (e.g., 'data'), not a specific blob
            $result = Get-StatusFromBlobStorage -sasToken "https://invalid.blob.core.windows.net/container/data?sv=invalid" -ErrorAction SilentlyContinue
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
            $tempRename = $false
            if (Test-Path $statusFile) {
                Rename-Item $statusFile "$statusFile.bak" -Force
                $tempRename = $true
            }
            
            try {
                $result = Set-StatusToBlobStorage -sasToken "https://test.blob.core.windows.net/test/actions.json?sv=test" -ErrorAction SilentlyContinue
                $result | Should -Be $false
            }
            finally {
                if ($tempRename) {
                    Rename-Item "$statusFile.bak" $statusFile -Force
                }
            }
        }
    }

    Context "Get-FailedForksFromBlobStorage function" {
        It "Should have function defined" {
            Get-Command Get-FailedForksFromBlobStorage -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have required sasToken parameter" {
            $params = (Get-Command Get-FailedForksFromBlobStorage).Parameters
            $params.Keys | Should -Contain 'sasToken'
        }
    }

    Context "Set-FailedForksToBlobStorage function" {
        It "Should have function defined" {
            Get-Command Set-FailedForksToBlobStorage -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have required sasToken parameter" {
            $params = (Get-Command Set-FailedForksToBlobStorage).Parameters
            $params.Keys | Should -Contain 'sasToken'
        }
    }

    Context "Set-SecretScanningAlertsToBlobStorage function" {
        It "Should have function defined" {
            Get-Command Set-SecretScanningAlertsToBlobStorage -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have required sasToken parameter" {
            $params = (Get-Command Set-SecretScanningAlertsToBlobStorage).Parameters
            $params.Keys | Should -Contain 'sasToken'
        }
    }

    Context "Blob storage URL handling" {
        It "Should use full URL when sasToken starts with https://" {
            # SAS URL should point to a folder (e.g., 'data'), not a specific blob
            { Get-StatusFromBlobStorage -sasToken "https://example.blob.core.windows.net/container/data?sv=test" -ErrorAction SilentlyContinue } | Should -Not -Throw
        }
    }
}

Describe "Status file path configuration" {
    It "Should have statusFile variable defined" {
        $statusFile | Should -Not -BeNullOrEmpty
    }

    It "Should have failedStatusFile variable defined" {
        $failedStatusFile | Should -Not -BeNullOrEmpty
    }

    It "Should have secretScanningAlertsFile variable defined" {
        $secretScanningAlertsFile | Should -Not -BeNullOrEmpty
    }

    It "Should have statusBlobFileName constant defined" {
        $script:statusBlobFileName | Should -Be "status.json"
    }

    It "Should have failedForksBlobFileName constant defined" {
        $script:failedForksBlobFileName | Should -Be "failedForks.json"
    }

    It "Should have secretScanningAlertsBlobFileName constant defined" {
        $script:secretScanningAlertsBlobFileName | Should -Be "secretScanningAlerts.json"
    }
}
