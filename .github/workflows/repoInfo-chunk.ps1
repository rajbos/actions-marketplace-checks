Param (
  $actions,
  $actionNames,  # Array of action names to process in this chunk
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
    # get a token to use from the app
    $accessToken = Get-TokenFromApp -appId $env:APP_ID -installationId $env:INSTALLATION_ID -pemKey $env:APP_PEM_KEY
}
else {
  # use the one send in as a file param
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
        $existingForks,
        [int] $chunkId,
        $access_token,
        $access_token_destination
    )

    Write-Message -message "# Chunk [$chunkId] - Repo Info Processing" -logToSummary $true
    Write-Message -message "Processing [$($actionNamesToProcess.Count)] actions in this chunk" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
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
        }
        else {
            Write-Warning "Fork [$actionName] not found in status, skipping"
        }
    }
    
    Write-Message -message "Found [$($forksToProcess.Count)] forks to process" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Load the functions needed from repoInfo.ps1
    . $PSScriptRoot/repoInfo.ps1
    
    $startTime = Get-Date
    Write-Host "Processing started at [$startTime]"
    
    # Process GetInfo for this chunk's forks
    $updatedForks = GetInfo -existingForks $forksToProcess -access_token $access_token -startTime $startTime
    
    # Process GetMoreInfo for this chunk's forks
    ($allActionsUpdated, $updatedForks) = GetMoreInfo -existingForks $updatedForks -access_token $access_token_destination -startTime $startTime
    
    Write-Message -message "" -logToSummary $true
    Write-Message -message "✓ Processed [$($updatedForks.Count)] forks in chunk [$chunkId]" -logToSummary $true
    
    return $updatedForks
}

Write-Message -message "# Chunk [$chunkId] RepoInfo Processing Started" -logToSummary $true
Write-Message -message "" -logToSummary $true

Write-Host "Got $($actions.Length) total actions"
Write-Host "Will process $($actionNames.Count) actions in this chunk"

GetRateLimitInfo -access_token $accessToken -access_token_destination $access_token_destination

# Load existing forks from status.json
try {
    $jsonContent = Get-Content status.json -Raw
    $jsonContent = $jsonContent -replace '^\uFEFF', ''  # Remove UTF-8 BOM (Unicode)
    $existingForks = $jsonContent | ConvertFrom-Json
    Write-Host "Loaded [$($existingForks.Count)] existing forks from status.json"
} catch {
    Write-Error "Failed to parse status.json: $($_.Exception.Message)"
    exit 1
}

# Process the chunk
$processedForks = ProcessRepoInfoChunk -allActions $actions -actionNamesToProcess $actionNames -existingForks $existingForks -chunkId $chunkId -access_token $accessToken -access_token_destination $access_token_destination

# Save partial status for this chunk
$outputPath = "status-partial-repoinfo-$chunkId.json"
Save-PartialStatusUpdate -processedForks $processedForks -chunkId $chunkId -outputPath $outputPath

GetRateLimitInfo -access_token $accessToken -access_token_destination $access_token_destination

Write-Message -message "" -logToSummary $true
Write-Message -message "✓ Chunk [$chunkId] repoInfo processing complete" -logToSummary $true

# Explicitly exit with success code to prevent PowerShell from inheriting exit codes from previous commands
exit 0
