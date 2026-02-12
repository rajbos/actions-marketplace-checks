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
