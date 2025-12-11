BeforeAll {
    # Set mock tokens to avoid validation errors
    $env:GITHUB_TOKEN = "test_token_mock"
    
    # Load library
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Conditional Chunk Summary Logging" {
    Context "Initialize-ChunkSummaryBuffer function" {
        It "Should create a buffer with correct initial state" {
            $buffer = Initialize-ChunkSummaryBuffer -chunkId 1
            
            $buffer.ChunkId | Should -Be 1
            $null -ne $buffer.Messages | Should -Be $true
            $buffer.Messages.Count | Should -Be 0
            $buffer.HasErrors | Should -Be $false
        }
        
        It "Should accept different chunk IDs" {
            $buffer1 = Initialize-ChunkSummaryBuffer -chunkId 5
            $buffer2 = Initialize-ChunkSummaryBuffer -chunkId 10
            
            $buffer1.ChunkId | Should -Be 5
            $buffer2.ChunkId | Should -Be 10
        }
    }
    
    Context "Add-ChunkMessage function" {
        It "Should add messages to the buffer" {
            $buffer = Initialize-ChunkSummaryBuffer -chunkId 1
            
            Add-ChunkMessage -buffer $buffer -message "Test message 1"
            Add-ChunkMessage -buffer $buffer -message "Test message 2"
            
            $buffer.Messages.Count | Should -Be 2
            $buffer.Messages[0] | Should -Be "Test message 1"
            $buffer.Messages[1] | Should -Be "Test message 2"
        }
        
        It "Should not mark buffer as having errors for normal messages" {
            $buffer = Initialize-ChunkSummaryBuffer -chunkId 1
            
            Add-ChunkMessage -buffer $buffer -message "Normal message"
            
            $buffer.HasErrors | Should -Be $false
        }
        
        It "Should mark buffer as having errors when isError is true" {
            $buffer = Initialize-ChunkSummaryBuffer -chunkId 1
            
            Add-ChunkMessage -buffer $buffer -message "Error message" -isError $true
            
            $buffer.HasErrors | Should -Be $true
        }
        
        It "Should keep HasErrors true once an error is added" {
            $buffer = Initialize-ChunkSummaryBuffer -chunkId 1
            
            Add-ChunkMessage -buffer $buffer -message "Normal message"
            $buffer.HasErrors | Should -Be $false
            
            Add-ChunkMessage -buffer $buffer -message "Error message" -isError $true
            $buffer.HasErrors | Should -Be $true
            
            Add-ChunkMessage -buffer $buffer -message "Another normal message"
            $buffer.HasErrors | Should -Be $true
        }
    }
    
    Context "Write-ChunkSummary function" {
        BeforeEach {
            # Create a temporary file to act as GITHUB_STEP_SUMMARY
            $tempFile = New-TemporaryFile
            $env:GITHUB_STEP_SUMMARY = $tempFile.FullName
        }
        
        AfterEach {
            # Clean up the temporary file
            if (Test-Path $env:GITHUB_STEP_SUMMARY) {
                Remove-Item $env:GITHUB_STEP_SUMMARY -Force
            }
            $env:GITHUB_STEP_SUMMARY = $null
        }
        
        It "Should not write to step summary when no errors occurred" {
            $buffer = Initialize-ChunkSummaryBuffer -chunkId 1
            Add-ChunkMessage -buffer $buffer -message "Success message 1"
            Add-ChunkMessage -buffer $buffer -message "Success message 2"
            
            Write-ChunkSummary -buffer $buffer
            
            if (Test-Path $env:GITHUB_STEP_SUMMARY) {
                $content = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
                $content | Should -BeNullOrEmpty
            }
        }
        
        It "Should write to step summary when errors occurred" {
            $buffer = Initialize-ChunkSummaryBuffer -chunkId 1
            Add-ChunkMessage -buffer $buffer -message "Normal message"
            Add-ChunkMessage -buffer $buffer -message "Error message" -isError $true
            Add-ChunkMessage -buffer $buffer -message "Another message"
            
            Write-ChunkSummary -buffer $buffer
            
            $content = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
            $content | Should -Not -BeNullOrEmpty
            $content | Should -Match "Normal message"
            $content | Should -Match "Error message"
            $content | Should -Match "Another message"
        }
        
        It "Should include all messages when errors occurred" {
            $buffer = Initialize-ChunkSummaryBuffer -chunkId 2
            Add-ChunkMessage -buffer $buffer -message "# Chunk 2 Processing"
            Add-ChunkMessage -buffer $buffer -message "Processing 10 items"
            Add-ChunkMessage -buffer $buffer -message "⚠️ Warning: Item failed" -isError $true
            Add-ChunkMessage -buffer $buffer -message "Completed 9 items"
            
            Write-ChunkSummary -buffer $buffer
            
            $content = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
            
            # Should contain all messages
            $content | Should -Match "Chunk 2 Processing"
            $content | Should -Match "Processing 10 items"
            $content | Should -Match "Warning: Item failed"
            $content | Should -Match "Completed 9 items"
        }
        
        It "Should handle empty GITHUB_STEP_SUMMARY environment variable gracefully" {
            $env:GITHUB_STEP_SUMMARY = $null
            
            $buffer = Initialize-ChunkSummaryBuffer -chunkId 1
            Add-ChunkMessage -buffer $buffer -message "Error message" -isError $true
            
            # Should not throw
            { Write-ChunkSummary -buffer $buffer } | Should -Not -Throw
        }
    }
    
    Context "Integration with chunk processing workflow" {
        It "Should follow the expected workflow pattern for success case" {
            $buffer = Initialize-ChunkSummaryBuffer -chunkId 1
            
            # Simulate successful processing
            Add-ChunkMessage -buffer $buffer -message "# Chunk 1 - Processing"
            Add-ChunkMessage -buffer $buffer -message "Processing 5 items"
            Add-ChunkMessage -buffer $buffer -message "✓ Completed successfully"
            
            Write-ChunkSummary -buffer $buffer
            
            # Verify no errors were flagged
            $buffer.HasErrors | Should -Be $false
        }
        
        It "Should follow the expected workflow pattern for error case" {
            $tempFile = New-TemporaryFile
            $env:GITHUB_STEP_SUMMARY = $tempFile.FullName
            
            try {
                $buffer = Initialize-ChunkSummaryBuffer -chunkId 2
                
                # Simulate processing with errors
                Add-ChunkMessage -buffer $buffer -message "# Chunk 2 - Processing"
                Add-ChunkMessage -buffer $buffer -message "Processing 5 items"
                Add-ChunkMessage -buffer $buffer -message "❌ Failed to process item 3" -isError $true
                Add-ChunkMessage -buffer $buffer -message "✓ Completed 4 out of 5"
                
                Write-ChunkSummary -buffer $buffer
                
                # Verify errors were flagged and summary was written
                $buffer.HasErrors | Should -Be $true
                $content = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
                $content | Should -Not -BeNullOrEmpty
            }
            finally {
                if (Test-Path $tempFile) {
                    Remove-Item $tempFile -Force
                }
                $env:GITHUB_STEP_SUMMARY = $null
            }
        }
    }
}
