Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "API Upsert Script" {
    Context "Script file exists" {
        It "Should have api-upsert.ps1 script file" {
            Test-Path "$PSScriptRoot/../.github/workflows/api-upsert.ps1" | Should -Be $true
        }
    }

    Context "Script parameters" {
        BeforeAll {
            # Mock the script content to analyze parameters
            $scriptContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.ps1" -Raw
        }

        It "Should have status parameter" {
            $scriptContent | Should -Match 'Param\s*\('
            $scriptContent | Should -Match '\$status'
        }

        It "Should have numberOfRepos parameter" {
            $scriptContent | Should -Match '\$numberOfRepos'
        }

        It "Should have apiUrl parameter" {
            $scriptContent | Should -Match '\$apiUrl'
        }
    }

    Context "Script functionality" {
        It "Should use Write-Message for logging" {
            $scriptContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.ps1" -Raw
            $scriptContent | Should -Match 'Write-Message'
        }

        It "Should validate inputs" {
            $scriptContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.ps1" -Raw
            $scriptContent | Should -Match 'if \(-not \$status'
            $scriptContent | Should -Match 'if \(-not \$apiUrl'
        }

        It "Should exit with error code 1 if all uploads fail" {
            $scriptContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.ps1" -Raw
            # Check for logic that exits with error when all uploads fail
            $scriptContent | Should -Match '\$allUploadsFailed = \(\$failCount -gt 0 -and \$successCount -eq 0\)'
            $scriptContent | Should -Match 'if \(\$allUploadsFailed\)'
            $scriptContent | Should -Match 'exit 1'
        }

        It "Should reference external Node.js script" {
            $scriptContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.ps1" -Raw
            $scriptContent | Should -Match 'node-scripts/upload-to-api\.js'
        }

        It "Should validate Node.js script exists" {
            $scriptContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.ps1" -Raw
            $scriptContent | Should -Match 'Test-Path.*nodeScriptPath'
        }

        It "Should create temp JSON file for actions data" {
            $scriptContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.ps1" -Raw
            $scriptContent | Should -Match 'temp-actions-data\.json'
        }

        It "Should check for Node.js availability" {
            $scriptContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.ps1" -Raw
            $scriptContent | Should -Match 'node --version'
        }

        It "Should use ActionsMarketplaceClient" {
            # Check that the external Node.js script exists
            Test-Path "$PSScriptRoot/../.github/workflows/node-scripts/upload-to-api.js" | Should -Be $true
            $nodeScript = Get-Content "$PSScriptRoot/../.github/workflows/node-scripts/upload-to-api.js" -Raw
            $nodeScript | Should -Match 'ActionsMarketplaceClient'
        }

        It "Should clean up temporary files" {
            $scriptContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.ps1" -Raw
            $scriptContent | Should -Match 'Remove-Item.*actionsJsonPath'
        }

        It "Should validate argument lengths in Node.js script" {
            $nodeScript = Get-Content "$PSScriptRoot/../.github/workflows/node-scripts/upload-to-api.js" -Raw
            $nodeScript | Should -Match 'apiUrl\.length'
            $nodeScript | Should -Match 'actionsJsonPath\.length'
        }

        It "Should test API connection" {
            $nodeScript = Get-Content "$PSScriptRoot/../.github/workflows/node-scripts/upload-to-api.js" -Raw
            $nodeScript | Should -Match 'Testing API connection'
        }

        It "Should use correct status.json schema fields" {
            $nodeScript = Get-Content "$PSScriptRoot/../.github/workflows/node-scripts/upload-to-api.js" -Raw
            # Check that it uses schema-documented fields
            $nodeScript | Should -Match 'action\.actionType'
            $nodeScript | Should -Match 'action\.repoInfo'
            $nodeScript | Should -Match 'action\.vulnerabilityStatus'
            # Ensure it doesn't use invented fields
            $nodeScript | Should -Not -Match 'actionData\.description'
            $nodeScript | Should -Not -Match 'actionData\.icon'
            $nodeScript | Should -Not -Match 'actionData\.color'
        }

        It "Should reference get-actions-count.js script" {
            $scriptContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.ps1" -Raw
            $scriptContent | Should -Match 'node-scripts/get-actions-count\.js'
        }

        It "Should get initial actions count from API" {
            $scriptContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.ps1" -Raw
            $scriptContent | Should -Match '\$initialKnownCount'
            $scriptContent | Should -Match 'Getting initial count of known actions from API'
        }

        It "Should display initial count in configuration table" {
            $scriptContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.ps1" -Raw
            $scriptContent | Should -Match 'Known actions in table storage \(start\)'
        }

        It "Should get final actions count from API" {
            $scriptContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.ps1" -Raw
            $scriptContent | Should -Match '\$finalKnownCount'
            $scriptContent | Should -Match 'Getting final count of known actions from API'
        }

        It "Should display final count after upload completed" {
            $scriptContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.ps1" -Raw
            $scriptContent | Should -Match 'Known actions in table storage \(end\)'
            $scriptContent | Should -Match 'Upload process completed'
        }
    }

    Context "Node.js script file" {
        It "Should have upload-to-api.js script file" {
            Test-Path "$PSScriptRoot/../.github/workflows/node-scripts/upload-to-api.js" | Should -Be $true
        }

        It "Should have get-actions-count.js script file" {
            Test-Path "$PSScriptRoot/../.github/workflows/node-scripts/get-actions-count.js" | Should -Be $true
        }

        It "Should use ActionsMarketplaceClient in get-actions-count.js" {
            $countScript = Get-Content "$PSScriptRoot/../.github/workflows/node-scripts/get-actions-count.js" -Raw
            $countScript | Should -Match 'ActionsMarketplaceClient'
        }

        It "Should call listActions in get-actions-count.js" {
            $countScript = Get-Content "$PSScriptRoot/../.github/workflows/node-scripts/get-actions-count.js" -Raw
            $countScript | Should -Match 'listActions'
        }

        It "Should output count with markers in get-actions-count.js" {
            $countScript = Get-Content "$PSScriptRoot/../.github/workflows/node-scripts/get-actions-count.js" -Raw
            $countScript | Should -Match '__COUNT_START__'
            $countScript | Should -Match '__COUNT_END__'
        }

        It "Should validate arguments in get-actions-count.js" {
            $countScript = Get-Content "$PSScriptRoot/../.github/workflows/node-scripts/get-actions-count.js" -Raw
            $countScript | Should -Match 'apiUrl\.length'
            $countScript | Should -Match 'functionKey\.length'
        }
    }

    Context "Workflow file exists and valid" {
        It "Should have api-upsert.yml workflow file" {
            Test-Path "$PSScriptRoot/../.github/workflows/api-upsert.yml" | Should -Be $true
        }

        It "Should have workflow_dispatch trigger" {
            $workflowContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.yml" -Raw
            $workflowContent | Should -Match 'workflow_dispatch'
        }

        It "Should have numberOfRepos input" {
            $workflowContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.yml" -Raw
            $workflowContent | Should -Match 'numberOfRepos'
        }

        It "Should install npm package" {
            $workflowContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.yml" -Raw
            $workflowContent | Should -Match '@devops-actions/actions-marketplace-client'
        }

        It "Should use Node.js 20" {
            $workflowContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.yml" -Raw
            $workflowContent | Should -Match "node-version.*'20'"
        }

        It "Should download status.json from blob storage" {
            $workflowContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.yml" -Raw
            $workflowContent | Should -Match 'Get-StatusFromBlobStorage'
        }

        It "Should use DEVOPS_ACTIONS_PACKAGE_DOWNLOAD secret" {
            $workflowContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.yml" -Raw
            $workflowContent | Should -Match 'DEVOPS_ACTIONS_PACKAGE_DOWNLOAD'
        }

        It "Should use AZ_FUNCTION_URL secret" {
            $workflowContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.yml" -Raw
            $workflowContent | Should -Match 'AZ_FUNCTION_URL'
        }

        It "Should trigger on changes to get-actions-count.js" {
            $workflowContent = Get-Content "$PSScriptRoot/../.github/workflows/api-upsert.yml" -Raw
            $workflowContent | Should -Match 'node-scripts/get-actions-count\.js'
        }
    }
}

Describe "Gitignore configuration" {
    Context "Temporary files excluded" {
        It "Should exclude temp-actions-data.json" {
            $gitignoreContent = Get-Content "$PSScriptRoot/../.gitignore" -Raw
            $gitignoreContent | Should -Match 'temp-actions-data\.json'
        }

        It "Should exclude node_modules" {
            $gitignoreContent = Get-Content "$PSScriptRoot/../.gitignore" -Raw
            $gitignoreContent | Should -Match 'node_modules'
        }
    }
}
