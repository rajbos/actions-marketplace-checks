<#
    .SYNOPSIS
    Helper script for manually downloading and uploading JSON files from/to Azure Blob Storage.

    .DESCRIPTION
    This script provides convenient commands for developers to:
    - Download status.json and failedForks.json from blob storage for local testing
    - Upload status.json and failedForks.json back to blob storage after local modifications
    - View the current status.json file info

    .PARAMETER Action
    The action to perform: 'download', 'upload', or 'info'

    .EXAMPLE
    # Download all JSON files from blob storage
    ./blob-helper.ps1 -Action download

    .EXAMPLE
    # Upload all JSON files to blob storage
    ./blob-helper.ps1 -Action upload

    .EXAMPLE
    # Show info about local status.json
    ./blob-helper.ps1 -Action info

    .NOTES
    Requires the BLOB_SAS_TOKEN environment variable to be set.
    Example: $env:BLOB_SAS_TOKEN = 'https://intostorage.blob.core.windows.net/intostorage/actions.json?sv=...'
    
    All files are stored in the 'status' subfolder in blob storage:
    - status/status.json
    - status/failedForks.json
    - status/secretScanningAlerts.json
#>

Param (
    [Parameter(Mandatory=$true)]
    [ValidateSet('download', 'upload', 'info')]
    [string] $Action
)

. $PSScriptRoot/.github/workflows/library.ps1

function Show-StatusInfo {
    Write-Host "=== status.json Information ===" -ForegroundColor Cyan
    
    if (-not (Test-Path $statusFile)) {
        Write-Host "status.json does not exist locally at: $statusFile" -ForegroundColor Yellow
        return
    }
    
    $fileInfo = Get-Item $statusFile
    Write-Host "Local file path: $($fileInfo.FullName)"
    Write-Host "File size: $([math]::Round($fileInfo.Length / 1MB, 2)) MB ($($fileInfo.Length) bytes)"
    Write-Host "Last modified: $($fileInfo.LastWriteTime)"
    
    try {
        $content = Get-Content $statusFile -Raw
        $content = $content -replace '^\uFEFF', ''  # Remove BOM if present
        $json = $content | ConvertFrom-Json
        Write-Host "Number of entries: $($json.Count)"
        
        # Show some statistics if available
        $withRepoInfo = ($json | Where-Object { $null -ne $_.repoInfo }).Count
        $withActionType = ($json | Where-Object { $null -ne $_.actionType }).Count
        $withDependabot = ($json | Where-Object { $_.dependabot -eq $true }).Count
        
        Write-Host ""
        Write-Host "Statistics:" -ForegroundColor Green
        Write-Host "  - With repo info: $withRepoInfo"
        Write-Host "  - With action type: $withActionType"
        Write-Host "  - With Dependabot enabled: $withDependabot"
    }
    catch {
        Write-Host "Could not parse JSON: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    Write-Host ""
    Write-Host "=== failedForks.json Information ===" -ForegroundColor Cyan
    if (Test-Path $failedStatusFile) {
        $fileInfo = Get-Item $failedStatusFile
        Write-Host "Local file path: $($fileInfo.FullName)"
        Write-Host "File size: $([math]::Round($fileInfo.Length / 1KB, 2)) KB ($($fileInfo.Length) bytes)"
        Write-Host "Last modified: $($fileInfo.LastWriteTime)"
    }
    else {
        Write-Host "failedForks.json does not exist locally" -ForegroundColor Yellow
    }
}

# Check for SAS token
if ([string]::IsNullOrWhiteSpace($env:BLOB_SAS_TOKEN)) {
    Write-Host "ERROR: BLOB_SAS_TOKEN environment variable is not set." -ForegroundColor Red
    Write-Host ""
    Write-Host "To use this script, set the BLOB_SAS_TOKEN environment variable:" -ForegroundColor Yellow
    Write-Host '  $env:BLOB_SAS_TOKEN = "https://intostorage.blob.core.windows.net/intostorage/actions.json?sv=..."'
    Write-Host ""
    Write-Host "You can get this token from the Azure Portal or from your team's secrets management." -ForegroundColor Yellow
    
    if ($Action -eq 'info') {
        Write-Host ""
        Show-StatusInfo
    }
    exit 1
}

switch ($Action) {
    'download' {
        Write-Host "Downloading JSON files from Azure Blob Storage..." -ForegroundColor Cyan
        
        Write-Host ""
        $result = Get-StatusFromBlobStorage -sasToken $env:BLOB_SAS_TOKEN
        if ($result) {
            Write-Host "SUCCESS: status.json downloaded successfully!" -ForegroundColor Green
        }
        else {
            Write-Host "WARNING: Could not download status.json" -ForegroundColor Yellow
        }
        
        Write-Host ""
        $result = Get-FailedForksFromBlobStorage -sasToken $env:BLOB_SAS_TOKEN
        if ($result) {
            Write-Host "SUCCESS: failedForks.json downloaded successfully!" -ForegroundColor Green
        }
        else {
            Write-Host "WARNING: Could not download failedForks.json" -ForegroundColor Yellow
        }
        
        Write-Host ""
        Show-StatusInfo
    }
    
    'upload' {
        Write-Host "Uploading JSON files to Azure Blob Storage..." -ForegroundColor Cyan
        
        Write-Host "WARNING: This will overwrite files in blob storage!" -ForegroundColor Yellow
        $confirm = Read-Host "Are you sure you want to upload? (yes/no)"
        if ($confirm -ne 'yes') {
            Write-Host "Upload cancelled." -ForegroundColor Yellow
            exit 0
        }
        
        Write-Host ""
        if (Test-Path $statusFile) {
            $result = Set-StatusToBlobStorage -sasToken $env:BLOB_SAS_TOKEN
            if ($result) {
                Write-Host "SUCCESS: status.json uploaded successfully!" -ForegroundColor Green
            }
            else {
                Write-Host "FAILED: Could not upload status.json" -ForegroundColor Red
            }
        }
        else {
            Write-Host "SKIPPED: status.json does not exist locally" -ForegroundColor Yellow
        }
        
        Write-Host ""
        if (Test-Path $failedStatusFile) {
            $result = Set-FailedForksToBlobStorage -sasToken $env:BLOB_SAS_TOKEN
            if ($result) {
                Write-Host "SUCCESS: failedForks.json uploaded successfully!" -ForegroundColor Green
            }
            else {
                Write-Host "FAILED: Could not upload failedForks.json" -ForegroundColor Red
            }
        }
        else {
            Write-Host "SKIPPED: failedForks.json does not exist locally" -ForegroundColor Yellow
        }
    }
    
    'info' {
        Show-StatusInfo
    }
}
