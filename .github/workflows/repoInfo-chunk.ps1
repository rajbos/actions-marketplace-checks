# Chunk processing script for gathering repository information
# This script processes a subset of forked repos for info gathering in parallel with other chunks.
#
# Note on logging: This script uses conditional step summary logging. Messages are always
# written to the job console logs (Write-Host), but are only written to the GitHub
# Step Summary when errors or warnings occur. This keeps the step summary clean when
# everything is working correctly, while still providing visibility when issues arise.

Param (
  $actions,
  $actionNames,  # Array of action names (fork names) to process in this chunk
  [int] $chunkId = 0,
  $access_token = $env:GITHUB_TOKEN,
  [string[]] $appIds = @($env:APP_ID, $env:APP_ID_2) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) },
  [string[]] $appPrivateKeys = @($env:APPLICATION_PRIVATE_KEY, $env:APPLICATION_PRIVATE_KEY_2) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) },
  [string] $appOrganization = $env:APP_ORGANIZATION
)

. $PSScriptRoot/library.ps1
. $PSScriptRoot/dependents.ps1

if ($appPrivateKeys.Count -gt 0 -and $appIds.Count -gt 0) {
    if ([string]::IsNullOrWhiteSpace($appOrganization)) {
        throw "APP_ORGANIZATION must be provided when using GitHub App credentials"
    }

    $tokenManager = New-GitHubAppTokenManager -AppIds $appIds -AppPrivateKeys $appPrivateKeys
    $tokenResult = $tokenManager.GetTokenForOrganization($appOrganization)

    $accessToken = $tokenResult.Token
}
else {
    $accessToken = $access_token
}

Test-AccessTokens -accessToken $accessToken -numberOfReposToDo $actionNames.Count

Import-Module powershell-yaml -Force

function ProcessRepoInfoChunk {
    Param (
        $allActions,
        $actionNamesToProcess,
        [int] $chunkId
    )

    # Initialize summary buffer for conditional logging
    $summaryBuffer = Initialize-ChunkSummaryBuffer -chunkId $chunkId
    
    Add-ChunkMessage -buffer $summaryBuffer -message "# Chunk [$chunkId] - Repo Info Processing"
    Add-ChunkMessage -buffer $summaryBuffer -message "Processing [$($actionNamesToProcess.Count)] forks in this chunk"
    Add-ChunkMessage -buffer $summaryBuffer -message ""
    
    # Get existing forks from status
    $existingForks = @()
    if (Test-Path "status.json") {
        try {
            $statusContent = Get-Content status.json -Raw
            $statusContent = $statusContent -replace '^\uFEFF', ''
            $existingForks = $statusContent | ConvertFrom-Json
        } catch {
            Write-Warning "Could not parse status.json: $($_.Exception.Message)"
            Add-ChunkMessage -buffer $summaryBuffer -message "⚠️ ERROR: Could not parse status.json: $($_.Exception.Message)" -isError $true
            Write-ChunkSummary -buffer $summaryBuffer
            return @()
        }
    } else {
        Write-Warning "status.json not found"
        Add-ChunkMessage -buffer $summaryBuffer -message "⚠️ ERROR: status.json not found" -isError $true
        Write-ChunkSummary -buffer $summaryBuffer
        return @()
    }
    
    # Create a hashtable for fast lookup
    $forksByName = @{}
    foreach ($fork in $existingForks) {
        if ($null -ne $fork.name -and $fork.name -ne "") {
            $forksByName[$fork.name] = $fork
        }
    }
    
    # Filter to only the forks we should process in this chunk
    $forksToProcess = @()
    foreach ($actionName in $actionNamesToProcess) {
        if ($forksByName.ContainsKey($actionName)) {
            $forksToProcess += $forksByName[$actionName]
        } else {
            Write-Warning "Fork [$actionName] not found in status, skipping"
            Add-ChunkMessage -buffer $summaryBuffer -message "⚠️ Fork [$actionName] not found in status, skipping" -isError $true
        }
    }
    
    Add-ChunkMessage -buffer $summaryBuffer -message "Found [$($forksToProcess.Count)] forks to process"
    Add-ChunkMessage -buffer $summaryBuffer -message ""
    
    if ($forksToProcess.Count -eq 0) {
        Add-ChunkMessage -buffer $summaryBuffer -message "No forks to process in this chunk"
        Write-ChunkSummary -buffer $summaryBuffer
        return @()
    }
    
    # For each fork to process, call repoInfo.ps1
    # This reuses existing logic by calling the script once with limited scope
    $processedCount = 0
    $currentDir = Get-Location
    
    try {
        # Call repoInfo.ps1 for this chunk
        # It will read from status.json and process the forks
        # Skip secret scan summary as it will be shown in consolidate job
        & "$PSScriptRoot/repoInfo.ps1" `
            -actions $allActions `
            -numberOfReposToDo $forksToProcess.Count `
            -access_token $accessToken `
            -access_token_destination $accessToken `
            -skipSecretScanSummary
        
        # Check if rate limit was exceeded during processing
        if (Test-RateLimitExceeded) {
            Add-ChunkMessage -buffer $summaryBuffer -message "⚠️ Rate limit exceeded (20+ minute wait) during repo info processing" -isError $true
            Add-ChunkMessage -buffer $summaryBuffer -message "Partial results will be saved"
        }
        
        $processedCount = $forksToProcess.Count
    } catch {
        Write-Warning "Failed to process repo info chunk: $($_.Exception.Message)"
        Add-ChunkMessage -buffer $summaryBuffer -message "❌ Failed to process repo info chunk: $($_.Exception.Message)" -isError $true
    } finally {
        Set-Location $currentDir
    }
    
    # Read the updated status.json to get processed forks
    $processedForks = @()
    if (Test-Path "status.json") {
        try {
            $statusContent = Get-Content status.json -Raw
            $statusContent = $statusContent -replace '^\uFEFF', ''
            $allForks = $statusContent | ConvertFrom-Json
            
            # Filter to only the forks we processed
            foreach ($fork in $allForks) {
                if ($actionNamesToProcess -contains $fork.name) {
                    $processedForks += $fork
                }
            }
        } catch {
            Write-Warning "Could not read updated status.json: $($_.Exception.Message)"
            Add-ChunkMessage -buffer $summaryBuffer -message "⚠️ ERROR: Could not read updated status.json: $($_.Exception.Message)" -isError $true
        }
    }
    
    Add-ChunkMessage -buffer $summaryBuffer -message "✓ Processed [$processedCount] forks, found [$($processedForks.Count)] results"
    
    # Write summary conditionally (only if errors occurred)
    Write-ChunkSummary -buffer $summaryBuffer
    
    return $processedForks
}

Write-Host "# Chunk [$chunkId] RepoInfo Processing Started"
Write-Host ""

Write-Host "Got $($actions.Length) total actions"
Write-Host "Will process $($actionNames.Count) forks in this chunk"

GetRateLimitInfo -access_token $accessToken -access_token_destination $accessToken

# Process the chunk (handles its own conditional summary logging)
$processedForks = ProcessRepoInfoChunk -allActions $actions -actionNamesToProcess $actionNames -chunkId $chunkId

# Save partial status for this chunk
$outputPath = "status-partial-repoinfo-$chunkId.json"
Save-PartialStatusUpdate -processedForks $processedForks -chunkId $chunkId -outputPath $outputPath

GetRateLimitInfo -access_token $accessToken -access_token_destination $accessToken -waitForRateLimit $false

Write-Host ""
Write-Host "✓ Chunk [$chunkId] repoInfo processing complete"

# Explicitly exit with success code
exit 0
