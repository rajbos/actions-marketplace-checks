# Chunk processing script for forking repositories
# This script processes a subset of actions for forking in parallel with other chunks.
# 
# Note on logging: This script uses conditional step summary logging. Messages are always
# written to the job console logs (Write-Host), but are only written to the GitHub
# Step Summary when errors or warnings occur. This keeps the step summary clean when
# everything is working correctly, while still providing visibility when issues arise.

Param (
  $actions,
  $actionNames,  # Array of action names to process in this chunk
  [int] $chunkId = 0,
  $access_token = $env:GITHUB_TOKEN,
  $access_token_destination = $env:GITHUB_TOKEN
)

. $PSScriptRoot/library.ps1

Test-AccessTokens -accessToken $access_token -access_token_destination $access_token_destination -numberOfReposToDo $actionNames.Count

function ProcessForkingChunk {
    Param (
        $allActions,
        $actionNamesToProcess,
        [int] $chunkId
    )

    # Initialize summary buffer for conditional logging
    $summaryBuffer = Initialize-ChunkSummaryBuffer -chunkId $chunkId
    
    Add-ChunkMessage -buffer $summaryBuffer -message "# Chunk [$chunkId] - Forking Processing"
    Add-ChunkMessage -buffer $summaryBuffer -message "Processing [$($actionNamesToProcess.Count)] actions in this chunk"
    Add-ChunkMessage -buffer $summaryBuffer -message ""
    
    # Create a hashtable for fast lookup
    $actionsByName = @{}
    foreach ($action in $allActions) {
        if ($null -ne $action.name -and $action.name -ne "") {
            $actionsByName[$action.name] = $action
        } elseif ($null -ne $action.forkedRepoName -and $action.forkedRepoName -ne "") {
            $actionsByName[$action.forkedRepoName] = $action
        }
    }
    
    # show hashtable count
    Write-Message -message "Total actions available for processing: [$($actionsByName.Count)]" -logToSummary $true
    
    # Filter to only the actions we should process in this chunk
    $actionsToProcess = @()
    foreach ($actionName in $actionNamesToProcess) {
        if ($actionsByName.ContainsKey($actionName)) {
            $actionsToProcess += $actionsByName[$actionName]
        } else {
            Write-Warning "Action [$actionName] not found in actions list, skipping"
            Add-ChunkMessage -buffer $summaryBuffer -message "⚠️ Action [$actionName] not found in actions list, skipping" -isError $true
        }
    }
    
    Add-ChunkMessage -buffer $summaryBuffer -message "Found [$($actionsToProcess.Count)] actions to process in chunk"
    
    # Filter actions to only ones with repoUrl
    $actionsToProcess = $actionsToProcess | Where-Object { $null -ne $_.repoUrl -and $_.repoUrl -ne "" }
    Add-ChunkMessage -buffer $summaryBuffer -message "Filtered to [$($actionsToProcess.Count)] actions with repoUrl"
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
        }
    }
    
    # Process each action individually by calling functions.ps1
    # Note: This processes one action at a time to maintain isolation and
    # avoid complex refactoring of the existing functions.ps1 script.
    # While this adds some overhead, it ensures correctness and maintainability.
    $processedForks = @()
    $forkedCount = 0
    $failedCount = 0
    
    foreach ($action in $actionsToProcess) {
        # Check if rate limit was exceeded before processing next action
        if (Test-RateLimitExceeded) {
            Add-ChunkMessage -buffer $summaryBuffer -message "⚠️ Rate limit exceeded (20+ minute wait), stopping chunk processing early" -isError $true
            Add-ChunkMessage -buffer $summaryBuffer -message "Processed [$forkedCount] actions before rate limit was reached"
            break
        }
        
        Write-Host "Processing action: $($action.name)"
        
        # Create a temp actions array with just this one action
        $singleAction = @($action)
        
        # Save current directory
        $currentDir = Get-Location
        
        try {
            # Call functions.ps1 for this single action
            & "$PSScriptRoot/functions.ps1" `
                -actions $singleAction `
                -numberOfReposToDo 1 `
                -access_token $access_token `
                -access_token_destination $access_token_destination
            
            $forkedCount++
        } catch {
            Write-Warning "Failed to process action $($action.name): $($_.Exception.Message)"
            Add-ChunkMessage -buffer $summaryBuffer -message "❌ Failed to process action $($action.name): $($_.Exception.Message)" -isError $true
            $failedCount++
        } finally {
            # Restore directory
            Set-Location $currentDir
        }
    }
    
    # Read the updated status.json to get processed forks
    if (Test-Path "status.json") {
        try {
            $statusContent = Get-Content status.json -Raw
            $statusContent = $statusContent -replace '^\uFEFF', ''
            $allForks = $statusContent | ConvertFrom-Json
            
            # Filter to only the forks we processed (by action name)
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
    
    Add-ChunkMessage -buffer $summaryBuffer -message "✓ Chunk [$chunkId] processed [$forkedCount] actions, found [$($processedForks.Count)] forks"
    if ($failedCount -gt 0) {
        Add-ChunkMessage -buffer $summaryBuffer -message "❌ Failed to process [$failedCount] actions"
    }
    
    # Write summary conditionally (only if errors occurred)
    Write-ChunkSummary -buffer $summaryBuffer
    
    return $processedForks
}

Write-Host "# Chunk [$chunkId] Forking Processing Started"
Write-Host ""

Write-Host "Got $($actions.Length) total actions"
Write-Host "Will process $($actionNames.Count) actions in this chunk"

GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination

# Get token expiration time
$script:tokenExpirationTime = Get-TokenExpirationTime -access_token $access_token_destination
if ($null -ne $script:tokenExpirationTime) {
    $timeUntilExpiration = $script:tokenExpirationTime - [DateTime]::UtcNow
    Write-Host "Token will expire in $([math]::Round($timeUntilExpiration.TotalMinutes, 1)) minutes"
}

# Process the chunk (handles its own conditional summary logging)
$processedForks = ProcessForkingChunk -allActions $actions -actionNamesToProcess $actionNames -chunkId $chunkId

# Save partial status for this chunk
$outputPath = "status-partial-functions-$chunkId.json"
Save-PartialStatusUpdate -processedForks $processedForks -chunkId $chunkId -outputPath $outputPath

GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination

Write-Host ""
Write-Host "✓ Chunk [$chunkId] forking processing complete"

# Explicitly exit with success code
exit 0
