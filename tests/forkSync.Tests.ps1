Import-Module Pester

BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Mirror Sync Tests" {
    Context "SyncMirrorWithUpstream function" {
        It "Should have function defined" {
            $result = Get-Command SyncMirrorWithUpstream
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Be "SyncMirrorWithUpstream"
        }
        
        It "Should have required parameters" {
            $command = Get-Command SyncMirrorWithUpstream
            $command.Parameters.Keys | Should -Contain "owner"
            $command.Parameters.Keys | Should -Contain "repo"
            $command.Parameters.Keys | Should -Contain "upstreamOwner"
            $command.Parameters.Keys | Should -Contain "upstreamRepo"
            $command.Parameters.Keys | Should -Contain "access_token"
        }
        
        It "Should return validation error for empty upstream owner" {
            $result = SyncMirrorWithUpstream -owner "test" -repo "test" -upstreamOwner "" -upstreamRepo "test" -access_token "test_token"
            $result.success | Should -Be $false
            $result.error_type | Should -Be "validation_error"
        }
        
        It "Should return validation error for empty upstream repo" {
            $result = SyncMirrorWithUpstream -owner "test" -repo "test" -upstreamOwner "test" -upstreamRepo "" -access_token "test_token"
            $result.success | Should -Be $false
            $result.error_type | Should -Be "validation_error"
        }
        
        It "Should return validation error for null upstream owner" {
            $result = SyncMirrorWithUpstream -owner "test" -repo "test" -upstreamOwner $null -upstreamRepo "test" -access_token "test_token"
            $result.success | Should -Be $false
            $result.error_type | Should -Be "validation_error"
        }
    }
    
    Context "Test-RepositoryExists function" {
        It "Should have function defined" {
            $result = Get-Command Test-RepositoryExists
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Be "Test-RepositoryExists"
        }
        
        It "Should have required parameters" {
            $command = Get-Command Test-RepositoryExists
            $command.Parameters.Keys | Should -Contain "owner"
            $command.Parameters.Keys | Should -Contain "repo"
            $command.Parameters.Keys | Should -Contain "access_token"
        }
        
        It "Should return false for empty owner" {
            $result = Test-RepositoryExists -owner "" -repo "test" -access_token "test_token"
            $result | Should -Be $false
        }
        
        It "Should return false for empty repo" {
            $result = Test-RepositoryExists -owner "test" -repo "" -access_token "test_token"
            $result | Should -Be $false
        }
        
        It "Should return false for null owner" {
            $result = Test-RepositoryExists -owner $null -repo "test" -access_token "test_token"
            $result | Should -Be $false
        }
        
        It "Should return false for whitespace-only owner" {
            $result = Test-RepositoryExists -owner "   " -repo "test" -access_token "test_token"
            $result | Should -Be $false
        }
    }
    
    Context "Invoke-GitCommandWithRetry function" {
        It "Should have function defined" {
            $result = Get-Command Invoke-GitCommandWithRetry
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Be "Invoke-GitCommandWithRetry"
        }
        
        It "Should have required parameters" {
            $command = Get-Command Invoke-GitCommandWithRetry
            $command.Parameters.Keys | Should -Contain "GitCommand"
            $command.Parameters.Keys | Should -Contain "GitArguments"
            $command.Parameters.Keys | Should -Contain "Description"
            $command.Parameters.Keys | Should -Contain "MaxRetries"
            $command.Parameters.Keys | Should -Contain "InitialDelaySeconds"
        }
        
        It "Should return success for git version command" {
            $result = Invoke-GitCommandWithRetry -GitCommand "--version" -Description "Test git version" -MaxRetries 1 -InitialDelaySeconds 1
            $result.Success | Should -Be $true
            $result.ExitCode | Should -Be 0
        }
        
        It "Should return failure for non-existent command" {
            $result = Invoke-GitCommandWithRetry -GitCommand "nonexistent-command" -Description "Test failure" -MaxRetries 1 -InitialDelaySeconds 1
            $result.Success | Should -Be $false
        }
    }
    
    Context "UpdateForkedRepos function from update-forks.ps1" {
        It "Should have UpdateForkedRepos function defined after script execution" {
            # Dot source the script content to define functions without executing main logic
            $scriptContent = Get-Content $PSScriptRoot/../.github/workflows/update-forks.ps1 -Raw
            # Extract just the function definition
            $functionMatch = [regex]::Match($scriptContent, 'function UpdateForkedRepos\s*\{[\s\S]*?\n\}(?=\s*\n)')
            
            $functionMatch.Success | Should -Be $true
            $functionMatch.Value | Should -Not -BeNullOrEmpty
        }

        It "Should create missing mirror and retry sync when mirror_not_found" {
            # Arrange: Define a real stub function first (not just a Mock)
            # This ensures the function exists when UpdateForkedRepos checks for it
            function Global:ForkActionRepo {
                Param (
                    $owner,
                    $repo
                )
                return $true
            }
            
            # Mock upstream owner/repo resolution from name
            Mock GetOrgActionInfo { return @("and-fm", "k8s-yaml-action") }

            # Track sync calls to simulate first failure then success on retry
            $script:syncCalls = 0
            Mock SyncMirrorWithUpstream {
                $script:syncCalls++ | Out-Null
                if ($script:syncCalls -eq 1) {
                    return @{ success = $false; message = "Mirror repository not found"; error_type = "mirror_not_found" }
                }
                else {
                    return @{ success = $true; message = "Successfully fetched and merged from upstream" }
                }
            }
            
            # Now define UpdateForkedRepos function
            $scriptContent = Get-Content $PSScriptRoot/../.github/workflows/update-forks.ps1 -Raw
            $functionMatch = [regex]::Match($scriptContent, 'function UpdateForkedRepos\s*\{[\s\S]*?\n\}(?=\s*\n)')
            $functionMatch.Success | Should -Be $true
            Invoke-Expression $functionMatch.Value

            # Prepare a single existing fork entry
            $existingForks = @(@{ name = "and-fm_k8s-yaml-action"; mirrorFound = $true })

            # Act: run update for 1 repo
            $result = UpdateForkedRepos -existingForks $existingForks -numberOfReposToDo 1

            # Assert: result should be the fork array
            # The function returns $existingForks, which should be a single-item array
            $result | Should -Not -BeNullOrEmpty
            # In PowerShell, when a function returns an array, it might be unrolled
            # If $result is an array with nested items, we need to handle it properly
            if ($result -is [array] -and $result.Count -gt 1) {
                # Check if first item is what we expect (a hashtable with 'name' property)
                $fork = $result[0]
            } else {
                $fork = $result
            }
            
            # Verify the fork has the expected properties
            $fork | Should -Not -BeNullOrEmpty
            $fork.name | Should -Be "and-fm_k8s-yaml-action"
            $fork.mirrorFound | Should -Be $true
            $fork.lastSynced | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Disable-GitHubActions function" {
        It "Should have function defined" {
            $result = Get-Command Disable-GitHubActions
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Be "Disable-GitHubActions"
        }
        
        It "Should have required parameters" {
            $command = Get-Command Disable-GitHubActions
            $command.Parameters.Keys | Should -Contain "owner"
            $command.Parameters.Keys | Should -Contain "repo"
            $command.Parameters.Keys | Should -Contain "access_token"
        }
        
        It "Should return false for empty owner" {
            $result = Disable-GitHubActions -owner "" -repo "test" -access_token "test_token" 3>$null
            $result | Should -Be $false
        }
        
        It "Should return false for empty repo" {
            $result = Disable-GitHubActions -owner "test" -repo "" -access_token "test_token" 3>$null
            $result | Should -Be $false
        }
        
        It "Should return false for null owner" {
            $result = Disable-GitHubActions -owner $null -repo "test" -access_token "test_token" 3>$null
            $result | Should -Be $false
        }
        
        It "Should return false for whitespace-only owner" {
            $result = Disable-GitHubActions -owner "   " -repo "test" -access_token "test_token" 3>$null
            $result | Should -Be $false
        }
        
        It "Should return false for whitespace-only repo" {
            $result = Disable-GitHubActions -owner "test" -repo "   " -access_token "test_token" 3>$null
            $result | Should -Be $false
        }
    }
    
    Context "Get-RepositoryDefaultBranchCommit function" {
        It "Should have function defined" {
            $result = Get-Command Get-RepositoryDefaultBranchCommit
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Be "Get-RepositoryDefaultBranchCommit"
        }
        
        It "Should have required parameters" {
            $command = Get-Command Get-RepositoryDefaultBranchCommit
            $command.Parameters.Keys | Should -Contain "owner"
            $command.Parameters.Keys | Should -Contain "repo"
            $command.Parameters.Keys | Should -Contain "access_token"
        }
        
        It "Should return failure for empty owner" {
            $result = Get-RepositoryDefaultBranchCommit -owner "" -repo "test" -access_token "test_token"
            $result.success | Should -Be $false
            $result.sha | Should -BeNullOrEmpty
            $result.error | Should -Be "Invalid owner or repo"
        }
        
        It "Should return failure for empty repo" {
            $result = Get-RepositoryDefaultBranchCommit -owner "test" -repo "" -access_token "test_token"
            $result.success | Should -Be $false
            $result.sha | Should -BeNullOrEmpty
            $result.error | Should -Be "Invalid owner or repo"
        }
        
        It "Should return failure for null owner" {
            $result = Get-RepositoryDefaultBranchCommit -owner $null -repo "test" -access_token "test_token"
            $result.success | Should -Be $false
            $result.sha | Should -BeNullOrEmpty
        }
        
        It "Should return failure for whitespace-only owner" {
            $result = Get-RepositoryDefaultBranchCommit -owner "   " -repo "test" -access_token "test_token"
            $result.success | Should -Be $false
            $result.error | Should -Be "Invalid owner or repo"
        }
    }
    
    Context "Compare-RepositoryCommitHashes function" {
        It "Should have function defined" {
            $result = Get-Command Compare-RepositoryCommitHashes
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Be "Compare-RepositoryCommitHashes"
        }
        
        It "Should have required parameters" {
            $command = Get-Command Compare-RepositoryCommitHashes
            $command.Parameters.Keys | Should -Contain "sourceOwner"
            $command.Parameters.Keys | Should -Contain "sourceRepo"
            $command.Parameters.Keys | Should -Contain "mirrorOwner"
            $command.Parameters.Keys | Should -Contain "mirrorRepo"
            $command.Parameters.Keys | Should -Contain "access_token"
        }
        
        It "Should return can_compare false for empty source owner" {
            $result = Compare-RepositoryCommitHashes -sourceOwner "" -sourceRepo "test" -mirrorOwner "test" -mirrorRepo "test" -access_token "test_token"
            $result.can_compare | Should -Be $false
            $result.in_sync | Should -Be $false
        }
        
        It "Should return can_compare false for empty source repo" {
            $result = Compare-RepositoryCommitHashes -sourceOwner "test" -sourceRepo "" -mirrorOwner "test" -mirrorRepo "test" -access_token "test_token"
            $result.can_compare | Should -Be $false
            $result.in_sync | Should -Be $false
        }
        
        It "Should return can_compare false for empty mirror owner" {
            $result = Compare-RepositoryCommitHashes -sourceOwner "test" -sourceRepo "test" -mirrorOwner "" -mirrorRepo "test" -access_token "test_token"
            $result.can_compare | Should -Be $false
            $result.in_sync | Should -Be $false
        }
        
        It "Should return can_compare false for empty mirror repo" {
            $result = Compare-RepositoryCommitHashes -sourceOwner "test" -sourceRepo "test" -mirrorOwner "test" -mirrorRepo "" -access_token "test_token"
            $result.can_compare | Should -Be $false
            $result.in_sync | Should -Be $false
        }
        
        It "Should have error message when comparison fails" {
            $result = Compare-RepositoryCommitHashes -sourceOwner "" -sourceRepo "test" -mirrorOwner "test" -mirrorRepo "test" -access_token "test_token"
            $result.error | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "LFS handling in SyncMirrorWithUpstream" {
        It "Should set GIT_LFS_SKIP_SMUDGE environment variable during sync operations" {
            # This test verifies that the fix for LFS errors is in place
            # We check if the code sets the environment variable by examining the function source
            $functionContent = (Get-Command SyncMirrorWithUpstream).Definition
            $functionContent | Should -Match 'GIT_LFS_SKIP_SMUDGE'
        }
        
        It "Should have cleanup code for GIT_LFS_SKIP_SMUDGE environment variable" {
            # Verify that cleanup code exists to remove the environment variable
            $functionContent = (Get-Command SyncMirrorWithUpstream).Definition
            $functionContent | Should -Match 'Remove-Item Env:\\GIT_LFS_SKIP_SMUDGE'
        }
        
        It "Should mention LFS in debug messages" {
            # Verify that the debug messaging indicates LFS handling
            $functionContent = (Get-Command SyncMirrorWithUpstream).Definition
            $functionContent | Should -Match 'LFS skip smudge enabled'
        }
    }
    
    Context "Empty repository handling in SyncMirrorWithUpstream" {
        It "Should detect empty mirror repositories (no commits)" {
            # Verify that the code checks for empty repos by looking for the unknown revision error
            $functionContent = (Get-Command SyncMirrorWithUpstream).Definition
            $functionContent | Should -Match 'unknown revision'
        }
        
        It "Should have special handling for empty mirror repositories" {
            # Verify that there's code to handle empty repos with initial sync
            $functionContent = (Get-Command SyncMirrorWithUpstream).Definition
            $functionContent | Should -Match 'isEmptyRepo'
        }
        
        It "Should perform initial sync for empty repositories" {
            # Verify that the code performs a reset for empty repos instead of merge
            $functionContent = (Get-Command SyncMirrorWithUpstream).Definition
            $functionContent | Should -Match 'Performing initial sync'
            $functionContent | Should -Match 'git reset --hard'
        }
        
        It "Should return initial_sync merge type for empty repositories" {
            # Verify that the return value distinguishes between initial sync and merge
            $functionContent = (Get-Command SyncMirrorWithUpstream).Definition
            $functionContent | Should -Match 'initial_sync'
        }
        
        It "Should not throw git reference error for empty repositories" {
            # Verify that the code doesn't throw on unknown revision when it's an empty repo
            $functionContent = (Get-Command SyncMirrorWithUpstream).Definition
            # Should check for empty repo condition before throwing
            $functionContent | Should -Match 'does not have any commits yet'
        }
    }
    
    Context "Force update on merge conflict in SyncMirrorWithUpstream" {
        It "Should have force update logic for merge conflicts" {
            $functionContent = (Get-Command SyncMirrorWithUpstream).Definition
            # Verify that merge conflict is detected
            $functionContent | Should -Match 'Merge conflict detected'
        }
        
        It "Should reset to upstream on merge conflict" {
            $functionContent = (Get-Command SyncMirrorWithUpstream).Definition
            # Verify that we reset to upstream when conflict is detected
            $functionContent | Should -Match 'Force updating mirror to match upstream'
            # Check that we call git reset --hard with upstream reference
            $functionContent | Should -Match 'git reset --hard \$resetRef'
            $functionContent | Should -Match '\$resetRef = "refs/remotes/upstream/\$currentBranch"'
        }
        
        It "Should set needForcePush flag on merge conflict" {
            $functionContent = (Get-Command SyncMirrorWithUpstream).Definition
            # Verify that we track when force push is needed
            $functionContent | Should -Match '\$needForcePush\s*=\s*\$true'
        }
        
        It "Should use force push when needForcePush is set" {
            $functionContent = (Get-Command SyncMirrorWithUpstream).Definition
            # Verify that we use --force flag when pushing after conflict resolution
            $functionContent | Should -Match '--force'
            $functionContent | Should -Match 'Force push to mirror'
        }
        
        It "Should return force_update merge type for conflict resolution" {
            $functionContent = (Get-Command SyncMirrorWithUpstream).Definition
            # Verify that the return value distinguishes force updates
            $functionContent | Should -Match 'force_update'
            $functionContent | Should -Match 'resolved merge conflict'
        }
        
        It "Should not abort merge without attempting reset" {
            $functionContent = (Get-Command SyncMirrorWithUpstream).Definition
            # Verify that merge --abort is called before reset (not throwing immediately)
            $matches = [regex]::Matches($functionContent, 'git merge --abort')
            $matches.Count | Should -BeGreaterOrEqual 1
            # And that we don't throw immediately after abort when it's a conflict
            $conflictHandling = [regex]::Match($functionContent, 'if \(\$mergeOutput -like "\*conflict\*"[\s\S]*?\}')
            $conflictHandling.Value | Should -Not -Match 'throw "Merge conflict detected"'
        }
    }
}
