
# Global flag to track if rate limit was exceeded (20+ minute wait)
$global:RateLimitExceeded = $false

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

. "$PSScriptRoot/get-github-app-token.ps1"
. "$PSScriptRoot/github-app-token-manager.ps1"

$script:GitHubAppTokenManagerInstance = $null
$script:HasLoggedRateLimitAppSwitch = $false

function Get-GitHubAppTokenManagerInstance {
    if ($null -ne $script:GitHubAppTokenManagerInstance) {
        return $script:GitHubAppTokenManagerInstance
    }

    try {
        $script:GitHubAppTokenManagerInstance = New-GitHubAppTokenManagerFromEnvironment
    }
    catch {
        $script:GitHubAppTokenManagerInstance = $null
    }

    return $script:GitHubAppTokenManagerInstance
}

# Blob file names in the 'status' subfolder
$script:actionsBlobFileName = "Actions-Full-Overview.Json"
$script:statusBlobFileName = "status.json"
$script:failedForksBlobFileName = "failedForks.json"
$script:secretScanningAlertsBlobFileName = "secretScanningAlerts.json"

<#
    .SYNOPSIS
    Generates a GitHub Actions workflow URL for the repository.

    .DESCRIPTION
    Creates a standardized URL to a GitHub Actions workflow page.
    Uses GitHub Actions environment variables when available, with fallback to defaults.
    
    Environment Variables Used:
    - GITHUB_SERVER_URL: The base URL of the GitHub server (default: https://github.com)
    - GITHUB_REPOSITORY: The owner/repo name (default: rajbos/actions-marketplace-checks)

    .PARAMETER workflowFileName
    The workflow YAML filename (e.g., "analyze.yml", "repoInfo.yml")

    .EXAMPLE
    Get-WorkflowUrl -workflowFileName "analyze.yml"
    # Returns: https://github.com/rajbos/actions-marketplace-checks/actions/workflows/analyze.yml
    # In GitHub Actions environment with GITHUB_REPOSITORY set

    .EXAMPLE
    $env:GITHUB_REPOSITORY = "myorg/myrepo"
    Get-WorkflowUrl "report.yml"
    # Returns: https://github.com/myorg/myrepo/actions/workflows/report.yml
#>
function Get-WorkflowUrl {
    Param (
        [Parameter(Mandatory=$true)]
        [string]$workflowFileName
    )
    
    # Get server URL from environment or use default
    $serverUrl = if ($env:GITHUB_SERVER_URL) {
        $env:GITHUB_SERVER_URL
    } else {
        "https://github.com"
    }
    
    # Get repository from environment or use default
    $repository = if ($env:GITHUB_REPOSITORY) {
        $env:GITHUB_REPOSITORY
    } else {
        "rajbos/actions-marketplace-checks"
    }
    
    return "$serverUrl/$repository/actions/workflows/$workflowFileName"
}

<#
    .SYNOPSIS
    Converts a date value to a DateTime object, handling multiple input formats.

    .DESCRIPTION
    This function normalizes date values from various formats into DateTime objects.
    It handles:
    - DateTime objects (returned as-is)
    - ISO 8601 strings (e.g., "2022-11-04T20:15:45Z")
    - Culture-specific date strings (e.g., "11/04/2022 20:15:45")
    - null/empty values (returned as $null)

    .PARAMETER dateValue
    The date value to convert. Can be a DateTime object, string, or $null.

    .EXAMPLE
    ConvertTo-NormalizedDateTime -dateValue "2022-11-04T20:15:45Z"

    .EXAMPLE
    ConvertTo-NormalizedDateTime -dateValue "11/04/2022 20:15:45"
#>
<#
    .SYNOPSIS
    Converts a file size in bytes to a human-readable format.

    .DESCRIPTION
    Takes a file size in bytes and converts it to the most appropriate unit
    (bytes, KB, MB, GB, TB) with 2 decimal places.

    .PARAMETER bytes
    The file size in bytes to convert.

    .EXAMPLE
    Format-FileSize -bytes 1024
    # Returns: "1.00 KB"

    .EXAMPLE
    Format-FileSize -bytes 29000000
    # Returns: "27.66 MB"
#>
function Format-FileSize {
    Param (
        [Parameter(Mandatory=$true)]
        [long]$bytes
    )

    if ($bytes -lt 1KB) {
        return "$bytes bytes"
    }
    elseif ($bytes -lt 1MB) {
        return "{0:N2} KB" -f ($bytes / 1KB)
    }
    elseif ($bytes -lt 1GB) {
        return "{0:N2} MB" -f ($bytes / 1MB)
    }
    elseif ($bytes -lt 1TB) {
        return "{0:N2} GB" -f ($bytes / 1GB)
    }
    else {
        return "{0:N2} TB" -f ($bytes / 1TB)
    }
}

function ConvertTo-NormalizedDateTime {
    Param (
        $dateValue
    )

    # Return null for null or empty values
    if ($null -eq $dateValue -or $dateValue -eq "") {
        return $null
    }

    # If already a DateTime, return as-is
    if ($dateValue -is [DateTime]) {
        return $dateValue
    }

    # If it's a string, try to parse it
    if ($dateValue -is [string]) {
        try {
            # Try parsing with ParseExact for common formats first (faster)
            # Note: MM/dd/yyyy is tried before dd/MM/yyyy to match US format convention
            # which is the format PowerShell's DateTime.ToString() uses by default.
            # This means ambiguous dates like "01/02/2022" will be interpreted as
            # January 2nd (US format) rather than February 1st (European format).
            # This is acceptable because:
            # 1. The data comes from PowerShell's own serialization which uses US format
            # 2. ISO 8601 formats are always tried first (unambiguous)
            # 3. The fallback Parse() uses InvariantCulture which also prefers US format
            $formats = @(
                # ISO 8601 formats (unambiguous, preferred)
                "yyyy-MM-ddTHH:mm:ssZ",
                "yyyy-MM-ddTHH:mm:ss.fffffffK",
                "yyyy-MM-ddTHH:mm:ss.ffffffK",
                "yyyy-MM-ddTHH:mm:ss.fffffK",
                "yyyy-MM-ddTHH:mm:ss.ffffK",
                "yyyy-MM-ddTHH:mm:ss.fffK",
                "yyyy-MM-ddTHH:mm:ss.ffK",
                "yyyy-MM-ddTHH:mm:ss.fK",
                "yyyy-MM-ddTHH:mm:ssK",
                # Culture-specific formats (from PowerShell's DateTime display)
                "MM/dd/yyyy HH:mm:ss",  # US format (e.g., "11/04/2022 20:15:45")
                "M/d/yyyy HH:mm:ss",    # US format without leading zeros
                "dd/MM/yyyy HH:mm:ss",  # European format (rarely used in this codebase)
                "d/M/yyyy HH:mm:ss"     # European format without leading zeros
            )
            
            foreach ($format in $formats) {
                try {
                    $result = [DateTime]::ParseExact($dateValue, $format, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None)
                    return $result
                }
                catch {
                    # Try next format
                }
            }
            
            # If ParseExact fails, fall back to Parse which is more flexible
            return [DateTime]::Parse($dateValue, [System.Globalization.CultureInfo]::InvariantCulture)
        }
        catch {
            Write-Warning "Failed to parse date value: [$dateValue]. Error: $($_.Exception.Message)"
            return $null
        }
    }

    # Unknown type
    Write-Warning "Unexpected date value type: $($dateValue.GetType().FullName)"
    return $null
}

<#
    .SYNOPSIS
    Normalizes date fields in action objects loaded from JSON.

    .DESCRIPTION
    Ensures that date fields in action objects are DateTime objects,
    regardless of how they were serialized in the JSON file.
    This handles the case where dates may be in different string formats.

    .PARAMETER actions
    Array of action objects to normalize.

    .EXAMPLE
    $actions = ConvertFrom-Json (Get-Content status.json)
    $actions = Normalize-ActionDates -actions $actions
#>
function Normalize-ActionDates {
    Param (
        [Parameter(Mandatory=$false)]
        $actions
    )

    if ($null -eq $actions) {
        return $null
    }

    foreach ($action in $actions) {
        if ($null -eq $action) {
            continue
        }

        # Normalize repoInfo dates
        if ($action.repoInfo) {
            if ($null -ne $action.repoInfo.updated_at) {
                $normalized = ConvertTo-NormalizedDateTime -dateValue $action.repoInfo.updated_at
                $action.repoInfo.updated_at = $normalized
            }
            if ($null -ne $action.repoInfo.latest_release_published_at) {
                $normalized = ConvertTo-NormalizedDateTime -dateValue $action.repoInfo.latest_release_published_at
                $action.repoInfo.latest_release_published_at = $normalized
            }
        }

        # Normalize mirrorLastUpdated
        if ($null -ne $action.mirrorLastUpdated) {
            $normalized = ConvertTo-NormalizedDateTime -dateValue $action.mirrorLastUpdated
            $action.mirrorLastUpdated = $normalized
        }

        # Normalize dependents.dependentsLastUpdated
        if ($action.dependents -and ($null -ne $action.dependents.dependentsLastUpdated)) {
            $normalized = ConvertTo-NormalizedDateTime -dateValue $action.dependents.dependentsLastUpdated
            $action.dependents.dependentsLastUpdated = $normalized
        }
    }

    return , $actions
}

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
            $fileSizeFormatted = Format-FileSize -bytes $fileSize
            $message = "✓ Successfully downloaded $script:actionsBlobFileName ($fileSizeFormatted) to [$localFilePath]"
            Write-Message -message $message -logToSummary $true
            return $true
        }
        else {
            $message = "⚠️ ERROR: Failed to download Actions-Full-Overview.Json - file not found after download"
            Write-Message -message $message -logToSummary $true
            Write-Error $message
        }

        # Guard against marketplace landing pages and malformed URLs
        if ($null -eq $url) {
            return $null
        }
        if ($url.StartsWith("https://github.com/marketplace/actions")) {
            return "", ""
        }
        $message = "⚠️ ERROR: Failed to download $script:actionsBlobFileName from blob storage: $($_.Exception.Message)"

        if ($urlParts.Length -lt 2) {
            return "", ""
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
            $fileSizeFormatted = Format-FileSize -bytes $fileSize
            $message = "✓ Successfully downloaded $blobFileName ($fileSizeFormatted) to [$localFilePath]"
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
                $fileSizeFormatted = Format-FileSize -bytes $localFileSize
                $message = "✓ No changes detected in $blobFileName (size: $fileSizeFormatted). Skipping upload."
                Write-Message -message $message -logToSummary $true
                Remove-Item -Path $tempCompareFile -Force -ErrorAction SilentlyContinue
                return $true
            }
            
            $localSizeFormatted = Format-FileSize -bytes $localFileSize
            $remoteSizeFormatted = Format-FileSize -bytes $remoteFileSize
            Write-Host "Changes detected in $blobFileName (local: $localSizeFormatted, remote: $remoteSizeFormatted)"
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
        $fileSizeFormatted = Format-FileSize -bytes $localFileSize
        Write-Host "Uploading $blobFileName ($fileSizeFormatted) to Azure Blob Storage..."
        
        $headers = @{
            "x-ms-blob-type" = "BlockBlob"
            "Content-Type" = "application/json"
        }
        
        $response = Invoke-WebRequest -Uri $blobUrl -Method PUT -Body $localContent -Headers $headers -UseBasicParsing
        
        if ($response.StatusCode -eq 201 -or $response.StatusCode -eq 200) {
            $message = "✓ Successfully uploaded $blobFileName ($fileSizeFormatted) to blob storage"
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

<#
    .SYNOPSIS
    Upload a JSON file to a custom folder in Azure Blob Storage.

    .DESCRIPTION
    Uploads a JSON file to a specified folder path in blob storage.
    Useful for organizing files in different folders (e.g., organization-scans).

    .PARAMETER sasToken
    The blob storage URL with SAS token query string.

    .PARAMETER folderPath
    The folder path in blob storage (e.g., 'organization-scans', 'status').

    .PARAMETER blobFileName
    The name of the file in blob storage.

    .PARAMETER localFilePath
    The local file path to upload.

    .EXAMPLE
    Set-JsonToBlobStorageFolder -sasToken $env:BLOB_SAS_TOKEN -folderPath "organization-scans" -blobFileName "github.json" -localFilePath "./github.json"
#>
function Set-JsonToBlobStorageFolder {
    Param (
        [Parameter(Mandatory=$true)]
        [string] $sasToken,
        
        [Parameter(Mandatory=$true)]
        [string] $folderPath,
        
        [Parameter(Mandatory=$true)]
        [string] $blobFileName,
        
        [Parameter(Mandatory=$true)]
        [string] $localFilePath
    )

    Write-Message -message "Checking upload status for $blobFileName to folder $folderPath..." -logToSummary $true

    # Validate file existence
    if (-not (Test-Path $localFilePath)) {
        $message = "⚠️ ERROR: $blobFileName does not exist at [$localFilePath]. Nothing to upload."
        Write-Message -message $message -logToSummary $true
        Write-Error $message
        return $false
    }

    # Normalize folder path (remove leading/trailing slashes)
    $folderPath = $folderPath.Trim('/')

    # Parse SAS token URL
    $baseUrlWithQuery = $sasToken
    $queryStart = $baseUrlWithQuery.IndexOf('?')
    $baseUrl = $baseUrlWithQuery.Substring(0, $queryStart)
    $sasQuery = $baseUrlWithQuery.Substring($queryStart)
    
    # Construct full blob URL with custom folder
    $blobUrl = "${baseUrl}/${folderPath}/${blobFileName}${sasQuery}"
    
    Write-Host "Blob URL: ${baseUrl}/${folderPath}/$blobFileName (SAS redacted)"

    # Read local file content
    $localContent = [System.IO.File]::ReadAllBytes($localFilePath)
    $localFileSize = $localContent.Length

    # Upload the file
    try {
        $fileSizeFormatted = Format-FileSize -bytes $localFileSize
        Write-Host "Uploading $blobFileName ($fileSizeFormatted) to Azure Blob Storage folder '$folderPath'..."
        
        $headers = @{
            "x-ms-blob-type" = "BlockBlob"
            "Content-Type" = "application/json"
        }
        
        $response = Invoke-WebRequest -Uri $blobUrl -Method PUT -Body $localContent -Headers $headers -UseBasicParsing
        
        if ($response.StatusCode -eq 201 -or $response.StatusCode -eq 200) {
            $message = "✓ Successfully uploaded $blobFileName ($fileSizeFormatted) to blob storage folder '$folderPath'"
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

<#
    .SYNOPSIS
    Download a JSON file from a custom folder in Azure Blob Storage.

    .DESCRIPTION
    Downloads a JSON file from a specified folder path in blob storage.

    .PARAMETER sasToken
    The blob storage URL with SAS token query string.

    .PARAMETER folderPath
    The folder path in blob storage (e.g., 'organization-scans', 'status').

    .PARAMETER blobFileName
    The name of the file in blob storage.

    .PARAMETER localFilePath
    The local file path where the downloaded file should be saved.

    .EXAMPLE
    Get-JsonFromBlobStorageFolder -sasToken $env:BLOB_SAS_TOKEN -folderPath "organization-scans" -blobFileName "github.json" -localFilePath "./github.json"
#>
function Get-JsonFromBlobStorageFolder {
    Param (
        [Parameter(Mandatory=$true)]
        [string] $sasToken,
        
        [Parameter(Mandatory=$true)]
        [string] $folderPath,
        
        [Parameter(Mandatory=$true)]
        [string] $blobFileName,
        
        [Parameter(Mandatory=$true)]
        [string] $localFilePath
    )

    Write-Message -message "Downloading $blobFileName from Azure Blob Storage folder '$folderPath'..." -logToSummary $true

    # Normalize folder path (remove leading/trailing slashes)
    $folderPath = $folderPath.Trim('/')

    # Parse SAS token URL
    $baseUrlWithQuery = $sasToken
    $queryStart = $baseUrlWithQuery.IndexOf('?')
    $baseUrl = $baseUrlWithQuery.Substring(0, $queryStart)
    $sasQuery = $baseUrlWithQuery.Substring($queryStart)
    
    # Construct full blob URL with custom folder
    $blobUrl = "${baseUrl}/${folderPath}/${blobFileName}${sasQuery}"
    
    Write-Host "Blob URL: ${baseUrl}/${folderPath}/$blobFileName (SAS redacted)"

    try {
        Invoke-WebRequest -Uri $blobUrl -Method GET -OutFile $localFilePath -UseBasicParsing | Out-Null
        
        if (Test-Path $localFilePath) {
            $fileSize = (Get-Item $localFilePath).Length
            $fileSizeFormatted = Format-FileSize -bytes $fileSize
            $message = "✓ Successfully downloaded $blobFileName ($fileSizeFormatted) from folder '$folderPath' to [$localFilePath]"
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
            $message = "ℹ️ $blobFileName does not exist in blob storage folder '$folderPath' yet."
            Write-Message -message $message -logToSummary $true
            return $false
        }
        $message = "⚠️ ERROR: Failed to download $blobFileName from blob storage: $($_.Exception.Message)"
        Write-Message -message $message -logToSummary $true
        Write-Error $message
        return $false
    }
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
        $access_token = $env:GITHUB_TOKEN,
        [string] $contextInfo = "",
        [bool] $waitForRateLimit = $true,
        [int] $retryCount = 0,
        [int] $maxRetries = 10,
        [int] $appSwitchCount = 0,
        [int] $maxAppSwitchCount = 1
    )
    
    # Check if we've exceeded the maximum number of retries
    if ($retryCount -gt $maxRetries) {
        $message = "Maximum retry limit ($maxRetries) exceeded for API call to [$url]. Stopping to prevent infinite loop."
        Write-Message -message $message -logToSummary $true
        Write-Warning $message
        # Set global flag to indicate we should stop processing
        $global:RateLimitExceeded = $true
        return $null
    }
    
    # Validate that access token is not null or empty before making API calls
    if ([string]::IsNullOrWhiteSpace($access_token)) {
        Write-Error "Missing GitHub access token. API call to [$url] cannot proceed without valid credentials."
        throw "No access token available for API call. Please ensure ACCESS_TOKEN or AUTOMATION_APP_KEY secrets are properly configured."
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
        # show additional context if provided
        if (-not [string]::IsNullOrEmpty($contextInfo)) {
            Write-Message -message $contextInfo -logToSummary $true
        }
        return $false
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
                    $nextResult = ApiCall -method $method -url $nextUrl -body $body -expected $expected -backOff $backOff -maxResultCount $maxResultCount -currentResultCount $currentResultCount -access_token $access_token -waitForRateLimit $waitForRateLimit -retryCount $retryCount -maxRetries $maxRetries -appSwitchCount $appSwitchCount -maxAppSwitchCount $maxAppSwitchCount
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
                $roundedSeconds = [math]::Round($rateLimitReset.TotalSeconds)
                $roundedMinutes = [math]::Round($rateLimitReset.TotalMinutes, 1)

                # When we are completely out of remaining requests, first look across
                # all configured GitHub Apps. If any app still has quota, switch to the
                # one with the highest remaining. If all apps are exhausted, sleep until
                # the earliest reset and then re-check all apps, selecting the one with
                # the highest rate limit at that time.
                if ($rateLimitRemaining[0] -eq 0) {
                    if ($waitForRateLimit) {
                        $organization = $env:APP_ORGANIZATION
                        $bestBeforeWait = Select-BestGitHubAppTokenForOrganization -organization $organization

                        if ($null -ne $bestBeforeWait) {
                            if ($bestBeforeWait.Remaining -gt 0 -and -not [string]::IsNullOrWhiteSpace($bestBeforeWait.Token)) {
                                if ($bestBeforeWait.Token -ne $access_token) {
                                    Write-Host "Rate limit remaining is 0 for current token, switching to GitHub App id [$($bestBeforeWait.AppId)] with [$($bestBeforeWait.Remaining)] remaining requests"
                                } else {
                                    Write-Host "Rate limit remaining is 0, but refreshed token for app id [$($bestBeforeWait.AppId)] has [$($bestBeforeWait.Remaining)] remaining requests"
                                }
                                # Persist the new token so future calls that rely on
                                # GITHUB_TOKEN will immediately use this app instead
                                # of continuing to hit the exhausted token.
                                $env:GITHUB_TOKEN = $bestBeforeWait.Token
                                return ApiCall -method $method -url $url -body $body -expected $expected -currentResultCount $currentResultCount -backOff $backOff -maxResultCount $maxResultCount -hideFailedCall $hideFailedCall -returnErrorInfo $returnErrorInfo -access_token $bestBeforeWait.Token -contextInfo $contextInfo -waitForRateLimit $waitForRateLimit -retryCount ($retryCount + 1) -maxRetries $maxRetries -appSwitchCount ($appSwitchCount + 1) -maxAppSwitchCount $maxAppSwitchCount
                            }

                            # All apps are currently exhausted; wait for the soonest
                            # reset time across all apps, then re-evaluate and pick the
                            # app with the highest remaining quota.
                            $waitSecondsAllApps = [math]::Round([double]$bestBeforeWait.WaitSeconds)
                            if ($waitSecondsAllApps -gt 1200) {
                                Format-RateLimitErrorTable -remaining $rateLimitRemaining[0] -used $rateLimitUsed[0] -waitSeconds $waitSecondsAllApps -continueAt $bestBeforeWait.ContinueAt -errorType "Exceeded"
                                $message = "Rate limit wait time is longer than 20 minutes across all apps, stopping execution"
                                Write-Message -message $message -logToSummary $true
                                Write-Warning $message
                                $global:RateLimitExceeded = $true
                                return $null
                            }

                            if ($waitSecondsAllApps -gt 0) {
                                Format-RateLimitErrorTable -remaining $rateLimitRemaining[0] -used $rateLimitUsed[0] -waitSeconds $waitSecondsAllApps -continueAt $bestBeforeWait.ContinueAt -errorType "Exceeded"
                                Write-Host "All configured GitHub Apps are out of rate limit. Waiting for [$waitSecondsAllApps] seconds (earliest reset at [$($bestBeforeWait.ContinueAt)]) before re-checking and selecting the best app."
                                Start-Sleep -Seconds $waitSecondsAllApps
                            }

                            $bestAfterWait = Select-BestGitHubAppTokenForOrganization -organization $organization
                            if ($null -ne $bestAfterWait -and $bestAfterWait.Remaining -gt 0 -and -not [string]::IsNullOrWhiteSpace($bestAfterWait.Token)) {
                                Write-Host "After waiting for rate limit reset, selected GitHub App id [$($bestAfterWait.AppId)] with [$($bestAfterWait.Remaining)] remaining requests"
                                return ApiCall -method $method -url $url -body $body -expected $expected -currentResultCount $currentResultCount -backOff $backOff -maxResultCount $maxResultCount -hideFailedCall $hideFailedCall -returnErrorInfo $returnErrorInfo -access_token $bestAfterWait.Token -contextInfo $contextInfo -waitForRateLimit $waitForRateLimit -retryCount ($retryCount + 1) -maxRetries $maxRetries -appSwitchCount ($appSwitchCount + 1) -maxAppSwitchCount $maxAppSwitchCount
                            }

                            $message = "Rate limit did not recover after waiting across all apps; stopping execution"
                            Write-Message -message $message -logToSummary $true
                            Write-Warning $message
                            $global:RateLimitExceeded = $true
                            return $null
                        }

                        # No app configuration or tokens available; fall back to
                        # treating this as a hard stop to avoid tight loops.
                        Format-RateLimitErrorTable -remaining $rateLimitRemaining[0] -used $rateLimitUsed[0] -waitSeconds $rateLimitReset.TotalSeconds -continueAt $oUNIXDate -errorType "Exceeded"
                        $message = "Rate limit reached with 0 remaining requests and no GitHub App configuration available, stopping execution"
                        Write-Message -message $message -logToSummary $true
                        Write-Warning $message
                        $global:RateLimitExceeded = $true
                        return $null
                    }

                    # When waitForRateLimit is false and remaining is 0, just return
                    # the partial/empty response we already have without waiting.
                    return $response
                }

                if ($rateLimitReset.TotalSeconds -gt 1200) {
                    # Only show messages and halt execution if we're configured to wait for rate limits
                    if ($waitForRateLimit) {
                        # First try to switch to the next GitHub App (if configured) and retry
                        $manager = Get-GitHubAppTokenManagerInstance
                        $organization = $env:APP_ORGANIZATION
                        if ($null -ne $manager -and -not [string]::IsNullOrWhiteSpace($organization) -and $appSwitchCount -lt $maxAppSwitchCount) {
                            Write-Host "Rate limit wait > 20 minutes, attempting to switch to next GitHub App for organization [$organization]"
                            try {
                                $manager.MoveToNextApp()
                                $tokenResult = $manager.GetTokenForOrganization($organization)
                                if ($null -ne $tokenResult -and -not [string]::IsNullOrWhiteSpace($tokenResult.Token)) {
                                    $newToken = $tokenResult.Token
                                    Write-Host "Switched to GitHub App id [$($tokenResult.AppId)] after rate limit; retrying API call"
                                    return ApiCall -method $method -url $url -body $body -expected $expected -currentResultCount $currentResultCount -backOff $backOff -maxResultCount $maxResultCount -hideFailedCall $hideFailedCall -returnErrorInfo $returnErrorInfo -access_token $newToken -contextInfo $contextInfo -waitForRateLimit $waitForRateLimit -retryCount $retryCount -maxRetries $maxRetries -appSwitchCount ($appSwitchCount + 1) -maxAppSwitchCount $maxAppSwitchCount
                                }
                            }
                            catch {
                                Write-Warning "Failed to switch GitHub App after rate limit: $($_.Exception.Message)"
                            }
                        }

                        # If we cannot switch apps or failover still leaves us waiting too long, stop execution
                        Format-RateLimitErrorTable -remaining $rateLimitRemaining[0] -used $rateLimitUsed[0] -waitSeconds $rateLimitReset.TotalSeconds -continueAt $oUNIXDate -errorType "Exceeded"
                        $message = "Rate limit wait time is longer than 20 minutes, stopping execution"
                        Write-Message -message $message -logToSummary $true
                        Write-Warning $message
                        # Set global flag to indicate rate limit exceeded
                        $global:RateLimitExceeded = $true
                        # Return null to indicate we should stop processing
                        return $null
                    }
                    # When not waiting for rate limits, just return the response we already have
                    # Don't show error messages or set the flag since we're intentionally not halting
                    return $response
                }
                Format-RateLimitErrorTable -remaining $rateLimitRemaining[0] -used $rateLimitUsed[0] -waitSeconds $rateLimitReset.TotalSeconds -continueAt $oUNIXDate -errorType "Warning"
                Write-Host ""
                # Only wait for rate limit if requested
                if ($waitForRateLimit) {
                    Start-Sleep -Milliseconds $rateLimitReset.TotalMilliseconds
                }
            }
            # prevent hitting max interval too fast
            if ($backOff -gt 2000) {
                $backOff = 5000
            }
            else {
                $backOff = $backOff * 2
            }
            return ApiCall -method $method -url $url -body $body -expected $expected -backOff ($backOff) -access_token $access_token -waitForRateLimit $waitForRateLimit -retryCount ($retryCount + 1) -maxRetries $maxRetries -appSwitchCount $appSwitchCount -maxAppSwitchCount $maxAppSwitchCount
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
            # If we're calling the rate_limit endpoint itself, don't retry - just return null
            if ($url.Contains("rate_limit")) {
                Write-Debug "Rate limit endpoint call failed, skipping retry to avoid recursion"
                return $null
            }
            
            Write-Host "Rate limit exceeded, waiting for [$backOff] seconds before continuing"
            Start-Sleep -Seconds $backOff
            GetRateLimitInfo -access_token $access_token -access_token_destination $access_token
            return ApiCall -method $method -url $url -body $body -expected $expected -backOff ($backOff*2) -access_token $access_token -waitForRateLimit $waitForRateLimit -retryCount ($retryCount + 1) -maxRetries $maxRetries -appSwitchCount $appSwitchCount -maxAppSwitchCount $maxAppSwitchCount
        }
        else {
            if (!$hideFailedCall) {
                Write-Host "Log message: $($messageData.message)"
            }
        }

        if ($messageData.message -And ($messageData.message.StartsWith("You have exceeded a secondary rate limit"))) {
            # If we're calling the rate_limit endpoint itself, don't retry - just return null
            if ($url.Contains("rate_limit")) {
                Write-Debug "Rate limit endpoint call failed with secondary rate limit, skipping retry to avoid recursion"
                return $null
            }
            
            if ($backOff -eq 5) {
                # start the initial backoff bigger, might give more change to continue faster
                $backOff = 120
            }
            else {
                $backOff = $backOff*2
                # prevent hitting max interval too fast
                if ($backOff -gt 2000) {
                    $backOff = 5000
                }
            }
            Write-Host "Secondary rate limit exceeded, waiting for [$backOff] seconds before continuing"
            Start-Sleep -Seconds $backOff

            return ApiCall -method $method -url $url -body $body -expected $expected -backOff $backOff -access_token $access_token -waitForRateLimit $waitForRateLimit -retryCount ($retryCount + 1) -maxRetries $maxRetries -appSwitchCount $appSwitchCount -maxAppSwitchCount $maxAppSwitchCount
        }

        $isUserRateLimit = $messageData.message -and $messageData.message.StartsWith("API rate limit exceeded for user ID")
        $isInstallationRateLimit = $messageData.message -and $messageData.message.StartsWith("API rate limit exceeded for installation ID")
        if ($isUserRateLimit -or $isInstallationRateLimit) {
            # If we're calling the rate_limit endpoint itself, don't retry - just return null
            if ($url.Contains("rate_limit")) {
                Write-Debug "Rate limit endpoint call failed with API rate limit exceeded, skipping retry to avoid recursion"
                return $null
            }

            $responseHeaders = $null
            if ($null -ne $_.Exception -and $null -ne $_.Exception.Response) {
                $responseHeaders = $_.Exception.Response.Headers
            }

            $rateInfo = Get-RateLimitRetryPlan -headers $responseHeaders
            $waitSeconds = $rateInfo.WaitSeconds
            $continueAt = $rateInfo.ContinueAt
            $remaining = $rateInfo.Remaining
            $used = $rateInfo.Used

            if ($isInstallationRateLimit -and $waitSeconds -le 0) {
                $waitSeconds = 60
                $continueAt = [DateTime]::UtcNow.AddSeconds($waitSeconds)
            }

            # When we hit an explicit API rate limit error, first look across all
            # configured GitHub Apps. If any app still has quota, immediately switch
            # to the one with the highest remaining. If all apps are exhausted, use
            # the earliest reset across all apps to decide how long to wait.
            $usedAllAppsWaitPlan = $false
            if ($waitForRateLimit) {
                $organization = $env:APP_ORGANIZATION
                $bestBeforeWait = Select-BestGitHubAppTokenForOrganization -organization $organization

                if ($null -ne $bestBeforeWait) {
                    if ($bestBeforeWait.Remaining -gt 0 -and -not [string]::IsNullOrWhiteSpace($bestBeforeWait.Token)) {
                        $formatType = if ($isInstallationRateLimit) { "Installation" } else { "Exceeded" }
                        if (-not $script:HasLoggedRateLimitAppSwitch) {
                            Write-Host "Rate limit ($formatType) encountered with remaining [$remaining], switching to GitHub App id [$($bestBeforeWait.AppId)] with [$($bestBeforeWait.Remaining)] remaining requests instead of waiting [$waitSeconds] seconds"
                            $script:HasLoggedRateLimitAppSwitch = $true
                        }
                        # Persist the new token globally so subsequent calls
                        # that don't explicitly pass access_token pick up the
                        # rotated app token instead of the exhausted one.
                        $env:GITHUB_TOKEN = $bestBeforeWait.Token
                        return ApiCall -method $method -url $url -body $body -expected $expected -currentResultCount $currentResultCount -backOff $backOff -maxResultCount $maxResultCount -hideFailedCall $hideFailedCall -returnErrorInfo $returnErrorInfo -access_token $bestBeforeWait.Token -contextInfo $contextInfo -waitForRateLimit $waitForRateLimit -retryCount ($retryCount + 1) -maxRetries $maxRetries -appSwitchCount ($appSwitchCount + 1) -maxAppSwitchCount $maxAppSwitchCount
                    }

                    # All apps are currently exhausted; prefer the earliest reset
                    # across all apps instead of the current token's reset time.
                    if ($bestBeforeWait.WaitSeconds -gt 0) {
                        $waitSeconds = [double]$bestBeforeWait.WaitSeconds
                        $continueAt = $bestBeforeWait.ContinueAt
                        $usedAllAppsWaitPlan = $true
                        $waitDisplay = Format-WaitTime -totalSeconds $waitSeconds
                        Write-Message -message "Using earliest reset across all GitHub Apps: waiting [$waitSeconds] seconds ($waitDisplay) until [$continueAt] before retrying" -logToSummary $true
                    }
                }
            }

            # Check if wait time exceeds 20 minutes (1200 seconds)
            if ($waitSeconds -gt 1200 -and -not $usedAllAppsWaitPlan) {
                # Only show messages and halt execution if we're configured to wait for rate limits
                if ($waitForRateLimit) {
                    # First try to switch to the next GitHub App (if configured) and retry
                    $manager = Get-GitHubAppTokenManagerInstance
                    $organization = $env:APP_ORGANIZATION
                    if ($null -ne $manager -and -not [string]::IsNullOrWhiteSpace($organization) -and $appSwitchCount -lt $maxAppSwitchCount) {
                        $formatType = if ($isInstallationRateLimit) { "Installation" } else { "Exceeded" }
                        Write-Host "Rate limit wait > 20 minutes ($formatType), attempting to switch to next GitHub App for organization [$organization]"
                        try {
                            $manager.MoveToNextApp()
                            $tokenResult = $manager.GetTokenForOrganization($organization)
                            if ($null -ne $tokenResult -and -not [string]::IsNullOrWhiteSpace($tokenResult.Token)) {
                                $newToken = $tokenResult.Token
                                Write-Host "Switched to GitHub App id [$($tokenResult.AppId)] after rate limit; retrying API call"
                                # Update the shared environment token so future
                                # calls use this app id by default.
                                $env:GITHUB_TOKEN = $newToken
                                return ApiCall -method $method -url $url -body $body -expected $expected -currentResultCount $currentResultCount -backOff $backOff -maxResultCount $maxResultCount -hideFailedCall $hideFailedCall -returnErrorInfo $returnErrorInfo -access_token $newToken -contextInfo $contextInfo -waitForRateLimit $waitForRateLimit -retryCount $retryCount -maxRetries $maxRetries -appSwitchCount ($appSwitchCount + 1) -maxAppSwitchCount $maxAppSwitchCount
                            }
                        }
                        catch {
                            Write-Warning "Failed to switch GitHub App after rate limit: $($_.Exception.Message)"
                        }
                    }

                    $formatType = if ($isInstallationRateLimit) { "Installation" } else { "Exceeded" }
                    if ($rateInfo.HasHeaderData -or $isInstallationRateLimit) {
                        Format-RateLimitErrorTable -remaining $remaining -used $used -waitSeconds $waitSeconds -continueAt $continueAt -errorType $formatType
                    }
                    $message = "Rate limit wait time is longer than 20 minutes, stopping execution"
                    Write-Message -message $message -logToSummary $true
                    Write-Warning $message
                    # Set global flag to indicate rate limit exceeded
                    $global:RateLimitExceeded = $true
                    # Return null to indicate we should stop processing
                    return $null
                }
                # When not waiting for rate limits, just return null without showing error messages
                # Don't set the global flag since we're intentionally not halting the workflow
                return $null
            }

            # For shorter wait times, only wait if requested
            if ($waitForRateLimit -and $waitSeconds -gt 0) {
                $waitDisplay = Format-WaitTime -totalSeconds $waitSeconds
                if ($isInstallationRateLimit) {
                    Format-RateLimitErrorTable -remaining $remaining -used $used -waitSeconds $waitSeconds -continueAt $continueAt -errorType "Installation"
                    Write-Host "Pausing after installation rate limit error for $waitDisplay"
                }
                else {
                    Write-Host "Rate limit hit, waiting for [$waitSeconds] seconds before continuing"
                }
                Start-Sleep -Milliseconds ($waitSeconds * 1000)
            }

            # Only retry if we're configured to wait for rate limits
            if ($waitForRateLimit) {
                # prevent hitting max interval too fast
                if ($backOff -gt 2000) {
                    $backOff = 5000
                }
                else {
                    $backOff = $backOff * 2
                }
                return ApiCall -method $method -url $url -body $body -expected $expected -backOff ($backOff) -access_token $access_token -waitForRateLimit $waitForRateLimit -retryCount ($retryCount + 1) -maxRetries $maxRetries -appSwitchCount $appSwitchCount -maxAppSwitchCount $maxAppSwitchCount
            }

            # When not waiting, return null
            return $null
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
                $message = "Unknown error"
                
                # Safely extract status code with nested null checks
                if ($null -ne $_.Exception -and $null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) {
                    $statusCode = $_.Exception.Response.StatusCode.value__
                }
                
                # Safely extract message with property check
                if ($null -ne $messageData -and ($messageData.PSObject.Properties['message'])) {
                    $message = $messageData.message
                }
                
                return @{
                    Error = $true
                    StatusCode = $statusCode
                    Message = $message
                    Url = $url
                }
            }
            
            if (!$hideFailedCall) {
                $statusCode = $null
                $content = $null
                if ($null -ne $_.Exception -and $null -ne $_.Exception.Response) {
                    $statusCode = $_.Exception.Response.StatusCode.value__
                    $content = $_.Exception.Response.Content
                }

                Write-Host "Error calling $url, status code [$statusCode]"
                Write-Host "MessageData: " $messageData
                Write-Host "Error: " $_
                if ($null -ne $content) {
                    if ($content.Length -gt 100) {
                        Write-Host "Content: " $content.Substring(0, 100) + "..."
                    }
                    else {
                        Write-Host "Content: " $content
                    }
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

    # Parse URL to extract owner and repo (first 2 path segments)
    # For URLs like https://github.com/owner/repo or https://github.com/owner/repo/path
    # we want to extract: owner, repo (ignoring any additional path components)
    try {
        # Handle both full URLs and simple owner/repo strings
        if ($url -match '^https?://') {
            $uri = [Uri]$url
            $segments = $uri.AbsolutePath.Trim('/').Split('/')
            if ($segments.Length -ge 2) {
                $owner = $segments[0]
                $repo = $segments[1]
                return $owner, $repo
            }
        } else {
            # Handle simple owner/repo or owner/repo/path strings
            $urlParts = $url.Trim('/').Split('/')
            if ($urlParts.Length -ge 2) {
                $owner = $urlParts[0]
                $repo = $urlParts[1]
                return $owner, $repo
            }
        }
    } catch {
        # Fall back to old logic if parsing fails
        $urlParts = $url.Split('/')
        if ($urlParts.Length -ge 2) {
            $repo = $urlParts[-1]
            $owner = $urlParts[-2]
            return $owner, $repo
        }
    }

    return $null, $null
}

function GetForkedRepoName {
    Param (
        $owner,
        $repo
     )
    # Replace all slashes in repo name with underscores (handles composite action paths)
    $repoSanitized = $repo -replace '/', '_'
    return "$($owner)_$($repoSanitized)"
}

function GetOrgActionInfo {
    Param (
        $forkedOwnerRepo
    )

    if ($null -ne $forkedOwnerRepo -And $forkedOwnerRepo -ne "") {
        $forkedOwnerRepoParts = $forkedOwnerRepo.Split('_')
        $owner = $forkedOwnerRepoParts[0]
        $repo = $forkedOwnerRepo.Substring($owner.Length + 1)
        # Convert underscores back to slashes in repo name (reverses the sanitization from GetForkedRepoName)
        $repo = $repo -replace '_', '/'

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
function Format-WaitTime {
    Param (
        [double] $totalSeconds
    )
    
    $seconds = [math]::Round($totalSeconds, 0)
    $minutes = [math]::Round($totalSeconds / 60, 1)
    
    if ($minutes -lt 1) {
        return "$seconds seconds"
    } elseif ($minutes -lt 60) {
        $minuteLabel = if ($minutes -eq 1) { "minute" } else { "minutes" }
        return "$seconds seconds ($minutes $minuteLabel)"
    } else {
        $hours = [math]::Floor($minutes / 60)
        $remainingMinutes = [math]::Round($minutes % 60, 1)
        $hourLabel = if ($hours -eq 1) { "hour" } else { "hours" }
        
        if ($remainingMinutes -eq 0) {
            return "$seconds seconds ($hours $hourLabel)"
        } else {
            $minuteLabel = if ($remainingMinutes -eq 1) { "minute" } else { "minutes" }
            return "$seconds seconds ($hours $hourLabel $remainingMinutes $minuteLabel)"
        }
    }
}

#region Mirror Retry Queue Helpers

function Get-RetryQueuePath {
    Param (
        [string] $QueuePath
    )

    if (-not [string]::IsNullOrWhiteSpace($QueuePath)) {
        return (Resolve-Path -Path $QueuePath).Path
    }

    # Default to repo root retry-queue.json (library lives in .github/workflows)
    $rootPath = Resolve-Path -Path (Join-Path $PSScriptRoot "..") | ForEach-Object { $_.ProviderPath }
    return Join-Path $rootPath "retry-queue.json"
}

function Load-RetryQueue {
    Param (
        [string] $QueuePath
    )

    $path = Get-RetryQueuePath -QueuePath $QueuePath
    if (-not (Test-Path $path)) {
        return @()
    }

    try {
        $json = Get-Content -Path $path -Raw
        if ([string]::IsNullOrWhiteSpace($json)) { return @() }
        return $json | ConvertFrom-Json
    }
    catch {
        Write-Warning "Failed to load retry queue from [$path]: $($_.Exception.Message)"
        return @()
    }
}

function Save-RetryQueue {
    Param (
        $Queue,
        [string] $QueuePath
    )

    $path = Get-RetryQueuePath -QueuePath $QueuePath
    try {
        $json = ConvertTo-Json -InputObject $Queue -Depth 6
        $tmpPath = "$path.tmp"
        [System.IO.File]::WriteAllText($tmpPath, $json, [System.Text.Encoding]::UTF8)
        Move-Item -Path $tmpPath -Destination $path -Force
        return $true
    }
    catch {
        Write-Warning "Failed to save retry queue to [$path]: $($_.Exception.Message)"
        return $false
    }
}

function Enqueue-MirrorRetry {
    Param (
        [Parameter(Mandatory = $true)][string] $MirrorName,
        [string] $ErrorMessage,
        [string] $ErrorType = "mirror_create_failed",
        [string] $QueuePath
    )

    $queue = @() + (Load-RetryQueue -QueuePath $QueuePath)
    $existing = $queue | Where-Object { $_.name -eq $MirrorName }
    $now = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"

    if ($existing) {
        foreach ($item in $existing) {
            $item.errorMessage = $ErrorMessage
            $item.errorType = $ErrorType
            $item.attempts = if ($item.attempts) { $item.attempts + 1 } else { 1 }
            $item.lastAttempt = $now
            $nextWaitMinutes = [math]::Min(180, [math]::Pow(2, [double]$item.attempts))
            $item.nextAttempt = (Get-Date).AddMinutes($nextWaitMinutes).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
    else {
        $queue += [pscustomobject]@{
            name        = $MirrorName
            errorMessage = $ErrorMessage
            errorType    = $ErrorType
            attempts     = 1
            firstSeen    = $now
            lastAttempt  = $now
            nextAttempt  = (Get-Date).AddMinutes(5).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }

    Save-RetryQueue -Queue $queue -QueuePath $QueuePath | Out-Null
}

#endregion

function Format-RateLimitComparisonTable {
    Param (
        $rateEntries,
        [string] $title = "Rate Limit Status"
    )

    if ($null -eq $rateEntries -or $rateEntries.Count -eq 0) {
        return
    }

    Write-Message -message "**${title}:**" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "| Token | Limit | Used | Remaining | Resets In |" -logToSummary $true
    Write-Message -message "|-------|------:|-----:|----------:|-----------|" -logToSummary $true

    foreach ($entry in $rateEntries) {
        if ($null -eq $entry -or $null -eq $entry.Rate) {
            continue
        }

        $rateData = $entry.Rate

        # Convert Unix timestamp to human-readable time remaining
        $resetTime = [DateTimeOffset]::FromUnixTimeSeconds($rateData.reset).UtcDateTime
        $timeUntilReset = $resetTime - (Get-Date).ToUniversalTime()

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

        $tokenName = if ($null -ne $entry.Name -and -not [string]::IsNullOrWhiteSpace($entry.Name)) { $entry.Name } else { "Token" }

        Write-Message -message "| $tokenName | $(DisplayIntWithDots $rateData.limit) | $(DisplayIntWithDots $rateData.used) | $(DisplayIntWithDots $rateData.remaining) | $resetDisplay |" -logToSummary $true
    }

    Write-Message -message "" -logToSummary $true
}

function Write-GitHubAppRateLimitOverview {
    Param (
        [string] $organization = $env:APP_ORGANIZATION,
        $appOverview = $null
    )

    if ($null -eq $appOverview -and -not [string]::IsNullOrWhiteSpace($organization)) {
        try {
            $appOverview = Get-GitHubAppRateLimitOverview -organization $organization
        }
        catch {
            Write-Warning "Failed to retrieve GitHub App rate limit overview: $($_.Exception.Message)"
            $appOverview = $null
        }
    }

    if ($null -ne $appOverview -and $appOverview.Count -gt 0) {
        Write-Message -message "| # | App Id | Remaining | Used | Wait Time | Continue At (UTC) | Token Expires In |" -logToSummary $true
        Write-Message -message "|---:|-------:|----------:|-----:|-----------|-------------------|------------------|" -logToSummary $true

        $index = 1
        foreach ($app in $appOverview) {
            $appWaitSeconds = if ($null -ne $app.WaitSeconds) { [double]$app.WaitSeconds } else { 0 }
            $appWaitTime = Format-WaitTime -totalSeconds $appWaitSeconds
            
            # Format expiration time
            $expirationDisplay = "N/A"
            if ($null -ne $app.MinutesUntilExpiration) {
                if ($app.MinutesUntilExpiration -le 0) {
                    $expirationDisplay = "⚠️ Expired"
                }
                elseif ($app.MinutesUntilExpiration -lt 15) {
                    $expirationDisplay = "⚠️ $($app.MinutesUntilExpiration)m"
                }
                elseif ($app.MinutesUntilExpiration -lt 60) {
                    $expirationDisplay = "$($app.MinutesUntilExpiration)m"
                }
                else {
                    $hours = [Math]::Floor($app.MinutesUntilExpiration / 60)
                    $minutes = [Math]::Round($app.MinutesUntilExpiration % 60)
                    $expirationDisplay = "${hours}h ${minutes}m"
                }
            }
            
            Write-Message -message "| $index | $($app.AppId) | $(DisplayIntWithDots $app.Remaining) | $(DisplayIntWithDots $app.Used) | $appWaitTime | $($app.ContinueAt) | $expirationDisplay |" -logToSummary $true
            $index++
        }

        Write-Message -message "" -logToSummary $true
    }
}

function Format-RateLimitErrorTable {
    Param (
        [int] $remaining,
        [int] $used,
        [double] $waitSeconds,
        [DateTime] $continueAt,
        [string] $errorType = "Error"
    )
    
    $waitTime = Format-WaitTime -totalSeconds $waitSeconds

    # Capture app overview once so we can avoid writing two tables when app data is available.
    $appOverview = $null
    try {
        $appOverview = Get-GitHubAppRateLimitOverview -organization $env:APP_ORGANIZATION
    }
    catch {
        Write-Warning "Failed to retrieve GitHub App rate limit overview: $($_.Exception.Message)"
    }
    $hasAppOverview = $null -ne $appOverview -and $appOverview.Count -gt 0
    
    Write-Message -message "" -logToSummary $true
    Write-Message -message "**Rate Limit ${errorType}:**" -logToSummary $true
    Write-Message -message "" -logToSummary $true

    if (-not $hasAppOverview) {
        Write-Message -message "| Remaining | Used | Wait Time | Continue At (UTC) |" -logToSummary $true
        Write-Message -message "|----------:|-----:|-----------|-------------------|" -logToSummary $true
        Write-Message -message "| $(DisplayIntWithDots $remaining) | $(DisplayIntWithDots $used) | $waitTime | $continueAt |" -logToSummary $true
        Write-Message -message "" -logToSummary $true
    }

    if ($hasAppOverview) {
        Write-GitHubAppRateLimitOverview -appOverview $appOverview
    }
}

function Test-IsLikelyGitHubAppPemKey {
    Param (
        [string] $pemKey
    )

    if ([string]::IsNullOrWhiteSpace($pemKey)) {
        return $false
    }

    # Very short values are almost certainly not full PEM contents
    if ($pemKey.Length -lt 100) {
        return $false
    }

    # GitHub App private keys are PEM-encoded and start with a BEGIN line
    if ($pemKey -match '-----BEGIN [A-Z ]*PRIVATE KEY-----') {
        return $true
    }

    return $false
}

function Get-GitHubAppRateLimitOverview {
    Param (
        [string] $organization = $env:APP_ORGANIZATION
    )

    $primaryKey = $env:APPLICATION_PRIVATE_KEY
    $secondaryKey = $env:APPLICATION_PRIVATE_KEY_2
    $tertiaryKey = $env:APPLICATION_PRIVATE_KEY_3

    $appIds = @($env:APP_ID, $env:APP_ID_2, $env:APP_ID_3) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $appPrivateKeys = @($primaryKey, $secondaryKey, $tertiaryKey) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    if ($appIds.Count -eq 0 -or $appPrivateKeys.Count -eq 0) {
        return @()
    }

    if ([string]::IsNullOrWhiteSpace($organization)) {
        return @()
    }

    $max = [Math]::Min($appIds.Count, $appPrivateKeys.Count)
    $results = @()

    for ($i = 0; $i -lt $max; $i++) {
        $appId = $appIds[$i]
        $pemKey = $appPrivateKeys[$i]

        if ([string]::IsNullOrWhiteSpace($appId) -or [string]::IsNullOrWhiteSpace($pemKey)) {
            continue
        }

        if (-not (Test-IsLikelyGitHubAppPemKey -pemKey $pemKey)) {
            Write-Warning "APPLICATION_PRIVATE_KEY value for app id [$appId] does not look like a PEM-encoded private key. Ensure you pasted the key contents, not the path or ID. Skipping this app for rate limit checks."
            continue
        }

        try {
            $tokenInfo = Get-TokenFromApp -appId $appId -pemKey $pemKey -targetAccountLogin $organization -returnFullInfo
            if ([string]::IsNullOrWhiteSpace($tokenInfo.token)) {
                continue
            }

            $token = $tokenInfo.token
            $headers = @{
                Authorization = GetBasicAuthenticationHeader -access_token $token
            }

            try {
                $rateUrl = "https://api.github.com/rate_limit"
                $result = Invoke-WebRequest -Uri $rateUrl -Headers $headers -Method GET -ErrorAction Stop
                $rateResponse = $result.Content | ConvertFrom-Json
                $rateData = $rateResponse.rate

                $rateInfo = Get-RateLimitRetryPlan -headers $result.Headers

                $remaining = if ($null -ne $rateData.remaining) { [int]$rateData.remaining } else { [int]$rateInfo.Remaining }
                $used = if ($null -ne $rateData.used) { [int]$rateData.used } else { [int]$rateInfo.Used }
                $waitSeconds = [double]$rateInfo.WaitSeconds
                $continueAt = $rateInfo.ContinueAt

                # Get token expiration time from the token info response
                # GitHub App tokens include 'expires_at' in the token creation response
                $expirationTime = $null
                if ($null -ne $tokenInfo.expiresAt -and -not [string]::IsNullOrWhiteSpace($tokenInfo.expiresAt)) {
                    try {
                        $expirationTime = [DateTimeOffset]::Parse($tokenInfo.expiresAt, [System.Globalization.CultureInfo]::InvariantCulture).UtcDateTime
                    }
                    catch {
                        Write-Debug "Failed to parse token expiration time for app id [$appId]: $($_.Exception.Message)"
                    }
                }

                # Calculate minutes until expiration
                $minutesUntilExpiration = $null
                if ($null -ne $expirationTime) {
                    $timeRemaining = $expirationTime - [DateTime]::UtcNow
                    $minutesUntilExpiration = [Math]::Round($timeRemaining.TotalMinutes, 1)
                }

                $results += [pscustomobject]@{
                    AppId = $appId
                    Token = $token
                    Remaining = $remaining
                    Used = $used
                    WaitSeconds = $waitSeconds
                    ContinueAt = $continueAt
                    ExpirationTime = $expirationTime
                    MinutesUntilExpiration = $minutesUntilExpiration
                }
            }
            catch {
                Write-Warning "Failed to get rate limit info for app id [$appId]: $($_.Exception.Message)"
            }
        }
        catch {
            Write-Warning "Failed to get token for app id [$appId] while checking rate limits: $($_.Exception.Message)"
        }
    }

    return ,$results
}

function Select-BestGitHubAppTokenForOrganization {
    Param (
        [string] $organization = $env:APP_ORGANIZATION,
        [int] $minMinutesUntilExpiration = 15
    )

    $overview = Get-GitHubAppRateLimitOverview -organization $organization

    if ($null -eq $overview -or $overview.Count -eq 0) {
        return $null
    }

    # Filter out tokens that will expire within the minimum threshold
    $nonExpiringTokens = $overview | Where-Object { 
        $null -eq $_.MinutesUntilExpiration -or $_.MinutesUntilExpiration -gt $minMinutesUntilExpiration
    }

    # First, try to find a non-expiring token with remaining quota
    $withRemaining = $nonExpiringTokens | Where-Object { $_.Remaining -gt 0 }
    if ($withRemaining -and $withRemaining.Count -gt 0) {
        # Sort by remaining quota (highest first), then by minutes until expiration (longest first)
        return $withRemaining | Sort-Object -Property @(
            @{ Expression = { $_.Remaining }; Descending = $true },
            @{ Expression = { if ($null -ne $_.MinutesUntilExpiration) { $_.MinutesUntilExpiration } else { [double]::MaxValue } }; Descending = $true }
        ) | Select-Object -First 1
    }

    # If no tokens have remaining quota, check if any non-expiring tokens will reset soon
    if ($nonExpiringTokens -and $nonExpiringTokens.Count -gt 0) {
        # Return the one that will become available soonest
        return $nonExpiringTokens | Sort-Object -Property WaitSeconds | Select-Object -First 1
    }

    # All tokens are either exhausted or about to expire
    # Check if there are any tokens at all (even expiring ones)
    $anyTokenWithQuota = $overview | Where-Object { $_.Remaining -gt 0 }
    if ($anyTokenWithQuota -and $anyTokenWithQuota.Count -gt 0) {
        # We have tokens with quota but they're all expiring soon
        # Return null to signal that we should stop gracefully
        return $null
    }

    # All apps are currently exhausted; return the one that will
    # become available soonest based on the shortest wait time.
    return $overview | Sort-Object -Property WaitSeconds | Select-Object -First 1
}

function Get-RateLimitRetryPlan {
    Param (
        $headers
    )

    $remainingValue = 0
    $usedValue = 0
    $waitSeconds = 0
    $continueAt = [DateTime]::UtcNow
    $hasHeaderData = $false

    if ($null -ne $headers) {
        $remainingHeader = $headers["X-RateLimit-Remaining"]
        if ($null -eq $remainingHeader) {
            $remainingHeader = $headers["X-Ratelimit-Remaining"]
        }

        if ($remainingHeader -and $remainingHeader.Count -gt 0) {
            $parsedRemaining = 0
            if ([int]::TryParse($remainingHeader[0], [ref]$parsedRemaining)) {
                $remainingValue = $parsedRemaining
                $hasHeaderData = $true
            }
        }

        $usedHeader = $headers["X-RateLimit-Used"]
        if ($null -eq $usedHeader) {
            $usedHeader = $headers["X-Ratelimit-Used"]
        }

        if ($usedHeader -and $usedHeader.Count -gt 0) {
            $parsedUsed = 0
            if ([int]::TryParse($usedHeader[0], [ref]$parsedUsed)) {
                $usedValue = $parsedUsed
                $hasHeaderData = $true
            }
        }

        $resetHeader = $headers["X-RateLimit-Reset"]
        if ($resetHeader -and $resetHeader.Count -gt 0) {
            $parsedReset = 0
            if ([int]::TryParse($resetHeader[0], [ref]$parsedReset)) {
                $resetTime = (Get-Date 01.01.1970) + ([System.TimeSpan]::FromSeconds($parsedReset))
                $timeUntilReset = $resetTime - [DateTime]::UtcNow
                if ($timeUntilReset.TotalSeconds -gt 0) {
                    $waitSeconds = $timeUntilReset.TotalSeconds
                    $continueAt = $resetTime
                    $hasHeaderData = $true
                }
            }
        }
    }

    return [pscustomobject]@{
        Remaining = $remainingValue
        Used = $usedValue
        WaitSeconds = $waitSeconds
        ContinueAt = $continueAt
        HasHeaderData = $hasHeaderData
    }
}

function GetRateLimitInfo {
    Param (
        [string]
        $access_token,
        [string]
        $access_token_destination,
        [bool]
        $waitForRateLimit = $true
    )
    $url = "rate_limit"
    $response = ApiCall -method GET -url $url -access_token $access_token -waitForRateLimit $waitForRateLimit

    # Check if rate limit was exceeded (returns null)
    if ($null -eq $response) {
        # Only show the "skipped" message if we were actually trying to wait for rate limits
        # When waitForRateLimit=false, we're intentionally not halting, so don't confuse users
        if ($waitForRateLimit -and (Test-RateLimitExceeded)) {
            Write-Message -message "⚠️ Rate limit check skipped - rate limit exceeded (20+ minute wait)" -logToSummary $true
            return
        } elseif ($waitForRateLimit) {
            Write-Warning "Failed to get rate limit info - API call returned null"
            return
        }
        # When waitForRateLimit=false and we hit rate limit, silently skip the check
        return
    }

    # Collect rate limit info for one or two tokens
    $rateEntries = @()

    $rateEntries += [pscustomobject]@{
        Name = "Primary"
        Rate = $response.rate
    }

    if ($access_token -ne $access_token_destination -and $access_token_destination -ne "" ) {
        # check the ratelimit for the destination token as well:
        $response2 = ApiCall -method GET -url $url -access_token $access_token_destination -waitForRateLimit $waitForRateLimit
        if ($null -ne $response2) {
            $rateEntries += [pscustomobject]@{
                Name = "Destination"
                Rate = $response2.rate
            }
        }
    }

    # Format combined rate limit info as a single table for easier comparison
    Format-RateLimitComparisonTable -rateEntries $rateEntries -title "Rate Limit Status"

    if ($response.rate.limit -eq 60) {
        throw "Rate limit is 60, this is not enough to run any of these scripts, check the token that is used"
    }
}

function Invoke-GitHubAppRateLimitCheckForConfiguredApps {
    Param (
        [string] $organization = $env:APP_ORGANIZATION
    )

    Write-Message -message "" -logToSummary $true
    Write-Message -message "### Final Rate Limit Check" -logToSummary $true
    Write-Message -message "" -logToSummary $true

    $primaryKey = $env:APPLICATION_PRIVATE_KEY
    $secondaryKey = $env:APPLICATION_PRIVATE_KEY_2
    $tertiaryKey = $env:APPLICATION_PRIVATE_KEY_3

    if ([string]::IsNullOrWhiteSpace($primaryKey) -and [string]::IsNullOrWhiteSpace($secondaryKey) -and [string]::IsNullOrWhiteSpace($tertiaryKey)) {
        throw "At least one APPLICATION_PRIVATE_KEY (or APPLICATION_PRIVATE_KEY_2 or APPLICATION_PRIVATE_KEY_3) must be provided to perform the rate limit check"
    }

    if ([string]::IsNullOrWhiteSpace($organization)) {
        throw "APP_ORGANIZATION (or explicit organization parameter) must be provided to perform the rate limit check"
    }

    $appIds = @($env:APP_ID, $env:APP_ID_2, $env:APP_ID_3) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $appPrivateKeys = @($primaryKey, $secondaryKey, $tertiaryKey) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    if ($appIds.Count -eq 0 -or $appPrivateKeys.Count -eq 0) {
        throw "At least one APP_ID and APPLICATION_PRIVATE_KEY must be provided to perform the rate limit check"
    }

    # Show rate limit status for all configured GitHub Apps instead of a single token
    Write-GitHubAppRateLimitOverview -organization $organization
}

<#
    .SYNOPSIS
    Checks if the global rate limit exceeded flag is set.
    
    .DESCRIPTION
    Returns true if the rate limit was exceeded (wait time > 20 minutes) during API calls.
    This can be used by calling scripts to gracefully stop processing and save partial results.
    
    .EXAMPLE
    if (Test-RateLimitExceeded) {
        Write-Host "Rate limit exceeded, saving partial results and exiting gracefully"
        Save-PartialStatusUpdate -processedForks $forks -chunkId $chunkId
        exit 0
    }
#>
function Test-RateLimitExceeded {
    return $global:RateLimitExceeded
}

function Get-TokenExpirationTime {
    Param (
        [Parameter(Mandatory=$true)]
        $access_token
    )
    
    # NOTE: GitHub API does not return token expiration information in response headers.
    # The 'GitHub-Authentication-Token-Expiration' header does not exist.
    # 
    # Token expiration time is only available when the token is first created
    # via the Get-GitHubAppInstallationToken function, which returns an 'expiresAt' field.
    # 
    # This function is kept for backwards compatibility but will always return null.
    # Use Get-GitHubAppRateLimitOverview to get expiration information for configured apps,
    # or track the expiresAt value from token creation.
    
    Write-Debug "Get-TokenExpirationTime: GitHub API does not provide token expiration in response headers. This function will always return null."
    return $null
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
        $percentage = if ($existingForks.Count -gt 0) { [math]::Round(($existingForksWithRepoInfo.Count / $existingForks.Count) * 100, 2) } else { 0 }
        Write-Message -message "Found [$(DisplayIntWithDots $existingForksWithRepoInfo.Count) out of $(DisplayIntWithDots $existingForks.Count)] repos that have repo information (${percentage}%)" -logToSummary $true
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
    # initialize lastIndex for optimized forward scanning
    $lastIndex = 0
    if ($existingForksNames.Count -eq 0) {
        # nothing to filter against, return the flattened list as-is
        return $actionsToProcess
    }
    # filter the actions list down to the set we still need to fork (not known in the existingForks list)
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

    Write-Message -message "Skipped [$(DisplayIntWithDots $skipping)] repos as they were checked less than 72 hours ago" -logToSummary $true
    Write-Message -message "Found [$(DisplayIntWithDots $vulnerableRepos)] new repos with a total of [$(DisplayIntWithDots $highAlerts)] repos with high alerts" -logToSummary $true
    Write-Message -message "Found [$(DisplayIntWithDots $vulnerableRepos)] new repos with a total of [$(DisplayIntWithDots $criticalAlerts)] repos with critical alerts" -logToSummary $true

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
        [int] $numberOfReposToDo
    )
    
    # Validate that accessToken is not null or empty
    if ([string]::IsNullOrWhiteSpace($accessToken)) {
        Write-Error "Missing GitHub access token (ACCESS_TOKEN). Please ensure the secret is configured in the repository."
        throw "No access token provided, please provide one!"
    }
    
    # Store the given access token as the environment variable GITHUB_TOKEN so that it will be used in the Workflow run
    $env:GITHUB_TOKEN = $accessToken
    
    Write-Host "Got an access token with a length of [$($accessToken.Length)], running for [$($numberOfReposToDo)] repos"
}

function ConvertCommasToDots {
    Param (
        $numberString
    )

    return $numberString -replace ",", "."
}

function DisplayIntWithDots {
    Param (
        [int] $number
    )
    # enforce the metric notation with dots as thousands separator

    $format = [System.Globalization.NumberFormatInfo]::InvariantInfo.Clone()
    $format.NumberGroupSeparator = "."
    return $number.ToString("N0", $format)
}

function Format-Percentage {
    Param (
        [double] $value
    )

    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:0.00}", $value)
}

function GetFoundSecretCount {
    Param (
        [string] $access_token_destination
    )
    if ([string]::IsNullOrWhiteSpace($access_token_destination)) {
        try {
            if (-not [string]::IsNullOrWhiteSpace($env:APP_ORGANIZATION)) {
                $tokenManager = New-GitHubAppTokenManagerFromEnvironment
                $tokenResult = $tokenManager.GetTokenForOrganization($env:APP_ORGANIZATION)
                $access_token_destination = $tokenResult.Token
            }
            elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
                $access_token_destination = $env:GITHUB_TOKEN
            }
            else {
                throw "No access token provided and no APP_ORGANIZATION or GITHUB_TOKEN configured for GetFoundSecretCount."
            }
        }
        catch {
            Write-Message "Failed to obtain token for secret scanning alerts: $($_.Exception.Message)" -logToSummary $true
            return
        }
    }
    Write-Message "Getting secret scanning alerts" -logToSummary $true

    $url = "/orgs/$forkOrg/secret-scanning/alerts"

    try {
        $alertsResult = ApiCall -method GET -url $url -access_token $access_token_destination -hideFailedCall $false
        Write-Message "" -logToSummary $true
        Write-Message "## Secret scanning alerts" -logToSummary $true
        $totalAlerts = 0

        # summarize the number of alerts per secret_type_display_name
        $alertTypes = @{}
        Write-Message "<details>" -logToSummary $true
        Write-Message "<summary>View secret scanning alerts details</summary>" -logToSummary $true
        Write-Message "" -logToSummary $true
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
        Write-Message "Found [$(DisplayIntWithDots $totalAlerts)] alerts for the organization in [$(DisplayIntWithDots $alertsResult.Length)] repositories" -logToSummary $true
        Write-Message "</details>" -logToSummary $true
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
        $summaryPath = $env:GITHUB_STEP_SUMMARY
        if ($null -ne $summaryPath -and ($summaryPath.Trim()).Length -gt 0) {
            Add-Content -Path $summaryPath -Value $message
        }
    }
}

# Helper functions for conditional step summary logging in chunk processing
function Initialize-ChunkSummaryBuffer {
    <#
    .SYNOPSIS
    Initializes a buffer for collecting chunk processing messages.
    
    .DESCRIPTION
    Creates a hashtable to track chunk processing state including:
    - Messages to potentially log to step summary
    - Whether any errors/warnings occurred
    - Chunk ID for context
    
    .PARAMETER chunkId
    The chunk ID being processed
    
    .EXAMPLE
    $summaryBuffer = Initialize-ChunkSummaryBuffer -chunkId 1
    #>
    param(
        [int] $chunkId
    )
    
    return @{
        ChunkId = $chunkId
        Messages = [System.Collections.ArrayList]@()
        HasErrors = $false
    }
}

function Add-ChunkMessage {
    <#
    .SYNOPSIS
    Adds a message to the chunk summary buffer.
    
    .DESCRIPTION
    Stores a message in the buffer and always writes it to console.
    The message will only be written to step summary if errors occur.
    
    .PARAMETER buffer
    The chunk summary buffer hashtable
    
    .PARAMETER message
    The message to add
    
    .PARAMETER isError
    Whether this message represents an error/warning condition
    
    .EXAMPLE
    Add-ChunkMessage -buffer $summaryBuffer -message "Processing 10 actions"
    Add-ChunkMessage -buffer $summaryBuffer -message "Error: Failed to fork" -isError $true
    #>
    param(
        [hashtable] $buffer,
        [string] $message,
        [bool] $isError = $false
    )
    
    # Always write to console
    Write-Host $message
    
    # Store message in buffer
    [void]$buffer.Messages.Add($message)
    
    # Track if this is an error
    if ($isError) {
        $buffer.HasErrors = $true
    }
}

function Write-ChunkSummary {
    <#
    .SYNOPSIS
    Conditionally writes chunk messages to the step summary.
    
    .DESCRIPTION
    If errors occurred during chunk processing, writes all buffered messages
    to the GitHub Step Summary. Otherwise, messages remain only in job logs.
    
    .PARAMETER buffer
    The chunk summary buffer hashtable
    
    .EXAMPLE
    Write-ChunkSummary -buffer $summaryBuffer
    #>
    param(
        [hashtable] $buffer
    )
    
    if ($buffer.HasErrors) {
        # Write all buffered messages to step summary since there were errors
        $summaryPath = $env:GITHUB_STEP_SUMMARY
        if ($null -ne $summaryPath -and ($summaryPath.Trim()).Length -gt 0) {
            Write-Host "Errors detected in chunk $($buffer.ChunkId), writing summary to step output"
            foreach ($msg in $buffer.Messages) {
                Add-Content -Path $summaryPath -Value $msg
            }
        }
    } else {
        Write-Host "Chunk $($buffer.ChunkId) completed successfully, summary only in job logs"
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
        
        # Normalize date fields to ensure consistent DateTime objects
        Write-Host "Normalizing date fields in status data..."
        $status = Normalize-ActionDates -actions $status
        
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

    if ($null -ne $actions) {
        Write-Host "Updating actions with split RepoUrl from the list of [$($actions.Count)] actions"
        if ($actions.Count -gt 0) {
            Write-Host "This is the first action on the list: "
            Write-Host "$(($actions[0] | ConvertTo-Json))"
        }

        # Track actions where we successfully derived a RepoUrl from the marketplace Url
        $derivedRepoUrlActions = @()

        # prep the actions file so that we only have to split the RepoUrl once
        $counter = 0
        foreach ($actionStatus in $actions){
            # Support both RepoUrl (marketplace data) and repoUrl (internal data)
            $repoUrlValue = if ($null -ne $actionStatus.RepoUrl -and $actionStatus.RepoUrl -ne "") { $actionStatus.RepoUrl }
                            elseif ($null -ne $actionStatus.repoUrl -and $actionStatus.repoUrl -ne "") { $actionStatus.repoUrl }
                            else { $null }

            # If RepoUrl is missing but we have a marketplace Url, try to derive the repo from Url + Publisher
            if ($null -eq $repoUrlValue) {
                $marketplaceUrl = $null
                if ($null -ne $actionStatus.Url -and $actionStatus.Url -ne "") {
                    $marketplaceUrl = $actionStatus.Url
                }
                elseif ($null -ne $actionStatus.URL -and $actionStatus.URL -ne "") {
                    $marketplaceUrl = $actionStatus.URL
                }

                if ($null -ne $marketplaceUrl -and $marketplaceUrl.StartsWith("https://github.com/marketplace/actions/")) {
                    $publisher = $actionStatus.Publisher
                    if (-not [string]::IsNullOrWhiteSpace($publisher)) {
                        $slug = $null
                        try {
                            $uri = [System.Uri]$marketplaceUrl
                            if ($uri.Segments.Count -gt 0) {
                                $slug = $uri.Segments[$uri.Segments.Count - 1].Trim('/')
                            }
                        }
                        catch {
                            $parts = $marketplaceUrl.TrimEnd('/') -split '/'
                            if ($parts.Length -gt 0) {
                                $slug = $parts[$parts.Length - 1]
                            }
                        }

                        if (-not [string]::IsNullOrWhiteSpace($slug)) {
                            $candidateRepo = "$publisher/$slug"
                            $contextInfo = "Checking derived repoUrl [$candidateRepo] for marketplace action [$marketplaceUrl]"
                            $repoCheck = ApiCall -method GET -url "repos/$candidateRepo" -body $null -expected $null -currentResultCount 0 -backOff 5 -maxResultCount 0 -hideFailedCall $true -returnErrorInfo $true -access_token $access_token -contextInfo $contextInfo -waitForRateLimit $true

                            # When returnErrorInfo is enabled, ApiCall returns a hashtable with Error=$true on failures
                            $isErrorResult = ($repoCheck -is [hashtable] -and $repoCheck.ContainsKey('Error') -and $repoCheck.Error)
                            if ($null -ne $repoCheck -and -not $isErrorResult) {
                                # Repository exists - record and update the action with a concrete RepoUrl
                                $repoUrlValue = "https://github.com/$candidateRepo"

                                if ($actionStatus.PSObject.Properties["RepoUrl"]) {
                                    $actionStatus.RepoUrl = $repoUrlValue
                                }
                                elseif ($actionStatus.PSObject.Properties["repoUrl"]) {
                                    $actionStatus.repoUrl = $repoUrlValue
                                }
                                else {
                                    $actionStatus | Add-Member -Name RepoUrl -Value $repoUrlValue -MemberType NoteProperty
                                }

                                $title = if ($null -ne $actionStatus.Title -and $actionStatus.Title -ne "") { $actionStatus.Title }
                                         elseif ($null -ne $actionStatus.name -and $actionStatus.name -ne "") { $actionStatus.name }
                                         else { "(no title)" }
                                $publisherDisplay = if ($null -ne $publisher -and $publisher -ne "") { $publisher } else { "(no publisher)" }

                                $derivedRepoUrlActions += [PSCustomObject]@{
                                    Title          = $title
                                    Publisher      = $publisherDisplay
                                    MarketplaceUrl = $marketplaceUrl
                                    Repo           = $candidateRepo
                                }
                            }
                        }
                    }
                }
            }

            if ($null -eq $repoUrlValue) {
                continue
            }

            ($owner, $repo) = SplitUrl -url $repoUrlValue
            # Skip invalid URLs that would produce an underscore-only name
            if ([string]::IsNullOrEmpty($owner) -or [string]::IsNullOrEmpty($repo)) {
                continue
            }
            $actionStatus | Add-Member -Name name -Value (GetForkedRepoName -owner $owner -repo $repo) -MemberType NoteProperty
            $counter++
        }
        Write-Host "Updated [$($counter)] actions with split RepoUrl"

        # Log summary of actions where we successfully derived a RepoUrl from the marketplace Url
        if ($derivedRepoUrlActions.Count -gt 0) {
            $totalDerived = $derivedRepoUrlActions.Count
            $message = "Derived RepoUrl from marketplace Url and verified repository existence for [$(DisplayIntWithDots $totalDerived)] actions"
            Write-Message -message "" -logToSummary $true
            Write-Message -message $message -logToSummary $true
            Write-Message -message "<details>" -logToSummary $true
            $firstToShow = [Math]::Min(10, $totalDerived)
            Write-Message -message "<summary>Derived RepoUrl from marketplace Url (showing first $firstToShow of $totalDerived)</summary>" -logToSummary $true
            Write-Message -message "" -logToSummary $true
            Write-Message -message "| # | Title | Publisher | Marketplace Url | Derived Repo |" -logToSummary $true
            Write-Message -message "| -: | --- | --- | --- | --- |" -logToSummary $true

            for ($i = 0; $i -lt $firstToShow; $i++) {
                $item = $derivedRepoUrlActions[$i]
                $index = $i + 1
                $row = "| $index | $($item.Title) | $($item.Publisher) | $($item.MarketplaceUrl) | $($item.Repo) |"
                Write-Message -message $row -logToSummary $true
            }

            Write-Message -message "</details>" -logToSummary $true
            Write-Message -message "" -logToSummary $true
        }
    }

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

    $missingNameNoRepoUrlCount = 0
    foreach ($action in $actions) {
        # check if action is already in $statusTable
        # guard against null/empty names to avoid null index errors
        if ([string]::IsNullOrWhiteSpace($action.name)) {
            $hasRepoUrl = $null -ne $action.RepoUrl -and $action.RepoUrl -ne ""
            $hasLowerRepoUrl = $null -ne $action.repoUrl -and $action.repoUrl -ne ""

            if (-not $hasRepoUrl -and -not $hasLowerRepoUrl) {
                # Many marketplace entries simply have no repository URL; skip quietly
                $missingNameNoRepoUrlCount++
            }
            else {
                $repoUrlValue = if ($hasRepoUrl) { $action.RepoUrl } else { $action.repoUrl }
                Write-Host "Skipping action with missing name from RepoUrl: [$repoUrlValue]"
            }
            continue
        }
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

    if ($missingNameNoRepoUrlCount -gt 0) {
        Write-Host "Skipped [$missingNameNoRepoUrlCount] actions with missing name and no RepoUrl/repoUrl"
    }

    return ($status, $failedForks)
}


<#
    .DESCRIPTION
    Wrapper that retrieves a GitHub App installation token. Either supply the installationId
    directly or provide the organization login so the installation can be resolved dynamically.
#>
function Get-TokenFromApp {
    param (
        [Parameter(Mandatory=$true)]
        [string] $appId,
        [string] $installationId,
        [Parameter(Mandatory=$true)]
        [string] $pemKey,
        [string] $targetAccountLogin,
        [switch] $returnFullInfo
    )

    if ([string]::IsNullOrWhiteSpace($appId)) {
        throw "GitHub App ID is required to request an installation token"
    }

    if ([string]::IsNullOrWhiteSpace($pemKey)) {
        throw "GitHub App private key is required to request an installation token"
    }

    $tokenInfo = Get-GitHubAppInstallationToken -AppId $appId -AppPrivateKey $pemKey -InstallationId $installationId -Organization $targetAccountLogin
    
    if ($returnFullInfo) {
        return $tokenInfo
    }
    
    return $tokenInfo.token
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
    #
    # Merge Conflict Handling:
    # When a merge conflict is detected, the function automatically performs a force update
    # by resetting the mirror to match the upstream repository exactly (git reset --hard).
    # The upstream is always considered the source of truth, and conflicts are resolved
    # by discarding any conflicting changes in the mirror. This ensures mirrors remain
    # accurate copies of upstream sources.
    
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
        git show-ref --verify $upstreamBranchRef 2>&1 | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            # Try master branch if main doesn't exist
            if ($currentBranch -eq "main") {
                $currentBranch = "master"
                $upstreamBranchRef = "refs/remotes/upstream/$currentBranch"
                git show-ref --verify $upstreamBranchRef 2>&1 | Out-Null
            }
        }
        
        if ($LASTEXITCODE -ne 0) {
            # Branch not found in upstream - the upstream might have changed their default branch
            # Query the upstream's actual default branch via API and force reset to it
            Write-Warning "Branch [$currentBranch] not found in upstream. Querying upstream's actual default branch..."
            
            # Get the upstream repository's default branch
            $upstreamDefaultBranch = $null
            try {
                $upstreamRepoInfo = ApiCall -method GET -url "repos/$upstreamOwner/$upstreamRepo" -access_token $access_token -hideFailedCall $true
                if ($null -ne $upstreamRepoInfo -and $null -ne $upstreamRepoInfo.default_branch) {
                    $upstreamDefaultBranch = $upstreamRepoInfo.default_branch
                    Write-Debug "Upstream's default branch is: [$upstreamDefaultBranch]"
                }
            }
            catch {
                Write-Debug "Failed to query upstream's default branch: $($_.Exception.Message)"
            }
            
            # If we found the upstream's default branch and it's different, use it
            if ($null -ne $upstreamDefaultBranch -and $upstreamDefaultBranch -ne $currentBranch) {
                Write-Warning "Upstream default branch is [$upstreamDefaultBranch], but mirror is on [$currentBranch]. Will force reset mirror to match upstream."
                $currentBranch = $upstreamDefaultBranch
                $upstreamBranchRef = "refs/remotes/upstream/$currentBranch"
                
                # Verify the upstream branch exists in our fetched refs before proceeding
                # This is a safety check to ensure the API-provided branch name is valid
                git show-ref --verify $upstreamBranchRef 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Upstream branch [$currentBranch] not found even after querying default branch"
                }
                
                # Force the mirror to use upstream's default branch
                # We'll set the flag to force push and reset later
                $needForcePush = $true
            }
            else {
                throw "Upstream branch [$currentBranch] not found"
            }
        }
        
        # Check if the mirror repo is empty (no commits yet)
        # This happens when a repo was created via API but never had content pushed
        $beforeHash = git rev-parse HEAD 2>&1
        $isEmptyRepo = $false
        if ($LASTEXITCODE -ne 0) {
            # Check if this is because the repo is empty (no commits)
            $errorOutput = $beforeHash | Out-String
            if ($errorOutput -like "*unknown revision*" -or $errorOutput -like "*does not have any commits yet*") {
                Write-Debug "Mirror repository is empty (no commits), will perform initial sync from upstream"
                $isEmptyRepo = $true
                $beforeHash = $null
            }
            else {
                throw "Failed to get current HEAD: $errorOutput"
            }
        }
        
        # Flag to track if we need to force push (e.g., after conflict resolution or branch mismatch)
        # Note: Only initialize if not already set, as it may have been set during branch mismatch detection above
        if ($null -eq $needForcePush) {
            $needForcePush = $false
        }
        
        # If repo is empty, do an initial sync from upstream instead of merge
        if ($isEmptyRepo) {
            Write-Debug "Performing initial sync: resetting to upstream/$currentBranch"
            # Reset the current branch to point to upstream branch (this creates the first commit)
            $resetRef = "refs/remotes/upstream/$currentBranch"
            git reset --hard $resetRef 2>&1 | Out-Null
            
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to reset to upstream branch"
            }
            
            $afterHash = git rev-parse HEAD 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to get HEAD after reset"
            }
        }
        elseif ($needForcePush) {
            # Branch mismatch detected (upstream changed its default branch)
            # Force reset our mirror to match upstream's default branch
            Write-Warning "Force resetting mirror to upstream's default branch [$currentBranch]"
            $resetRef = "refs/remotes/upstream/$currentBranch"
            git reset --hard $resetRef 2>&1 | Out-Null
            
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to force reset to upstream branch [$currentBranch]"
            }
            
            $afterHash = git rev-parse HEAD 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to get HEAD after reset"
            }
        }
        else {
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
                    
                    # Force update the mirror to match upstream (upstream is always correct)
                    Write-Warning "Merge conflict detected. Force updating mirror to match upstream."
                    $resetRef = "refs/remotes/upstream/$currentBranch"
                    $resetResult = git reset --hard $resetRef 2>&1
                    
                    if ($LASTEXITCODE -ne 0) {
                        $resetOutput = $resetResult | Out-String
                        throw "Failed to force reset to upstream after merge conflict: $resetOutput"
                    }
                    
                    Write-Debug "Successfully force updated mirror to match upstream after conflict"
                    $needForcePush = $true
                }
                elseif ($mergeOutput -like "*refusing to merge unrelated histories*") {
                    # Unrelated histories error - the upstream was likely recreated or the branch changed
                    # Abort the merge and force reset to upstream
                    git merge --abort 2>&1 | Out-Null
                    
                    Write-Warning "Unrelated histories detected. Force updating mirror to match upstream."
                    $resetRef = "refs/remotes/upstream/$currentBranch"
                    $resetResult = git reset --hard $resetRef 2>&1
                    
                    if ($LASTEXITCODE -ne 0) {
                        $resetOutput = $resetResult | Out-String
                        throw "Failed to force reset to upstream after unrelated histories: $resetOutput"
                    }
                    
                    Write-Debug "Successfully force updated mirror to match upstream after unrelated histories"
                    $needForcePush = $true
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
        }
        
        # Disable GitHub Actions before pushing changes to prevent workflows from running
        Write-Debug "Disabling GitHub Actions for [$owner/$repo] before push"
        $disableResult = Disable-GitHubActions -owner $owner -repo $repo -access_token $access_token
        if (-not $disableResult) {
            Write-Warning "Could not disable GitHub Actions for [$owner/$repo], continuing with push anyway"
        }
        
        # Push changes back to mirror using explicit branch reference with retry
        # Use force push if we did a force reset (e.g., after conflict resolution)
        if ($needForcePush) {
            Write-Debug "Pushing changes to mirror with --force (after conflict resolution)"
            $pushRef = "HEAD:refs/heads/$currentBranch"
            $pushResult = Invoke-GitCommandWithRetry -GitCommand "push" -GitArguments @("--force", "origin", $pushRef) -Description "Force push to mirror"
        }
        else {
            Write-Debug "Pushing changes to mirror"
            $pushRef = "HEAD:refs/heads/$currentBranch"
            $pushResult = Invoke-GitCommandWithRetry -GitCommand "push" -GitArguments @("origin", $pushRef) -Description "Push to mirror"
        }
        
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
        
        # Return appropriate message based on whether this was an initial sync, merge, or force update
        if ($isEmptyRepo) {
            $message = "Successfully performed initial sync from upstream"
            $mergeType = "initial_sync"
        }
        elseif ($needForcePush) {
            $message = "Successfully force updated from upstream (resolved merge conflict)"
            $mergeType = "force_update"
        }
        else {
            $message = "Successfully fetched and merged from upstream"
            $mergeType = "merge"
        }
        
        return @{
            success = $true
            message = $message
            merge_type = $mergeType
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
    Only includes forks that have mirrorFound = true.
    Returns a hashtable mapping chunk index to the list of fork names.
    
    .PARAMETER existingForks
    The full list of forks from status.json
    
    .PARAMETER numberOfChunks
    The number of chunks to split the work into (corresponds to matrix job count)
    
    .EXAMPLE
    $chunks = Split-ForksIntoChunks -existingForks $forks -numberOfChunks 4
#>
<#
    .SYNOPSIS
    Splits actions into chunks for parallel processing.
    
    .DESCRIPTION
    Splits the actions array into multiple chunks for parallel processing.
    Each chunk contains action names that should be processed together.
    
    .PARAMETER actions
    The array of action objects to split
    
    .PARAMETER numberOfChunks
    Number of chunks to create (default: 4)
    
    .PARAMETER filterToUnprocessed
    If true, filter to only actions that need processing (mirrorFound = true and repoUrl exists)
    
    .EXAMPLE
    $chunks = Split-ActionsIntoChunks -actions $actions -numberOfChunks 4
#>
function Split-ActionsIntoChunks {
    Param (
        $actions,
        [int] $numberOfChunks = 4,
        [bool] $filterToUnprocessed = $false
    )
    
    Write-Message -message "Splitting actions into [$(DisplayIntWithDots $numberOfChunks)] chunks for parallel processing" -logToSummary $true
    
    $actionsToProcess = $actions
    
    # Optionally filter to actions with repoUrl
    if ($filterToUnprocessed) {
        $actionsToProcess = $actions | Where-Object { 
            $null -ne $_.repoUrl -and $_.repoUrl -ne ""
        }
    }
    
    if ($actionsToProcess.Count -eq 0) {
        Write-Message -message "No actions to process" -logToSummary $true
        return @{}
    }
    
    Write-Message -message "Found [$(DisplayIntWithDots $actionsToProcess.Count)] actions to process out of [$(DisplayIntWithDots $actions.Count)] total" -logToSummary $true
    
    # Calculate chunk size (round up to ensure all items are included)
    $chunkSize = [Math]::Ceiling($actionsToProcess.Count / $numberOfChunks)
    Write-Message -message "Each chunk will process up to [$(DisplayIntWithDots $chunkSize)] actions" -logToSummary $true
    
    # Split into chunks
    $chunks = @{}
    for ($i = 0; $i -lt $numberOfChunks; $i++) {
        $startIndex = $i * $chunkSize
        $endIndex = [Math]::Min(($startIndex + $chunkSize - 1), ($actionsToProcess.Count - 1))
        
        if ($startIndex -lt $actionsToProcess.Count) {
            # Get the subset of action names for this chunk
            $chunkActions = @()
            for ($j = $startIndex; $j -le $endIndex; $j++) {
                $action = $actionsToProcess[$j]
                $identifier = $null
                
                # Try forkedRepoName first (used for actions from actions.json)
                if ($null -ne $action.forkedRepoName -and $action.forkedRepoName -ne "") {
                    $identifier = $action.forkedRepoName
                }
                # Fall back to name property (used for status.json entries)
                elseif ($null -ne $action.name -and $action.name -ne "") {
                    $identifier = $action.name
                }
                # Fall back to computing from RepoUrl or repoUrl (used for marketplace actions)
                else {
                    $repoUrlValue = if ($null -ne $action.RepoUrl -and $action.RepoUrl -ne "") { $action.RepoUrl } 
                                   elseif ($null -ne $action.repoUrl -and $action.repoUrl -ne "") { $action.repoUrl } 
                                   else { $null }
                    
                    if ($null -ne $repoUrlValue) {
                        ($owner, $repo) = SplitUrl -url $repoUrlValue
                        if ($null -ne $owner -and $null -ne $repo) {
                            $identifier = GetForkedRepoName -owner $owner -repo $repo
                        }
                        else {
                            Write-Warning "Action at index $j has RepoUrl/repoUrl but could not extract owner/repo: $repoUrlValue"
                        }
                    }
                }
                
                if ($null -ne $identifier) {
                    $chunkActions += $identifier
                }
                else {
                    Write-Warning "Action at index $j has no valid identifier (no name, forkedRepoName, or RepoUrl/repoUrl)"
                }
            }
            
            $chunks[$i] = $chunkActions
            Write-Message -message "Chunk [$i]: [$(DisplayIntWithDots $chunkActions.Count)] actions (indices $startIndex-$endIndex)" -logToSummary $true
        }
    }
    
    # Check if we actually created any chunks with work
    $totalActionsInChunks = 0
    foreach ($chunkId in $chunks.Keys) {
        $totalActionsInChunks += $chunks[$chunkId].Count
    }
    
    if ($totalActionsInChunks -eq 0 -and $actionsToProcess.Count -gt 0) {
        Write-Message -message "⚠️ WARNING: No actions were added to chunks. This may indicate a problem with action identifiers." -logToSummary $true
        Write-Message -message "Actions have the following properties: $($actionsToProcess[0].PSObject.Properties.Name -join ', ')" -logToSummary $true
    }
    elseif ($totalActionsInChunks -eq 0) {
        Write-Message -message "ℹ️ No work to be done - no actions to process" -logToSummary $true
    }
    else {
        Write-Message -message "✓ Successfully distributed [$(DisplayIntWithDots $totalActionsInChunks)] actions across [$(DisplayIntWithDots $chunks.Keys.Count)] chunks" -logToSummary $true
    }
    
    return $chunks
}

<#
    .SYNOPSIS
    Selects forks to process with prioritization based on last sync time and cool-off periods.
    
    .DESCRIPTION
    Filters and sorts forks to ensure:
    - Only forks with mirrorFound = true are selected
    - Forks that haven't been synced recently are prioritized
    - Failed sync attempts respect a cool-off period before retry
    - Upstream unavailable repos are skipped
    
    .PARAMETER existingForks
    The complete array of fork objects from status.json
    
    .PARAMETER numberOfRepos
    Maximum number of repos to select for processing
    
    .PARAMETER coolOffHoursForFailedSync
    Hours to wait before retrying a failed sync attempt (default: 24)
    
    .EXAMPLE
    $selectedForks = Select-ForksToProcess -existingForks $allForks -numberOfRepos 300 -coolOffHoursForFailedSync 24
#>
function Select-ForksToProcess {
    Param (
        $existingForks,
        [int] $numberOfRepos = 300,
        [int] $coolOffHoursForFailedSync = 24
    )
    
    $now = Get-Date
    $coolOffThreshold = $now.AddHours(-$coolOffHoursForFailedSync)
    
    Write-Message -message "Selecting up to [$(DisplayIntWithDots $numberOfRepos)] forks to process" -logToSummary $true
    Write-Message -message "Cool-off period for failed syncs: [$(DisplayIntWithDots $coolOffHoursForFailedSync)] hours" -logToSummary $true
    
    # Track filtering statistics
    $totalForks = $existingForks.Count
    $filteredNoMirror = 0
    $filteredUpstreamUnavailable = 0
    $filteredCoolOff = 0
    
    # First pass: count each filter reason and collect eligible forks
    # Use generic List for better performance and type safety with large datasets
    $eligibleForks = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($fork in $existingForks) {
        # Must have a mirror
        if ($fork.mirrorFound -ne $true) {
            $filteredNoMirror++
            continue
        }
        
        # Skip if upstream is marked as unavailable
        if ($fork.upstreamAvailable -eq $false) {
            $filteredUpstreamUnavailable++
            continue
        }
        
        # Check cool-off period for failed syncs
        if ($fork.lastSyncError -and $fork.lastSyncAttempt) {
            try {
                $lastAttempt = [DateTime]::Parse($fork.lastSyncAttempt)
                if ($lastAttempt -gt $coolOffThreshold) {
                    # Still in cool-off period
                    $filteredCoolOff++
                    continue
                }
            } catch {
                # If we can't parse the date, include it to be safe (safer to retry than skip)
                Write-Debug "Failed to parse lastSyncAttempt for [$($fork.name)]: $($fork.lastSyncAttempt)"
            }
        }
        
        # This fork passed all filters
        [void]$eligibleForks.Add($fork)
    }
    
    # Display filtering statistics
    Write-Message -message "" -logToSummary $true
    Write-Message -message "### Fork Selection Filtering Results" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "| Filter Reason | Count |" -logToSummary $true
    Write-Message -message "|--------------|------:|" -logToSummary $true
    Write-Message -message "| Total forks in dataset | $(DisplayIntWithDots $totalForks) |" -logToSummary $true
    Write-Message -message "| Filtered: No mirror found | $(DisplayIntWithDots $filteredNoMirror) |" -logToSummary $true
    Write-Message -message "| Filtered: Upstream unavailable | $(DisplayIntWithDots $filteredUpstreamUnavailable) |" -logToSummary $true
    Write-Message -message "| Filtered: In cool-off period (failed < ${coolOffHoursForFailedSync}h ago) | $(DisplayIntWithDots $filteredCoolOff) |" -logToSummary $true
    Write-Message -message "| **Eligible forks after filtering** | **$(DisplayIntWithDots $eligibleForks.Count)** |" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Sort: never-synced forks first (by name), then synced forks by oldest lastSynced (then by name)
    $sortedForks = $eligibleForks | Sort-Object -Property @(
        # Primary: Never-synced first (0), then synced (1)
        @{ Expression = { if ($_.lastSynced) { 1 } else { 0 } }; Ascending = $true },
        # Secondary: For never-synced, use name for stable order; for synced, use lastSynced
        @{ Expression = {
            if ($_.lastSynced) {
                try {
                    return [DateTime]::Parse($_.lastSynced).Ticks
                } catch {
                    return [int64]::MaxValue
                }
            } else {
                # Use name as a tiebreaker for never-synced
                return [int64]::MinValue
            }
        }; Ascending = $true },
        # Tertiary: Always use name as final tiebreaker
        @{ Expression = { $_.name }; Ascending = $true }
    )

    # Apply failure penalty deprioritization while preserving the priority order above
    # This allows us to move recently-failed repos to the end while preserving
    # the never-synced vs synced hierarchy
    $forksWithPenalty = [System.Collections.Generic.List[PSObject]]::new()
    $forksNoPenalty = [System.Collections.Generic.List[PSObject]]::new()
    
    foreach ($fork in $sortedForks) {
        $hasPenalty = $false
        
        # Check if this fork has a recent failure that should deprioritize it
        if ($fork.lastSyncError -and $fork.lastSyncAttempt) {
            try {
                $lastAttemptDate = [DateTime]::Parse($fork.lastSyncAttempt)
                $hoursSinceAttempt = ($now - $lastAttemptDate).TotalHours
                
                # Determine if this is a repeated failure
                $isRepeatedFailure = $false
                if ($fork.lastSynced) {
                    try {
                        $lastSyncDate = [DateTime]::Parse($fork.lastSynced)
                        if ($lastAttemptDate -gt $lastSyncDate) {
                            $isRepeatedFailure = $true
                        }
                    } catch {
                        $isRepeatedFailure = $true
                    }
                } else {
                    # Never had a successful sync
                    $isRepeatedFailure = $true
                }
                
                # Apply penalty if it's a repeated failure within the last 7 days
                if ($isRepeatedFailure -and $hoursSinceAttempt -lt 168) {
                    $hasPenalty = $true
                }
            } catch {
                Write-Debug "Failed to parse lastSyncAttempt for penalty calculation: $($fork.lastSyncAttempt)"
            }
        }
        
        if ($hasPenalty) {
            [void]$forksWithPenalty.Add($fork)
        } else {
            [void]$forksNoPenalty.Add($fork)
        }
    }
    
    # Final sorted list: forks without penalty first, then forks with penalty
    $sortedForks = $forksNoPenalty + $forksWithPenalty
    
    $actualSelectCount = [Math]::Min($numberOfRepos, $sortedForks.Count)
    $selectedForks = $sortedForks | Select-Object -First $actualSelectCount
    
    # Calculate statistics about selection
    $reposWithRecentFailures = ($eligibleForks | Where-Object { 
        if ($_.lastSyncError -and $_.lastSyncAttempt -and $_.lastSynced) {
            try {
                $lastAttemptDate = [DateTime]::Parse($_.lastSyncAttempt)
                $lastSyncDate = [DateTime]::Parse($_.lastSynced)
                # Has a recent failure (attempt is more recent than last success)
                return $lastAttemptDate -gt $lastSyncDate
            } catch {
                return $false
            }
        }
        return $false
    }).Count
    
    Write-Message -message "### Fork Selection Summary" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "- **Requested:** [$(DisplayIntWithDots $numberOfRepos)] forks" -logToSummary $true
    Write-Message -message "- **Selected:** [$(DisplayIntWithDots $selectedForks.Count)] forks for processing" -logToSummary $true
    
    if ($selectedForks.Count -lt $numberOfRepos) {
        $shortage = $numberOfRepos - $selectedForks.Count
        Write-Message -message "- ⚠️ **Note:** Only [$(DisplayIntWithDots $selectedForks.Count)] eligible forks available ([$(DisplayIntWithDots $shortage)] fewer than requested)" -logToSummary $true
        Write-Message -message "  - To process more repos, wait for cool-off period to expire or resolve upstream issues" -logToSummary $true
    }
    
    Write-Message -message "- Eligible forks with recent failures: [$(DisplayIntWithDots $reposWithRecentFailures)] (deprioritized by smart sorting)" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    return $selectedForks
}

function Split-ForksIntoChunks {
    Param (
        $existingForks,
        [int] $numberOfChunks = 4
    )
    
    Write-Message -message "Splitting forks into [$(DisplayIntWithDots $numberOfChunks)] chunks for parallel processing" -logToSummary $true
    
    # Filter to only forks that should be processed (mirrorFound = true)
    $forksToProcess = $existingForks | Where-Object { $_.mirrorFound -eq $true }
    
    if ($forksToProcess.Count -eq 0) {
        Write-Message -message "No forks to process (all have mirrorFound = false)" -logToSummary $true
        return @{}
    }
    
    Write-Message -message "Found [$(DisplayIntWithDots $forksToProcess.Count)] forks to process out of [$(DisplayIntWithDots $existingForks.Count)] total" -logToSummary $true
    
    # Calculate chunk size (round up to ensure all items are included)
    $chunkSize = [Math]::Ceiling($forksToProcess.Count / $numberOfChunks)
    Write-Message -message "Each chunk will process up to [$(DisplayIntWithDots $chunkSize)] forks" -logToSummary $true
    
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
            Write-Message -message "Chunk [$i]: [$(DisplayIntWithDots $chunkForks.Count)] forks (indices $startIndex-$endIndex)" -logToSummary $true
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
    
    Write-Message -message "Saving [$(DisplayIntWithDots $processedForks.Count)] processed forks for chunk [$chunkId]" -logToSummary $true
    
    # Convert to JSON and save
    $json = ConvertTo-Json -InputObject $processedForks -Depth 10
    [System.IO.File]::WriteAllText($outputPath, $json, [System.Text.Encoding]::UTF8)
    
    Write-Message -message "✓ Saved partial status for chunk [$chunkId]" -logToSummary $true
    return $true
}

<#
    .SYNOPSIS
    Saves chunk summary statistics to a JSON file for artifact upload.
    
    .DESCRIPTION
    Saves the processing summary statistics for a chunk (synced, failed, up-to-date, etc.)
    to a JSON file that can be uploaded as an artifact and later merged to show overall statistics.
    
    .PARAMETER chunkId
    The chunk ID for this summary
    
    .PARAMETER synced
    Number of successfully synced mirrors
    
    .PARAMETER upToDate
    Number of mirrors already up to date
    
    .PARAMETER conflicts
    Number of mirrors with merge conflicts
    
    .PARAMETER upstreamNotFound
    Number of mirrors where upstream was not found
    
    .PARAMETER failed
    Number of mirrors that failed to sync
    
    .PARAMETER skipped
    Number of mirrors that were skipped
    
    .PARAMETER totalProcessed
    Total number of mirrors processed
    
    .PARAMETER failedRepos
    Array of failed repos with details (name, errorType, errorMessage)
    
    .PARAMETER outputPath
    The file path to save the summary (defaults to chunk-summary-{chunkId}.json)
    
    .EXAMPLE
    Save-ChunkSummary -chunkId 0 -synced 3 -upToDate 147 -conflicts 0 -upstreamNotFound 0 -failed 0 -skipped 0 -totalProcessed 150
#>
function Save-ChunkSummary {
    Param (
        [int] $chunkId,
        [int] $synced = 0,
        [int] $upToDate = 0,
        [int] $mirrorsCreated = 0,
        [int] $conflicts = 0,
        [int] $upstreamNotFound = 0,
        [int] $failed = 0,
        [int] $skipped = 0,
        [int] $totalProcessed = 0,
        [array] $failedRepos = @(),
        [string] $outputPath = "chunk-summary-$chunkId.json"
    )
    
    $summary = @{
        chunkId = $chunkId
        synced = $synced
        upToDate = $upToDate
        mirrorsCreated = $mirrorsCreated
        conflicts = $conflicts
        upstreamNotFound = $upstreamNotFound
        failed = $failed
        skipped = $skipped
        totalProcessed = $totalProcessed
        failedRepos = $failedRepos
    }
    
    Write-Host "Saving chunk [$chunkId] summary to [$outputPath]"
    
    # Convert to JSON and save
    $json = ConvertTo-Json -InputObject $summary -Depth 5
    [System.IO.File]::WriteAllText($outputPath, $json, [System.Text.Encoding]::UTF8)
    
    Write-Host "✓ Saved chunk summary for chunk [$chunkId]"
    return $true
}

<#
    .SYNOPSIS
    Merges chunk summary JSON files and displays consolidated statistics.
    
    .DESCRIPTION
    Loads all chunk summary JSON files, aggregates the statistics, and displays
    an overall summary table in the GitHub Step Summary.
    
    .PARAMETER chunkSummaryFiles
    Array of file paths to chunk summary JSON files
    
    .EXAMPLE
    Show-ConsolidatedChunkSummary -chunkSummaryFiles @("chunk-summary-0.json", "chunk-summary-1.json")
#>
function Show-ConsolidatedChunkSummary {
    Param (
        [string[]] $chunkSummaryFiles
    )
    
    Write-Message -message "# Overall Chunk Processing Summary" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Initialize totals
    $totalSynced = 0
    $totalUpToDate = 0
    $totalMirrorsCreated = 0
    $totalConflicts = 0
    $totalUpstreamNotFound = 0
    $totalFailed = 0
    $totalSkipped = 0
    $totalProcessed = 0
    
    # Initialize failure breakdown tracking
    $failuresByType = @{}
    $allFailedRepos = @()
    
    if ($null -eq $chunkSummaryFiles -or $chunkSummaryFiles.Count -eq 0) {
        Write-Message -message "No chunk summary files found" -logToSummary $true
        # Return consistent structure with zero values
        return @{
            synced = $totalSynced
            upToDate = $totalUpToDate
            mirrorsCreated = $totalMirrorsCreated
            conflicts = $totalConflicts
            upstreamNotFound = $totalUpstreamNotFound
            failed = $totalFailed
            skipped = $totalSkipped
            totalProcessed = $totalProcessed
        }
    }
    
    # Load and aggregate all chunk summaries
    foreach ($summaryFile in $chunkSummaryFiles) {
        if (-not (Test-Path $summaryFile)) {
            Write-Warning "Chunk summary file not found: [$summaryFile]"
            continue
        }
        
        Write-Host "Loading chunk summary from: [$summaryFile]"
        
        try {
            $jsonContent = Get-Content $summaryFile -Raw
            # Remove UTF-8 BOM if present (regex pattern is more reliable than string manipulation)
            $jsonContent = $jsonContent -replace '^\uFEFF', ''
            $chunkSummary = $jsonContent | ConvertFrom-Json
            
            $totalSynced += $chunkSummary.synced
            $totalUpToDate += $chunkSummary.upToDate
            $totalMirrorsCreated += (if ($chunkSummary.PSObject.Properties["mirrorsCreated"]) { $chunkSummary.mirrorsCreated } else { 0 })
            $totalConflicts += $chunkSummary.conflicts
            $totalUpstreamNotFound += $chunkSummary.upstreamNotFound
            $totalFailed += $chunkSummary.failed
            $totalSkipped += $chunkSummary.skipped
            $totalProcessed += $chunkSummary.totalProcessed
            
            # Collect failed repos if available
            if ($chunkSummary.failedRepos -and $chunkSummary.failedRepos.Count -gt 0) {
                foreach ($failedRepo in $chunkSummary.failedRepos) {
                    $allFailedRepos += $failedRepo
                    
                    # Count by error type for breakdown
                    $errorType = $failedRepo.errorType
                    if ([string]::IsNullOrEmpty($errorType)) {
                        $errorType = "unknown"
                    }
                    
                    if ($failuresByType.ContainsKey($errorType)) {
                        $failuresByType[$errorType] += 1
                    } else {
                        $failuresByType[$errorType] = 1
                    }
                }
            }
            
            Write-Host "  Chunk [$($chunkSummary.chunkId)]: Processed $($chunkSummary.totalProcessed) repos"
        }
        catch {
            Write-Warning "Failed to load chunk summary file [$summaryFile]: $($_.Exception.Message)"
            continue
        }
    }
    
    # Display consolidated summary
    Write-Message -message "Aggregated results from [$(DisplayIntWithDots $chunkSummaryFiles.Count)] chunks:" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "| Status | Count |" -logToSummary $true
    Write-Message -message "|--------|------:|" -logToSummary $true
    Write-Message -message "| ✅ Synced | $(DisplayIntWithDots $totalSynced) |" -logToSummary $true
    Write-Message -message "| ✓ Up to Date | $(DisplayIntWithDots $totalUpToDate) |" -logToSummary $true
    Write-Message -message "| 🆕 Mirrors Created | $(DisplayIntWithDots $totalMirrorsCreated) |" -logToSummary $true
    Write-Message -message "| ⚠️ Conflicts | $(DisplayIntWithDots $totalConflicts) |" -logToSummary $true
    Write-Message -message "| ❌ Upstream Not Found | $(DisplayIntWithDots $totalUpstreamNotFound) |" -logToSummary $true
    Write-Message -message "| ❌ Failed | $(DisplayIntWithDots $totalFailed) |" -logToSummary $true
    Write-Message -message "| ⏭️ Skipped | $(DisplayIntWithDots $totalSkipped) |" -logToSummary $true
    Write-Message -message "| **Total Processed** | **$(DisplayIntWithDots $totalProcessed)** |" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Display failure breakdown if there are failures
    if ($failuresByType.Count -gt 0) {
        Write-Message -message "## Failure Breakdown by Category" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        Write-Message -message "| Error Type | Count |" -logToSummary $true
        Write-Message -message "|------------|------:|" -logToSummary $true
        
        # Sort by count descending for better visibility
        $sortedFailures = $failuresByType.GetEnumerator() | Sort-Object -Property Value -Descending
        foreach ($entry in $sortedFailures) {
            Write-Message -message "| $($entry.Key) | $($entry.Value) |" -logToSummary $true
        }
        Write-Message -message "" -logToSummary $true
    }
    
    # Display first 10 failed repos with clickable links in a collapsible section
    if ($allFailedRepos.Count -gt 0) {
        Write-Message -message "## Failed Repositories" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        Write-Message -message "Total failed repositories: **$(DisplayIntWithDots $allFailedRepos.Count)**" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        Write-Message -message "<details>" -logToSummary $true
        Write-Message -message "<summary>Click to view first 10 failed repositories</summary>" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        Write-Message -message "| Repository | Upstream | Error Type | Error Message |" -logToSummary $true
        Write-Message -message "|------------|----------|------------|---------------|" -logToSummary $true
        
        # Take first 10 repos
        $first10Failed = $allFailedRepos | Select-Object -First 10
        foreach ($failedRepo in $first10Failed) {
            $repoName = $failedRepo.name
            $errorType = $failedRepo.errorType
            $errorMessage = $failedRepo.errorMessage
            
            # Create clickable GitHub link using the configured fork organization
            $repoLink = "[$repoName](https://github.com/$forkOrg/$repoName)"
            
            # Parse the mirror name to extract upstream owner and repo
            ($upstreamOwner, $upstreamRepo) = GetOrgActionInfo -forkedOwnerRepo $repoName
            $upstreamLink = "N/A"
            if (-not [string]::IsNullOrEmpty($upstreamOwner) -and -not [string]::IsNullOrEmpty($upstreamRepo)) {
                $upstreamLink = "[$upstreamOwner/$upstreamRepo](https://github.com/$upstreamOwner/$upstreamRepo)"
            }
            
            # Truncate error message if too long
            if ($errorMessage -and $errorMessage.Length -gt 100) {
                $errorMessage = $errorMessage.Substring(0, 97) + "..."
            }
            
            Write-Message -message "| $repoLink | $upstreamLink | $errorType | $errorMessage |" -logToSummary $true
        }
        
        Write-Message -message "" -logToSummary $true
        Write-Message -message "</details>" -logToSummary $true
        Write-Message -message "" -logToSummary $true
    }
    
    return @{
        synced = $totalSynced
        upToDate = $totalUpToDate
        mirrorsCreated = $totalMirrorsCreated
        conflicts = $totalConflicts
        upstreamNotFound = $totalUpstreamNotFound
        failed = $totalFailed
        skipped = $totalSkipped
        totalProcessed = $totalProcessed
    }
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
    
    Write-Message -message "Merging partial status updates from [$(DisplayIntWithDots $partialStatusFiles.Count)] chunks" -logToSummary $true
    
    # Create a hashtable for fast lookup by name
    $statusByName = @{}
    foreach ($item in $currentStatus) {
        $statusByName[$item.name] = $item
    }
    
    $totalUpdates = 0
    
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
            
            # Merge each updated fork from the partial status into the current status
            foreach ($updatedFork in $partialStatus) {
                if ($statusByName.ContainsKey($updatedFork.name)) {
                    # Update existing entry by copying properties from the updated fork
                    $existing = $statusByName[$updatedFork.name]
                    
                    $updatedFork.PSObject.Properties | ForEach-Object {
                        $propName = $_.Name
                        $propValue = $_.Value
                        
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
    
    Write-Message -message "✓ Merged [$(DisplayIntWithDots $totalUpdates)] fork updates from [$(DisplayIntWithDots $partialStatusFiles.Count)] chunks into main status" -logToSummary $true
    
    # Convert hashtable back to array
    return $statusByName.Values
}

<#
    .SYNOPSIS
    Shows overall dataset statistics for the repository mirrors.
    
    .DESCRIPTION
    Calculates and displays statistics about the mirror dataset including:
    - Total repositories in dataset
    - Repositories with valid mirrors (mirrorFound = true)
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
    
    # Count repos with mirrorFound = true (valid mirrors)
    # Wrap in @() to ensure it's always an array (PowerShell returns single items as scalars)
    $reposWithMirrors = @($existingForks | Where-Object { $_.mirrorFound -eq $true }).Count
    
    # Count repos without mirrors
    $reposWithoutMirrors = $totalRepos - $reposWithMirrors
    
    # Count repos explicitly marked as not having mirrors (mirrorFound = false)
    $reposExplicitlyNoMirror = @($existingForks | Where-Object { 
        $null -ne $_.PSObject.Properties["mirrorFound"] -and $_.mirrorFound -eq $false
    }).Count
    
    # Count repos not yet checked (mirrorFound is null or missing)
    $reposNotYetChecked = @($existingForks | Where-Object { 
        $null -eq $_.PSObject.Properties["mirrorFound"]
    }).Count
    
    # Count repos synced in the last 7 days (only from repos with mirrors)
    # Wrap in @() to ensure it's always an array
    $reposSyncedLast7Days = @($existingForks | Where-Object { 
        if ($_.mirrorFound -ne $true) {
            return $false
        }
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
    
    # Count repos with valid mirrors but no lastSynced timestamp or unparseable timestamp
    $reposNeverSynced = ($existingForks | Where-Object { 
        if ($_.mirrorFound -eq $true) {
            if ([string]::IsNullOrEmpty($_.lastSynced)) {
                return $true
            }
            # Also count repos where lastSynced exists but cannot be parsed
            try {
                [DateTime]::Parse($_.lastSynced) | Out-Null
                return $false
            } catch {
                return $true
            }
        }
        return $false
    }).Count
    
    # Calculate percentages for repos with mirrors
    if ($reposWithMirrors -gt 0) {
        $percentChecked = [math]::Round(($reposSyncedLast7Days / $reposWithMirrors) * 100, 2)
        $percentRemaining = [math]::Round((($reposWithMirrors - $reposSyncedLast7Days) / $reposWithMirrors) * 100, 2)
        $percentNeverSynced = [math]::Round(($reposNeverSynced / $reposWithMirrors) * 100, 2)
    } else {
        $percentChecked = 0
        $percentRemaining = 0
        $percentNeverSynced = 0
    }
    
    # Calculate percentages of total dataset
    $percentWithMirrors = [math]::Round(($reposWithMirrors / $totalRepos) * 100, 2)
    $percentWithoutMirrors = [math]::Round(($reposWithoutMirrors / $totalRepos) * 100, 2)
    
    $reposNotChecked = $reposWithMirrors - $reposSyncedLast7Days
    
    # Display overall repository breakdown
    Write-Message -message "#### Repository Status Breakdown" -logToSummary $true
    Write-Message -message "| Category | Count | Percentage |" -logToSummary $true
    Write-Message -message "|----------|------:|-----------:|" -logToSummary $true
    Write-Message -message "| **Total Repositories in Dataset** | **$(DisplayIntWithDots $totalRepos)** | **100%** |" -logToSummary $true
    Write-Message -message "| └─ Repositories with Valid Mirrors | $(DisplayIntWithDots $reposWithMirrors) | ${percentWithMirrors}% |" -logToSummary $true
    Write-Message -message "| └─ Repositories without Mirrors | $(DisplayIntWithDots $reposWithoutMirrors) | ${percentWithoutMirrors}% |" -logToSummary $true
    
    # Add breakdown of repos without mirrors if we have that data
    if ($reposExplicitlyNoMirror -gt 0 -or $reposNotYetChecked -gt 0) {
        $percentExplicitlyNo = if ($reposWithoutMirrors -gt 0) { [math]::Round(($reposExplicitlyNoMirror / $reposWithoutMirrors) * 100, 2) } else { 0 }
        $percentNotChecked = if ($reposWithoutMirrors -gt 0) { [math]::Round(($reposNotYetChecked / $reposWithoutMirrors) * 100, 2) } else { 0 }
        Write-Message -message "| &nbsp;&nbsp;&nbsp;&nbsp;├─ Confirmed No Mirror | $(DisplayIntWithDots $reposExplicitlyNoMirror) | ${percentExplicitlyNo}% |" -logToSummary $true
        Write-Message -message "| &nbsp;&nbsp;&nbsp;&nbsp;└─ Not Yet Checked | $(DisplayIntWithDots $reposNotYetChecked) | ${percentNotChecked}% |" -logToSummary $true
    }
    
    Write-Message -message "" -logToSummary $true
    
    # Add collapsible section with top 10 repositories without mirrors
    if ($reposWithoutMirrors -gt 0) {
        # Get repos without mirrors
        $reposWithoutMirrorsList = @($existingForks | Where-Object { $_.mirrorFound -ne $true })
        
        # Take top 10 (or fewer if less than 10)
        $top10ReposWithoutMirrors = $reposWithoutMirrorsList | Select-Object -First 10
        
        Write-Message -message "<details>" -logToSummary $true
        Write-Message -message "<summary>Top $(if ($reposWithoutMirrorsList.Count -lt 10) { $reposWithoutMirrorsList.Count } else { 10 }) Repositories without Mirrors</summary>" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        Write-Message -message "| Mirror | Upstream | Reason |" -logToSummary $true
        Write-Message -message "|--------|----------|--------|" -logToSummary $true
        Write-Message -message "| Mirror | Upstream | Reason |" -logToSummary $true
        Write-Message -message "|--------|----------|--------|" -logToSummary $true
        
        foreach ($repo in $top10ReposWithoutMirrors) {
            $repoName = $repo.name
            
            # Create clickable GitHub link for the mirror (using the configured fork organization)
            $mirrorLink = "[$repoName](https://github.com/$forkOrg/$repoName)"
            
            # Parse the mirror name to extract upstream owner and repo
            # Only parse if the name contains an underscore (proper format: owner_repo)
            $upstreamLink = "N/A"
            if ($repoName -match '_') {
                ($upstreamOwner, $upstreamRepo) = GetOrgActionInfo -forkedOwnerRepo $repoName
                if (-not [string]::IsNullOrEmpty($upstreamOwner) -and -not [string]::IsNullOrEmpty($upstreamRepo)) {
                    $upstreamLink = "[$upstreamOwner/$upstreamRepo](https://github.com/$upstreamOwner/$upstreamRepo)"
                }
            }
            
            # Derive a human-readable reason for missing mirror
            $lastSyncError = $repo.PSObject.Properties["lastSyncError"] ? $repo.lastSyncError : $null
            $lastSyncErrorType = $repo.PSObject.Properties["lastSyncErrorType"] ? $repo.lastSyncErrorType : $null
            $upstreamAvailable = $repo.PSObject.Properties["upstreamAvailable"] ? $repo.upstreamAvailable : $null

            $reason = "Not yet checked"
            if ($upstreamAvailable -eq $false -or $lastSyncErrorType -eq "upstream_not_found") {
                $reason = "Upstream missing or renamed"
            }
            elseif ($repo.PSObject.Properties["mirrorFound"] -and $repo.mirrorFound -eq $false) {
                $reason = "Mirror missing after auto-create"
            }
            elseif ($lastSyncErrorType -eq "mirror_name_conflict" -or $lastSyncErrorType -eq "mirror_conflict" -or ($lastSyncError -and ($lastSyncError -match "already exists" -or $lastSyncError -match "name already exists" -or $lastSyncError -match "repository already exists"))) {
                $reason = "Mirror name collision"
            }
            elseif ($repo.PSObject.Properties["mirrorFound"] -and $repo.mirrorFound -ne $true) {
                $reason = "Mirror not found"
            }

            Write-Message -message "| $mirrorLink | $upstreamLink | $reason |" -logToSummary $true
        }
        
        Write-Message -message "" -logToSummary $true
        Write-Message -message "</details>" -logToSummary $true
        Write-Message -message "" -logToSummary $true
    }
    
    Write-Message -message "_Note: **Repositories without mirrors** cannot be synced. This includes:_" -logToSummary $true
    Write-Message -message "- _**Confirmed No Mirror**: Repositories where a mirror is still missing after an auto-create attempt (for example the upstream was deleted or mirror creation failed)_" -logToSummary $true
    Write-Message -message "- _**Not Yet Checked**: Repositories that haven't been processed by the [Get repo info workflow](https://github.com/rajbos/actions-marketplace-checks/actions/workflows/repoInfo.yml) yet, so the auto-create step has not been run_" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "_💡 To increase the number of repositories with known mirror status, focus on the [Get repo info workflow](https://github.com/rajbos/actions-marketplace-checks/actions/workflows/repoInfo.yml), which processes repositories hourly to check their mirror status._" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "#### Last 7 Days Sync Activity (Valid Mirrors Only)" -logToSummary $true
    Write-Message -message "_The following statistics are for the **$(DisplayIntWithDots $reposWithMirrors) repositories with valid mirrors** only:_" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "| Metric | Count | Percentage |" -logToSummary $true
    Write-Message -message "|--------|------:|-----------:|" -logToSummary $true
    Write-Message -message "| ✅ Repos Checked (Last 7 Days) | $(DisplayIntWithDots $reposSyncedLast7Days) | ${percentChecked}% |" -logToSummary $true
    Write-Message -message "| ⏳ Repos Not Checked Yet | $(DisplayIntWithDots $reposNotChecked) | ${percentRemaining}% |" -logToSummary $true
    Write-Message -message "| 🆕 Repos Never Checked | $(DisplayIntWithDots $reposNeverSynced) | ${percentNeverSynced}% |" -logToSummary $true
    Write-Message -message "" -logToSummary $true
}
