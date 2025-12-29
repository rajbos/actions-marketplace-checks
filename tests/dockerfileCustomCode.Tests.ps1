Import-Module Pester

BeforeAll {
    # Copy the function definition for testing
    function Test-DockerfileHasCustomCode {
        param (
            [string]$dockerFileContent
        )
        
        if ($null -eq $dockerFileContent -or "" -eq $dockerFileContent) {
            return $false
        }
        
        # Split into lines and normalize
        $lines = $dockerFileContent.Split("`n") | ForEach-Object { $_.Trim().TrimEnd("`r") }
        
        # Look for COPY or ADD instructions
        foreach ($line in $lines) {
            # Skip comments and empty lines
            if ($line -match '^\s*#' -or $line -match '^\s*$') {
                continue
            }
            
            # Check for COPY instruction (but not COPY --from=stage which is multi-stage build)
            if ($line -match '^COPY\s+(?!--from=)') {
                Write-Debug "Found COPY instruction indicating custom code: $line"
                return $true
            }
            
            # Check for ADD instruction (but not ADD with URLs which pulls external resources)
            if ($line -match '^ADD\s+(?!https?://)') {
                Write-Debug "Found ADD instruction indicating custom code: $line"
                return $true
            }
        }
        
        return $false
    }
}

Describe "Test-DockerfileHasCustomCode" {
    Context "Dockerfiles with custom code" {
        It "Should detect COPY instruction" {
            # Arrange
            $dockerFileContent = @"
FROM ubuntu:22.04
COPY app.js /app/
RUN npm install
"@
            
            # Act
            $result = Test-DockerfileHasCustomCode -dockerFileContent $dockerFileContent
            
            # Assert
            $result | Should -Be $true
        }
        
        It "Should detect ADD instruction with local file" {
            # Arrange
            $dockerFileContent = @"
FROM node:16
ADD package.json /app/
RUN npm install
"@
            
            # Act
            $result = Test-DockerfileHasCustomCode -dockerFileContent $dockerFileContent
            
            # Assert
            $result | Should -Be $true
        }
        
        It "Should detect COPY with multiple files" {
            # Arrange
            $dockerFileContent = @"
FROM python:3.9
COPY requirements.txt setup.py /app/
RUN pip install -r /app/requirements.txt
"@
            
            # Act
            $result = Test-DockerfileHasCustomCode -dockerFileContent $dockerFileContent
            
            # Assert
            $result | Should -Be $true
        }
        
        It "Should detect COPY with directory" {
            # Arrange
            $dockerFileContent = @"
FROM alpine:latest
COPY ./src /app/src
WORKDIR /app
"@
            
            # Act
            $result = Test-DockerfileHasCustomCode -dockerFileContent $dockerFileContent
            
            # Assert
            $result | Should -Be $true
        }
    }
    
    Context "Dockerfiles without custom code" {
        It "Should return false for Dockerfile with only FROM" {
            # Arrange
            $dockerFileContent = @"
FROM ubuntu:22.04
"@
            
            # Act
            $result = Test-DockerfileHasCustomCode -dockerFileContent $dockerFileContent
            
            # Assert
            $result | Should -Be $false
        }
        
        It "Should return false for Dockerfile with only RUN commands" {
            # Arrange
            $dockerFileContent = @"
FROM ubuntu:22.04
RUN apt-get update
RUN apt-get install -y curl
"@
            
            # Act
            $result = Test-DockerfileHasCustomCode -dockerFileContent $dockerFileContent
            
            # Assert
            $result | Should -Be $false
        }
        
        It "Should ignore COPY --from= multi-stage build" {
            # Arrange
            $dockerFileContent = @"
FROM node:16 AS builder
RUN npm install
FROM alpine:latest
COPY --from=builder /app /app
"@
            
            # Act
            $result = Test-DockerfileHasCustomCode -dockerFileContent $dockerFileContent
            
            # Assert
            $result | Should -Be $false
        }
        
        It "Should ignore ADD with URL" {
            # Arrange
            $dockerFileContent = @"
FROM ubuntu:22.04
ADD https://example.com/file.tar.gz /tmp/
RUN tar -xzf /tmp/file.tar.gz
"@
            
            # Act
            $result = Test-DockerfileHasCustomCode -dockerFileContent $dockerFileContent
            
            # Assert
            $result | Should -Be $false
        }
        
        It "Should return false for empty content" {
            # Act
            $result = Test-DockerfileHasCustomCode -dockerFileContent ""
            
            # Assert
            $result | Should -Be $false
        }
        
        It "Should return false for null content" {
            # Act
            $result = Test-DockerfileHasCustomCode -dockerFileContent $null
            
            # Assert
            $result | Should -Be $false
        }
        
        It "Should ignore comment lines" {
            # Arrange
            $dockerFileContent = @"
FROM ubuntu:22.04
# COPY app.js /app/
RUN apt-get update
"@
            
            # Act
            $result = Test-DockerfileHasCustomCode -dockerFileContent $dockerFileContent
            
            # Assert
            $result | Should -Be $false
        }
    }
    
    Context "Real-world examples" {
        It "Should detect custom code in typical action Dockerfile" {
            # Arrange - typical GitHub Action with entrypoint script
            $dockerFileContent = @"
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y curl
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
"@
            
            # Act
            $result = Test-DockerfileHasCustomCode -dockerFileContent $dockerFileContent
            
            # Assert
            $result | Should -Be $true
        }
        
        It "Should not detect custom code in bare image reference" {
            # Arrange - Dockerfile that just extends another image
            $dockerFileContent = @"
FROM ubuntu:22.04
ENV MY_VAR=value
WORKDIR /app
CMD ["bash"]
"@
            
            # Act
            $result = Test-DockerfileHasCustomCode -dockerFileContent $dockerFileContent
            
            # Assert
            $result | Should -Be $false
        }
        
        It "Should handle Windows line endings" {
            # Arrange
            $dockerFileContent = "FROM ubuntu:22.04`r`nCOPY app.js /app/`r`nRUN npm install`r`n"
            
            # Act
            $result = Test-DockerfileHasCustomCode -dockerFileContent $dockerFileContent
            
            # Assert
            $result | Should -Be $true
        }
    }
}
