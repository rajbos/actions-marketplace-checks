#requires -Version 7.0

<#!
.SYNOPSIS
    Manages GitHub App installation tokens for one or more Apps.

.DESCRIPTION
    Provides a central, reusable helper for working with multiple GitHub Apps.
    It can obtain installation tokens for a given organization and is designed
    to support failover between Apps when needed.

    The manager builds on Get-TokenFromApp from library.ps1, which in turn
    uses Get-GitHubAppInstallationToken from get-github-app-token.ps1.

 .EXAMPLE
    # Create a manager from explicit ids/keys
    $manager = New-GitHubAppTokenManager -AppIds @("1234","5678") -AppPrivateKeys @($key1,$key2)
    $tokenInfo = $manager.GetTokenForOrganization("my-org")

.EXAMPLE
    # Create a manager from environment configuration
    $manager = New-GitHubAppTokenManagerFromEnvironment
    $tokenInfo = $manager.GetTokenForOrganization($env:APP_ORGANIZATION)
#>
class GitHubAppTokenManager {
    [string[]] $AppIds
    [string[]] $AppPrivateKeys
    [int] $CurrentIndex = 0

    GitHubAppTokenManager([string[]] $appIds, [string[]] $appPrivateKeys) {
        if ($null -eq $appIds -or $appIds.Count -eq 0) {
            throw "At least one App ID must be provided to create GitHubAppTokenManager"
        }

        if ($null -eq $appPrivateKeys -or $appPrivateKeys.Count -eq 0) {
            throw "At least one App private key must be provided to create GitHubAppTokenManager"
        }

        $filteredAppIds = @()
        $filteredAppPrivateKeys = @()

        $max = [Math]::Min($appIds.Count, $appPrivateKeys.Count)
        for ($i = 0; $i -lt $max; $i++) {
            $appId = $appIds[$i]
            $pemKey = $appPrivateKeys[$i]

            if ([string]::IsNullOrWhiteSpace($appId) -or [string]::IsNullOrWhiteSpace($pemKey)) {
                continue
            }

            $filteredAppIds += $appId
            $filteredAppPrivateKeys += $pemKey
        }

        if ($filteredAppIds.Count -eq 0) {
            throw "No valid app id/private key combinations provided to GitHubAppTokenManager"
        }

        $this.AppIds = $filteredAppIds
        $this.AppPrivateKeys = $filteredAppPrivateKeys
    }

    static [GitHubAppTokenManager] CreateFromEnvironment() {
        $envAppIds = @($env:APP_ID, $env:APP_ID_2) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $envAppPrivateKeys = @($env:APPLICATION_PRIVATE_KEY, $env:APPLICATION_PRIVATE_KEY_2) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        if ($envAppIds.Count -eq 0 -or $envAppPrivateKeys.Count -eq 0) {
            throw "At least one APP_ID and APPLICATION_PRIVATE_KEY must be provided in environment to create GitHubAppTokenManager"
        }

        return [GitHubAppTokenManager]::new($envAppIds, $envAppPrivateKeys)
    }

    [pscustomobject] GetTokenForOrganization([string] $organization) {
        if ([string]::IsNullOrWhiteSpace($organization)) {
            throw "Target organization must be provided when requesting a GitHub App token"
        }

        $count = $this.AppIds.Count
        $startIndex = $this.CurrentIndex

        if ($count -le 0) {
            throw "GitHubAppTokenManager has no configured App IDs to use for token retrieval"
        }

        for ($offset = 0; $offset -lt $count; $offset++) {
            $index = ($startIndex + $offset) % $count
            $appId = $this.AppIds[$index]
            $pemKey = $this.AppPrivateKeys[$index]

            if ([string]::IsNullOrWhiteSpace($appId) -or [string]::IsNullOrWhiteSpace($pemKey)) {
                continue
            }

            Write-Host "Trying GitHub App id [$appId] for organization [$organization]"
            try {
                $token = Get-TokenFromApp -appId $appId -pemKey $pemKey -targetAccountLogin $organization
                if (-not [string]::IsNullOrWhiteSpace($token)) {
                    Write-Host "Successfully obtained token using app id [$appId]"
                    $this.CurrentIndex = $index
                    return [pscustomobject]@{
                        Token = $token
                        AppId = $appId
                    }
                }
            }
            catch {
                Write-Warning "Failed to get token for app id [$appId]: $($_.Exception.Message)"
            }
        }

        throw "Failed to obtain GitHub App token for organization [$organization] using any provided credentials"
    }

    [void] MoveToNextApp() {
        if ($this.AppIds.Count -le 1) {
            return
        }

        $this.CurrentIndex = ($this.CurrentIndex + 1) % $this.AppIds.Count
    }
}

function New-GitHubAppTokenManager {
    Param (
        [string[]] $AppIds,
        [string[]] $AppPrivateKeys
    )

    return [GitHubAppTokenManager]::new($AppIds, $AppPrivateKeys)
}

function New-GitHubAppTokenManagerFromEnvironment {
    return [GitHubAppTokenManager]::CreateFromEnvironment()
}
