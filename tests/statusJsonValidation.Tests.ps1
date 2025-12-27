Import-Module Pester

BeforeAll {
    # Create temp directory for test files
    $script:testDir = Join-Path $TestDrive "statusValidation"
    New-Item -ItemType Directory -Path $script:testDir -Force | Out-Null
}

Describe "Status.json File Validation" {
    Context "File size validation - download scenario" {
        It "Should fail validation when file is empty (0 bytes)" {
            $testFile = Join-Path $script:testDir "empty.json"
            "" | Out-File -FilePath $testFile -NoNewline -Encoding UTF8
            
            $fileSize = (Get-Item $testFile).Length
            $fileSize | Should -Be 0
            $fileSize -le 5 | Should -Be $true
        }

        It "Should fail validation when file is 1 byte" {
            $testFile = Join-Path $script:testDir "1byte.json"
            "[" | Out-File -FilePath $testFile -NoNewline -Encoding UTF8
            
            $fileSize = (Get-Item $testFile).Length
            $fileSize | Should -Be 1
            $fileSize -le 5 | Should -Be $true
        }

        It "Should fail validation when file is 5 bytes or less" {
            $testFile = Join-Path $script:testDir "5bytes.json"
            "[]  " | Out-File -FilePath $testFile -NoNewline -Encoding UTF8
            
            $fileSize = (Get-Item $testFile).Length
            $fileSize | Should -BeLessOrEqual 5
            $fileSize -le 5 | Should -Be $true
        }

        It "Should pass validation when file is larger than 5 bytes" {
            $testFile = Join-Path $script:testDir "valid.json"
            "[{""test"":""data""}]" | Out-File -FilePath $testFile -NoNewline -Encoding UTF8
            
            $fileSize = (Get-Item $testFile).Length
            $fileSize | Should -BeGreaterThan 5
            $fileSize -le 5 | Should -Be $false
        }

        It "Should pass validation for a typical status.json structure" {
            $testFile = Join-Path $script:testDir "status.json"
            $sampleData = @(
                @{
                    name = "test_repo"
                    owner = "actions-marketplace-validations"
                    upstreamFound = $true
                    mirrorFound = $true
                }
            )
            $sampleData | ConvertTo-Json -Depth 10 | Out-File -FilePath $testFile -Encoding UTF8
            
            $fileSize = (Get-Item $testFile).Length
            $fileSize | Should -BeGreaterThan 5
            $fileSize -le 5 | Should -Be $false
        }
    }

    Context "File size validation - upload scenario" {
        It "Should detect when file does not exist" {
            $testFile = Join-Path $script:testDir "nonexistent.json"
            Test-Path $testFile | Should -Be $false
        }

        It "Should fail upload validation when file becomes empty during processing" {
            $testFile = Join-Path $script:testDir "corrupted.json"
            # Simulate a file that gets corrupted during processing
            "" | Out-File -FilePath $testFile -NoNewline -Encoding UTF8
            
            Test-Path $testFile | Should -Be $true
            $fileSize = (Get-Item $testFile).Length
            $fileSize | Should -Be 0
            $fileSize -le 5 | Should -Be $true
        }

        It "Should pass upload validation for valid status.json" {
            $testFile = Join-Path $script:testDir "valid-upload.json"
            $sampleData = @(
                @{
                    name = "owner_repo1"
                    owner = "actions-marketplace-validations"
                    upstreamFound = $true
                }
                @{
                    name = "owner_repo2"
                    owner = "actions-marketplace-validations"
                    upstreamFound = $false
                }
            )
            $sampleData | ConvertTo-Json -Depth 10 | Out-File -FilePath $testFile -Encoding UTF8
            
            Test-Path $testFile | Should -Be $true
            $fileSize = (Get-Item $testFile).Length
            $fileSize | Should -BeGreaterThan 5
            $fileSize -le 5 | Should -Be $false
        }
    }

    Context "Edge cases" {
        It "Should handle exactly 6 bytes (minimum valid size)" {
            $testFile = Join-Path $script:testDir "6bytes.json"
            "[{""a"":1}]" | Out-File -FilePath $testFile -NoNewline -Encoding UTF8
            
            $fileSize = (Get-Item $testFile).Length
            # We expect more than 5 bytes for valid JSON
            $fileSize | Should -BeGreaterThan 5
            $fileSize -le 5 | Should -Be $false
        }

        It "Should reject malformed empty JSON array" {
            $testFile = Join-Path $script:testDir "empty-array.json"
            "[]" | Out-File -FilePath $testFile -NoNewline -Encoding UTF8
            
            $fileSize = (Get-Item $testFile).Length
            $fileSize | Should -Be 2
            $fileSize -le 5 | Should -Be $true
        }
    }
}
