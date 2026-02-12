BeforeAll {
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "semver-check action name parsing" {
    It "should parse action with duplicate owner prefix correctly" {
        # Simulate action object from status.json
        $action = @{
            owner = "github"
            name = "github_docs"
        }
        
        # Parse using the same logic as Test-ActionSemver
        $fullPath = "$($action.owner)/$($action.name)"
        $upstreamOwner, $upstreamRepo = SplitUrl -url $fullPath
        
        $upstreamOwner | Should -Be "github"
        $upstreamRepo | Should -Be "docs"
    }
    
    It "should parse action with hyphenated duplicate prefix correctly" {
        $action = @{
            owner = "github"
            name = "github_safe-settings"
        }
        
        $fullPath = "$($action.owner)/$($action.name)"
        $upstreamOwner, $upstreamRepo = SplitUrl -url $fullPath
        
        $upstreamOwner | Should -Be "github"
        $upstreamRepo | Should -Be "safe-settings"
    }
    
    It "should parse action with underscored duplicate prefix correctly" {
        $action = @{
            owner = "actions"
            name = "actions_attest-build-provenance"
        }
        
        $fullPath = "$($action.owner)/$($action.name)"
        $upstreamOwner, $upstreamRepo = SplitUrl -url $fullPath
        
        $upstreamOwner | Should -Be "actions"
        $upstreamRepo | Should -Be "attest-build-provenance"
    }
    
    It "should parse normal action without duplicate prefix correctly" {
        $action = @{
            owner = "docker"
            name = "build-push-action"
        }
        
        $fullPath = "$($action.owner)/$($action.name)"
        $upstreamOwner, $upstreamRepo = SplitUrl -url $fullPath
        
        $upstreamOwner | Should -Be "docker"
        $upstreamRepo | Should -Be "build-push-action"
    }
    
    It "should handle action with multiple underscores correctly" {
        $action = @{
            owner = "microsoft"
            name = "microsoft_some_complex_action"
        }
        
        $fullPath = "$($action.owner)/$($action.name)"
        $upstreamOwner, $upstreamRepo = SplitUrl -url $fullPath
        
        $upstreamOwner | Should -Be "microsoft"
        $upstreamRepo | Should -Be "some_complex_action"
    }
    
    It "should handle edge case with hyphen separator duplicate prefix" {
        $action = @{
            owner = "github"
            name = "github-command"
        }
        
        $fullPath = "$($action.owner)/$($action.name)"
        $upstreamOwner, $upstreamRepo = SplitUrl -url $fullPath
        
        $upstreamOwner | Should -Be "github"
        $upstreamRepo | Should -Be "command"
    }
}
