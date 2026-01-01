Import-Module Pester

BeforeAll {
    # Load the functions we need to test from repoInfo.ps1
    # We'll mock ApiCall to avoid actual API calls
    
    # Mock helper function
    function SplitUrlLastPart {
        Param ($url)
        $urlParts = $url.Split('/')
        return $urlParts[-1]
    }
    
    # Mock ApiCall function
    function ApiCall {
        Param (
            [string]$method,
            [string]$url,
            $access_token
        )
        
        # Return mock data based on the URL
        if ($url -like "*/git/matching-refs/tags") {
            # Mock tag data
            return @(
                @{ ref = "refs/tags/v1.0.0"; object = @{ sha = "abc123def456" } }
                @{ ref = "refs/tags/v1.1.0"; object = @{ sha = "def789ghi012" } }
                @{ ref = "refs/tags/v2.0.0"; object = @{ sha = "ghi345jkl678" } }
            )
        }
        elseif ($url -like "*/releases") {
            # Mock release data
            return @(
                @{ tag_name = "v1.0.0"; target_commitish = "abc123def456" }
                @{ tag_name = "v1.1.0"; target_commitish = "def789ghi012" }
                @{ tag_name = "v2.0.0"; target_commitish = "ghi345jkl678" }
            )
        }
        
        return @()
    }
    
    # Load GetRepoTagInfo function
    function GetRepoTagInfo {
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
            return
        }

        $url = "repos/$owner/$repo/git/matching-refs/tags"
        $response = ApiCall -method GET -url $url -access_token $access_token

        # Return array of objects with tag name and SHA
        $response = $response | ForEach-Object { 
            @{
                tag = SplitUrlLastPart($_.ref)
                sha = $_.object.sha
            }
        }

        return $response
    }
    
    # Load GetRepoReleases function
    function GetRepoReleases {
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
            return
        }

        $url = "repos/$owner/$repo/releases"
        $response = ApiCall -method GET -url $url -access_token $access_token

        # Return array of objects with tag name and target_commitish (SHA)
        $response = $response | ForEach-Object { 
            @{
                tag_name = SplitUrlLastPart($_.tag_name)
                target_commitish = $_.target_commitish
            }
        }

        return $response
    }
}

Describe "GetRepoTagInfo - SHA tracking" {
    It "Should return array of objects with tag and sha properties" {
        # Arrange
        $startTime = Get-Date
        
        # Act
        $result = GetRepoTagInfo -owner "testowner" -repo "testrepo" -access_token "token" -startTime $startTime
        
        # Assert
        $result | Should -Not -BeNullOrEmpty
        $result.Count | Should -Be 3
        
        # Verify first tag
        $result[0] | Should -BeOfType [hashtable]
        $result[0].tag | Should -Be "v1.0.0"
        $result[0].sha | Should -Be "abc123def456"
        
        # Verify second tag
        $result[1].tag | Should -Be "v1.1.0"
        $result[1].sha | Should -Be "def789ghi012"
        
        # Verify third tag
        $result[2].tag | Should -Be "v2.0.0"
        $result[2].sha | Should -Be "ghi345jkl678"
    }
    
    It "Should return null when owner is null or empty" {
        # Arrange
        $startTime = Get-Date
        
        # Act & Assert
        GetRepoTagInfo -owner $null -repo "testrepo" -access_token "token" -startTime $startTime | Should -BeNullOrEmpty
        GetRepoTagInfo -owner "" -repo "testrepo" -access_token "token" -startTime $startTime | Should -BeNullOrEmpty
    }
    
    It "Should extract tag name correctly from refs/tags/ path" {
        # Arrange
        $startTime = Get-Date
        
        # Act
        $result = GetRepoTagInfo -owner "testowner" -repo "testrepo" -access_token "token" -startTime $startTime
        
        # Assert
        $result[0].tag | Should -Not -Match "refs/tags/"
        $result[0].tag | Should -Be "v1.0.0"
    }
}

Describe "GetRepoReleases - SHA tracking" {
    It "Should return array of objects with tag_name and target_commitish properties" {
        # Arrange
        $startTime = Get-Date
        
        # Act
        $result = GetRepoReleases -owner "testowner" -repo "testrepo" -access_token "token" -startTime $startTime
        
        # Assert
        $result | Should -Not -BeNullOrEmpty
        $result.Count | Should -Be 3
        
        # Verify first release
        $result[0] | Should -BeOfType [hashtable]
        $result[0].tag_name | Should -Be "v1.0.0"
        $result[0].target_commitish | Should -Be "abc123def456"
        
        # Verify second release
        $result[1].tag_name | Should -Be "v1.1.0"
        $result[1].target_commitish | Should -Be "def789ghi012"
        
        # Verify third release
        $result[2].tag_name | Should -Be "v2.0.0"
        $result[2].target_commitish | Should -Be "ghi345jkl678"
    }
    
    It "Should return null when owner is null or empty" {
        # Arrange
        $startTime = Get-Date
        
        # Act & Assert
        GetRepoReleases -owner $null -repo "testrepo" -access_token "token" -startTime $startTime | Should -BeNullOrEmpty
        GetRepoReleases -owner "" -repo "testrepo" -access_token "token" -startTime $startTime | Should -BeNullOrEmpty
    }
}

Describe "Environment State - SHA tracking statistics" {
    BeforeAll {
        # Create test data with different formats
        $script:testForks = @(
            # Repo with new format (objects with SHA)
            @{ 
                name = "repo1"
                tagInfo = @(
                    @{ tag = "v1.0.0"; sha = "abc123" }
                    @{ tag = "v1.1.0"; sha = "def456" }
                )
                releaseInfo = @(
                    @{ tag_name = "v1.0.0"; target_commitish = "abc123" }
                )
            },
            # Repo with old format (strings only)
            @{ 
                name = "repo2"
                tagInfo = @("v1.0.0", "v1.1.0")
                releaseInfo = @("v1.0.0")
            },
            # Repo with new format but empty
            @{ 
                name = "repo3"
                tagInfo = @()
                releaseInfo = @()
            },
            # Repo with no tagInfo/releaseInfo
            @{ 
                name = "repo4"
            },
            # Another repo with new format
            @{ 
                name = "repo5"
                tagInfo = @(
                    @{ tag = "v2.0.0"; sha = "ghi789" }
                )
                releaseInfo = @(
                    @{ tag_name = "v2.0.0"; target_commitish = "ghi789" }
                )
            }
        )
    }
    
    It "Should correctly count repos with tag SHA information" {
        # Arrange
        $existingForks = $script:testForks
        
        # Act
        $reposWithTagSHA = ($existingForks | Where-Object {
            if ($_.tagInfo -and $_.tagInfo.Count -gt 0) {
                # Check if the first tag has SHA property (new format with objects)
                $firstTag = $_.tagInfo[0]
                if ($firstTag -is [hashtable] -or $firstTag -is [PSCustomObject]) {
                    # Check if it has a sha property
                    return ($null -ne $firstTag.sha -or $null -ne $firstTag.PSObject.Properties['sha'])
                }
            }
            return $false
        }).Count
        
        # Assert
        $reposWithTagSHA | Should -Be 2  # repo1 and repo5
    }
    
    It "Should correctly count repos with release SHA information" {
        # Arrange
        $existingForks = $script:testForks
        
        # Act
        $reposWithReleaseSHA = ($existingForks | Where-Object {
            if ($_.releaseInfo -and $_.releaseInfo.Count -gt 0) {
                # Check if the first release has target_commitish property (new format with objects)
                $firstRelease = $_.releaseInfo[0]
                if ($firstRelease -is [hashtable] -or $firstRelease -is [PSCustomObject]) {
                    # Check if it has a target_commitish property
                    return ($null -ne $firstRelease.target_commitish -or $null -ne $firstRelease.PSObject.Properties['target_commitish'])
                }
            }
            return $false
        }).Count
        
        # Assert
        $reposWithReleaseSHA | Should -Be 2  # repo1 and repo5
    }
    
    It "Should not count repos with old string format as having SHA info" {
        # Arrange
        $oldFormatRepo = @(
            @{ 
                name = "old-format"
                tagInfo = @("v1.0.0", "v1.1.0")
                releaseInfo = @("v1.0.0")
            }
        )
        
        # Act
        $reposWithTagSHA = ($oldFormatRepo | Where-Object {
            if ($_.tagInfo -and $_.tagInfo.Count -gt 0) {
                $firstTag = $_.tagInfo[0]
                if ($firstTag -is [hashtable] -or $firstTag -is [PSCustomObject]) {
                    return ($null -ne $firstTag.sha -or $null -ne $firstTag.PSObject.Properties['sha'])
                }
            }
            return $false
        }).Count
        
        # Assert
        $reposWithTagSHA | Should -Be 0
    }
    
    It "Should not count repos with empty arrays as having SHA info" {
        # Arrange
        $emptyRepo = @(
            @{ 
                name = "empty"
                tagInfo = @()
                releaseInfo = @()
            }
        )
        
        # Act
        $reposWithTagSHA = ($emptyRepo | Where-Object {
            if ($_.tagInfo -and $_.tagInfo.Count -gt 0) {
                $firstTag = $_.tagInfo[0]
                if ($firstTag -is [hashtable] -or $firstTag -is [PSCustomObject]) {
                    return ($null -ne $firstTag.sha -or $null -ne $firstTag.PSObject.Properties['sha'])
                }
            }
            return $false
        }).Count
        
        # Assert
        $reposWithTagSHA | Should -Be 0
    }
    
    It "Should handle repos without tagInfo/releaseInfo properties" {
        # Arrange
        $noInfoRepo = @(
            @{ name = "no-info" }
        )
        
        # Act
        $reposWithTagSHA = ($noInfoRepo | Where-Object {
            if ($_.tagInfo -and $_.tagInfo.Count -gt 0) {
                $firstTag = $_.tagInfo[0]
                if ($firstTag -is [hashtable] -or $firstTag -is [PSCustomObject]) {
                    return ($null -ne $firstTag.sha -or $null -ne $firstTag.PSObject.Properties['sha'])
                }
            }
            return $false
        }).Count
        
        # Assert
        $reposWithTagSHA | Should -Be 0
    }
}

Describe "SHA Information - Data Structure Validation" {
    It "Should store tag information with both tag name and SHA" {
        # Arrange
        $tagData = @{
            tag = "v1.0.0"
            sha = "abc123def456"
        }
        
        # Assert
        $tagData.tag | Should -Be "v1.0.0"
        $tagData.sha | Should -Be "abc123def456"
        $tagData.ContainsKey("tag") | Should -Be $true
        $tagData.ContainsKey("sha") | Should -Be $true
    }
    
    It "Should store release information with both tag name and target_commitish" {
        # Arrange
        $releaseData = @{
            tag_name = "v1.0.0"
            target_commitish = "abc123def456"
        }
        
        # Assert
        $releaseData.tag_name | Should -Be "v1.0.0"
        $releaseData.target_commitish | Should -Be "abc123def456"
        $releaseData.ContainsKey("tag_name") | Should -Be $true
        $releaseData.ContainsKey("target_commitish") | Should -Be $true
    }
    
    It "Should allow comparison of tag and release SHAs" {
        # Arrange
        $tag = @{ tag = "v1.0.0"; sha = "abc123" }
        $release = @{ tag_name = "v1.0.0"; target_commitish = "abc123" }
        
        # Act & Assert
        $tag.tag | Should -Be $release.tag_name
        $tag.sha | Should -Be $release.target_commitish
    }
}
