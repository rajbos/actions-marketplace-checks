BeforeAll {
    . $PSScriptRoot/../.github/workflows/library.ps1
    . $PSScriptRoot/../.github/workflows/semver-check.ps1
}

Describe "semver-check action name parsing" {
    It "should parse action with duplicate owner prefix correctly" {
        $action = @{ owner = "github"; name = "github_docs" }
        $upstreamOwner, $upstreamRepo = Get-UpstreamRepoName -action $action
        
        $upstreamOwner | Should -Be "github"
        $upstreamRepo | Should -Be "docs"
    }
    
    It "should parse action with hyphenated duplicate prefix correctly" {
        $action = @{ owner = "github"; name = "github_safe-settings" }
        $upstreamOwner, $upstreamRepo = Get-UpstreamRepoName -action $action
        
        $upstreamOwner | Should -Be "github"
        $upstreamRepo | Should -Be "safe-settings"
    }
    
    It "should parse action with underscored duplicate prefix correctly" {
        $action = @{ owner = "actions"; name = "actions_attest-build-provenance" }
        $upstreamOwner, $upstreamRepo = Get-UpstreamRepoName -action $action
        
        $upstreamOwner | Should -Be "actions"
        $upstreamRepo | Should -Be "attest-build-provenance"
    }
    
    It "should parse normal action without duplicate prefix correctly" {
        $action = @{ owner = "docker"; name = "build-push-action" }
        $upstreamOwner, $upstreamRepo = Get-UpstreamRepoName -action $action
        
        $upstreamOwner | Should -Be "docker"
        $upstreamRepo | Should -Be "build-push-action"
    }
    
    It "should handle action with multiple underscores correctly" {
        $action = @{ owner = "microsoft"; name = "microsoft_some_complex_action" }
        $upstreamOwner, $upstreamRepo = Get-UpstreamRepoName -action $action
        
        $upstreamOwner | Should -Be "microsoft"
        $upstreamRepo | Should -Be "some_complex_action"
    }
    
    It "should handle edge case with hyphen separator duplicate prefix" {
        $action = @{ owner = "github"; name = "github-command" }
        $upstreamOwner, $upstreamRepo = Get-UpstreamRepoName -action $action
        
        $upstreamOwner | Should -Be "github"
        $upstreamRepo | Should -Be "command"
    }
}

Describe "semver-check summary report" {
    BeforeEach {
        # Set up a temporary file to capture summary output
        $env:GITHUB_STEP_SUMMARY = [System.IO.Path]::GetTempFileName()
    }
    
    AfterEach {
        # Clean up temporary file
        if ($env:GITHUB_STEP_SUMMARY -and (Test-Path $env:GITHUB_STEP_SUMMARY)) {
            Remove-Item $env:GITHUB_STEP_SUMMARY -Force
        }
    }
    
    It "should create summary table for actions with issues" {
        $results = @(
            @{
                Repository = "actions/checkout"
                Owner = "actions"
                Name = "checkout"
                Success = $true
                Issues = @(
                    @{ Severity = "error"; Message = "Tag v1 is missing"; Status = "failed" }
                    @{ Severity = "warning"; Message = "Tag v2 may be outdated"; Status = "unfixable" }
                )
                Output = "Return Code: 1, Fixed: 5, Failed: 1, Unfixable: 1"
                Error = $null
                RateLimited = $false
                Dependents = "1,234"
            }
            @{
                Repository = "actions/setup-node"
                Owner = "actions"
                Name = "setup-node"
                Success = $true
                Issues = @()
                Output = "Return Code: 0, Fixed: 0, Failed: 0, Unfixable: 0"
                Error = $null
                RateLimited = $false
                Dependents = "5,678"
            }
        )
        
        Write-SummaryReport -results $results
        
        $summaryContent = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
        
        # Verify overall statistics table exists
        $summaryContent | Should -Match "## Overall Statistics"
        $summaryContent | Should -Match "Repos with issues"
        $summaryContent | Should -Match "Repos without issues"
        $summaryContent | Should -Match "Repos with more than 5 issues"
        
        # Verify table header exists with simplified columns including Dependents
        $summaryContent | Should -Match "## Issue Summary by Repository"
        $summaryContent | Should -Match "\| Repository \| Total Issues \| Issue Types \| Dependents \|"
        
        # Verify table row for actions/checkout includes issue types and dependents
        $summaryContent | Should -Match "\| actions/checkout \| 2 \|"
        $summaryContent | Should -Match "Missing Tag"
        $summaryContent | Should -Match "Outdated"
        $summaryContent | Should -Match "1,234"
        
        # Verify detailed information is in collapsible section
        $summaryContent | Should -Match "<details>"
        $summaryContent | Should -Match "<summary><b>actions/checkout</b>"
        $summaryContent | Should -Match "</details>"
        
        # Verify clean actions section
        $summaryContent | Should -Match "## ✅ Actions Without Issues"
        $summaryContent | Should -Match "actions/setup-node"
    }
    
    It "should handle results with no issues" {
        $results = @(
            @{
                Repository = "actions/checkout"
                Owner = "actions"
                Name = "checkout"
                Success = $true
                Issues = @()
                Output = "Return Code: 0, Fixed: 0, Failed: 0, Unfixable: 0"
                Error = $null
                RateLimited = $false
                Dependents = $null
            }
        )
        
        Write-SummaryReport -results $results
        
        $summaryContent = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
        
        # Should have overall statistics table
        $summaryContent | Should -Match "## Overall Statistics"
        $summaryContent | Should -Match "Repos without issues \| 1 \| 100%"
        
        # Should not have issue summary table when no issues
        $summaryContent | Should -Not -Match "## Issue Summary by Repository"
        
        # Should have clean actions section
        $summaryContent | Should -Match "## ✅ Actions Without Issues"
        $summaryContent | Should -Match "actions/checkout"
    }
    
    It "should properly categorize issue types" {
        $results = @(
            @{
                Repository = "docker/build-push-action"
                Owner = "docker"
                Name = "build-push-action"
                Success = $true
                Issues = @(
                    @{ Severity = "error"; Message = "Major version tag missing"; Status = "failed" }
                    @{ Severity = "error"; Message = "Minor version tag missing"; Status = "failed" }
                    @{ Severity = "warning"; Message = "Tag format could be improved"; Status = "unfixable" }
                )
                Output = "Return Code: 1, Fixed: 0, Failed: 2, Unfixable: 1"
                Error = $null
                RateLimited = $false
                Dependents = "N/A"
            }
        )
        
        Write-SummaryReport -results $results
        
        $summaryContent = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
        
        # Verify issue types are extracted and shown
        $summaryContent | Should -Match "\| docker/build-push-action \| 3 \|"
        $summaryContent | Should -Match "Missing MAJ Tag"
        $summaryContent | Should -Match "Missing MIN Tag"
        $summaryContent | Should -Match "Format Issue"
        $summaryContent | Should -Match "N/A"
    }
    
    It "should calculate overall statistics correctly" {
        $results = @(
            @{
                Repository = "actions/checkout"
                Owner = "actions"
                Name = "checkout"
                Success = $true
                Issues = @(
                    @{ Severity = "error"; Message = "Tag v1 is missing"; Status = "failed" }
                )
                Output = "Return Code: 1, Fixed: 0, Failed: 1, Unfixable: 0"
                Error = $null
                RateLimited = $false
                Dependents = "100"
            }
            @{
                Repository = "actions/setup-node"
                Owner = "actions"
                Name = "setup-node"
                Success = $true
                Issues = @()
                Output = "Return Code: 0, Fixed: 0, Failed: 0, Unfixable: 0"
                Error = $null
                RateLimited = $false
                Dependents = "200"
            }
            @{
                Repository = "docker/build-push-action"
                Owner = "docker"
                Name = "build-push-action"
                Success = $true
                Issues = @(
                    @{ Severity = "error"; Message = "Tag v1 is missing"; Status = "failed" }
                    @{ Severity = "error"; Message = "Tag v2 is missing"; Status = "failed" }
                    @{ Severity = "error"; Message = "Tag v3 is missing"; Status = "failed" }
                    @{ Severity = "error"; Message = "Tag v4 is missing"; Status = "failed" }
                    @{ Severity = "error"; Message = "Tag v5 is missing"; Status = "failed" }
                    @{ Severity = "error"; Message = "Tag v6 is missing"; Status = "failed" }
                )
                Output = "Return Code: 1, Fixed: 0, Failed: 6, Unfixable: 0"
                Error = $null
                RateLimited = $false
                Dependents = "300"
            }
            @{
                Repository = "microsoft/action"
                Owner = "microsoft"
                Name = "action"
                Success = $true
                Issues = @()
                Output = "Return Code: 0, Fixed: 0, Failed: 0, Unfixable: 0"
                Error = $null
                RateLimited = $false
                Dependents = "400"
            }
        )
        
        Write-SummaryReport -results $results
        
        $summaryContent = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
        
        # Verify overall statistics table
        $summaryContent | Should -Match "## Overall Statistics"
        
        # 2 repos with issues out of 4 total = 50%
        $summaryContent | Should -Match "Repos with issues \| 2 \| 50%"
        
        # 2 repos without issues out of 4 total = 50%
        $summaryContent | Should -Match "Repos without issues \| 2 \| 50%"
        
        # 1 repo with more than 5 issues out of 4 total = 25%
        $summaryContent | Should -Match "Repos with more than 5 issues \| 1 \| 25%"
    }
}
