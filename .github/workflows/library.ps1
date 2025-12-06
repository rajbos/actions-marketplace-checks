
# default variables
$forkOrg = "actions-marketplace-validations"
$tempDir = "$((Get-Item $PSScriptRoot).parent.parent.FullName)/mirroredRepos"
$actionsFile = "$((Get-Item $PSScriptRoot).parent.parent.FullName)/Actions-Full-Overview.Json"
$statusFile = "$((Get-Item $PSScriptRoot).parent.parent.FullName)/status.json"
$failedStatusFile = "$((Get-Item $PSScriptRoot).parent.parent.FullName)/failedForks.json"
$secretScanningAlertsFile = "$((Get-Item $PSScriptRoot).parent.parent.FullName)/secretScanningAlerts.json"
Write-Host "tempDir location: [$tempDir]"
Write-Host "actionsFile location: [$actionsFile]"
Write-Host "statusFile location: [$statusFile]"
Write-Host "failedStatusFile location: [$failedStatusFile]"
Write-Host "secretScanningAlertsFile location: [$secretScanningAlertsFile]"

# Blob file names in the 'status' subfolder
$script:actionsBlobFileName = "Actions-Full-Overview.Json"
$script:statusBlobFileName = "status.json"
$script:failedForksBlobFileName = "failedForks.json"
$script:secretScanningAlertsBlobFileName = "secretScanningAlerts.json"

<#
    .SYNOPSIS
    Downloads actions.json from Azure Blob Storage.

    .DESCRIPTION
    Downloads the actions.json file from blob storage.
    This is the main data file containing all marketplace actions.

    .PARAMETER sasToken
    The blob storage URL with SAS token query string (e.g., https://storage.blob.core.windows.net/container/data?sp=racwdl&st=...).
    The URL should already include the data folder path.

    .PARAMETER localFilePath
    The local file path where the downloaded file should be saved. Defaults to $actionsFile.

    .EXAMPLE
    Get-ActionsJsonFromBlobStorage -sasToken $env:BLOB_SAS_TOKEN
#>
function Get-ActionsJsonFromBlobStorage {
    Param (
        [Parameter(Mandatory=$true)]
        [string] $sasToken,
        
        [Parameter(Mandatory=$false)]
        [string] $localFilePath = $actionsFile
    )

    Write-Message -message "Downloading $script:actionsBlobFileName from Azure Blob Storage..." -logToSummary $true

    # The sasToken is the blob storage URL with SAS query (e.g., https://.../container/data?sp=racwdl&st=...)
    # The URL already includes the /data path, so we just append /actions.json
    $baseUrlWithQuery = $sasToken
    $queryStart = $baseUrlWithQuery.IndexOf('?')
    $baseUrl = $baseUrlWithQuery.Substring(0, $queryStart)
    $sasQuery = $baseUrlWithQuery.Substring($queryStart)
    
    # Construct full blob URL: baseUrl + /actions.json + SAS query
    $blobUrl = "${baseUrl}/${script:actionsBlobFileName}${sasQuery}"
    
    Write-Host "Blob URL: ${baseUrl}/${script:actionsBlobFileName} (SAS redacted)"

    try {
        Invoke-WebRequest -Uri $blobUrl -Method GET -OutFile $localFilePath -UseBasicParsing | Out-Null
        
        if (Test-Path $localFilePath) {
            $fileSize = (Get-Item $localFilePath).Length
            $message = "✓ Successfully downloaded $script:actionsBlobFileName ($fileSize bytes) to [$localFilePath]"
            Write-Message -message $message -logToSummary $true
            return $true
        }
        else {
            $message = "⚠️ ERROR: Failed to download Actions-Full-Overview.Json - file not found after download"
            Write-Message -message $message -logToSummary $true
            Write-Error $message
            return $false
        }
    }
    catch {
        $message = "⚠️ ERROR: Failed to download $script:actionsBlobFileName from blob storage: $($_.Exception.Message)"
        Write-Message -message $message -logToSummary $true
        Write-Error $message
        return $false
    }
}

<#
    .SYNOPSIS
    Common function to download a JSON file from Azure Blob Storage.

    .DESCRIPTION
    Uses the provided SAS token URL to download a JSON file from Azure Blob Storage.
    The SAS token should include the data folder path (e.g., https://storage.blob.core.windows.net/container/data?sp=racwdl&st=...).
    Files are downloaded from the 'status' subfolder within that path.
    If the file doesn't exist (404), creates an empty JSON array file locally.

    .PARAMETER sasToken
    The blob storage URL with SAS token query string, including the data folder path.

    .PARAMETER blobFileName
    The name of the file in blob storage (e.g., 'status.json').

    .PARAMETER localFilePath
    The local file path where the downloaded file should be saved.

    .EXAMPLE
    Get-JsonFromBlobStorage -sasToken $env:BLOB_SAS_TOKEN -blobFileName "status.json" -localFilePath $statusFile
#>
function Get-JsonFromBlobStorage {
    Param (
        [Parameter(Mandatory=$true)]
        [string] $sasToken,
        
        [Parameter(Mandatory=$true)]
        [string] $blobFileName,
        
        [Parameter(Mandatory=$true)]
        [string] $localFilePath
    )

    Write-Message -message "Downloading $blobFileName from Azure Blob Storage..." -logToSummary $true

    # The sasToken is the blob storage URL with SAS query (e.g., https://.../container/data?sp=racwdl&st=...)
    # The URL already includes the /data path, so we append /status/blobFileName
    $baseUrlWithQuery = $sasToken
    $queryStart = $baseUrlWithQuery.IndexOf('?')
    $baseUrl = $baseUrlWithQuery.Substring(0, $queryStart)
    $sasQuery = $baseUrlWithQuery.Substring($queryStart)
    
    # Construct full blob URL: baseUrl + /status/blobFileName + SAS query
    $blobUrl = "${baseUrl}/status/${blobFileName}${sasQuery}"
    
    Write-Host "Blob URL: ${baseUrl}/status/$blobFileName (SAS redacted)"

    try {
        Invoke-WebRequest -Uri $blobUrl -Method GET -OutFile $localFilePath -UseBasicParsing | Out-Null
        
        if (Test-Path $localFilePath) {
            $fileSize = (Get-Item $localFilePath).Length
            $message = "✓ Successfully downloaded $blobFileName ($fileSize bytes) to [$localFilePath]"
            Write-Message -message $message -logToSummary $true
            return $true
        }
        else {
            $message = "⚠️ ERROR: Failed to download $blobFileName - file not found after download"
            Write-Message -message $message -logToSummary $true
            Write-Error $message
            return $false
        }
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            $message = "ℹ️ $blobFileName does not exist in blob storage yet. Starting with empty array."
            Write-Message -message $message -logToSummary $true
            "[]" | Out-File -FilePath $localFilePath -Encoding UTF8
            return $true
        }
        $message = "⚠️ ERROR: Failed to download $blobFileName from blob storage: $($_.Exception.Message)"
        Write-Message -message $message -logToSummary $true
        Write-Error $message
        return $false
    }
}

<#
    .SYNOPSIS
    Common function to upload a JSON file to Azure Blob Storage.

    .DESCRIPTION
    Uses the provided SAS token URL to upload a JSON file to Azure Blob Storage.
    The SAS token should include the data folder path (e.g., https://storage.blob.core.windows.net/container/data?sp=racwdl&st=...).
    Files are uploaded to the 'status' subfolder within that path.
    If the local file doesn't exist, returns true (nothing to upload).
    Before uploading, it downloads the current version from blob storage and compares content.
    Only uploads if the content has changed, optimizing efficiency.

    .PARAMETER sasToken
    The blob storage URL with SAS token query string, including the data folder path.

    .PARAMETER blobFileName
    The name of the file in blob storage (e.g., 'status.json').

    .PARAMETER localFilePath
    The local file path to upload.

    .PARAMETER failIfMissing
    If true, returns false when the local file doesn't exist. Default is false.

    .EXAMPLE
    Set-JsonToBlobStorage -sasToken $env:BLOB_SAS_TOKEN -blobFileName "status.json" -localFilePath $statusFile
#>
function Set-JsonToBlobStorage {
    Param (
        [Parameter(Mandatory=$true)]
        [string] $sasToken,
        
        [Parameter(Mandatory=$true)]
        [string] $blobFileName,
        
        [Parameter(Mandatory=$true)]
        [string] $localFilePath,
        
        [Parameter(Mandatory=$false)]
        [bool] $failIfMissing = $false
    )

    Write-Message -message "Checking upload status for $blobFileName..." -logToSummary $true

    # Validate file existence
    if (-not (Test-Path $localFilePath)) {
        if ($failIfMissing) {
            $message = "⚠️ ERROR: $blobFileName does not exist at [$localFilePath]. Nothing to upload."
            Write-Message -message $message -logToSummary $true
            Write-Error $message
            return $false
        }
        $message = "⚠️ WARNING: $blobFileName does not exist at [$localFilePath]. Skipping upload."
        Write-Message -message $message -logToSummary $true
        return $true
    }

    # The sasToken is the blob storage URL with SAS query (e.g., https://.../container/data?sp=racwdl&st=...)
    # The URL already includes the /data path, so we append /status/blobFileName
    $baseUrlWithQuery = $sasToken
    $queryStart = $baseUrlWithQuery.IndexOf('?')
    $baseUrl = $baseUrlWithQuery.Substring(0, $queryStart)
    $sasQuery = $baseUrlWithQuery.Substring($queryStart)
    
    # Construct full blob URL: baseUrl + /status/blobFileName + SAS query
    $blobUrl = "${baseUrl}/status/${blobFileName}${sasQuery}"
    
    Write-Host "Blob URL: ${baseUrl}/status/$blobFileName (SAS redacted)"

    # Read local file content
    $localContent = [System.IO.File]::ReadAllBytes($localFilePath)
    $localFileSize = $localContent.Length
    
    # Download current version from blob storage to compare
    $tempCompareFile = [System.IO.Path]::GetTempFileName()
    try {
        Write-Host "Downloading current version of $blobFileName from blob storage for comparison..."
        Invoke-WebRequest -Uri $blobUrl -Method GET -OutFile $tempCompareFile -UseBasicParsing -ErrorAction SilentlyContinue | Out-Null
        
        if (Test-Path $tempCompareFile) {
            $remoteContent = [System.IO.File]::ReadAllBytes($tempCompareFile)
            $remoteFileSize = $remoteContent.Length
            
            # Compare file content using SHA256 hash for efficiency (especially for large files)
            $filesMatch = $false
            if ($localFileSize -eq $remoteFileSize) {
                # Compute SHA256 hashes for comparison
                $localHash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($localContent)
                $remoteHash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($remoteContent)
                
                # Convert hashes to base64 for comparison
                $localHashString = [Convert]::ToBase64String($localHash)
                $remoteHashString = [Convert]::ToBase64String($remoteHash)
                
                $filesMatch = $localHashString -eq $remoteHashString
            }
            
            if ($filesMatch) {
                $message = "✓ No changes detected in $blobFileName (size: $localFileSize bytes). Skipping upload."
                Write-Message -message $message -logToSummary $true
                Remove-Item -Path $tempCompareFile -Force -ErrorAction SilentlyContinue
                return $true
            }
            
            Write-Host "Changes detected in $blobFileName (local: $localFileSize bytes, remote: $remoteFileSize bytes)"
        }
        else {
            Write-Host "$blobFileName does not exist in blob storage yet. Will upload new file."
        }
    }
    catch {
        # If download fails (e.g., 404 for new file), continue with upload
        Write-Host "Could not download current version of $blobFileName (might be new file): $($_.Exception.Message)"
    }
    finally {
        # Clean up temp file
        if (Test-Path $tempCompareFile) {
            Remove-Item -Path $tempCompareFile -Force -ErrorAction SilentlyContinue
        }
    }

    # Upload the file
    try {
        Write-Host "Uploading $blobFileName ($localFileSize bytes) to Azure Blob Storage..."
        
        $headers = @{
            "x-ms-blob-type" = "BlockBlob"
            "Content-Type" = "application/json"
        }
        
        $response = Invoke-WebRequest -Uri $blobUrl -Method PUT -Body $localContent -Headers $headers -UseBasicParsing
        
        if ($response.StatusCode -eq 201 -or $response.StatusCode -eq 200) {
            $message = "✓ Successfully uploaded $blobFileName ($localFileSize bytes) to blob storage"
            Write-Message -message $message -logToSummary $true
            return $true
        }
        else {
            $message = "⚠️ ERROR: Unexpected status code when uploading $blobFileName`: $($response.StatusCode)"
            Write-Message -message $message -logToSummary $true
            Write-Error $message
            return $false
        }
    }
    catch {
        $message = "⚠️ ERROR: Failed to upload $blobFileName to blob storage: $($_.Exception.Message)"
        Write-Message -message $message -logToSummary $true
        Write-Error $message
        return $false
    }
}

# Convenience wrapper functions for specific files

function Get-StatusFromBlobStorage {
    Param ([Parameter(Mandatory=$true)][string] $sasToken)
    return Get-JsonFromBlobStorage -sasToken $sasToken -blobFileName $script:statusBlobFileName -localFilePath $statusFile
}

function Set-StatusToBlobStorage {
    Param ([Parameter(Mandatory=$true)][string] $sasToken)
    return Set-JsonToBlobStorage -sasToken $sasToken -blobFileName $script:statusBlobFileName -localFilePath $statusFile -failIfMissing $true
}

function Get-FailedForksFromBlobStorage {
    Param ([Parameter(Mandatory=$true)][string] $sasToken)
    return Get-JsonFromBlobStorage -sasToken $sasToken -blobFileName $script:failedForksBlobFileName -localFilePath $failedStatusFile
}

function Set-FailedForksToBlobStorage {
    Param ([Parameter(Mandatory=$true)][string] $sasToken)
    return Set-JsonToBlobStorage -sasToken $sasToken -blobFileName $script:failedForksBlobFileName -localFilePath $failedStatusFile
}

function Set-SecretScanningAlertsToBlobStorage {
    Param ([Parameter(Mandatory=$true)][string] $sasToken)
    return Set-JsonToBlobStorage -sasToken $sasToken -blobFileName $script:secretScanningAlertsBlobFileName -localFilePath $secretScanningAlertsFile
}

function ApiCall {
    Param (
        $method,
        $url,
        $body,
        $expected,
        [int] $currentResultCount,
        [int] $backOff = 5,
        [int] $maxResultCount = 0,
        [bool] $hideFailedCall = $false,
        [bool] $returnErrorInfo = $false,
        $access_token = $env:GITHUB_TOKEN
    )
    
    # Validate that access token is not null or empty before making API calls
    if ([string]::IsNullOrWhiteSpace($access_token)) {
        Write-Error "Missing GitHub access token. API call to [$url] cannot proceed without valid credentials."
        throw "No access token available for API call. Please ensure ACCESS_TOKEN or Automation_App_Key secrets are properly configured."
    }
    
    $headers = @{
        Authorization = GetBasicAuthenticationHeader -access_token $access_token
    }
    if ($null -ne $body) {
        $headers.Add('Content-Type', 'application/json')
        $headers.Add('User-Agent', 'rajbos')
    }

    # prevent errors with empty urls
    if ($null -eq $url -or $url -eq "") {
        Write-Message -message "ApiCall Url is empty" -logToSummary $true
        # show the method that called this function
        Write-Message -message "ApiCall was called from: $(Get-PSCallStack | Select-Object -Skip 1 | Select-Object -First 1 | ForEach-Object { $_.Command })" -logToSummary $true
        return false
    }
    # prevent errors with starting slashes
    if ($url.StartsWith("/")) {
        $url = $url.Substring(1)
    }
    # auto prepend with api url
    if (!$url.StartsWith('https://api.github.com/')) {
        if (!$url.StartsWith('https://raw.githubusercontent.com')) {
            $url = "https://api.github.com/"+$url
        }
    }
    try
    {
        #$response = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -Body $body -ContentType 'application/json'
        if ($method -eq "GET" -or $method -eq "DELETE") {
            $result = Invoke-WebRequest -Uri $url -Headers $headers -Method $method -ErrorVariable $errvar -ErrorAction Continue
        }
        else {
            $result = Invoke-WebRequest -Uri $url -Headers $headers -Method $method -Body $body -ContentType 'application/json' -ErrorVariable $errvar -ErrorAction Continue
        }

        if (!$url.StartsWith('https://raw.githubusercontent.com')) {
            $response = $result.Content | ConvertFrom-Json
        }
        else {
            $response = $result.Content
        }
        #Write-Host "Got this response: $($response | ConvertTo-Json)"
        # todo: check and handle the rate limit headers
        Write-Debug "  StatusCode: $($result.StatusCode)"
        Write-Debug "  RateLimit-Limit: $($result.Headers["X-RateLimit-Limit"])"
        Write-Debug "  RateLimit-Remaining: $($result.Headers["X-RateLimit-Remaining"])"
        Write-Debug "  RateLimit-Reset: $($result.Headers["X-RateLimit-Reset"])"
        Write-Debug "  RateLimit-Used: $($result.Headers["X-Ratelimit-used"])"
        Write-Debug "  Retry-After: $($result.Headers["Retry-After"])"

        if ($result.Headers["Link"]) {
            #Write-Host "Found pagination link: $($result.Headers["Link"])"
            # load next link from header

            $result.Headers["Link"].Split(',') | ForEach-Object {
                # search for the 'next' link in this list
                $link = $_.Split(';')[0].Trim()
                if ($_.Split(';')[1].Contains("next")) {
                    $nextUrl = $link.Substring(1, $link.Length - 2)

                    $currentResultCount = $currentResultCount + $response.Count
                    if ($maxResultCount -ne 0) {
                        Write-Host "Loading next page of data, where at [$($currentResultCount)] of max [$maxResultCount]"
                    }
                    # and get the results
                    if ($maxResultCount -ne 0) {
                        # check if we need to stop getting more pages
                        if ($currentResultCount -gt $maxResultCount) {
                            Write-Host "Stopping with [$($currentResultCount)] results, which is more then the max result count [$maxResultCount]"
                            return $response
                        }
                    }

                    # continue fetching next page
                    $nextResult = ApiCall -method $method -url $nextUrl -body $body -expected $expected -backOff $backOff -maxResultCount $maxResultCount -currentResultCount $currentResultCount -access_token $access_token
                    $response += $nextResult
                }
            }
        }

        $rateLimitRemaining = $result.Headers["X-RateLimit-Remaining"]
        $rateLimitReset = $result.Headers["X-RateLimit-Reset"]
        $rateLimitUsed = $result.Headers["X-Ratelimit-Used"]
        if ($rateLimitRemaining -And $rateLimitRemaining[0] -lt 100) {
            # convert rateLimitReset from epoch to ms
            $rateLimitResetInt = [int]$rateLimitReset[0]
            $oUNIXDate=(Get-Date 01.01.1970)+([System.TimeSpan]::fromseconds($rateLimitResetInt))
            $rateLimitReset = $oUNIXDate - [DateTime]::UtcNow
            if ($rateLimitReset.TotalMilliseconds -gt 0) {
                Write-Host ""
                if ($rateLimitReset.TotalSeconds -gt 1200) {
                    $message = "Rate limit is low or hit (Remaining/Used) [$($rateLimitRemaining)/$($rateLimitUsed)], and we need to wait for [$([math]::Round($rateLimitReset.TotalSeconds, 0))] seconds before continuing, which would mean continuing at [$oUNIXDate UTC]. This is longer then 20 minutes, so we are stopping the execution"
                    Write-Message -message $message -logToSummary $true
                    throw $message
                }
                $message = "Rate limit is low or hit (Remaining/Used) [$($rateLimitRemaining)/$($rateLimitUsed)], waiting for [$([math]::Round($rateLimitReset.TotalSeconds, 0))] seconds before continuing. Continuing at [$oUNIXDate UTC]"
                Write-Message -message $message -logToSummary $true
                Write-Host ""
                Start-Sleep -Milliseconds $rateLimitReset.TotalMilliseconds
            }
            return ApiCall -method $method -url $url -body $body -expected $expected -backOff ($backOff*2) -access_token $access_token
        }

        if ($null -ne $expected) {
            if ($result.StatusCode -ne $expected) {
                Write-Host "  Expected status code [$expected] but got [$($result.StatusCode)]"
                return $false
            }
            else {
                return $true
            }
        }

        return $response
    }
    catch
    {
        $messageData
        try {
            $messageData = $_.ErrorDetails.Message | ConvertFrom-Json
        }
        catch {
            $messageData = $_.ErrorDetails.Message
        }

        if ($messageData.message -eq "was submitted too quickly") {
            Write-Host "Rate limit exceeded, waiting for [$backOff] seconds before continuing"
            Start-Sleep -Seconds $backOff
            GetRateLimitInfo -access_token $access_token -access_token_destination $access_token
            return ApiCall -method $method -url $url -body $body -expected $expected -backOff ($backOff*2) -access_token $access_token
        }
        else {
            if (!$hideFailedCall) {
                Write-Host "Log message: $($messageData.message)"
            }
        }

        if ($messageData.message -And ($messageData.message.StartsWith("You have exceeded a secondary rate limit"))) {
            if ($backOff -eq 5) {
                # start the initial backoff bigger, might give more change to continue faster
                $backOff = 120
            }
            else {
                $backOff = $backOff*2
            }
            Write-Host "Secondary rate limit exceeded, waiting for [$backOff] seconds before continuing"
            Start-Sleep -Seconds $backOff

            return ApiCall -method $method -url $url -body $body -expected $expected -backOff $backOff -access_token $access_token
        }

        if ($messageData.message -And ($messageData.message.StartsWith("API rate limit exceeded for user ID"))) {
            $rateLimitReset = $_.Exception.Response.Headers["X-RateLimit-Reset"]
            $rateLimitRemaining = $result.Headers["X-RateLimit-Remaining"]
            if ($rateLimitRemaining -And $rateLimitRemaining[0] -lt 10) {
                # convert rateLimitReset from epoch to ms
                $rateLimitResetInt = [int]$rateLimitReset[0]
                $oUNIXDate=(Get-Date 01.01.1970)+([System.TimeSpan]::fromseconds($rateLimitResetInt))
                $rateLimitReset = $oUNIXDate - [DateTime]::UtcNow
                if ($rateLimitReset.TotalMilliseconds -gt 0) {
                    Write-Host "Rate limit is low or hit, waiting for [$($rateLimitReset.TotalSeconds)] seconds before continuing"
                    Start-Sleep -Milliseconds $rateLimitReset.TotalMilliseconds
                }
            }
            return ApiCall -method $method -url $url -body $body -expected $expected -backOff ($backOff*2) -access_token $access_token
        }

        if ($null -ne $expected)
        {
            Write-Host "Expected status code [$expected] but got [$($_.Exception.Response.StatusCode)] for [$url]"
            if ($_.Exception.Response.StatusCode -eq $expected) {
                # expected error
                Write-Host "Returning true"
                return $true
            }
            else {
                Write-Host "Returning false"
                return $false
            }
        }
        else {
            # if the call failure is expected, suppress the error
            if ($returnErrorInfo) {
                # Return error information instead of throwing
                $statusCode = 0
                if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                    $statusCode = $_.Exception.Response.StatusCode.value__
                }
                $message = if ($messageData -and $messageData.message) { $messageData.message } else { "Unknown error" }
                
                return @{
                    Error = $true
                    StatusCode = $statusCode
                    Message = $message
                    Url = $url
                }
            }
            
            if (!$hideFailedCall) {
                Write-Host "Error calling $url, status code [$($result.StatusCode)]"
                Write-Host "MessageData: " $messageData
                Write-Host "Error: " $_
                if ($result.Content.Length -gt 100) {
                    Write-Host "Content: " $result.Content.Substring(0, 100) + "..."
                }
                else {
                    Write-Host "Content: " $result.Content
                }

                throw
            }
        }
    }
}

function GetBasicAuthenticationHeader(){
    Param (
        $access_token = $env:GITHUB_TOKEN
    )

    $CredPair = "x:$access_token"
    $EncodedCredentials = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($CredPair))

    return "Basic $EncodedCredentials";
}

function SplitUrl {
    Param (
        $url
    )

    # this fails when finding the repo name from this url
    #if ($url.StartsWith("https://github.com/marketplace/actions")) {
    #    return "";
    #}
    if ($null -eq $url) {
        return $null
    }

    # split the url into the last 2 parts
    $urlParts = $url.Split('/')
    $repo = $urlParts[-1]
    $owner = $urlParts[-2]
    # return repo and org
    return $owner, $repo
}

function GetForkedRepoName {
    Param (
        $owner,
        $repo
     )
    return "$($owner)_$($repo)"
}

function GetOrgActionInfo {
    Param (
        $forkedOwnerRepo
    )

    if ($null -ne $forkedOwnerRepo -And $forkedOwnerRepo -ne "") {
        $forkedOwnerRepoParts = $forkedOwnerRepo.Split('_')
        $owner = $forkedOwnerRepoParts[0]
        $repo = $forkedOwnerRepo.Substring($owner.Length + 1)

        return $owner, $repo
    }

    return "", ""
}

function SplitUrlLastPart {
    Param (
        $url
    )

    # this fails when finding the repo name from this url
    #if ($url.StartsWith("https://github.com/marketplace/actions")) {
    #    return "";
    #}

    # split the url into the last part
    $urlParts = $url.Split('/')
    $repo = $urlParts[-1]
    # return repo
    return $repo
}

<#
    .SYNOPSIS
    Formats rate limit information as a markdown table.
    
    .DESCRIPTION
    Takes rate limit data and outputs it as a formatted markdown table.
    Converts Unix timestamp to human-readable time remaining.
    
    .PARAMETER rateData
    The rate limit object containing limit, used, remaining, and reset properties
    
    .PARAMETER title
    Optional title to display above the table
    
    .EXAMPLE
    Format-RateLimitTable -rateData $response.rate -title "Rate Limit Status"
#>
function Format-RateLimitTable {
    Param (
        $rateData,
        [string] $title = "Rate Limit Status"
    )
    
    # Convert Unix timestamp to human-readable time
    $resetTime = [DateTimeOffset]::FromUnixTimeSeconds($rateData.reset).UtcDateTime
    $timeUntilReset = $resetTime - (Get-Date).ToUniversalTime()
    
    # Format time remaining as human-readable string
    if ($timeUntilReset.TotalMinutes -lt 1) {
        $resetDisplay = "< 1 minute"
    } elseif ($timeUntilReset.TotalHours -lt 1) {
        $resetDisplay = "$([math]::Floor($timeUntilReset.TotalMinutes)) minutes"
    } else {
        $hours = [math]::Floor($timeUntilReset.TotalHours)
        $minutes = [math]::Floor($timeUntilReset.Minutes)
        if ($minutes -eq 0) {
            $resetDisplay = "$hours hours"
        } else {
            $resetDisplay = "$hours hours $minutes minutes"
        }
    }
    
    Write-Message -message "**${title}:**" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "| Limit | Used | Remaining | Resets In |" -logToSummary $true
    Write-Message -message "|------:|-----:|----------:|-----------|" -logToSummary $true
    Write-Message -message "| $($rateData.limit) | $($rateData.used) | $($rateData.remaining) | $resetDisplay |" -logToSummary $true
    Write-Message -message "" -logToSummary $true
}

function GetRateLimitInfo {
    Param (
        $access_token,
        $access_token_destination
    )
    $url = "rate_limit"
    $response = ApiCall -method GET -url $url -access_token $access_token

    # Format rate limit info as a table using the helper function
    Format-RateLimitTable -rateData $response.rate -title "Rate Limit Status"

    if ($access_token -ne $access_token_destination) {
        # check the ratelimit for the destination token as well:
        $response2 = ApiCall -method GET -url $url -access_token $access_token_destination
        Format-RateLimitTable -rateData $response2.rate -title "Access Token Destination Rate Limit Status"
    }

    if ($response.rate.limit -eq 60) {
        throw "Rate limit is 60, this is not enough to run this script, check the token that is used"
    }
}

function Get-TokenExpirationTime {
    Param (
        [Parameter(Mandatory=$true)]
        $access_token
    )
    
    # Call the rate_limit API to get token expiration information from response headers
    # GitHub App tokens include a 'GitHub-Authentication-Token-Expiration' header
    # that contains the expiration timestamp in ISO 8601 format
    
    $url = "rate_limit"
    $headers = @{
        Authorization = GetBasicAuthenticationHeader -access_token $access_token
    }
    
    try {
        $result = Invoke-WebRequest -Uri "https://api.github.com/$url" -Headers $headers -Method GET -ErrorAction Stop
        
        # Check for token expiration header
        # GitHub uses 'GitHub-Authentication-Token-Expiration' header for App tokens
        $expirationHeader = $null
        if ($result.Headers.ContainsKey('GitHub-Authentication-Token-Expiration')) {
            $expirationHeader = $result.Headers['GitHub-Authentication-Token-Expiration']
        }
        elseif ($result.Headers.ContainsKey('github-authentication-token-expiration')) {
            $expirationHeader = $result.Headers['github-authentication-token-expiration']
        }
        
        if ($null -ne $expirationHeader) {
            # Parse the ISO 8601 timestamp using culture-invariant parsing
            # GitHub returns timestamps in format like: "2024-12-04 08:30:45 UTC"
            try {
                $expirationTime = [DateTimeOffset]::Parse($expirationHeader[0], [System.Globalization.CultureInfo]::InvariantCulture).UtcDateTime
                Write-Host "Token expiration time: $expirationTime UTC"
                return $expirationTime
            }
            catch {
                Write-Warning "Failed to parse token expiration header value: $($expirationHeader[0])"
                Write-Debug "Parse error: $($_.Exception.Message)"
                return $null
            }
        }
        else {
            Write-Warning "Token expiration header not found in response. Token may not be a GitHub App token."
            Write-Debug "Available headers: $($result.Headers.Keys -join ', ')"
            return $null
        }
    }
    catch {
        Write-Error "Failed to get token expiration time: $($_.Exception.Message)"
        return $null
    }
}

function Test-TokenExpiration {
    Param (
        [Parameter(Mandatory=$true)]
        [DateTime]$expirationTime,
        [int]$warningMinutes = 5
    )
    
    # Check if the token is about to expire within the specified number of minutes
    # Returns $true if expiration is imminent, $false otherwise
    
    $currentTime = [DateTime]::UtcNow
    $timeRemaining = $expirationTime - $currentTime
    
    if ($timeRemaining.TotalMinutes -le $warningMinutes) {
        return $true
    }
    
    return $false
}

function SaveStatus {
    Param (
        $existingForks,
        $failedForks
    )
    Write-Host "SaveStatus"
    # Note: git pull is handled by the workflow's "Commit changes" step, not here.
    # Doing git pull here was causing 30+ minute delays due to merge operations
    # on the large status.json file during concurrent workflow runs.
    
    if ($null -ne $existingForks -and $existingForks.Count -gt 0) {
        Write-Host "Storing the information of [$($existingForks.Count)] existing forks to the status file"
        # Use -InputObject to avoid slow pipeline processing for large arrays
        $json = ConvertTo-Json -InputObject $existingForks -Depth 10
        [System.IO.File]::WriteAllText($statusFile, $json, [System.Text.Encoding]::UTF8)
        Write-Host "Saved"

        # get number of forks that have repo information
        $existingForksWithRepoInfo = $existingForks | Where-Object { $_.repoInfo -And ($null -ne $_.repoInfo.updated_at) }
        Write-Message -message "Found [$($existingForksWithRepoInfo.Count) out of $($existingForks.Count)] repos that have repo information" -logToSummary $true
    }

    if ($null -ne $failedForks -and $failedForks.Count -gt 0) {
        Write-Host "Storing the information of [$($failedForks.Count)] failed forks to the failed status file"
        # Use -InputObject to avoid slow pipeline processing for large arrays
        $json = ConvertTo-Json -InputObject $failedForks -Depth 10
        [System.IO.File]::WriteAllText($failedStatusFile, $json, [System.Text.Encoding]::UTF8)
        Write-Host "Saved"
    }
}

function FilterActionsToProcess {
    Param (
        $actionsToProcess,
        $existingForks
    )

    # flatten the list for faster processing
    $actionsToProcess = FlattenActionsList -actions $actionsToProcess | Sort-Object -Property forkedRepoName
    # for faster searching, convert to single string array instead of objects
    $existingForksNames = @($existingForks | ForEach-Object { $_.name } | Sort-Object)
    # filter the actions list down to the set we still need to fork (not known in the existingForks list)
    $lastIndex = 0
    $actionsToProcess = $actionsToProcess | ForEach-Object {
        $forkedRepoName = $_.forkedRepoName
        $found = $false
        # for loop since the existingForksNames is a sorted array
        for ($j = $lastIndex; $j -lt $existingForksNames.Count; $j++) {
            if ($existingForksNames[$j] -eq $forkedRepoName) {
                $found = $true
                $lastIndex = $j
                break
            }
            # check first letter, since we sorted we do not need to go any further
            if ($existingForksNames[$j][0] -gt $forkedRepoName[0]) {
                $lastIndex = $j
                break
            }
        }
        if (!$found) {
           return $_
        }
    }

    return $actionsToProcess
}

function FilterActionsToProcessDependabot {
    Param (
        $actionsToProcess,
        $existingForks
    )

    # flatten the list for faster processing
    $actionsToProcess = FlattenActionsList -actions $actionsToProcess | Sort-Object -Property forkedRepoName
    # for faster searching, convert to single string array instead of objects
    $existingForksNames = @($existingForks | ForEach-Object { $_.name } | Sort-Object)
    # filter the actions list down to the set we still need to fork (not known in the existingForks list)
    $j = 0
    $existingFork = $null
    $forkedRepoName = ""
    $found = $false
    $actionsToProcess = $actionsToProcess | ForEach-Object {
        $forkedRepoName = $_.forkedRepoName
        $found = $false
        # for loop since the existingForksNames is a sorted array
        for ($j = 0; $j -lt $existingForksNames.Count; $j++) {
            if ($existingForksNames[$j] -eq $forkedRepoName) {
                $existingFork = $existingForks | Where-Object { $_.name -eq $forkedRepoName }
                if ($existingFork.dependabot) {
                    $found = $true
                }
                break
            }
            # check first letter, since we sorted we do not need to go any further
            if ($existingForksNames[$j][0] -gt $forkedRepoName[0]) {
                break
            }
        }
        if (!$found) {
           return $_
        }
    }

    return $actionsToProcess
}

function FilterActionsToProcessDependabot-Improved {
    Param (
        $actionsToProcess,
        $existingForks
    )

    # flatten the list for faster processing
    $actionsToProcess = FlattenActionsList -actions $actionsToProcess | Sort-Object -Property forkedRepoName
    # for faster searching, convert to single string array instead of objects
    $existingForksNames = @($existingForks | ForEach-Object { $_.name } | Sort-Object)
    # filter the actions list down to the set we still need to fork (not known in the existingForks list)
    $j = 0
    $existingFork = $null
    $forkedRepoName = ""
    $found = $false
    $lastIndex = 0
    $actionsToProcess = $actionsToProcess | ForEach-Object {
        $forkedRepoName = $_.forkedRepoName
        $found = $false
        # for loop since the existingForksNames is a sorted array
        for ($j = $lastIndex = 0; $j -lt $existingForksNames.Count; $j++) {
            if ($existingForksNames[$j] -eq $forkedRepoName) {
                $existingFork = $existingForks | Where-Object { $_.name -eq $forkedRepoName }
                if ($existingFork.dependabot) {
                    $found = $true
                    $lastIndex = $j
                }
                break
            }
            # check first letter, since we sorted we do not need to go any further
            if ($existingForksNames[$j][0] -gt $forkedRepoName[0]) {
                $lastIndex = $j
                break
            }
        }
        if (!$found) {
           return $_
        }
    }

    return $actionsToProcess
}

function FlattenActionsList {
    Param (
        $actions
    )
    $owner = ""
    $repo = ""
    $action = @{
        owner = ""
        repo = ""
        forkedRepoName = ""
    }

    # get a full list with the info we actually need
    $flattenedList = $actions | ForEach-Object {
        if ($_.RepoUrl){
            ($owner, $repo) = SplitUrl -url $_.RepoUrl
            $action = @{
                owner = $owner
                repo = $repo
                forkedRepoName = GetForkedRepoName -owner $owner -repo $repo
            }
            return $action
        }
    }

    return $flattenedList
}

function GetDependabotStatus {
    Param (
        $owner,
        $repo,
        $access_token = $env:GITHUB_TOKEN
    )

    $url = "repos/$owner/$repo/vulnerability-alerts"
    $status = ApiCall -method GET -url $url -body $null -expected 204 -access_token $access_token
    return $status
}

function EnableDependabot {
    Param (
      $existingFork,
      $access_token_destination
    )
    if ($existingFork.name -eq "" -or $null -eq $existingFork.name) {
        Write-Debug "No repo name found, skipping [$($existingFork.name)]:"
        Write-Debug ($existingFork | ConvertTo-Json)
        return $false
    }

    # enable dependabot if not enabled yet
    if ($null -eq $existingFork.dependabotEnabled) {
        Write-Debug "Enabling Dependabot for [$($existingFork.name)]"
        $url = "repos/$forkOrg/$($existingFork.name)/vulnerability-alerts"
        $status = ApiCall -method PUT -url $url -body $null -expected 204 -access_token $access_token_destination
        if ($status -eq $true) {
            return $true
        }
        else {
            Write-Host "Failed to enable dependabot for [$($existingFork.name)]"
        }
        return $status
    }

    return $false
}

function GetDependabotAlerts {
    Param (
        $existingForks,
        [int] $numberOfReposToDo
    )

    Write-Message -message "Loading vulnerability alerts for repos" -logToSummary $true

    $i = $existingForks.Length
    $max = $existingForks.Length + $numberOfReposToDo

    $highAlerts = 0
    $criticalAlerts = 0
    $vulnerableRepos = 0
    $skipping = 0
    foreach ($repo in $existingForks) {

        if ($i -ge $max) {
            # do not run to long
            Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
            break
        }

        if ($repo.name -eq "" -or $null -eq $repo.name) {
            if ($null -eq $repo) {
                Write-Debug "Skipping repo with no name" $repo | ConvertTo-Json
            }
            else {
                Write-Debug "Skipping null repo"
            }
            continue
        }

        if ($repo.vulnerabilityStatus) {
            $timeDiff = [DateTime]::UtcNow.Subtract($repo.vulnerabilityStatus.lastUpdated)
            if ($timeDiff.Hours -lt 72) {
                Write-Debug "Skipping repo [$($repo.name)] as it was checked less than 72 hours ago"
                $skipping++
                continue
            }
        }

        Write-Host "$i / $max Loading vulnerability alerts for [$($repo.name)]"
        $dependabotStatus = $(GetDependabotVulnerabilityAlerts -owner $forkOrg -repo $repo.name -access_token $access_token_destination)
        if ($dependabotStatus.high -gt 0) {
            Write-Host "Found [$($dependabotStatus.high)] high alerts for repo [$($repo.name)]"
            $highAlerts++
        }
        if ($dependabotStatus.critical -gt 0) {
            Write-Host "Found [$($dependabotStatus.critical)] critical alerts for repo [$($repo.name)]"
            $criticalAlerts++
        }

        if ($dependabotStatus.high -gt 0 -or $dependabotStatus.critical -gt 0) {
            $vulnerableRepos++
        }

       $vulnerabilityStatus = @{
            high = $dependabotStatus.high
            critical = $dependabotStatus.critical
            lastUpdated = [DateTime]::UtcNow
        }
        #if ($repo.vulnerabilityStatus) {
        if (Get-Member -inputobject $repo -name "vulnerabilityStatus" -Membertype Properties) {
            $repo.vulnerabilityStatus = $vulnerabilityStatus
        }
        else {
            $repo | Add-Member -Name vulnerabilityStatus -Value $vulnerabilityStatus -MemberType NoteProperty
        }

        $i++ | Out-Null
    }

    Write-Message -message "Skipped [$($skipping)] repos as they were checked less than 72 hours ago" -logToSummary $true
    Write-Message -message "Found [$($vulnerableRepos)] new repos with a total of [$($highAlerts)] repos with high alerts" -logToSummary $true
    Write-Message -message "Found [$($vulnerableRepos)] new repos with a total of [$($criticalAlerts)] repos with critical alerts" -logToSummary $true

    return $existingForks
}

function GetDependabotVulnerabilityAlerts {
    Param (
        $owner,
        $repo,
        $access_token = $env:GITHUB_TOKEN
    )

    $query = '
    query($name:String!, $owner:String!){
        repository(name: $name, owner: $owner) {
            vulnerabilityAlerts(first: 100) {
                nodes {
                    createdAt
                    dismissedAt
                    fixedAt
                    dependencyScope
                    securityVulnerability {
                        package {
                            name
                        }
                        advisory {
                            description
                            severity
                        }
                    }
                }
            }
        }
    }'

    $variables = "
        {
            ""owner"": ""$owner"",
            ""name"": ""$repo""
        }
        "

    $uri = "https://api.github.com/graphql"
    $requestHeaders = @{
        Authorization = GetBasicAuthenticationHeader -access_token $access_token
    }

    Write-Debug "Loading vulnerability alerts for repo $repo"
    $response = (Invoke-GraphQLQuery -Query $query -Variables $variables -Uri $uri -Headers $requestHeaders -Raw | ConvertFrom-Json)
    #Write-Host ($response | ConvertTo-Json)
    $nodes = $response.data.repository.vulnerabilityAlerts.nodes
    #Write-Host "Found [$($nodes.Count)] vulnerability alerts"
    #Write-Host $nodes | ConvertTo-Json
    $moderate=0
    $high=0
    $critical=0
    # todo: check for dismissed or fixed alerts: if we start regularly updating the repo, there might be old reports that are not relevant anymore for the analysis
    # todo: group by $node.dependencyScope [DEVELOPMENT, RUNTIME]
    foreach ($node in $nodes) {
        #Write-Host "Found $($node.securityVulnerability.advisory.severity)"
        #Write-Host $node.securityVulnerability.advisory.severity
        if ($node.dependencyScope -eq "RUNTIME") {
            switch ($node.securityVulnerability.advisory.severity) {
                "MODERATE" {
                    $moderate++
                }
                "HIGH" {
                    $high++
                }
                "CRITICAL" {
                    $critical++
                }
            }
        }
    }
    #Write-Host "Dependabot status: " $($response | ConvertTo-Json -Depth 10)
    return @{
        moderate = $moderate
        high = $high
        critical = $critical
    }
}

function Test-AccessTokens {
    Param (
        [string] $accessToken,
        [string] $access_token_destination,
        [int] $numberOfReposToDo
    )
    
    # Validate that accessToken is not null or empty
    if ([string]::IsNullOrWhiteSpace($accessToken)) {
        Write-Error "Missing GitHub access token (ACCESS_TOKEN). Please ensure the secret is configured in the repository."
        throw "No access token provided, please provide one!"
    }
    
    # Validate that access_token_destination is not null or empty
    if ([string]::IsNullOrWhiteSpace($access_token_destination)) {
        Write-Error "Missing GitHub access token for destination (Automation_App_Key). Please ensure the secret is configured in the repository."
        throw "No access token for destination provided, please provide one!"
    }
    
    #store the given access token as the environment variable GITHUB_TOKEN so that it will be used in the Workflow run
    $env:GITHUB_TOKEN = $accessToken
    
    Write-Host "Got an access token with a length of [$($accessToken.Length)], running for [$($numberOfReposToDo)] repos"

    if ($access_token_destination -ne $accessToken) {
        Write-Host "Got an access token for the destination with a length of [$($access_token_destination.Length)]"
    }
}

function GetFoundSecretCount {
    Param (
        [Parameter(Mandatory=$true)]
        [string] $access_token_destination
    )
    Write-Message "Getting secret scanning alerts" -logToSummary $true

    $url = "/orgs/$forkOrg/secret-scanning/alerts"

    try {
        $alertsResult = ApiCall -method GET -url $url -access_token $access_token_destination -hideFailedCall $false
        Write-Message "" -logToSummary $true
        Write-Message "## Secret scanning alerts" -logToSummary $true
        $totalAlerts = 0

        # summarize the number of alerts per secret_type_display_name
        $alertTypes = @{}
        Write-Message "|Alert type| Count |" -logToSummary $true
        Write-Message "|---| ---: |" -logToSummary $true
        foreach ($alert in $alertsResult) {
            $totalAlerts += $alert.number
            #$key = "$($alert.secret_type) - $($alert.secret_type_display_name)" # note: currently does not give extra info
            $key = "$($alert.secret_type_display_name)"
            if ($alertTypes.ContainsKey($key)) {
                $alertTypes[$key] += $alert.number
            }
            else {
                $alertTypes.Add($key, $alert.number)
            }
        }
        $alertTypes = $alertTypes.GetEnumerator() | Sort-Object -Descending -Property Value
        foreach ($alertType in $alertTypes) {
            Write-Message "| $($alertType.Key) | $($alertType.Value) |" -logToSummary $true
        }

        Write-Message "" -logToSummary $true
        Write-Message "Found [$($totalAlerts)] alerts for the organization in [$($alertsResult.Length)] repositories" -logToSummary $true
        Write-Message "" -logToSummary $true

        # log all resuls into a json file
        Set-Content -Path $secretScanningAlertsFile -Value (ConvertTo-Json $alertsResult -Depth 10)
    }
    catch {
        Write-Message "Failed to get secret scanning alerts" -logToSummary $true
        Write-Message "Error: $($_.Exception.Message)" -logToSummary $true
    }
}

function Write-Message {
    param(
        [string] $message,
        [bool] $logToSummary = $false
    )
    Write-Host $message
    if ($logToSummary) {
        $message >> $env:GITHUB_STEP_SUMMARY
    }
}

function GetForkedActionRepos {
    Param (
        $actions,
        $access_token
    )
    # if file exists, read it
    $status = $null
    if (Test-Path $statusFile) {
        Write-Host "Using existing status file"
        $status = Get-Content $statusFile | ConvertFrom-Json
        if (Test-Path $failedStatusFile) {
            $failedForks = Get-Content $failedStatusFile | ConvertFrom-Json
            if ($null -eq $failedForks) {
                # init empty list
                $failedForks = New-Object System.Collections.ArrayList
            }
        }
        else {
            $failedForks = New-Object System.Collections.ArrayList
        }

        Write-Host "Found [$($status.Count)] existing repos in status file"
        Write-Host "Found [$($failedForks.Count)] existing records in the failed forks file"
    }
    else {
        # build up status from scratch
        Write-Host "Loading current forks and status from scratch"

        # get all existing repos in target org
        $forkedRepos = GetForkedActionRepoList -access_token $access_token
        Write-Host "Found [$($forkedRepos.Count)] existing repos in target org"
        # convert list of forkedRepos to a new array with only the name of the repo
        $status = New-Object System.Collections.ArrayList
        foreach ($repo in $forkedRepos) {
            $status.Add(@{name = $repo.name; dependabot = $null}) | Out-Null
        }
        Write-Host "Found [$($status.Count)] existing repos in target org"
        # for each repo, get the Dependabot status
        foreach ($repo in $status) {
            $repo.dependabot = $(GetDependabotStatus -owner $forkOrg -repo $repo.name -access_token $access_token)
        }

        $failedForks = New-Object System.Collections.ArrayList
    }

    Write-Host "Updating actions with split RepoUrl from the list of [$($actions.Count)] actions"
    if ($null -ne $actions -And $actions.Count -gt 0) {
        Write-Host "This is the first action on the list: "
        Write-Host "$($actions[0] | ConvertTo-Json)"
    }

    # prep the actions file so that we only have to split the repourl once
    $counter = 0
    foreach ($actionStatus in $actions){
        ($owner, $repo) = SplitUrl -url $actionStatus.RepoUrl

        $actionStatus | Add-Member -Name name -Value (GetForkedRepoName -owner $owner -repo $repo) -MemberType NoteProperty
        $counter++
    }
    Write-Host "Updated [$($counter)] actions with split RepoUrl"

    # convert the static array into a collection so we can add items to it
    $status = {$status}.Invoke()
    Write-Host "And this is the first status on the list:"
    Write-Host "$($status[0] | ConvertTo-Json)"

    Write-Host "Update the status file with newly found actions"
    # find any new action that is not yet in the status file

    # Convert $status to a hashtable for faster lookup
    $statusTable = @{}
    foreach ($item in $status) {
        if ($null -ne $item.name -And $item.name -ne "") {
            $statusTable[$item.name] = $item
        }
    }

    foreach ($action in $actions) {
        # check if action is already in $statusTable
        $found = $statusTable[$action.name]

        if (!$found) {
            Write-Host "Adding new action to the list: [$($action.owner)/$($action.name)]"
            # add to status
            $statusTable.Add($action.name, @{
                name = $action.name;
                owner = $action.owner;
                dependabot = $null;
                verified = $action.Verified;
            }) | Out-Null
        }
        else {
            # get the item from the status lists as it is already in it
            if (Get-Member -inputobject $found -name "Verified" -Membertype Properties) {
                #Write-Host "Verified already on object"
            }
            else {
                #Write-Host "Verified not on object"
                $found | Add-Member -Name verified -Value $action.Verified -MemberType NoteProperty
            }
        }
    }

    # convert the hashtable back to an array
    $status = $statusTable.Values
    $statusVerified = $status | Where-Object {$_.verified}
    Write-Host "Found [$($statusVerified.Count)] verified repos in status file of total $($status.Count) repos"
    return ($status, $failedForks)
}


<#
    .DESCRIPTION
    Get-TokenFromApp uses the paramsas credentials
    for the GitHub App to load an aceess token with. Be aware that this token is only valid for an hour.
    Note: this token has only access to the repositories that the App has been installed to.
    We cannot use this token to create new repositories or install the app in a repo.
#>
function Get-TokenFromApp {
    param (
        [string] $appId,
        [string] $installationId,
        [string] $pemKey
    )
    # get a temporary jwt token from the key file and app id (hardcoded in the file:)
    $generated_jwt = $(bash ./github-app-jwt.sh $appId $pemKey)
    $github_api_url = "https://api.github.com/app"

    #Write-Host "Loaded jwt token: [$($generated_jwt)]"
    $github_api_url="https://api.github.com/app/installations"
    Write-Debug "Calling [${github_api_url}]"
    $installationId = ""
    try {
        $response = Invoke-RestMethod -Uri $github_api_url -Headers @{Authorization = "Bearer $generated_jwt" } -ContentType "application/json" -Method Get

        Write-Debug "Found installationId: [$($response[0].id)]"
        $installationId = $response[0].id
    }
    catch
    {
        Write-Error "Error in finding the app installations: $($_)"
    }

    $github_api_url="https://api.github.com/app/installations/$installationId/access_tokens"
    Write-Host "Calling [${github_api_url}]"
    $token = ""
    try {
        $response = Invoke-RestMethod -Uri $github_api_url -Headers @{Authorization = "Bearer $generated_jwt" } -ContentType "application/json" -Method POST -Body "{}"
        $token = $response.token
        Write-Host "Got an access token that will expire at: [$($response.expires_at)]"
    }
    catch
    {
        Write-Error "Error in getting an access token: $($_)"
    }

    Write-Host "Found token with [$($token.length)]"
    return $token
}

function Get-RepositoryDefaultBranchCommit {
    Param (
        [string] $owner,
        [string] $repo,
        $access_token = $env:GITHUB_TOKEN
    )
    
    # Get the latest commit SHA from the default branch of a repository using the GitHub API
    # Returns a hashtable with success status, commit SHA, and branch name
    # This is more efficient than cloning the repo just to check if it's up to date
    
    if ([string]::IsNullOrWhiteSpace($owner) -or [string]::IsNullOrWhiteSpace($repo)) {
        return @{
            success = $false
            sha = $null
            branch = $null
            error = "Invalid owner or repo"
        }
    }
    
    try {
        # First get the repository info to find the default branch
        $repoUrl = "repos/$owner/$repo"
        $repoInfo = ApiCall -method GET -url $repoUrl -access_token $access_token -hideFailedCall $true
        
        if ($null -eq $repoInfo -or $repoInfo -eq $false) {
            return @{
                success = $false
                sha = $null
                branch = $null
                error = "Repository not found"
            }
        }
        
        $defaultBranch = $repoInfo.default_branch
        if ([string]::IsNullOrWhiteSpace($defaultBranch)) {
            # Repository metadata may not have default_branch set; default to main
            $defaultBranch = "main"
        }
        
        # Get the latest commit from the default branch
        $branchUrl = "repos/$owner/$repo/branches/$defaultBranch"
        $branchInfo = ApiCall -method GET -url $branchUrl -access_token $access_token -hideFailedCall $true
        
        if ($null -eq $branchInfo -or $branchInfo -eq $false) {
            # If the default branch is 'main' and wasn't found, try 'master' as some repos use it
            # This fallback only applies to 'main' since it's our default assumption
            if ($defaultBranch -eq "main") {
                $defaultBranch = "master"
                $branchUrl = "repos/$owner/$repo/branches/$defaultBranch"
                $branchInfo = ApiCall -method GET -url $branchUrl -access_token $access_token -hideFailedCall $true
            }
        }
        
        if ($null -eq $branchInfo -or $branchInfo -eq $false) {
            return @{
                success = $false
                sha = $null
                branch = $defaultBranch
                error = "Branch not found"
            }
        }
        
        return @{
            success = $true
            sha = $branchInfo.commit.sha
            branch = $defaultBranch
            error = $null
        }
    }
    catch {
        return @{
            success = $false
            sha = $null
            branch = $null
            error = $_.Exception.Message
        }
    }
}

function Compare-RepositoryCommitHashes {
    Param (
        [string] $sourceOwner,
        [string] $sourceRepo,
        [string] $mirrorOwner,
        [string] $mirrorRepo,
        $access_token = $env:GITHUB_TOKEN
    )
    
    # Compare the latest commit hashes of source and mirror repositories
    # Returns a hashtable indicating if they are in sync and the commit details
    # This allows early exit before expensive git clone/fetch operations
    
    Write-Debug "Comparing commits: source [$sourceOwner/$sourceRepo] vs mirror [$mirrorOwner/$mirrorRepo]"
    
    # Get source repository commit
    $sourceCommit = Get-RepositoryDefaultBranchCommit -owner $sourceOwner -repo $sourceRepo -access_token $access_token
    if (-not $sourceCommit.success) {
        return @{
            in_sync = $false
            can_compare = $false
            source_sha = $null
            mirror_sha = $null
            error = "Could not get source commit: $($sourceCommit.error)"
        }
    }
    
    # Get mirror repository commit  
    $mirrorCommit = Get-RepositoryDefaultBranchCommit -owner $mirrorOwner -repo $mirrorRepo -access_token $access_token
    if (-not $mirrorCommit.success) {
        return @{
            in_sync = $false
            can_compare = $false
            source_sha = $sourceCommit.sha
            mirror_sha = $null
            error = "Could not get mirror commit: $($mirrorCommit.error)"
        }
    }
    
    # Compare the commit SHAs
    $inSync = $sourceCommit.sha -eq $mirrorCommit.sha
    
    return @{
        in_sync = $inSync
        can_compare = $true
        source_sha = $sourceCommit.sha
        mirror_sha = $mirrorCommit.sha
        source_branch = $sourceCommit.branch
        mirror_branch = $mirrorCommit.branch
        error = $null
    }
}

function Test-RepositoryExists {
    Param (
        [string] $owner,
        [string] $repo,
        $access_token = $env:GITHUB_TOKEN
    )
    
    # Check if a repository exists using the GitHub API
    # Returns $true if the repo exists and is accessible, $false otherwise
    
    if ([string]::IsNullOrWhiteSpace($owner) -or [string]::IsNullOrWhiteSpace($repo)) {
        return $false
    }
    
    $url = "repos/$owner/$repo"
    try {
        $result = ApiCall -method GET -url $url -access_token $access_token -hideFailedCall $true
        if ($null -ne $result -and $result -ne $false) {
            return $true
        }
        return $false
    }
    catch {
        # Repository doesn't exist or isn't accessible
        return $false
    }
}

function Invoke-GitCommandWithRetry {
    Param (
        [string] $GitCommand,
        [string[]] $GitArguments,
        [string] $Description = "Git command",
        [int] $MaxRetries = 3,
        [int] $InitialDelaySeconds = 5
    )
    
    # Execute a git command with exponential backoff retry logic
    # Uses safe execution method instead of Invoke-Expression
    # Returns the command output and exit code
    
    $attempt = 0
    $delay = $InitialDelaySeconds
    $lastError = $null
    $lastOutput = $null
    
    while ($attempt -lt $MaxRetries) {
        $attempt++
        
        try {
            # Execute git command safely using the call operator
            if ($GitArguments) {
                $output = & git $GitCommand @GitArguments 2>&1
            } else {
                $output = & git $GitCommand 2>&1
            }
            $exitCode = $LASTEXITCODE
            
            if ($exitCode -eq 0) {
                return @{
                    Success = $true
                    Output = $output
                    ExitCode = $exitCode
                }
            }
            
            # Check if this is a transient error that should be retried
            $outputString = $output | Out-String
            $isTransientError = $outputString -like "*could not read Username*" -or 
                               $outputString -like "*Connection refused*" -or
                               $outputString -like "*Connection timed out*" -or
                               $outputString -like "*SSL*" -or
                               $outputString -like "*Network is unreachable*"
            
            if (-not $isTransientError) {
                # Non-transient error, don't retry
                return @{
                    Success = $false
                    Output = $output
                    ExitCode = $exitCode
                }
            }
            
            $lastError = $outputString
            $lastOutput = $output
            
            if ($attempt -lt $MaxRetries) {
                Write-Debug "$Description failed (attempt $attempt/$MaxRetries), retrying in $delay seconds..."
                Start-Sleep -Seconds $delay
                $delay = $delay * 2  # Exponential backoff
            }
        }
        catch {
            $lastError = $_.Exception.Message
            if ($attempt -lt $MaxRetries) {
                Write-Debug "$Description failed (attempt $attempt/$MaxRetries): $lastError, retrying in $delay seconds..."
                Start-Sleep -Seconds $delay
                $delay = $delay * 2
            }
        }
    }
    
    # All retries exhausted
    return @{
        Success = $false
        Output = $lastOutput
        ExitCode = $LASTEXITCODE
        Error = $lastError
    }
}

function SyncMirrorWithUpstream {
    Param (
        $owner,
        $repo,
        $upstreamOwner,
        $upstreamRepo,
        $access_token = $env:GITHUB_TOKEN
    )
    
    # Sync a mirror repository by pulling from upstream and pushing to mirror
    # This is different from fork sync - these are mirrors created by cloning upstream repos
    # Mirror repos are named: actions-marketplace-validations/upstreamOwner_upstreamRepo
    # Upstream repos are at: github.com/upstreamOwner/upstreamRepo
    
    Write-Debug "Syncing mirror [$owner/$repo] with upstream [$upstreamOwner/$upstreamRepo]"
    
    # Validate parameters
    if ([string]::IsNullOrWhiteSpace($upstreamOwner) -or [string]::IsNullOrWhiteSpace($upstreamRepo)) {
        return @{
            success = $false
            message = "Invalid upstream owner or repo name"
            error_type = "validation_error"
        }
    }
    
    # Check if upstream repository exists before attempting sync
    $upstreamExists = Test-RepositoryExists -owner $upstreamOwner -repo $upstreamRepo -access_token $access_token
    if (-not $upstreamExists) {
        Write-Debug "Upstream repository [$upstreamOwner/$upstreamRepo] does not exist or is not accessible"
        return @{
            success = $false
            message = "Upstream repository not found"
            error_type = "upstream_not_found"
        }
    }
    
    # Check if mirror repository exists
    $mirrorExists = Test-RepositoryExists -owner $owner -repo $repo -access_token $access_token
    if (-not $mirrorExists) {
        Write-Debug "Mirror repository [$owner/$repo] does not exist"
        return @{
            success = $false
            message = "Mirror repository not found"
            error_type = "mirror_not_found"
        }
    }
    
    # Early sync detection: Compare commit hashes before cloning
    # This avoids expensive git clone/fetch operations when repos are already in sync
    $comparison = Compare-RepositoryCommitHashes -sourceOwner $upstreamOwner -sourceRepo $upstreamRepo -mirrorOwner $owner -mirrorRepo $repo -access_token $access_token
    
    if ($comparison.can_compare -and $comparison.in_sync) {
        Write-Debug "Mirror [$owner/$repo] is already in sync with upstream (SHA: $($comparison.source_sha))"
        return @{
            success = $true
            message = "Already up to date"
            merge_type = "none"
            source_sha = $comparison.source_sha
            mirror_sha = $comparison.mirror_sha
        }
    }
    
    # If comparison failed, continue with normal sync process (clone/fetch/merge)
    # This handles cases where API comparison might fail but git operations could succeed
    if (-not $comparison.can_compare) {
        Write-Debug "Could not compare commits via API, proceeding with git-based sync: $($comparison.error)"
    }
    
    # Create temp directory if it doesn't exist
    $syncTempDir = "$tempDir/sync-$(Get-Random)"
    if (-not (Test-Path $syncTempDir)) {
        New-Item -ItemType Directory -Path $syncTempDir | Out-Null
    }
    
    # Save current directory for cleanup
    $originalDir = Get-Location
    
    try {
        Set-Location $syncTempDir | Out-Null
        
        # Set environment variable to skip LFS smudging (downloading actual files)
        # This prevents failures when LFS objects are missing on the server (404 errors)
        # Git will keep LFS pointer files instead of trying to download missing objects
        $env:GIT_LFS_SKIP_SMUDGE = "1"
        
        # Clone the mirror repo with retry logic
        # Token is embedded in URL for authentication (standard git approach)
        Write-Debug "Cloning mirror repo [https://github.com/$owner/$repo.git] with LFS skip smudge enabled"
        $cloneUrl = "https://x:$access_token@github.com/$owner/$repo.git"
        $cloneResult = Invoke-GitCommandWithRetry -GitCommand "clone" -GitArguments @($cloneUrl) -Description "Clone mirror repo"
        
        if (-not $cloneResult.Success) {
            $errorOutput = $cloneResult.Output | Out-String
            if ($errorOutput -like "*Repository not found*" -or $errorOutput -like "*not found*") {
                throw "Mirror repository not found"
            }
            elseif ($errorOutput -like "*could not read Username*") {
                throw "Authentication failed - could not read credentials"
            }
            throw "Failed to clone mirror repo: $errorOutput"
        }
        
        Set-Location $repo | Out-Null
        
        # Configure git user identity locally for this repo only
        git config user.email "actions-marketplace-checks@example.com" 2>&1 | Out-Null
        git config user.name "actions-marketplace-checks" 2>&1 | Out-Null
        
        # Get the current branch name using explicit refs to avoid ambiguity
        $currentBranch = $null
        $branchOutput = git symbolic-ref --short HEAD 2>&1
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrEmpty($branchOutput)) {
            $currentBranch = $branchOutput.Trim()
        }
        
        if ([string]::IsNullOrEmpty($currentBranch)) {
            # Try to get default branch from remote
            $remoteHeadOutput = git symbolic-ref refs/remotes/origin/HEAD 2>&1
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrEmpty($remoteHeadOutput)) {
                $currentBranch = $remoteHeadOutput -replace 'refs/remotes/origin/', ''
            }
            
            if ([string]::IsNullOrEmpty($currentBranch)) {
                # Default to main
                $currentBranch = "main"
            }
        }
        Write-Debug "Current branch: [$currentBranch]"
        
        # Add upstream remote with authentication to avoid rate limiting
        Write-Debug "Adding upstream remote with authentication"
        $upstreamCloneUrl = "https://x:$access_token@github.com/$upstreamOwner/$upstreamRepo.git"
        git remote add upstream $upstreamCloneUrl 2>&1 | Out-Null
        
        # Fetch from upstream with retry logic
        Write-Debug "Fetching from upstream"
        $fetchResult = Invoke-GitCommandWithRetry -GitCommand "fetch" -GitArguments @("upstream") -Description "Fetch from upstream"
        
        if (-not $fetchResult.Success) {
            $errorOutput = $fetchResult.Output | Out-String
            if ($errorOutput -like "*Repository not found*" -or $errorOutput -like "*not found*") {
                throw "Upstream repository not found during fetch"
            }
            throw "Failed to fetch from upstream: $errorOutput"
        }
        
        # Check if upstream has the target branch using explicit refs
        $upstreamBranchRef = "refs/remotes/upstream/$currentBranch"
        $branchCheckOutput = git show-ref --verify $upstreamBranchRef 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            # Try master branch if main doesn't exist
            if ($currentBranch -eq "main") {
                $currentBranch = "master"
                $upstreamBranchRef = "refs/remotes/upstream/$currentBranch"
                $branchCheckOutput = git show-ref --verify $upstreamBranchRef 2>&1
            }
        }
        
        if ($LASTEXITCODE -ne 0) {
            throw "Upstream branch [$currentBranch] not found"
        }
        
        # Get the current commit hash using explicit HEAD ref
        $beforeHash = git rev-parse HEAD 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to get current HEAD: unknown revision or path not in the working tree"
        }
        
        # Try to merge upstream changes using explicit branch reference
        Write-Debug "Merging upstream/$currentBranch"
        $mergeRef = "refs/remotes/upstream/$currentBranch"
        $mergeResult = git merge $mergeRef --no-edit 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            $mergeOutput = $mergeResult | Out-String
            # Check if it's a conflict
            if ($mergeOutput -like "*conflict*" -or $mergeOutput -like "*CONFLICT*") {
                # Abort the merge
                git merge --abort 2>&1 | Out-Null
                throw "Merge conflict detected"
            }
            elseif ($mergeOutput -like "*refspec*matches more than one*") {
                throw "Ambiguous git reference: $mergeOutput"
            }
            else {
                throw "Failed to merge: $mergeOutput"
            }
        }
        
        # Get the commit hash after merge
        $afterHash = git rev-parse HEAD 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to get HEAD after merge"
        }
        
        # Check if there were any changes
        if ($beforeHash -eq $afterHash) {
            Write-Debug "Mirror [$owner/$repo] is already up to date"
            # Clean up
            Set-Location $originalDir | Out-Null
            Remove-Item -Path $syncTempDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
            # Clear LFS skip smudge environment variable
            Remove-Item Env:\GIT_LFS_SKIP_SMUDGE -ErrorAction SilentlyContinue
            return @{
                success = $true
                message = "Already up to date"
                merge_type = "none"
            }
        }
        
        # Disable GitHub Actions before pushing changes to prevent workflows from running
        Write-Debug "Disabling GitHub Actions for [$owner/$repo] before push"
        $disableResult = Disable-GitHubActions -owner $owner -repo $repo -access_token $access_token
        if (-not $disableResult) {
            Write-Warning "Could not disable GitHub Actions for [$owner/$repo], continuing with push anyway"
        }
        
        # Push changes back to mirror using explicit branch reference with retry
        Write-Debug "Pushing changes to mirror"
        $pushRef = "HEAD:refs/heads/$currentBranch"
        $pushResult = Invoke-GitCommandWithRetry -GitCommand "push" -GitArguments @("origin", $pushRef) -Description "Push to mirror"
        
        if (-not $pushResult.Success) {
            $errorOutput = $pushResult.Output | Out-String
            if ($errorOutput -like "*refspec*matches more than one*") {
                throw "Ambiguous push reference: src refspec matches more than one"
            }
            throw "Failed to push to mirror: $errorOutput"
        }
        
        Write-Debug "Successfully synced mirror [$owner/$repo]"
        
        # Clean up
        Set-Location $originalDir | Out-Null
        Remove-Item -Path $syncTempDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        
        # Clear LFS skip smudge environment variable
        Remove-Item Env:\GIT_LFS_SKIP_SMUDGE -ErrorAction SilentlyContinue
        
        return @{
            success = $true
            message = "Successfully fetched and merged from upstream"
            merge_type = "merge"
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Warning "Error syncing mirror [$owner/$repo]: $errorMessage"
        
        # Clean up
        try {
            Set-Location $originalDir | Out-Null
            Remove-Item -Path $syncTempDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
            # Clear LFS skip smudge environment variable
            Remove-Item Env:\GIT_LFS_SKIP_SMUDGE -ErrorAction SilentlyContinue
        }
        catch {
            # Ignore cleanup errors
        }
        
        # Categorize errors for better reporting
        $errorType = "unknown"
        $cleanMessage = $errorMessage
        
        if ($errorMessage -like "*Merge conflict*") {
            $errorType = "merge_conflict"
            $cleanMessage = "Merge conflict detected"
        }
        elseif ($errorMessage -like "*Upstream repository not found*" -or $errorMessage -like "*not found during fetch*") {
            $errorType = "upstream_not_found"
            $cleanMessage = "Upstream repository not found"
        }
        elseif ($errorMessage -like "*Mirror repository not found*") {
            $errorType = "mirror_not_found"
            $cleanMessage = "Mirror repository not found"
        }
        elseif ($errorMessage -like "*branch*not found*") {
            $errorType = "branch_not_found"
            $cleanMessage = "Branch not found"
        }
        elseif ($errorMessage -like "*could not read Username*" -or $errorMessage -like "*Authentication failed*") {
            $errorType = "auth_error"
            $cleanMessage = "Authentication error"
        }
        elseif ($errorMessage -like "*unknown revision*" -or $errorMessage -like "*ambiguous*") {
            $errorType = "git_reference_error"
            $cleanMessage = "Git reference error"
        }
        elseif ($errorMessage -like "*refspec*matches more than one*") {
            $errorType = "ambiguous_refspec"
            $cleanMessage = "Ambiguous git reference"
        }
        
        return @{
            success = $false
            message = $cleanMessage
            error_type = $errorType
            full_error = $errorMessage
        }
    }
}

function Disable-GitHubActions {
    Param (
        [string] $owner,
        [string] $repo,
        [string] $access_token = $env:GITHUB_TOKEN
    )
    
    # Disable GitHub Actions for a repository to prevent workflows from running on push
    # Uses the GitHub API: PUT /repos/{owner}/{repo}/actions/permissions
    # See: https://docs.github.com/en/rest/actions/permissions#set-github-actions-permissions-for-a-repository
    
    if ([string]::IsNullOrWhiteSpace($owner) -or [string]::IsNullOrWhiteSpace($repo)) {
        Write-Warning "Cannot disable GitHub Actions: owner and/or repo is empty or null"
        return $false
    }
    
    $url = "repos/$owner/$repo/actions/permissions"
    $body = @{
        enabled = $false
    } | ConvertTo-Json
    
    Write-Debug "Disabling GitHub Actions for [$owner/$repo]"
    
    try {
        $result = ApiCall -method PUT -url $url -body $body -expected 204 -access_token $access_token
        if ($result -eq $true) {
            Write-Debug "GitHub Actions disabled for [$owner/$repo]"
            return $true
        }
        else {
            Write-Warning "Failed to disable GitHub Actions for [$owner/$repo]"
            return $false
        }
    }
    catch {
        Write-Warning "Error disabling GitHub Actions for [$owner/$repo]: $($_.Exception.Message)"
        return $false
    }
}

<#
    .SYNOPSIS
    Splits a list of forks into equal chunks for parallel processing.
    
    .DESCRIPTION
    Takes a list of forks and splits them into a specified number of chunks.
    Only includes forks that have forkFound = true.
    Returns a hashtable mapping chunk index to the list of fork names.
    
    .PARAMETER existingForks
    The full list of forks from status.json
    
    .PARAMETER numberOfChunks
    The number of chunks to split the work into (corresponds to matrix job count)
    
    .EXAMPLE
    $chunks = Split-ForksIntoChunks -existingForks $forks -numberOfChunks 4
#>
function Split-ForksIntoChunks {
    Param (
        $existingForks,
        [int] $numberOfChunks = 4
    )
    
    Write-Message -message "Splitting forks into [$numberOfChunks] chunks for parallel processing" -logToSummary $true
    
    # Filter to only forks that should be processed (forkFound = true)
    $forksToProcess = $existingForks | Where-Object { $_.forkFound -eq $true }
    
    if ($forksToProcess.Count -eq 0) {
        Write-Message -message "No forks to process (all have forkFound = false)" -logToSummary $true
        return @{}
    }
    
    Write-Message -message "Found [$($forksToProcess.Count)] forks to process out of [$($existingForks.Count)] total" -logToSummary $true
    
    # Calculate chunk size (round up to ensure all items are included)
    $chunkSize = [Math]::Ceiling($forksToProcess.Count / $numberOfChunks)
    Write-Message -message "Each chunk will process up to [$chunkSize] forks" -logToSummary $true
    
    # Split into chunks
    $chunks = @{}
    for ($i = 0; $i -lt $numberOfChunks; $i++) {
        $startIndex = $i * $chunkSize
        $endIndex = [Math]::Min(($startIndex + $chunkSize - 1), ($forksToProcess.Count - 1))
        
        if ($startIndex -lt $forksToProcess.Count) {
            # Get the subset of forks for this chunk
            $chunkForks = @()
            for ($j = $startIndex; $j -le $endIndex; $j++) {
                $chunkForks += $forksToProcess[$j].name
            }
            
            $chunks[$i] = $chunkForks
            Write-Message -message "Chunk [$i]: [$($chunkForks.Count)] forks (indices $startIndex-$endIndex)" -logToSummary $true
        }
    }
    
    return $chunks
}

<#
    .SYNOPSIS
    Saves a partial status update for a specific chunk of forks.
    
    .DESCRIPTION
    Saves only the forks that were processed by this job to a partial status file.
    This file will be uploaded as an artifact and merged later.
    
    .PARAMETER processedForks
    The forks that were processed by this job (with updated fields like lastSynced)
    
    .PARAMETER chunkId
    The identifier for this chunk (used in filename)
    
    .PARAMETER outputPath
    The path where the partial status file should be saved
    
    .EXAMPLE
    Save-PartialStatusUpdate -processedForks $forks -chunkId 0 -outputPath "./status-partial-0.json"
#>
function Save-PartialStatusUpdate {
    Param (
        $processedForks,
        [int] $chunkId,
        [string] $outputPath = "status-partial-$chunkId.json"
    )
    
    Write-Message -message "Saving partial status update for chunk [$chunkId] to [$outputPath]" -logToSummary $true
    
    if ($null -eq $processedForks -or $processedForks.Count -eq 0) {
        Write-Message -message "No forks to save for chunk [$chunkId]" -logToSummary $true
        # Save empty array to indicate this chunk completed but had no changes
        "[]" | Out-File -FilePath $outputPath -Encoding UTF8
        return $true
    }
    
    Write-Message -message "Saving [$($processedForks.Count)] processed forks for chunk [$chunkId]" -logToSummary $true
    
    # Convert to JSON and save
    $json = ConvertTo-Json -InputObject $processedForks -Depth 10
    [System.IO.File]::WriteAllText($outputPath, $json, [System.Text.Encoding]::UTF8)
    
    Write-Message -message "✓ Saved partial status for chunk [$chunkId]" -logToSummary $true
    return $true
}

<#
    .SYNOPSIS
    Merges partial status updates from multiple chunks into the main status file.
    
    .DESCRIPTION
    Takes the current full status.json and applies updates from all partial status files.
    Updates are merged by name - if a fork exists in a partial update, its data is merged into the main status.
    
    .PARAMETER currentStatus
    The current full status array from status.json
    
    .PARAMETER partialStatusFiles
    Array of file paths to partial status files from each chunk
    
    .EXAMPLE
    $mergedStatus = Merge-PartialStatusUpdates -currentStatus $status -partialStatusFiles @("status-partial-0.json", "status-partial-1.json")
#>
function Merge-PartialStatusUpdates {
    Param (
        $currentStatus,
        [string[]] $partialStatusFiles
    )
    
    Write-Message -message "Merging partial status updates from [$($partialStatusFiles.Count)] chunks" -logToSummary $true
    
    # Create a hashtable for fast lookup by name
    $statusByName = @{}
    foreach ($item in $currentStatus) {
        $statusByName[$item.name] = $item
    }
    
    $totalUpdates = 0
    $totalChunks = $partialStatusFiles.Count
    
    foreach ($partialFile in $partialStatusFiles) {
        if (-not (Test-Path $partialFile)) {
            Write-Warning "Partial status file not found: [$partialFile]"
            continue
        }
        
        Write-Host "Processing partial status file: [$partialFile]"
        
        try {
            $jsonContent = Get-Content $partialFile -Raw
            $jsonContent = $jsonContent -replace '^\uFEFF', ''  # Remove UTF-8 BOM
            $partialStatus = $jsonContent | ConvertFrom-Json
            
            if ($null -eq $partialStatus -or $partialStatus.Count -eq 0) {
                Write-Host "  No updates in this chunk"
                continue
            }
            
            Write-Host "  Found [$($partialStatus.Count)] updates in this chunk"
            
            # Merge each updated fork
            foreach ($updatedFork in $partialStatus) {
                if ($statusByName.ContainsKey($updatedFork.name)) {
                    # Update existing entry
                    # Copy all properties from updated fork to the existing one
                    $existing = $statusByName[$updatedFork.name]
                    
                    # Get all properties from the updated fork
                    $updatedFork.PSObject.Properties | ForEach-Object {
                        $propName = $_.Name
                        $propValue = $_.Value
                        
                        # Update or add the property
                        if (Get-Member -InputObject $existing -Name $propName -MemberType Properties) {
                            $existing.$propName = $propValue
                        } else {
                            $existing | Add-Member -Name $propName -Value $propValue -MemberType NoteProperty -Force
                        }
                    }
                    
                    $totalUpdates++
                } else {
                    Write-Warning "Fork [$($updatedFork.name)] from partial status not found in current status"
                }
            }
        }
        catch {
            Write-Error "Failed to process partial status file [$partialFile]: $($_.Exception.Message)"
            continue
        }
    }
    
    Write-Message -message "✓ Merged [$totalUpdates] fork updates from [$totalChunks] chunks into main status" -logToSummary $true
    
    # Convert hashtable back to array
    return $statusByName.Values
}

<#
    .SYNOPSIS
    Shows overall dataset statistics for the repository mirrors.
    
    .DESCRIPTION
    Calculates and displays statistics about the mirror dataset including:
    - Total repositories in dataset
    - Repositories with valid mirrors (forkFound = true)
    - Repositories synced in the last 7 days
    - Percentage coverage
    
    .PARAMETER existingForks
    The array of fork objects from status.json
    
    .EXAMPLE
    ShowOverallDatasetStatistics -existingForks $forks
#>
function ShowOverallDatasetStatistics {
    Param (
        $existingForks
    )
    
    Write-Message -message "" -logToSummary $true
    Write-Message -message "### Overall Dataset Statistics" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Calculate 7-day window
    $sevenDaysAgo = (Get-Date).AddDays(-7)
    
    # Total repos in dataset
    $totalRepos = $existingForks.Count
    
    # Count repos with forkFound = true (valid mirrors)
    $reposWithMirrors = ($existingForks | Where-Object { $_.forkFound -eq $true }).Count
    
    # Count repos synced in the last 7 days
    $reposSyncedLast7Days = ($existingForks | Where-Object { 
        if ($_.lastSynced) {
            try {
                $syncDate = [DateTime]::Parse($_.lastSynced)
                return $syncDate -gt $sevenDaysAgo
            } catch {
                Write-Debug "Failed to parse lastSynced date for repo: $($_.name)"
                return $false
            }
        }
        return $false
    }).Count
    
    # Calculate percentages
    if ($reposWithMirrors -gt 0) {
        $percentChecked = [math]::Round(($reposSyncedLast7Days / $reposWithMirrors) * 100, 2)
        $percentRemaining = [math]::Round((($reposWithMirrors - $reposSyncedLast7Days) / $reposWithMirrors) * 100, 2)
    } else {
        $percentChecked = 0
        $percentRemaining = 0
    }
    
    $reposNotChecked = $reposWithMirrors - $reposSyncedLast7Days
    
    Write-Message -message "**Total Repositories in Dataset:** $totalRepos" -logToSummary $true
    Write-Message -message "**Repositories with Valid Mirrors:** $reposWithMirrors" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "#### Last 7 Days Activity" -logToSummary $true
    Write-Message -message "| Metric | Count | Percentage |" -logToSummary $true
    Write-Message -message "|--------|------:|-----------:|" -logToSummary $true
    Write-Message -message "| ✅ Repos Checked (Last 7 Days) | $reposSyncedLast7Days | ${percentChecked}% |" -logToSummary $true
    Write-Message -message "| ⏳ Repos Not Checked Yet | $reposNotChecked | ${percentRemaining}% |" -logToSummary $true
    Write-Message -message "" -logToSummary $true
}
