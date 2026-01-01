function ConvertTo-Base64Url {
    param ([byte[]]$Bytes)
    return ([Convert]::ToBase64String($Bytes)).TrimEnd('=') -replace '\+', '-' -replace '/', '_'
}

function ConvertStringTo-Base64Url {
    param ([string]$Value)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    return ConvertTo-Base64Url -Bytes $bytes
}

function Normalize-PrivateKey {
    param ([string]$PrivateKey)
    $normalized = $PrivateKey -replace "\r", ""
    if ($normalized -match "\\n") {
        $normalized = $normalized -replace "\\n", "`n"
    }
    if (-not ($normalized.TrimEnd().EndsWith("`n"))) {
        $normalized = "$normalized`n"
    }
    return $normalized
}

function New-GitHubAppJwt {
    param (
        [Parameter(Mandatory=$true)][string]$AppId,
        [Parameter(Mandatory=$true)][string]$PrivateKey,
        [TimeSpan]$Lifetime = [TimeSpan]::FromMinutes(5)
    )

    $normalizedKey = Normalize-PrivateKey -PrivateKey $PrivateKey
    $headerJson = @{ alg = "RS256"; typ = "JWT" } | ConvertTo-Json -Compress
    $now = [DateTimeOffset]::UtcNow.AddSeconds(-30)
    $issued = [int]$now.ToUnixTimeSeconds()
    $expires = [int]$now.Add($Lifetime).ToUnixTimeSeconds()
    $payloadJson = @{ iat = $issued; exp = $expires; iss = [int]$AppId } | ConvertTo-Json -Compress

    $unsignedToken = "$(ConvertStringTo-Base64Url $headerJson).$(ConvertStringTo-Base64Url $payloadJson)"

    $rsa = [System.Security.Cryptography.RSA]::Create()
    $rsa.ImportFromPem($normalizedKey)
    $hashName = [System.Security.Cryptography.HashAlgorithmName]::SHA256
    $padding = [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    $signatureBytes = $rsa.SignData([System.Text.Encoding]::UTF8.GetBytes($unsignedToken), $hashName, $padding)
    $signature = ConvertTo-Base64Url -Bytes $signatureBytes

    return "$unsignedToken.$signature"
}

function Get-GitHubAppInstallationToken {
    param (
        [Parameter(Mandatory=$true)][string]$AppId,
        [Parameter(Mandatory=$true)][string]$PrivateKey,
        [string]$InstallationId,
        [string]$Organization,
        [string]$ApiUrl = "https://api.github.com",
        [switch]$IncludeMetadata
    )

    if ([string]::IsNullOrWhiteSpace($InstallationId) -and [string]::IsNullOrWhiteSpace($Organization)) {
        throw "InstallationId or Organization must be provided."
    }

    $jwt = New-GitHubAppJwt -AppId $AppId -PrivateKey $PrivateKey
    $headers = @{
        Authorization = "Bearer $jwt"
        Accept = "application/vnd.github+json"
        "User-Agent" = "actions-marketplace-checks"
    }

    $resolvedInstallationId = $InstallationId
    if ([string]::IsNullOrWhiteSpace($resolvedInstallationId)) {
        $installationsUrl = "$ApiUrl/app/installations"
        $installations = Invoke-RestMethod -Method Get -Uri $installationsUrl -Headers $headers
        $match = $installations | Where-Object { $_.account.login -eq $Organization -or $_.account.slug -eq $Organization }
        if (-not $match) {
            throw "No installation found for $Organization."
        }
        $resolvedInstallationId = $match[0].id
    }

    $tokenUrl = "$ApiUrl/app/installations/$resolvedInstallationId/access_tokens"
    $response = Invoke-RestMethod -Method Post -Uri $tokenUrl -Headers $headers -Body "{}"

    if ($IncludeMetadata) {
        return [PSCustomObject]@{
            token = $response.token
            expiresAt = $response.expires_at
            installationId = $resolvedInstallationId
        }
    }

    return $response.token
}
