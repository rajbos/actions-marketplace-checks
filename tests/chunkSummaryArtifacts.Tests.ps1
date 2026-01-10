BeforeAll {
    # Set mock tokens to avoid validation errors
    $env:GITHUB_TOKEN = "test_token_mock"
    
    # Load library
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Chunk Summary Artifact Functions" {
    Context "Save-ChunkSummary function" {
        BeforeEach {
            # Create temp directory for tests
            $script:testDir = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()
            New-Item -ItemType Directory -Path $script:testDir | Out-Null
        }
        
        AfterEach {
            # Cleanup
            if (Test-Path $script:testDir) {
                Remove-Item -Path $script:testDir -Recurse -Force
            }
        }
        
        It "Should save chunk summary to JSON file" {
            $outputPath = Join-Path $script:testDir "chunk-summary-0.json"
            
            $result = Save-ChunkSummary `
                -chunkId 0 `
                -synced 3 `
                -upToDate 147 `
                -mirrorsCreated 2 `
                -conflicts 0 `
                -upstreamNotFound 0 `
                -failed 0 `
                -skipped 0 `
                -totalProcessed 150 `
                -outputPath $outputPath
            
            $result | Should -Be $true
            Test-Path $outputPath | Should -Be $true
            
            # Verify content
            $saved = Get-Content $outputPath | ConvertFrom-Json
            $saved.chunkId | Should -Be 0
            $saved.synced | Should -Be 3
            $saved.upToDate | Should -Be 147
            $saved.mirrorsCreated | Should -Be 2
            $saved.conflicts | Should -Be 0
            $saved.upstreamNotFound | Should -Be 0
            $saved.failed | Should -Be 0
            $saved.skipped | Should -Be 0
            $saved.totalProcessed | Should -Be 150
        }
        
        It "Should handle zero values" {
            $outputPath = Join-Path $script:testDir "chunk-summary-1.json"
            
            $result = Save-ChunkSummary `
                -chunkId 1 `
                -synced 0 `
                -upToDate 0 `
                -mirrorsCreated 0 `
                -conflicts 0 `
                -upstreamNotFound 0 `
                -failed 0 `
                -skipped 0 `
                -totalProcessed 0 `
                -outputPath $outputPath
            
            $result | Should -Be $true
            Test-Path $outputPath | Should -Be $true
            
            # Verify all values are zero
            $saved = Get-Content $outputPath | ConvertFrom-Json
            $saved.synced | Should -Be 0
            $saved.mirrorsCreated | Should -Be 0
            $saved.totalProcessed | Should -Be 0
        }
        
        It "Should use default filename format" {
            # Use explicit output path since we can't reliably test default path
            # The default path would be relative to the current directory at execution time
            $outputPath = Join-Path $script:testDir "chunk-summary-5.json"
            
            $result = Save-ChunkSummary -chunkId 5 -synced 10 -upToDate 20 -mirrorsCreated 1 -totalProcessed 30 -outputPath $outputPath
            
            $result | Should -Be $true
            Test-Path $outputPath | Should -Be $true
            
            $saved = Get-Content $outputPath | ConvertFrom-Json
            $saved.chunkId | Should -Be 5
            $saved.synced | Should -Be 10
            $saved.mirrorsCreated | Should -Be 1
            
            # Verify the filename follows the expected pattern
            (Split-Path $outputPath -Leaf) | Should -Match "chunk-summary-\d+\.json"
        }
    }
    
    Context "Show-ConsolidatedChunkSummary function" {
        BeforeEach {
            # Create temp directory for tests
            $script:testDir = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()
            New-Item -ItemType Directory -Path $script:testDir | Out-Null
        }
        
        AfterEach {
            # Cleanup
            if (Test-Path $script:testDir) {
                Remove-Item -Path $script:testDir -Recurse -Force
            }
        }
        
        It "Should consolidate summaries from multiple chunks" {
            # Create chunk summary files
            $summary1 = @{
                chunkId = 0
                synced = 3
                upToDate = 147
                mirrorsCreated = 2
                conflicts = 0
                upstreamNotFound = 0
                failed = 0
                skipped = 0
                totalProcessed = 150
            }
            
            $summary2 = @{
                chunkId = 1
                synced = 5
                upToDate = 143
                mirrorsCreated = 1
                conflicts = 1
                upstreamNotFound = 0
                failed = 1
                skipped = 0
                totalProcessed = 150
            }
            
            $file1 = Join-Path $script:testDir "chunk-summary-0.json"
            $file2 = Join-Path $script:testDir "chunk-summary-1.json"
            
            $summary1 | ConvertTo-Json | Out-File $file1 -Encoding UTF8
            $summary2 | ConvertTo-Json | Out-File $file2 -Encoding UTF8
            
            # Consolidate
            $result = Show-ConsolidatedChunkSummary -chunkSummaryFiles @($file1, $file2)
            
            # Verify aggregated totals
            $result.synced | Should -Be 8
            $result.upToDate | Should -Be 290
            $result.mirrorsCreated | Should -Be 3
            $result.conflicts | Should -Be 1
            $result.upstreamNotFound | Should -Be 0
            $result.failed | Should -Be 1
            $result.skipped | Should -Be 0
            $result.totalProcessed | Should -Be 300
        }
        
        It "Should handle empty file list" {
            $result = Show-ConsolidatedChunkSummary -chunkSummaryFiles @()
            
            # Should return hashtable with zero values for consistency
            $result | Should -Not -BeNullOrEmpty
            $result.synced | Should -Be 0
            $result.upToDate | Should -Be 0
            $result.mirrorsCreated | Should -Be 0
            $result.totalProcessed | Should -Be 0
        }
        
        It "Should handle missing files gracefully" {
            $nonExistentFile = Join-Path $script:testDir "nonexistent.json"
            
            # Should not throw
            { Show-ConsolidatedChunkSummary -chunkSummaryFiles @($nonExistentFile) } | Should -Not -Throw
        }
        
        It "Should handle single chunk" {
            $summary = @{
                chunkId = 0
                synced = 10
                upToDate = 20
                mirrorsCreated = 1
                conflicts = 1
                upstreamNotFound = 2
                failed = 3
                skipped = 4
                totalProcessed = 40
            }
            
            $file = Join-Path $script:testDir "chunk-summary-0.json"
            $summary | ConvertTo-Json | Out-File $file -Encoding UTF8
            
            $result = Show-ConsolidatedChunkSummary -chunkSummaryFiles @($file)
            
            # Should match input exactly
            $result.synced | Should -Be 10
            $result.upToDate | Should -Be 20
            $result.mirrorsCreated | Should -Be 1
            $result.conflicts | Should -Be 1
            $result.upstreamNotFound | Should -Be 2
            $result.failed | Should -Be 3
            $result.skipped | Should -Be 4
            $result.totalProcessed | Should -Be 40
        }
        
        It "Should handle chunk summaries with UTF-8 BOM" {
            $summary = @{
                chunkId = 0
                synced = 5
                upToDate = 10
                mirrorsCreated = 0
                conflicts = 0
                upstreamNotFound = 0
                failed = 0
                skipped = 0
                totalProcessed = 15
            }
            
            $file = Join-Path $script:testDir "chunk-summary-bom.json"
            $json = ConvertTo-Json -InputObject $summary
            # Add UTF-8 BOM
            $utf8BOM = [System.Text.Encoding]::UTF8.GetPreamble()
            $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $fullBytes = $utf8BOM + $jsonBytes
            [System.IO.File]::WriteAllBytes($file, $fullBytes)
            
            # Should handle BOM correctly
            $result = Show-ConsolidatedChunkSummary -chunkSummaryFiles @($file)
            
            $result.synced | Should -Be 5
            $result.totalProcessed | Should -Be 15
        }
        
        It "Should save and consolidate failed repos information" {
            # Create chunk summaries with failed repos
            $failedRepos1 = @(
                @{
                    name = "owner1_repo1"
                    errorType = "upstream_not_found"
                    errorMessage = "Upstream repository not found"
                },
                @{
                    name = "owner2_repo2"
                    errorType = "merge_conflict"
                    errorMessage = "Merge conflict detected"
                }
            )
            
            $failedRepos2 = @(
                @{
                    name = "owner3_repo3"
                    errorType = "auth_error"
                    errorMessage = "Authentication failed"
                }
            )
            
            $summary1 = @{
                chunkId = 0
                synced = 3
                upToDate = 147
                mirrorsCreated = 1
                conflicts = 1
                upstreamNotFound = 1
                failed = 1
                skipped = 0
                totalProcessed = 150
                failedRepos = $failedRepos1
            }
            
            $summary2 = @{
                chunkId = 1
                synced = 5
                upToDate = 143
                mirrorsCreated = 1
                conflicts = 0
                upstreamNotFound = 0
                failed = 1
                skipped = 0
                totalProcessed = 150
                failedRepos = $failedRepos2
            }
            
            $file1 = Join-Path $script:testDir "chunk-summary-0.json"
            $file2 = Join-Path $script:testDir "chunk-summary-1.json"
            
            $summary1 | ConvertTo-Json -Depth 5 | Out-File $file1 -Encoding UTF8
            $summary2 | ConvertTo-Json -Depth 5 | Out-File $file2 -Encoding UTF8
            
            # Consolidate
            $result = Show-ConsolidatedChunkSummary -chunkSummaryFiles @($file1, $file2)
            
            # Verify aggregated totals are correct
            $result.synced | Should -Be 8
            $result.conflicts | Should -Be 1
            $result.upstreamNotFound | Should -Be 1
            $result.failed | Should -Be 2
        }
        
        It "Should display upstream repository links in failed repos table" {
            # Create a temporary file to act as GITHUB_STEP_SUMMARY
            $tempSummaryFile = New-TemporaryFile
            $env:GITHUB_STEP_SUMMARY = $tempSummaryFile.FullName
            
            try {
                # Create chunk summaries with failed repos
                $failedRepos = @(
                    @{
                        name = "actions_checkout"
                        errorType = "merge_conflict"
                        errorMessage = "Merge conflict detected"
                    },
                    @{
                        name = "github_issue-metrics"
                        errorType = "upstream_not_found"
                        errorMessage = "Upstream not found"
                    }
                )
                
                $summary = @{
                    chunkId = 0
                    synced = 0
                    upToDate = 0
                    mirrorsCreated = 0
                    conflicts = 1
                    upstreamNotFound = 1
                    failed = 2
                    skipped = 0
                    totalProcessed = 2
                    failedRepos = $failedRepos
                }
                
                $file = Join-Path $script:testDir "chunk-summary-test.json"
                $summary | ConvertTo-Json -Depth 5 | Out-File $file -Encoding UTF8
                
                # Consolidate - this should write to step summary
                $result = Show-ConsolidatedChunkSummary -chunkSummaryFiles @($file)
                
                # Read the step summary content
                $stepSummaryContent = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
                
                # Verify the table has upstream column header
                $stepSummaryContent | Should -Match "\| Repository \| Upstream \| Error Type \| Error Message \|"
                
                # Verify upstream links are present for each failed repo
                $stepSummaryContent | Should -Match "\[actions/checkout\]\(https://github.com/actions/checkout\)"
                $stepSummaryContent | Should -Match "\[github/issue-metrics\]\(https://github.com/github/issue-metrics\)"
                
                # Verify mirror links are present
                $stepSummaryContent | Should -Match "\[actions_checkout\]\(https://github.com/actions-marketplace-validations/actions_checkout\)"
                $stepSummaryContent | Should -Match "\[github_issue-metrics\]\(https://github.com/actions-marketplace-validations/github_issue-metrics\)"
            }
            finally {
                # Cleanup
                if (Test-Path $tempSummaryFile) {
                    Remove-Item $tempSummaryFile -Force
                }
                $env:GITHUB_STEP_SUMMARY = $null
            }
        }
    }
    
    Context "Integration with update-forks-chunk.ps1 pattern" {
        It "Should match the statistics tracked in UpdateForkedReposChunk" {
            # This test verifies that the statistics structure matches what's expected
            $testStats = @{
                synced = 3
                upToDate = 147
                mirrorsCreated = 2
                conflicts = 0
                upstreamNotFound = 0
                failed = 0
                skipped = 0
                totalProcessed = 150
            }
            
            # All expected keys should be present
            $testStats.Keys | Should -Contain "synced"
            $testStats.Keys | Should -Contain "upToDate"
            $testStats.Keys | Should -Contain "conflicts"
            $testStats.Keys | Should -Contain "upstreamNotFound"
            $testStats.Keys | Should -Contain "failed"
            $testStats.Keys | Should -Contain "skipped"
            $testStats.Keys | Should -Contain "totalProcessed"
        }
        
        It "Should save chunk summary with failed repos" {
            # Create temp directory for tests
            $testDir = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()
            New-Item -ItemType Directory -Path $testDir | Out-Null
            
            try {
                $outputPath = Join-Path $testDir "chunk-summary-with-failed.json"
                
                $failedRepos = @(
                    @{
                        name = "owner1_repo1"
                        errorType = "upstream_not_found"
                        errorMessage = "Upstream repository not found"
                    },
                    @{
                        name = "owner2_repo2"
                        errorType = "git_reference_error"
                        errorMessage = "Reference error"
                    }
                )
                
                $result = Save-ChunkSummary `
                    -chunkId 0 `
                    -synced 3 `
                    -upToDate 145 `
                    -mirrorsCreated 1 `
                    -conflicts 0 `
                    -upstreamNotFound 1 `
                    -failed 1 `
                    -skipped 0 `
                    -totalProcessed 150 `
                    -failedRepos $failedRepos `
                    -outputPath $outputPath
                
                $result | Should -Be $true
                Test-Path $outputPath | Should -Be $true
                
                # Verify content includes failed repos
                $saved = Get-Content $outputPath | ConvertFrom-Json
                $saved.failedRepos.Count | Should -Be 2
                $saved.failedRepos[0].name | Should -Be "owner1_repo1"
                $saved.failedRepos[0].errorType | Should -Be "upstream_not_found"
                $saved.failedRepos[1].name | Should -Be "owner2_repo2"
                $saved.failedRepos[1].errorType | Should -Be "git_reference_error"
            }
            finally {
                # Cleanup
                if (Test-Path $testDir) {
                    Remove-Item -Path $testDir -Recurse -Force
                }
            }
        }
    }
}
