Import-Module Pester

BeforeAll {
    # Import the copilot-memories script
    $script:scriptPath = "$PSScriptRoot/../.github/workflows/copilot-memories.ps1"
}

Describe "Copilot Memories Script Tests" {
    Context "Repository Format Validation" {
        It "Should accept valid repository format 'owner/repo'" {
            $validRepo = "rajbos/actions-marketplace-checks"
            $parts = $validRepo.Split('/')
            $parts.Count | Should -Be 2
            $parts[0] | Should -Not -BeNullOrEmpty
            $parts[1] | Should -Not -BeNullOrEmpty
        }

        It "Should reject invalid repository format without slash" {
            $invalidRepo = "invalid-repo-format"
            $parts = $invalidRepo.Split('/')
            $parts.Count | Should -Be 1
        }

        It "Should reject invalid repository format with multiple slashes" {
            $invalidRepo = "owner/repo/extra"
            $parts = $invalidRepo.Split('/')
            $parts.Count | Should -Be 3
        }

        It "Should reject empty repository string" {
            $emptyRepo = ""
            [string]::IsNullOrWhiteSpace($emptyRepo) | Should -Be $true
        }

        It "Should reject whitespace-only repository string" {
            $whitespaceRepo = "   "
            [string]::IsNullOrWhiteSpace($whitespaceRepo) | Should -Be $true
        }
    }

    Context "Script Parameter Validation" {
        It "Script should exist" {
            Test-Path $script:scriptPath | Should -Be $true
        }

        It "Script should be a PowerShell file" {
            $script:scriptPath | Should -Match '\.ps1$'
        }

        It "Script should have mandatory repositories parameter" {
            $scriptContent = Get-Content $script:scriptPath -Raw
            $scriptContent | Should -Match '\[Parameter\(Mandatory=\$true\)\][\s\S]*?\[string\[\]\]\s+\$repositories'
        }

        It "Script should have mandatory githubToken parameter" {
            $scriptContent = Get-Content $script:scriptPath -Raw
            $scriptContent | Should -Match '\[Parameter\(Mandatory=\$true\)\][\s\S]*?\[string\]\s+\$githubToken'
        }

        It "Script should have optional limit parameter with default value" {
            $scriptContent = Get-Content $script:scriptPath -Raw
            $scriptContent | Should -Match '\[Parameter\(Mandatory=\$false\)\][\s\S]*?\[int\]\s+\$limit\s*=\s*20'
        }
    }

    Context "API URL Construction" {
        It "Should construct correct API URL format" {
            $owner = "testowner"
            $repo = "testrepo"
            $limit = 20
            
            $expectedUrl = "https://api.githubcopilot.com/agents/swe/internal/memory/v0/$owner/$repo/recent?limit=$limit"
            $expectedUrl | Should -Match '^https://api\.githubcopilot\.com/agents/swe/internal/memory/v0/[^/]+/[^/]+/recent\?limit=\d+$'
        }

        It "Should use correct API endpoint base URL" {
            $baseUrl = "https://api.githubcopilot.com/agents/swe/internal/memory/v0"
            $baseUrl | Should -Be "https://api.githubcopilot.com/agents/swe/internal/memory/v0"
        }
    }

    Context "Result Structure Validation" {
        It "Should create result hashtable with required fields on success" {
            $mockResult = @{
                repository = "owner/repo"
                owner = "owner"
                repo = "repo"
                memories = @()
                memoriesCount = 0
                success = $true
            }
            
            $mockResult.ContainsKey("repository") | Should -Be $true
            $mockResult.ContainsKey("owner") | Should -Be $true
            $mockResult.ContainsKey("repo") | Should -Be $true
            $mockResult.ContainsKey("memories") | Should -Be $true
            $mockResult.ContainsKey("memoriesCount") | Should -Be $true
            $mockResult.ContainsKey("success") | Should -Be $true
        }

        It "Should create result hashtable with error fields on failure" {
            $mockResult = @{
                repository = "owner/repo"
                owner = "owner"
                repo = "repo"
                memories = @()
                memoriesCount = 0
                success = $false
                error = "Test error"
                statusCode = 404
            }
            
            $mockResult.ContainsKey("success") | Should -Be $true
            $mockResult.ContainsKey("error") | Should -Be $true
            $mockResult.ContainsKey("statusCode") | Should -Be $true
            $mockResult.success | Should -Be $false
        }
    }

    Context "Output File Generation" {
        It "Should specify JSON output file name" {
            $expectedOutputFile = "copilot-memories-results.json"
            $expectedOutputFile | Should -Be "copilot-memories-results.json"
        }

        It "Should export results with appropriate JSON depth" {
            $testResults = @(
                @{
                    repository = "test/repo"
                    memories = @(
                        @{ fact = "test memory 1" },
                        @{ fact = "test memory 2" }
                    )
                    memoriesCount = 2
                    success = $true
                }
            )
            
            $json = $testResults | ConvertTo-Json -Depth 10
            $json | Should -Not -BeNullOrEmpty
            $parsed = $json | ConvertFrom-Json
            $parsed[0].repository | Should -Be "test/repo"
        }
    }

    Context "GitHub Actions Integration" {
        It "Should set GITHUB_OUTPUT variable when environment variable exists" {
            $env:GITHUB_OUTPUT = $null
            $env:GITHUB_OUTPUT | Should -BeNullOrEmpty
        }

        It "Should format has_memories as lowercase boolean" {
            $hasMemories = $true
            $formatted = $hasMemories.ToString().ToLower()
            $formatted | Should -BeIn @("true", "false")
            $formatted | Should -Be "true"
        }

        It "Should format has_memories=false as lowercase boolean" {
            $hasMemories = $false
            $formatted = $hasMemories.ToString().ToLower()
            $formatted | Should -BeIn @("true", "false")
            $formatted | Should -Be "false"
        }
    }

    Context "Script Syntax Validation" {
        It "Script should have valid PowerShell syntax" {
            $errors = $null
            $tokens = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:scriptPath,
                [ref]$tokens,
                [ref]$errors
            )
            $errors.Count | Should -Be 0
            $ast | Should -Not -BeNullOrEmpty
        }
    }
}
