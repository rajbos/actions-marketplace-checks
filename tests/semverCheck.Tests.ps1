BeforeAll {
    . $PSScriptRoot/../.github/workflows/library.ps1
    
    # Helper function to parse action names (mirrors the logic in semver-check.ps1)
    function Parse-ActionName {
        param($owner, $name)
        
        $fullPath = "$owner/$name"
        $upstreamOwner, $upstreamRepo = SplitUrl -url $fullPath
        
        return @{
            Owner = $upstreamOwner
            Repo = $upstreamRepo
        }
    }
}

Describe "semver-check action name parsing" {
    It "should parse action with duplicate owner prefix correctly" {
        $result = Parse-ActionName -owner "github" -name "github_docs"
        
        $result.Owner | Should -Be "github"
        $result.Repo | Should -Be "docs"
    }
    
    It "should parse action with hyphenated duplicate prefix correctly" {
        $result = Parse-ActionName -owner "github" -name "github_safe-settings"
        
        $result.Owner | Should -Be "github"
        $result.Repo | Should -Be "safe-settings"
    }
    
    It "should parse action with underscored duplicate prefix correctly" {
        $result = Parse-ActionName -owner "actions" -name "actions_attest-build-provenance"
        
        $result.Owner | Should -Be "actions"
        $result.Repo | Should -Be "attest-build-provenance"
    }
    
    It "should parse normal action without duplicate prefix correctly" {
        $result = Parse-ActionName -owner "docker" -name "build-push-action"
        
        $result.Owner | Should -Be "docker"
        $result.Repo | Should -Be "build-push-action"
    }
    
    It "should handle action with multiple underscores correctly" {
        $result = Parse-ActionName -owner "microsoft" -name "microsoft_some_complex_action"
        
        $result.Owner | Should -Be "microsoft"
        $result.Repo | Should -Be "some_complex_action"
    }
    
    It "should handle edge case with hyphen separator duplicate prefix" {
        $result = Parse-ActionName -owner "github" -name "github-command"
        
        $result.Owner | Should -Be "github"
        $result.Repo | Should -Be "command"
    }
}
