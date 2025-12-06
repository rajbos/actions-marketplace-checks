Param (
  $actions,
  $actionNames,  # Array of action names (fork names) to process in this chunk
  [int] $chunkId = 0,
  $access_token = $env:GITHUB_TOKEN,
  $access_token_destination = $env:GITHUB_TOKEN
)

. $PSScriptRoot/library.ps1
. $PSScriptRoot/dependents.ps1

if ($env:APP_PEM_KEY) {
    Write-Host "GitHub App information found, using GitHub App"
    $env:APP_ID = 264650
    $env:INSTALLATION_ID = 31486141
    $accessToken = Get-TokenFromApp -appId $env:APP_ID -installationId $env:INSTALLATION_ID -pemKey $env:APP_PEM_KEY
}
else {
    $accessToken = $access_token
}

Test-AccessTokens -accessToken $accessToken -access_token_destination $access_token_destination -numberOfReposToDo $actionNames.Count

Import-Module powershell-yaml -Force

# default variables
$forkOrg = "actions-marketplace-validations"

function ProcessRepoInfoChunk {
    Param (
        $allActions,
        $actionNamesToProcess,
        [int] $chunkId
    )

    Write-Message -message "# Chunk [$chunkId] - Repo Info Processing" -logToSummary $true
    Write-Message -message "Processing [$($actionNamesToProcess.Count)] forks in this chunk" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Get existing forks from status
    $existingForks = @()
    if (Test-Path "status.json") {
        try {
            $statusContent = Get-Content status.json -Raw
            $statusContent = $statusContent -replace '^\uFEFF', ''
            $existingForks = $statusContent | ConvertFrom-Json
        } catch {
            Write-Warning "Could not parse status.json: $($_.Exception.Message)"
            return @()
        }
    } else {
        Write-Warning "status.json not found"
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
        }
    }
    
    Write-Message -message "Found [$($forksToProcess.Count)] forks to process" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    if ($forksToProcess.Count -eq 0) {
        Write-Message -message "No forks to process in this chunk" -logToSummary $true
        return @()
    }
    
    # For each fork to process, call repoInfo.ps1
    # This reuses existing logic by calling the script once with limited scope
    $processedCount = 0
    $currentDir = Get-Location
    
    try {
        # Call repoInfo.ps1 for this chunk
        # It will read from status.json and process the forks
        & "$PSScriptRoot/repoInfo.ps1" `
            -actions $allActions `
            -numberOfReposToDo $forksToProcess.Count `
            -access_token $accessToken `
            -access_token_destination $access_token_destination
        
        $processedCount = $forksToProcess.Count
    } catch {
        Write-Warning "Failed to process repo info chunk: $($_.Exception.Message)"
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
        }
    }
    
    Write-Message -message "✓ Processed [$processedCount] forks, found [$($processedForks.Count)] results" -logToSummary $true
    
    return $processedForks
}

Write-Message -message "# Chunk [$chunkId] RepoInfo Processing Started" -logToSummary $true
Write-Message -message "" -logToSummary $true

Write-Host "Got $($actions.Length) total actions"
Write-Host "Will process $($actionNames.Count) forks in this chunk"

GetRateLimitInfo -access_token $accessToken -access_token_destination $access_token_destination

# Process the chunk
$processedForks = ProcessRepoInfoChunk -allActions $actions -actionNamesToProcess $actionNames -chunkId $chunkId

# Save partial status for this chunk
$outputPath = "status-partial-repoinfo-$chunkId.json"
Save-PartialStatusUpdate -processedForks $processedForks -chunkId $chunkId -outputPath $outputPath

GetRateLimitInfo -access_token $accessToken -access_token_destination $access_token_destination

Write-Message -message "" -logToSummary $true
Write-Message -message "✓ Chunk [$chunkId] repoInfo processing complete" -logToSummary $true

# Explicitly exit with success code
exit 0
