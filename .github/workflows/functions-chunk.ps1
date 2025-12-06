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

    Write-Message -message "# Chunk [$chunkId] - Forking Processing" -logToSummary $true
    Write-Message -message "Processing [$($actionNamesToProcess.Count)] actions in this chunk" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Create a hashtable for fast lookup
    $actionsByName = @{}
    foreach ($action in $allActions) {
        if ($null -ne $action.name -and $action.name -ne "") {
            $actionsByName[$action.name] = $action
        } elseif ($null -ne $action.forkedRepoName -and $action.forkedRepoName -ne "") {
            $actionsByName[$action.forkedRepoName] = $action
        }
    }
    
    # Filter to only the actions we should process in this chunk
    $actionsToProcess = @()
    foreach ($actionName in $actionNamesToProcess) {
        if ($actionsByName.ContainsKey($actionName)) {
            $actionsToProcess += $actionsByName[$actionName]
        } else {
            Write-Warning "Action [$actionName] not found in actions list, skipping"
        }
    }
    
    Write-Message -message "Found [$($actionsToProcess.Count)] actions to process in chunk" -logToSummary $true
    
    # Filter actions to only ones with repoUrl
    $actionsToProcess = $actionsToProcess | Where-Object { $null -ne $_.repoUrl -and $_.repoUrl -ne "" }
    Write-Message -message "Filtered to [$($actionsToProcess.Count)] actions with repoUrl" -logToSummary $true
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
        }
    }
    
    # For each action to process, call functions.ps1 with just that action
    # This is a simple approach that reuses existing logic
    $processedForks = @()
    $forkedCount = 0
    
    foreach ($action in $actionsToProcess) {
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
        }
    }
    
    Write-Message -message "✓ Chunk [$chunkId] processed [$forkedCount] actions, found [$($processedForks.Count)] forks" -logToSummary $true
    
    return $processedForks
}

Write-Message -message "# Chunk [$chunkId] Forking Processing Started" -logToSummary $true
Write-Message -message "" -logToSummary $true

Write-Host "Got $($actions.Length) total actions"
Write-Host "Will process $($actionNames.Count) actions in this chunk"

GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination

# Get token expiration time
$script:tokenExpirationTime = Get-TokenExpirationTime -access_token $access_token_destination
if ($null -ne $script:tokenExpirationTime) {
    $timeUntilExpiration = $script:tokenExpirationTime - [DateTime]::UtcNow
    Write-Host "Token will expire in $([math]::Round($timeUntilExpiration.TotalMinutes, 1)) minutes"
}

# Process the chunk
$processedForks = ProcessForkingChunk -allActions $actions -actionNamesToProcess $actionNames -chunkId $chunkId

# Save partial status for this chunk
$outputPath = "status-partial-functions-$chunkId.json"
Save-PartialStatusUpdate -processedForks $processedForks -chunkId $chunkId -outputPath $outputPath

GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination

Write-Message -message "" -logToSummary $true
Write-Message -message "✓ Chunk [$chunkId] forking processing complete" -logToSummary $true

# Explicitly exit with success code
exit 0
