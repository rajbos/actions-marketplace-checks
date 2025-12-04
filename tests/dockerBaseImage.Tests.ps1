Import-Module Pester

BeforeAll {
    # Import only the function we need, not the entire script
    # Note: We copy the function definition here rather than sourcing repoInfo.ps1
    # because that script executes initialization code requiring GitHub access tokens
    # This approach ensures tests can run in isolation without authentication
    function GetDockerBaseImageNameFromContent {
        param (
            $dockerFileContent
        )

        if ($null -eq $dockerFileContent -or "" -eq $dockerFileContent) {
            return ""
        }

        # find first line with FROM in the Dockerfile
        $lines = $dockerFileContent.Split("`n")
        $firstFromLine = $lines | Where-Object { $_ -like "FROM *" }
        $dockerBaseImage = $firstFromLine | Select-Object -First 1
        if ($dockerBaseImage) {
            $dockerBaseImage = $dockerBaseImage.Split(" ")[1]
        }

        # remove \r from the end
        $dockerBaseImage = $dockerBaseImage.TrimEnd("`r")

        return $dockerBaseImage
    }
}

Describe "GetDockerBaseImageNameFromContent" {
    It "Should extract base image from simple Dockerfile" {
        # Arrange
        $dockerFileContent = @"
FROM ubuntu:22.04
RUN apt-get update
"@
        
        # Act
        $result = GetDockerBaseImageNameFromContent -dockerFileContent $dockerFileContent
        
        # Assert
        $result | Should -Be "ubuntu:22.04"
    }

    It "Should extract base image from multi-line Dockerfile" {
        # Arrange
        $dockerFileContent = @"
# This is a comment
FROM ubuntu:22.04
RUN apt-get update
RUN apt-get install -y curl
"@
        
        # Act
        $result = GetDockerBaseImageNameFromContent -dockerFileContent $dockerFileContent
        
        # Assert
        $result | Should -Be "ubuntu:22.04"
    }

    It "Should handle Dockerfile from jeremyoverman/cloudflared-service-token-scp-proxy" {
        # Arrange - actual content from the problematic repository
        $dockerFileContent = @"
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y curl openssh-client openssl gettext-base
# Add cloudflare gpg key
RUN mkdir -p --mode=0755 /usr/share/keyrings
RUN curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
# Add this repo to your apt repositories
RUN echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared jammy main' | tee /etc/apt/sources.list.d/cloudflared.list

USER root
RUN mkdir /root/.ssh
RUN touch /root/.ssh/config

# install cloudflared
RUN apt-get update && apt-get install -y cloudflared
COPY ./ssh-client.conf /root/ssh-client.conf
RUN cat /root/.ssh/config
COPY ./entrypoint.sh /root/entrypoint.sh
RUN chmod a+x /root/entrypoint.sh
RUN cat /root/entrypoint.sh

ENTRYPOINT ["/root/entrypoint.sh"]
"@
        
        # Act
        $result = GetDockerBaseImageNameFromContent -dockerFileContent $dockerFileContent
        
        # Assert
        $result | Should -Be "ubuntu:22.04"
    }

    It "Should handle Dockerfile with Windows line endings" {
        # Arrange
        $dockerFileContent = "FROM alpine:3.14`r`nRUN apk add curl`r`n"
        
        # Act
        $result = GetDockerBaseImageNameFromContent -dockerFileContent $dockerFileContent
        
        # Assert
        $result | Should -Be "alpine:3.14"
    }

    It "Should return empty string for null content" {
        # Act
        $result = GetDockerBaseImageNameFromContent -dockerFileContent $null
        
        # Assert
        $result | Should -Be ""
    }

    It "Should return empty string for empty content" {
        # Act
        $result = GetDockerBaseImageNameFromContent -dockerFileContent ""
        
        # Assert
        $result | Should -Be ""
    }

    It "Should handle Dockerfile with FROM as" {
        # Arrange
        $dockerFileContent = @"
FROM node:16 AS builder
RUN npm install
FROM alpine:3.14
COPY --from=builder /app /app
"@
        
        # Act
        $result = GetDockerBaseImageNameFromContent -dockerFileContent $dockerFileContent
        
        # Assert
        $result | Should -Be "node:16"
    }

    It "Should handle Dockerfile with no tag" {
        # Arrange
        $dockerFileContent = "FROM ubuntu"
        
        # Act
        $result = GetDockerBaseImageNameFromContent -dockerFileContent $dockerFileContent
        
        # Assert
        $result | Should -Be "ubuntu"
    }
}
