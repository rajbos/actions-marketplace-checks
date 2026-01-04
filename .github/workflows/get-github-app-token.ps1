#requires -Version 7.0
<#!
.SYNOPSIS
    Helper functions to create GitHub App JWTs and exchange them for installation tokens.

.DESCRIPTION
    Builds on the jwt helpers from https://gist.github.com/rajbos/8581083586b537029fe8ab796506bec3.
    Given an App ID, private key, and either an installation id or organization login,
    the script returns an installation access token response.

.EXAMPLE
    . ./get-github-app-token.ps1
    $tokenInfo = Get-GitHubAppInstallationToken -AppId 1234 -AppPrivateKey $env:APP_PEM_KEY -Organization "my-org"
    $token = $tokenInfo.token
#>

function Build-Payload {
    Param (
        [Parameter(Mandatory=$true)]
        [string] $app_id
    )

    $issuedAt = [int][Math]::Floor(([DateTimeOffset]::UtcNow).ToUnixTimeSeconds())
    $payload = @{
        iat = $issuedAt
        exp = $issuedAt + 300
        iss = [int]$app_id
    }

    return $payload | ConvertTo-Json -Compress
}

function ConvertTo-Base64Url {
    param (
        [Parameter(ValueFromPipeline=$true, Mandatory=$true)]
        [string] $InputObject
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($InputObject)
    return [Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')
}

function ConvertTo-CompactJson {
    param (
        [Parameter(ValueFromPipeline=$true, Mandatory=$true)]
        [string] $InputObject
    )

    return $InputObject | ConvertFrom-Json | ConvertTo-Json -Compress
}

function Invoke-RS256Signature {
    param (
        [Parameter(Mandatory=$true)]
        [string] $InputObject,
        [Parameter(Mandatory=$true)]
        [string] $PrivateKey
    )

    $rsaProvider = [System.Security.Cryptography.RSA]::Create()
    $rsaProvider.ImportFromPem($PrivateKey)
    $hashAlgorithmName = [System.Security.Cryptography.HashAlgorithmName]::SHA256
    $rsaSignaturePadding = [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    $signedBytes = $rsaProvider.SignData([Text.Encoding]::UTF8.GetBytes($InputObject), $hashAlgorithmName, $rsaSignaturePadding)
    return [Convert]::ToBase64String($signedBytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')
}

function ConvertTo-MultilinePem {
    param (
        [Parameter(Mandatory=$true)]
        [string] $KeyContent
    )

    $normalized = $KeyContent -replace "\r", ""
    if ($normalized -match "\\n") {
        $normalized = $normalized -replace "\\n", "`n"
    }
    if (-not $normalized.EndsWith("`n")) {
        $normalized += "`n"
    }
    return $normalized
}

function Get-JWTToken {
    Param (
        [Parameter(Mandatory=$true)]
        [string] $app_id,
        [Parameter(Mandatory=$true)]
        [string] $app_private_key
    )

    $payload = Build-Payload -app_id $app_id
    $header = @{ alg = "RS256"; typ = "JWT" } | ConvertTo-Json
    $signedContent = "$( $header | ConvertTo-CompactJson | ConvertTo-Base64Url ).$( $payload | ConvertTo-Base64Url )"
    $signature = Invoke-RS256Signature -InputObject $signedContent -PrivateKey $app_private_key
    return "$signedContent.$signature"
}

function Get-NextLink {
    param (
        [string] $LinkHeader
    )

    if ([string]::IsNullOrWhiteSpace($LinkHeader)) {
        return $null
    }

    foreach ($section in $LinkHeader.Split(',')) {
        if ($section -match '<(?<url>[^>]+)>; rel="next"') {
            return $matches['url']
        }
    }

    return $null
}

function Get-GitHubAppInstallationId {
    param (
        [Parameter(Mandatory=$true)]
        [string] $Jwt,
        [Parameter(Mandatory=$true)]
        [string] $Organization
    )

    $headers = @{
        Authorization = "Bearer $Jwt"
        Accept = "application/vnd.github+json"
        "User-Agent" = "actions-marketplace-checks"
    }

    $requestUri = "https://api.github.com/app/installations?per_page=100"
    while ($requestUri) {
        $response = Invoke-WebRequest -Uri $requestUri -Headers $headers -Method Get -ErrorAction Stop
        $installations = $response.Content | ConvertFrom-Json

        foreach ($installation in $installations) {
            $login = $installation.account.login
            $slug = $installation.account.slug
            if ($login -and ($login -ieq $Organization)) {
                return $installation.id
            }
            if ($slug -and ($slug -ieq $Organization)) {
                return $installation.id
            }
        }

        $requestUri = Get-NextLink -LinkHeader $response.Headers.Link
    }

    throw "Unable to find a GitHub App installation for organization [$Organization]"
}

function Get-GitHubAppInstallationToken {
    Param (
        [Parameter(Mandatory=$true)]
        [string] $AppId,
        [Parameter(Mandatory=$true)]
        [string] $AppPrivateKey,
        [string] $InstallationId,
        [string] $Organization,
        [string[]] $Repositories,
        [hashtable] $Permissions
    )

    $normalizedKey = ConvertTo-MultilinePem -KeyContent $AppPrivateKey
    $jwt = Get-JWTToken -app_id $AppId -app_private_key $normalizedKey

    $headers = @{
        Authorization = "Bearer $jwt"
        Accept = "application/vnd.github+json"
        "User-Agent" = "actions-marketplace-checks"
    }

    $resolvedInstallationId = $InstallationId
    if ([string]::IsNullOrWhiteSpace($resolvedInstallationId)) {
        if ([string]::IsNullOrWhiteSpace($Organization)) {
            throw "Organization name is required when installationId is not provided"
        }
        $resolvedInstallationId = Get-GitHubAppInstallationId -Jwt $jwt -Organization $Organization
    }

    $requestBody = @{}
    if ($Repositories) {
        $requestBody.repositories = $Repositories
    }
    if ($Permissions) {
        $requestBody.permissions = $Permissions
    }

    $bodyJson = if ($requestBody.Count -gt 0) { $requestBody | ConvertTo-Json -Depth 5 } else { "{}" }

    $tokenUri = "https://api.github.com/app/installations/$resolvedInstallationId/access_tokens"
    try {
        $tokenResponse = Invoke-RestMethod -Uri $tokenUri -Headers $headers -Method Post -Body $bodyJson -ErrorAction Stop
    }
    catch {
        throw "Error requesting GitHub App installation token: $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($tokenResponse.token)) {
        throw "GitHub App installation token response did not include a token"
    }

    return [pscustomobject]@{
        token = $tokenResponse.token
        expiresAt = $tokenResponse.expires_at
        installationId = $resolvedInstallationId
        organization = if ($Organization) { $Organization } else { $tokenResponse.account.login }
        permissions = $tokenResponse.permissions
        repositories = $tokenResponse.repositories
    }
}
