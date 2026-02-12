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
            }
        )
        
        Write-SummaryReport -results $results
        
        $summaryContent = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
        
        # Verify table header exists
        $summaryContent | Should -Match "## Issue Summary by Repository"
        $summaryContent | Should -Match "\| Repository \| Total Issues \| Errors \| Warnings \| Fixed \| Failed \| Unfixable \|"
        
        # Verify table row for actions/checkout
        $summaryContent | Should -Match "\| actions/checkout \| 2 \| 1 \| 1 \| 5 \| 1 \| 1 \|"
        
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
            }
        )
        
        Write-SummaryReport -results $results
        
        $summaryContent = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
        
        # Should not have issue summary table when no issues
        $summaryContent | Should -Not -Match "## Issue Summary by Repository"
        
        # Should have clean actions section
        $summaryContent | Should -Match "## ✅ Actions Without Issues"
        $summaryContent | Should -Match "actions/checkout"
    }
    
    It "should properly count errors and warnings" {
        $results = @(
            @{
                Repository = "docker/build-push-action"
                Owner = "docker"
                Name = "build-push-action"
                Success = $true
                Issues = @(
                    @{ Severity = "error"; Message = "Error 1"; Status = "failed" }
                    @{ Severity = "error"; Message = "Error 2"; Status = "failed" }
                    @{ Severity = "warning"; Message = "Warning 1"; Status = "unfixable" }
                )
                Output = "Return Code: 1, Fixed: 0, Failed: 2, Unfixable: 1"
                Error = $null
                RateLimited = $false
            }
        )
        
        Write-SummaryReport -results $results
        
        $summaryContent = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
        
        # Verify counts are correct
        $summaryContent | Should -Match "\| docker/build-push-action \| 3 \| 2 \| 1 \| 0 \| 2 \| 1 \|"
    }
}
