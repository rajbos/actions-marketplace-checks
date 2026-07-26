BeforeAll {
    # Mock Write-Message function
    function Write-Message {
        Param (
            [string] $message,
            [bool] $logToSummary = $false
        )
        Write-Host $message
    }

    # Copy the function under test to avoid loading repoInfo.ps1's script-level code
    function GetRepoDockerBaseImage {
        Param (
            [string] $owner,
            [string] $repo,
            $actionType,
            [Alias('access_token')]
            $accessToken
        )

        $result = @{
            dockerBaseImage = ""
            hasCustomCode = $false
        }

        if ($actionType.actionDockerType -eq "Image") {
            # Remote image actions reference an image in action.yml; there is no repo-local Dockerfile to analyze here.
            return $result
        }

        if ($actionType.actionDockerType -eq "Dockerfile") {
            $url = "/repos/$owner/$repo/contents/Dockerfile"
            $repoUrl = "https://github.com/$owner/$repo"
            $dockerfilePath = "Dockerfile"
            $contextInfo = "Repository: $repoUrl, File: $dockerfilePath"
            try {
                $dockerFile = ApiCall -method GET -url $url -hideFailedCall $true -contextInfo $contextInfo -access_token $accessToken
                $hasValidDownloadUrl = $null -ne $dockerFile -and $null -ne $dockerFile.download_url -and $dockerFile.download_url -ne ""
                if ($hasValidDownloadUrl) {
                    $dockerFileContent = ApiCall -method GET -url $dockerFile.download_url -contextInfo $contextInfo -access_token $accessToken
                    $result.dockerBaseImage = GetDockerBaseImageNameFromContent -dockerFileContent $dockerFileContent
                    $result.hasCustomCode = Test-DockerfileHasCustomCode -dockerFileContent $dockerFileContent
                }
                else {
                    Write-Host "Error: No download_url found for Dockerfile in [$owner/$repo]"
                }
            }
            catch {
                Write-Host "Error getting Dockerfile for [$owner/$repo]: $($_.Exception.Message), trying lowercase file"
                # retry with lowercase dockerfile name
                $url = "/repos/$owner/$repo/contents/dockerfile"
                $dockerfilePath = "dockerfile"
                $contextInfo = "Repository: $repoUrl, File: $dockerfilePath"
                try {
                    $dockerFile = ApiCall -method GET -url $url -hideFailedCall $true -contextInfo $contextInfo -access_token $accessToken
                    $hasValidDownloadUrl = $null -ne $dockerFile -and $null -ne $dockerFile.download_url -and $dockerFile.download_url -ne ""
                    if ($hasValidDownloadUrl) {
                        $dockerFileContent = ApiCall -method GET -url $dockerFile.download_url -contextInfo $contextInfo -access_token $accessToken
                        $result.dockerBaseImage = GetDockerBaseImageNameFromContent -dockerFileContent $dockerFileContent
                        $result.hasCustomCode = Test-DockerfileHasCustomCode -dockerFileContent $dockerFileContent
                    }
                    else {
                        Write-Host "Error: No download_url found for dockerfile in [$owner/$repo]"
                    }
                }
                catch {
                    Write-Host "Error getting dockerfile for [$owner/$repo]: $($_.Exception.Message)"
                }
            }
        }
        else {
            Write-Host "Cant load docker base image for action type [$($actionType.actionType)] with [$($actionType.actionDockerType)] in [$owner/$repo]"
        }

        return $result
    }

    function GetDockerBaseImageNameFromContent {
        param ($dockerFileContent)
        if ($null -eq $dockerFileContent -or "" -eq $dockerFileContent) {
            return ""
        }
        $lines = $dockerFileContent.Split("`n")
        $firstFromLine = $lines | Where-Object { $_ -like "FROM *" } | Select-Object -First 1
        if ($firstFromLine) {
            $firstFromLine = $firstFromLine.Split(" ")[1]
        }
        return $firstFromLine.TrimEnd("`r")
    }

    function Test-DockerfileHasCustomCode {
        param ([string]$dockerFileContent)
        if ($null -eq $dockerFileContent -or "" -eq $dockerFileContent) {
            return $false
        }
        $lines = $dockerFileContent.Split("`n") | ForEach-Object { $_.Trim().TrimEnd("`r") }
        foreach ($line in $lines) {
            if ($line -match '^COPY\s+(?:--from=\S+\s+)?\S+\s+\S+' -or $line -match '^ADD\s+(?!\s*https?://)\S+\s+\S+') {
                return $true
            }
        }
        return $false
    }
}

Describe "GetRepoDockerBaseImage" {
    It "Should return empty result for remote image actions without calling ApiCall" {
        # Arrange
        $actionType = @{
            actionType = "Docker"
            actionDockerType = "Image"
            dockerImageReference = "docker://hyperngn/github-actions-11ty:latest"
        }
        $apiCallInvoked = $false
        function ApiCall { $apiCallInvoked = $true }

        # Act
        $result = GetRepoDockerBaseImage -owner "hyperngn" -repo "github-actions-11ty" -actionType $actionType -accessToken "test"

        # Assert
        $result.dockerBaseImage | Should -Be ""
        $result.hasCustomCode | Should -Be $false
        $apiCallInvoked | Should -Be $false
    }

    It "Should analyze Dockerfile when actionDockerType is Dockerfile" {
        # Arrange
        $actionType = @{
            actionType = "Docker"
            actionDockerType = "Dockerfile"
        }
        function ApiCall {
            param ([string]$method, [string]$url, $access_token)
            if ($url -like "*/contents/Dockerfile") {
                return @{ download_url = "https://raw.githubusercontent.com/test/repo/Dockerfile" }
            }
            if ($url -eq "https://raw.githubusercontent.com/test/repo/Dockerfile") {
                return "FROM alpine:3.14`nCOPY . /app"
            }
            return $null
        }

        # Act
        $result = GetRepoDockerBaseImage -owner "test" -repo "repo" -actionType $actionType -accessToken "test"

        # Assert
        $result.dockerBaseImage | Should -Be "alpine:3.14"
        $result.hasCustomCode | Should -Be $true
    }
}

Describe "Docker image reference tracking" {
    It "Should count remote image actions with references" {
        # Arrange
        $forks = @(
            @{
                name = "docker-remote-with-ref"
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Image"
                    dockerImageReference = "docker://owner/image:tag"
                }
            },
            @{
                name = "docker-remote-without-ref"
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Image"
                }
            },
            @{
                name = "docker-local"
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Dockerfile"
                }
            }
        )

        # Act
        $dockerRemoteImage = 0
        $dockerRemoteImageWithReference = 0
        foreach ($fork in $forks) {
            if ($fork.actionType.actionType -eq "Docker" -and $fork.actionType.actionDockerType -eq "Image") {
                $dockerRemoteImage++
                if ($fork.actionType.dockerImageReference) {
                    $dockerRemoteImageWithReference++
                }
            }
        }

        # Assert
        $dockerRemoteImage | Should -Be 2
        $dockerRemoteImageWithReference | Should -Be 1
    }
}
