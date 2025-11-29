<#
    .SYNOPSIS
    Helper script for manually downloading and uploading status.json from/to Azure Blob Storage.

    .DESCRIPTION
    This script provides convenient commands for developers to:
    - Download status.json from blob storage for local testing
    - Upload status.json back to blob storage after local modifications
    - View the current status.json file info

    .PARAMETER Action
    The action to perform: 'download', 'upload', or 'info'

    .EXAMPLE
    # Download status.json from blob storage
    ./blob-helper.ps1 -Action download

    .EXAMPLE
    # Upload status.json to blob storage
    ./blob-helper.ps1 -Action upload

    .EXAMPLE
    # Show info about local status.json
    ./blob-helper.ps1 -Action info

    .NOTES
    Requires the STATUS_BLOB_SAS_TOKEN environment variable to be set.
    Example: $env:STATUS_BLOB_SAS_TOKEN = 'https://intostorage.blob.core.windows.net/intostorage/status.json?sv=...'
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
}

# Check for SAS token
if ([string]::IsNullOrWhiteSpace($env:STATUS_BLOB_SAS_TOKEN)) {
    Write-Host "ERROR: STATUS_BLOB_SAS_TOKEN environment variable is not set." -ForegroundColor Red
    Write-Host ""
    Write-Host "To use this script, set the STATUS_BLOB_SAS_TOKEN environment variable:" -ForegroundColor Yellow
    Write-Host '  $env:STATUS_BLOB_SAS_TOKEN = "https://intostorage.blob.core.windows.net/intostorage/status.json?sv=..."'
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
        Write-Host "Downloading status.json from Azure Blob Storage..." -ForegroundColor Cyan
        $result = Get-StatusFromBlobStorage -sasToken $env:STATUS_BLOB_SAS_TOKEN
        if ($result) {
            Write-Host "SUCCESS: status.json downloaded successfully!" -ForegroundColor Green
            Show-StatusInfo
        }
        else {
            Write-Host "FAILED: Could not download status.json" -ForegroundColor Red
            exit 1
        }
    }
    
    'upload' {
        Write-Host "Uploading status.json to Azure Blob Storage..." -ForegroundColor Cyan
        
        if (-not (Test-Path $statusFile)) {
            Write-Host "ERROR: status.json does not exist at: $statusFile" -ForegroundColor Red
            Write-Host "Nothing to upload. Download first or create the file." -ForegroundColor Yellow
            exit 1
        }
        
        Write-Host "WARNING: This will overwrite the status.json in blob storage!" -ForegroundColor Yellow
        $confirm = Read-Host "Are you sure you want to upload? (yes/no)"
        if ($confirm -ne 'yes') {
            Write-Host "Upload cancelled." -ForegroundColor Yellow
            exit 0
        }
        
        $result = Set-StatusToBlobStorage -sasToken $env:STATUS_BLOB_SAS_TOKEN
        if ($result) {
            Write-Host "SUCCESS: status.json uploaded successfully!" -ForegroundColor Green
        }
        else {
            Write-Host "FAILED: Could not upload status.json" -ForegroundColor Red
            exit 1
        }
    }
    
    'info' {
        Show-StatusInfo
    }
}
