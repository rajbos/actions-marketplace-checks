BeforeAll {
    # Set mock tokens to avoid validation errors
    $env:GITHUB_TOKEN = "test_token_mock"
    
    # Load library
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Parallel Update Functions" {
    Context "Split-ForksIntoChunks function" {
        It "Should split forks evenly into chunks" {
            $testData = @(
                @{ name = "repo1"; mirrorFound = $true }
                @{ name = "repo2"; mirrorFound = $true }
                @{ name = "repo3"; mirrorFound = $true }
                @{ name = "repo4"; mirrorFound = $true }
                @{ name = "repo5"; mirrorFound = $true }
                @{ name = "repo6"; mirrorFound = $true }
                @{ name = "repo7"; mirrorFound = $true }
                @{ name = "repo8"; mirrorFound = $true }
            )
            
            $chunks = Split-ForksIntoChunks -existingForks $testData -numberOfChunks 2
            
            $chunks.Count | Should -Be 2
            $chunks[0].Count | Should -Be 4
            $chunks[1].Count | Should -Be 4
        }
        
        It "Should handle uneven splits" {
            $testData = @(
                @{ name = "repo1"; mirrorFound = $true }
                @{ name = "repo2"; mirrorFound = $true }
                @{ name = "repo3"; mirrorFound = $true }
                @{ name = "repo4"; mirrorFound = $true }
                @{ name = "repo5"; mirrorFound = $true }
            )
            
            $chunks = Split-ForksIntoChunks -existingForks $testData -numberOfChunks 2
            
            $chunks.Count | Should -Be 2
            $chunks[0].Count | Should -Be 3  # Ceiling(5/2) = 3
            $chunks[1].Count | Should -Be 2
        }
        
        It "Should only include forks with mirrorFound = true" {
            $testData = @(
                @{ name = "repo1"; mirrorFound = $true }
                @{ name = "repo2"; mirrorFound = $false }
                @{ name = "repo3"; mirrorFound = $true }
                @{ name = "repo4" }  # No mirrorFound property
            )
            
            $chunks = Split-ForksIntoChunks -existingForks $testData -numberOfChunks 2
            
            $chunks.Count | Should -Be 2
            # Should only include repo1 and repo3
            ($chunks[0] + $chunks[1]).Count | Should -Be 2
        }
        
        It "Should handle empty fork list" {
            $testData = @()
            
            $chunks = Split-ForksIntoChunks -existingForks $testData -numberOfChunks 2
            
            $chunks.Count | Should -Be 0
        }
        
        It "Should handle all forks with mirrorFound = false" {
            $testData = @(
                @{ name = "repo1"; mirrorFound = $false }
                @{ name = "repo2"; mirrorFound = $false }
            )
            
            $chunks = Split-ForksIntoChunks -existingForks $testData -numberOfChunks 2
            
            $chunks.Count | Should -Be 0
        }
        
        It "Should handle more chunks than forks" {
            $testData = @(
                @{ name = "repo1"; mirrorFound = $true }
                @{ name = "repo2"; mirrorFound = $true }
            )
            
            $chunks = Split-ForksIntoChunks -existingForks $testData -numberOfChunks 5
            
            # Should create only as many chunks as needed
            $chunks.Count | Should -BeLessOrEqual 5
            # Total items should equal number of valid forks
            $totalItems = 0
            foreach ($key in $chunks.Keys) {
                $totalItems += $chunks[$key].Count
            }
            $totalItems | Should -Be 2
        }
    }
    
    Context "Save-PartialStatusUpdate function" {
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
        
        It "Should save partial status to file" {
            $testData = @(
                @{ name = "repo1"; mirrorFound = $true; lastSynced = "2024-01-01T00:00:00Z" }
                @{ name = "repo2"; mirrorFound = $true; lastSynced = "2024-01-02T00:00:00Z" }
            )
            
            $outputPath = Join-Path $script:testDir "status-partial-0.json"
            
            $result = Save-PartialStatusUpdate -processedForks $testData -chunkId 0 -outputPath $outputPath
            
            $result | Should -Be $true
            Test-Path $outputPath | Should -Be $true
            
            # Verify content
            $saved = Get-Content $outputPath | ConvertFrom-Json
            $saved.Count | Should -Be 2
            $saved[0].name | Should -Be "repo1"
        }
        
        It "Should handle empty fork list" {
            $testData = @()
            
            $outputPath = Join-Path $script:testDir "status-partial-1.json"
            
            $result = Save-PartialStatusUpdate -processedForks $testData -chunkId 1 -outputPath $outputPath
            
            $result | Should -Be $true
            Test-Path $outputPath | Should -Be $true
            
            # Should save empty array
            $saved = Get-Content $outputPath | ConvertFrom-Json
            $saved.Count | Should -Be 0
        }
        
        It "Should handle null fork list" {
            $outputPath = Join-Path $script:testDir "status-partial-2.json"
            
            $result = Save-PartialStatusUpdate -processedForks $null -chunkId 2 -outputPath $outputPath
            
            $result | Should -Be $true
            Test-Path $outputPath | Should -Be $true
        }
    }
    
    Context "Merge-PartialStatusUpdates function" {
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
        
        It "Should merge updates from multiple chunks" {
            # Create current status
            $currentStatus = @(
                [PSCustomObject]@{ name = "repo1"; mirrorFound = $true; lastSynced = $null }
                [PSCustomObject]@{ name = "repo2"; mirrorFound = $true; lastSynced = $null }
                [PSCustomObject]@{ name = "repo3"; mirrorFound = $true; lastSynced = $null }
            )
            
            # Create partial updates
            $partial1 = @(
                [PSCustomObject]@{ name = "repo1"; mirrorFound = $true; lastSynced = "2024-01-01T00:00:00Z" }
            )
            $partial2 = @(
                [PSCustomObject]@{ name = "repo2"; mirrorFound = $true; lastSynced = "2024-01-02T00:00:00Z" }
            )
            
            $partial1File = Join-Path $script:testDir "status-partial-0.json"
            $partial2File = Join-Path $script:testDir "status-partial-1.json"
            
            $partial1 | ConvertTo-Json | Out-File $partial1File -Encoding UTF8
            $partial2 | ConvertTo-Json | Out-File $partial2File -Encoding UTF8
            
            # Merge
            $merged = Merge-PartialStatusUpdates -currentStatus $currentStatus -partialStatusFiles @($partial1File, $partial2File)
            
            $merged.Count | Should -Be 3
            
            # Check that updates were applied
            $repo1 = $merged | Where-Object { $_.name -eq "repo1" } | Select-Object -First 1
            $repo1.lastSynced | Should -Not -BeNullOrEmpty
            
            $repo2 = $merged | Where-Object { $_.name -eq "repo2" } | Select-Object -First 1
            $repo2.lastSynced | Should -Not -BeNullOrEmpty
            
            # repo3 should still have null lastSynced
            $repo3 = $merged | Where-Object { $_.name -eq "repo3" } | Select-Object -First 1
            $repo3.lastSynced | Should -Be $null
        }
        
        It "Should handle missing partial files gracefully" {
            $currentStatus = @(
                [PSCustomObject]@{ name = "repo1"; mirrorFound = $true }
            )
            
            $nonExistentFile = Join-Path $script:testDir "nonexistent.json"
            
            # Should not throw
            { Merge-PartialStatusUpdates -currentStatus $currentStatus -partialStatusFiles @($nonExistentFile) } | Should -Not -Throw
        }
        
        It "Should add new properties from partial updates" {
            $currentStatus = @(
                [PSCustomObject]@{ name = "repo1"; mirrorFound = $true }
            )
            
            $partial = @(
                [PSCustomObject]@{ name = "repo1"; mirrorFound = $true; lastSyncError = "Some error"; upstreamAvailable = $false }
            )
            
            $partialFile = Join-Path $script:testDir "status-partial-0.json"
            $partial | ConvertTo-Json | Out-File $partialFile -Encoding UTF8
            
            $merged = Merge-PartialStatusUpdates -currentStatus $currentStatus -partialStatusFiles @($partialFile)
            
            $repo1 = $merged | Where-Object { $_.name -eq "repo1" } | Select-Object -First 1
            $repo1.lastSyncError | Should -Be "Some error"
            $repo1.upstreamAvailable | Should -Be $false
        }
        
        It "Should handle empty partial update files" {
            $currentStatus = @(
                [PSCustomObject]@{ name = "repo1"; mirrorFound = $true }
            )
            
            $partialFile = Join-Path $script:testDir "status-partial-empty.json"
            "[]" | Out-File $partialFile -Encoding UTF8
            
            $merged = Merge-PartialStatusUpdates -currentStatus $currentStatus -partialStatusFiles @($partialFile)
            
            $merged.Count | Should -Be 1
        }
    }
    
    Context "End-to-end workflow simulation" {
        BeforeEach {
            $script:testDir = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()
            New-Item -ItemType Directory -Path $script:testDir | Out-Null
        }
        
        AfterEach {
            if (Test-Path $script:testDir) {
                Remove-Item -Path $script:testDir -Recurse -Force
            }
        }
        
        It "Should handle complete split-process-merge workflow" {
            # Initial status
            $initialStatus = @(
                [PSCustomObject]@{ name = "repo1"; mirrorFound = $true; lastSynced = $null }
                [PSCustomObject]@{ name = "repo2"; mirrorFound = $true; lastSynced = $null }
                [PSCustomObject]@{ name = "repo3"; mirrorFound = $true; lastSynced = $null }
                [PSCustomObject]@{ name = "repo4"; mirrorFound = $true; lastSynced = $null }
            )
            
            # Split into chunks
            $chunks = Split-ForksIntoChunks -existingForks $initialStatus -numberOfChunks 2
            
            $chunks.Count | Should -Be 2
            
            # Simulate processing each chunk
            $partialFiles = @()
            $chunkId = 0
            foreach ($key in ($chunks.Keys | Sort-Object)) {
                $chunkForks = $chunks[$key]
                
                # Simulate processing - update lastSynced for each fork
                $processedForks = @()
                foreach ($forkName in $chunkForks) {
                    $fork = $initialStatus | Where-Object { $_.name -eq $forkName } | Select-Object -First 1
                    # Clone the object
                    $processed = [PSCustomObject]@{
                        name = $fork.name
                        mirrorFound = $fork.mirrorFound
                        lastSynced = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
                    }
                    $processedForks += $processed
                }
                
                # Save partial update
                $partialFile = Join-Path $script:testDir "status-partial-$chunkId.json"
                Save-PartialStatusUpdate -processedForks $processedForks -chunkId $chunkId -outputPath $partialFile
                $partialFiles += $partialFile
                
                $chunkId++
            }
            
            # Merge all updates
            $merged = Merge-PartialStatusUpdates -currentStatus $initialStatus -partialStatusFiles $partialFiles
            
            $merged.Count | Should -Be 4
            
            # All repos should have lastSynced updated
            foreach ($repo in $merged) {
                $repo.lastSynced | Should -Not -BeNullOrEmpty
            }
        }
    }
}
