Param (
  $actions,
  $actionNames,  # Array of action names to process in this chunk
  [int] $chunkId = 0,
  $access_token = $env:GITHUB_TOKEN,
  $access_token_destination = $env:GITHUB_TOKEN
)

. $PSScriptRoot/library.ps1

Test-AccessTokens -accessToken $access_token -access_token_destination $access_token_destination -numberOfReposToDo $actionNames.Count

function GetForkedActionRepoList {
    Param (
        $access_token
    )
    # get all existing repos in target org
    $repoUrl = "orgs/$forkOrg/repos"
    $repoResponse = ApiCall -method GET -url $repoUrl -body "{`"organization`":`"$forkOrg`"}" -access_token $access_token
    Write-Host "Found [$($repoResponse.Count)] existing repos in org [$forkOrg]"
    
    return $repoResponse
}

function ProcessActionsChunk {
    Param (
        $allActions,
        $actionNamesToProcess,
        $existingForks,
        $failedForks,
        [int] $chunkId
    )

    Write-Message -message "# Chunk [$chunkId] - Fork Processing" -logToSummary $true
    Write-Message -message "Processing [$($actionNamesToProcess.Count)] actions in this chunk" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Create a hashtable for fast lookup
    $actionsByName = @{}
    foreach ($action in $allActions) {
        if ($null -ne $action.name -and $action.name -ne "") {
            $actionsByName[$action.name] = $action
        }
    }
    
    # Filter to only the actions we should process in this chunk
    $actionsToProcess = @()
    foreach ($actionName in $actionNamesToProcess) {
        if ($actionsByName.ContainsKey($actionName)) {
            $actionsToProcess += $actionsByName[$actionName]
        }
        else {
            Write-Warning "Action [$actionName] not found in actions list, skipping"
        }
    }
    
    # Filter actions list to only the ones with a repoUrl
    $actionsToProcess = $actionsToProcess | Where-Object { $null -ne $_.repoUrl -and $_.repoUrl -ne "" }
    Write-Message -message "Found [$($actionsToProcess.Count)] actions with a repoUrl to process" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Load the functions needed from functions.ps1
    . $PSScriptRoot/functions.ps1
    
    # Process this chunk's actions
    ($newlyForkedRepos, $updatedExistingForks, $updatedFailedForks) = ForkActionRepos -actions $actionsToProcess -existingForks $existingForks -failedForks $failedForks
    
    Write-Message -message "Forked [$newlyForkedRepos] new repos" -logToSummary $true
    Write-Message -message "Updated [$($updatedExistingForks.Count)] existing forks" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Return only the forks that were updated by this chunk
    # We need to identify which forks were changed by comparing with the original
    $processedForks = @()
    foreach ($fork in $updatedExistingForks) {
        # Check if this fork is in our actionNames list
        if ($actionNamesToProcess -contains $fork.name) {
            $processedForks += $fork
        }
    }
    
    return ($processedForks, $updatedFailedForks)
}

Write-Message -message "# Chunk [$chunkId] Processing Started" -logToSummary $true
Write-Message -message "" -logToSummary $true

Write-Host "Got $($actions.Length) total actions"
Write-Host "Will process $($actionNames.Count) actions in this chunk"

GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination

# Get token expiration time and store it for checking during the loop
$script:tokenExpirationTime = Get-TokenExpirationTime -access_token $access_token_destination
if ($null -eq $script:tokenExpirationTime) {
    Write-Warning "Could not determine token expiration time. Continuing without expiration checks."
}
else {
    $timeUntilExpiration = $script:tokenExpirationTime - [DateTime]::UtcNow
    Write-Host "Token will expire in $([math]::Round($timeUntilExpiration.TotalMinutes, 1)) minutes at $($script:tokenExpirationTime) UTC"
}

# Load the list of forked repos
($existingForks, $failedForks) = GetForkedActionRepos -access_token $access_token_destination

# Process the chunk
($processedForks, $updatedFailedForks) = ProcessActionsChunk -allActions $actions -actionNamesToProcess $actionNames -existingForks $existingForks -failedForks $failedForks -chunkId $chunkId

# Save partial status for this chunk
$outputPath = "status-partial-functions-$chunkId.json"
Save-PartialStatusUpdate -processedForks $processedForks -chunkId $chunkId -outputPath $outputPath

# Save failed forks for this chunk
if ($updatedFailedForks -and $updatedFailedForks.Count -gt 0) {
    $failedForksOutputPath = "failedForks-partial-$chunkId.json"
    $json = ConvertTo-Json -InputObject $updatedFailedForks -Depth 10
    [System.IO.File]::WriteAllText($failedForksOutputPath, $json, [System.Text.Encoding]::UTF8)
    Write-Message -message "Saved partial failed forks for chunk [$chunkId] to [$failedForksOutputPath]" -logToSummary $true
}

GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination

Write-Message -message "" -logToSummary $true
Write-Message -message "✓ Chunk [$chunkId] processing complete" -logToSummary $true

# Explicitly exit with success code to prevent PowerShell from inheriting exit codes from previous commands
exit 0
