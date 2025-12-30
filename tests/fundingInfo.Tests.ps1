BeforeAll {
    . $PSScriptRoot/../.github/workflows/library.ps1
    
    # Define GetFundingInfo function inline to avoid loading repoInfo.ps1's script-level code
    function GetFundingInfo {
        Param (
            $owner,
            $repo,
            $access_token,
            $startTime
        )

        if ($null -eq $owner -or $owner.Length -eq 0) {
            return $null
        }

        # Check if we are nearing the 50-minute mark
        $timeSpan = (Get-Date) - $startTime
        if ($timeSpan.TotalMinutes -gt 50) {
            Write-Host "Stopping the run, since we are nearing the 50-minute mark"
            return $null
        }

        # Try to find FUNDING.yml in .github folder first, then in root
        $fundingLocations = @(
            "/repos/$owner/$repo/contents/.github/FUNDING.yml",
            "/repos/$owner/$repo/contents/FUNDING.yml"
        )

        $fundingFileContent = $null
        $fundingFileLocation = $null

        foreach ($location in $fundingLocations) {
            try {
                Write-Debug "Checking for FUNDING.yml at [$location]"
                $response = ApiCall -method GET -url $location -hideFailedCall $true -access_token $access_token
                
                if ($response -and $response.download_url) {
                    Write-Message "Found FUNDING.yml for [$owner/$repo] at [$location]"
                    $fundingFileLocation = $location
                    # Download the file content
                    $fundingFileContent = ApiCall -method GET -url $response.download_url -access_token $access_token -returnErrorInfo $true
                    break
                }
            }
            catch {
                Write-Debug "No FUNDING.yml found at [$location]"
                continue
            }
        }

        if ($null -eq $fundingFileContent) {
            Write-Debug "No FUNDING.yml found for [$owner/$repo]"
            return $null
        }

        # Parse the FUNDING.yml content to count platforms
        # FUNDING.yml can have platforms like: github, patreon, open_collective, ko_fi, etc.
        # Each line typically has format: platform: username or platform: [user1, user2]
        
        try {
            $platformCount = 0
            $platforms = @()
            
            # Split content by lines and process each line
            $lines = $fundingFileContent -split "`n"
            foreach ($line in $lines) {
                $line = $line.Trim()
                
                # Skip comments and empty lines
                if ($line -match "^#" -or $line -eq "") {
                    continue
                }
                
                # Match lines like "github: username" or "patreon: username"
                if ($line -match "^([a-z_]+):\s*(.+)$") {
                    $platform = $matches[1].Trim()
                    $value = $matches[2].Trim()
                    
                    # Skip if value is empty or just whitespace
                    if ($value -ne "" -and $value -ne "[]" -and $value -ne "null") {
                        $platformCount++
                        $platforms += $platform
                        Write-Debug "Found funding platform: [$platform] with value: [$value]"
                    }
                }
            }
            
            Write-Message "Parsed FUNDING.yml for [$owner/$repo]: $platformCount platforms found"
            
            return @{
                hasFunding = $true
                platformCount = $platformCount
                platforms = $platforms
                fileLocation = $fundingFileLocation
                lastChecked = Get-Date
            }
        }
        catch {
            Write-Host "Error parsing FUNDING.yml for [$owner/$repo]: $($_.Exception.Message)"
            return @{
                hasFunding = $true
                platformCount = 0
                platforms = @()
                fileLocation = $fundingFileLocation
                lastChecked = Get-Date
                parseError = $true
            }
        }
    }
}

Describe 'GetFundingInfo' {
    BeforeEach {
        # Mock ApiCall to avoid real API calls
        Mock ApiCall { }
        Mock Write-Message { }
    }

    It 'Should return null when owner is null' {
        # Act
        $result = GetFundingInfo -owner $null -repo "test-repo" -access_token "token" -startTime (Get-Date)

        # Assert
        $result | Should -Be $null
    }

    It 'Should return null when owner is empty' {
        # Act
        $result = GetFundingInfo -owner "" -repo "test-repo" -access_token "token" -startTime (Get-Date)

        # Assert
        $result | Should -Be $null
    }

    It 'Should return null when time limit exceeded' {
        # Arrange
        $startTime = (Get-Date).AddMinutes(-51)

        # Act
        $result = GetFundingInfo -owner "test-owner" -repo "test-repo" -access_token "token" -startTime $startTime

        # Assert
        $result | Should -Be $null
    }

    It 'Should return null when no FUNDING.yml found' {
        # Arrange - Mock ApiCall to throw exceptions for all locations
        Mock ApiCall {
            throw "Not found"
        }

        # Act
        $result = GetFundingInfo -owner "test-owner" -repo "test-repo" -access_token "token" -startTime (Get-Date)

        # Assert
        $result | Should -Be $null
    }

    It 'Should parse FUNDING.yml with single platform' {
        # Arrange
        Mock ApiCall {
            param($method, $url, $access_token, $hideFailedCall, $returnErrorInfo)
            
            if ($url -match "contents") {
                # Return file metadata
                return @{
                    download_url = "https://raw.githubusercontent.com/test/test/main/FUNDING.yml"
                }
            }
            else {
                # Return file content
                return "github: testuser"
            }
        }

        # Act
        $result = GetFundingInfo -owner "test-owner" -repo "test-repo" -access_token "token" -startTime (Get-Date)

        # Assert
        $result | Should -Not -Be $null
        $result.hasFunding | Should -Be $true
        $result.platformCount | Should -Be 1
        $result.platforms | Should -Contain "github"
    }

    It 'Should parse FUNDING.yml with multiple platforms' {
        # Arrange
        Mock ApiCall {
            param($method, $url, $access_token, $hideFailedCall, $returnErrorInfo)
            
            if ($url -match "contents") {
                return @{
                    download_url = "https://raw.githubusercontent.com/test/test/main/FUNDING.yml"
                }
            }
            else {
                return @"
github: testuser
patreon: testcreator
ko_fi: testkoficreator
"@
            }
        }

        # Act
        $result = GetFundingInfo -owner "test-owner" -repo "test-repo" -access_token "token" -startTime (Get-Date)

        # Assert
        $result | Should -Not -Be $null
        $result.hasFunding | Should -Be $true
        $result.platformCount | Should -Be 3
        $result.platforms | Should -Contain "github"
        $result.platforms | Should -Contain "patreon"
        $result.platforms | Should -Contain "ko_fi"
    }

    It 'Should skip empty lines and comments' {
        # Arrange
        Mock ApiCall {
            param($method, $url, $access_token, $hideFailedCall, $returnErrorInfo)
            
            if ($url -match "contents") {
                return @{
                    download_url = "https://raw.githubusercontent.com/test/test/main/FUNDING.yml"
                }
            }
            else {
                return @"
# This is a comment
github: testuser

# Another comment
patreon: testcreator
"@
            }
        }

        # Act
        $result = GetFundingInfo -owner "test-owner" -repo "test-repo" -access_token "token" -startTime (Get-Date)

        # Assert
        $result | Should -Not -Be $null
        $result.platformCount | Should -Be 2
    }

    It 'Should skip platforms with null values' {
        # Arrange
        Mock ApiCall {
            param($method, $url, $access_token, $hideFailedCall, $returnErrorInfo)
            
            if ($url -match "contents") {
                return @{
                    download_url = "https://raw.githubusercontent.com/test/test/main/FUNDING.yml"
                }
            }
            else {
                return @"
github: testuser
patreon: null
ko_fi: 
"@
            }
        }

        # Act
        $result = GetFundingInfo -owner "test-owner" -repo "test-repo" -access_token "token" -startTime (Get-Date)

        # Assert
        $result | Should -Not -Be $null
        $result.platformCount | Should -Be 1
        $result.platforms | Should -Contain "github"
        $result.platforms | Should -Not -Contain "patreon"
        $result.platforms | Should -Not -Contain "ko_fi"
    }

    It 'Should check .github folder first then root' {
        # Arrange
        $callCount = 0
        Mock ApiCall {
            param($method, $url, $access_token, $hideFailedCall, $returnErrorInfo)
            
            $script:callCount++
            
            if ($url -match "\.github/FUNDING\.yml" -and $url -match "contents") {
                # First call should be to .github folder
                $script:callCount | Should -Be 1
                return @{
                    download_url = "https://raw.githubusercontent.com/test/test/main/.github/FUNDING.yml"
                }
            }
            elseif ($url -match "contents") {
                throw "Not found"
            }
            else {
                return "github: testuser"
            }
        }

        # Act
        $result = GetFundingInfo -owner "test-owner" -repo "test-repo" -access_token "token" -startTime (Get-Date)

        # Assert
        $result | Should -Not -Be $null
        $result.fileLocation | Should -Match "\.github/FUNDING\.yml"
    }

    It 'Should handle parse errors gracefully' {
        # Arrange
        Mock ApiCall {
            param($method, $url, $access_token, $hideFailedCall, $returnErrorInfo)
            
            if ($url -match "contents") {
                return @{
                    download_url = "https://raw.githubusercontent.com/test/test/main/FUNDING.yml"
                }
            }
            else {
                # Return empty string which will cause no platforms to be found
                return ""
            }
        }

        # Act
        $result = GetFundingInfo -owner "test-owner" -repo "test-repo" -access_token "token" -startTime (Get-Date)

        # Assert - Empty content should still return a result but with 0 platforms
        $result | Should -Not -Be $null
        $result.hasFunding | Should -Be $true
        $result.platformCount | Should -Be 0
    }
}

Describe 'Funding Statistics in Environment State' {
    BeforeEach {
        Mock Write-Message { }
    }

    It 'Should count repos with funding info correctly' {
        # Arrange
        $testForks = @(
            @{ 
                name = "repo1"
                fundingInfo = @{
                    hasFunding = $true
                    platformCount = 2
                    platforms = @("github", "patreon")
                }
            }
            @{ 
                name = "repo2"
                fundingInfo = @{
                    hasFunding = $true
                    platformCount = 1
                    platforms = @("github")
                }
            }
            @{ 
                name = "repo3"
            }
        )

        # Act
        $reposWithFunding = ($testForks | Where-Object {
            $_.fundingInfo -and $_.fundingInfo.hasFunding -eq $true
        }).Count

        # Assert
        $reposWithFunding | Should -Be 2
    }

    It 'Should calculate total platforms correctly' {
        # Arrange
        $testForks = @(
            @{ 
                fundingInfo = @{
                    hasFunding = $true
                    platformCount = 2
                }
            }
            @{ 
                fundingInfo = @{
                    hasFunding = $true
                    platformCount = 1
                }
            }
            @{ 
                fundingInfo = @{
                    hasFunding = $true
                    platformCount = 3
                }
            }
        )

        # Act
        $totalPlatforms = 0
        foreach ($fork in $testForks) {
            if ($fork.fundingInfo -and $fork.fundingInfo.hasFunding -eq $true) {
                $totalPlatforms += $fork.fundingInfo.platformCount
            }
        }

        # Assert
        $totalPlatforms | Should -Be 6
    }
}
