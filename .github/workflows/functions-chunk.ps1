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
    [string[]] $appIds,
    [string[]] $appPrivateKeys,
    [string] $appOrganization
)

. $PSScriptRoot/library.ps1

if (-not $appIds -or $appIds.Count -eq 0) {
    $appIds = @($env:APP_ID, $env:APP_ID_2, $env:APP_ID_3) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

if (-not $appPrivateKeys -or $appPrivateKeys.Count -eq 0) {
    $appPrivateKeys = @($env:APPLICATION_PRIVATE_KEY, $env:APPLICATION_PRIVATE_KEY_2, $env:APPLICATION_PRIVATE_KEY_3) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

if ([string]::IsNullOrWhiteSpace($appOrganization)) {
    $appOrganization = $env:APP_ORGANIZATION
}

if ($appPrivateKeys.Count -eq 0 -or $appIds.Count -eq 0) {
    throw "APP_ID and APPLICATION_PRIVATE_KEY environment variables must be provided when running functions-chunk.ps1"
}

if ([string]::IsNullOrWhiteSpace($appOrganization)) {
    throw "APP_ORGANIZATION must be provided when using GitHub App credentials"
}

$tokenManager = New-GitHubAppTokenManager -AppIds $appIds -AppPrivateKeys $appPrivateKeys
# Share the token manager instance with library.ps1 so ApiCall can
# coordinate app switching and failover across all requests in this chunk.
$script:GitHubAppTokenManagerInstance = $tokenManager
$tokenResult = $tokenManager.GetTokenForOrganization($appOrganization)

$access_token = $tokenResult.Token
$access_token_destination = $tokenResult.Token

Test-AccessTokens -accessToken $access_token -numberOfReposToDo $actionNames.Count

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
    
    # Create a hashtable for fast lookup (case-insensitive), pre-normalized once
    $actionsByName = @{}
    $keyStats = [ordered]@{ fromName = 0; fromForkedRepoName = 0; fromRepoUrl = 0; invalidRepoUrl = 0 }
    foreach ($action in $allActions) {
        if ($null -ne $action.name -and $action.name -ne "") {
            $actionsByName[$action.name.ToLower()] = $action
            $keyStats.fromName++
            continue
        }

        if ($null -ne $action.forkedRepoName -and $action.forkedRepoName -ne "") {
            $actionsByName[$action.forkedRepoName.ToLower()] = $action
            $keyStats.fromForkedRepoName++
            continue
        }

        # Fallback: derive owner/repo from repoUrl if present (handles actions without name/forkedRepoName)
        if ($null -ne $action.repoUrl -and $action.repoUrl -ne "") {
            $repoUrlStr = $action.repoUrl.Trim()
            # Handle plain owner/repo strings (no scheme/host)
            if ($repoUrlStr -match '^[^/]+/[^/]+$') {
                $normalized = $repoUrlStr.ToLower()
                $actionsByName[$normalized] = $action
                # Ensure the action has a writable 'name' property
                $hasNameProp = $action.PSObject.Properties.Match('name').Count -gt 0
                if (-not $hasNameProp) { $action | Add-Member -NotePropertyName name -NotePropertyValue $normalized -Force }
                elseif ($null -eq $action.name -or $action.name -eq "") { $action.name = $normalized }
                $keyStats.fromRepoUrl++
            } else {
                try {
                    $uri = [Uri]$repoUrlStr
                    # Expecting paths like /owner/repo or /owner/repo/...; take first two segments
                    $segments = $uri.AbsolutePath.Trim('/').Split('/')
                    if ($segments.Length -ge 2) {
                        $derivedKey = "$( $segments[0] )/$( $segments[1] )"
                        if ($derivedKey -ne "") {
                            $normalized = $derivedKey.ToLower()
                            $actionsByName[$normalized] = $action
                            # Ensure the action has a writable 'name' property
                            $hasNameProp = $action.PSObject.Properties.Match('name').Count -gt 0
                            if (-not $hasNameProp) { $action | Add-Member -NotePropertyName name -NotePropertyValue $normalized -Force }
                            elseif ($null -eq $action.name -or $action.name -eq "") { $action.name = $normalized }
                            $keyStats.fromRepoUrl++
                        }
                    }
                } catch {
                    # Ignore URL parse errors; no key added in this case
                    $keyStats.invalidRepoUrl++
                }
            }
        }
    }
    
    # show hashtable count, origin stats, and a sample of keys for quick verification
    Write-Message -message "Total actions available for processing: [$(DisplayIntWithDots $actionsByName.Count)]" -logToSummary $true
    Write-Host "Key origin stats: name=$($keyStats.fromName), forkedRepoName=$($keyStats.fromForkedRepoName), repoUrl-derived=$($keyStats.fromRepoUrl), invalidRepoUrl=$($keyStats.invalidRepoUrl)"
    $sampleKeys = ($actionsByName.Keys | Select-Object -First 5) -join ', '
    if ($sampleKeys) { Write-Host "Sample keys: $sampleKeys" }

    # Log a tiny sample of action fields to validate schema
    $firstAction = $allActions | Select-Object -First 1
    if ($null -ne $firstAction) {
        $schemaPreview = [ordered]@{
            name = $firstAction.name
            forkedRepoName = $firstAction.forkedRepoName
            repoUrl = $firstAction.repoUrl
        } | ConvertTo-Json -Compress
        Write-Host "Action schema preview: $schemaPreview"
    }
    
    # Normalize chunk names for lookup - try both formats
    # 1. Direct underscore format (matches forkedRepoName in hashtable)
    # 2. First underscore to slash (matches name in hashtable)
    $actionsToProcess = @()
    foreach ($nm in $actionNamesToProcess) {
        if ($null -eq $nm -or $nm -eq "") {
            continue
        }
        
        $lowerName = $nm.ToLower()
        $found = $false
        
        # Try 1: Direct lookup with underscore format (for forkedRepoName)
        if ($actionsByName.ContainsKey($lowerName)) {
            $actionsToProcess += $actionsByName[$lowerName]
            $found = $true
        }
        # Try 2: Convert first underscore to slash (for name)
        elseif ($lowerName.Contains('_')) {
            $slashVariant = [regex]::Replace($lowerName, '_', '/', 1)
            if ($actionsByName.ContainsKey($slashVariant)) {
                $actionsToProcess += $actionsByName[$slashVariant]
                $found = $true
            }
        }
        
        if (-not $found) {
            # Brief diagnostics for unmatched names
            $lookupKey = $lowerName
            $prefixMatches = $actionsByName.Keys | Where-Object { $_.StartsWith($lookupKey) } | Select-Object -First 2
            $containsMatches = $actionsByName.Keys | Where-Object { $_ -like "*${lookupKey}*" } | Select-Object -First 2
            
            $slashVariant = if ($lookupKey.Contains('_')) { [regex]::Replace($lookupKey, '_', '/', 1) } else { "N/A" }
            
            Write-Warning "Action not found. Original=[$nm] Tried: [$lookupKey] and [$slashVariant]"
            if ($prefixMatches) { Write-Host "Near prefix matches: $(($prefixMatches -join ', '))" }
            if ($containsMatches) { Write-Host "Near contains matches: $(($containsMatches -join ', '))" }
            
            Add-ChunkMessage -buffer $summaryBuffer -message "⚠️ Action [$lookupKey] not found in actions list, skipping" -isError $true
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
    $failedCount = 0

    # Batch process: call functions.ps1 once for the entire chunk
    if ($actionsToProcess.Count -gt 0) {
        Write-Host "Processing chunk with [$($actionsToProcess.Count)] actions"
        $currentDir = Get-Location
        try {
            & "$PSScriptRoot/functions.ps1" `
                -actions $actionsToProcess `
                -numberOfReposToDo $actionsToProcess.Count `
                -access_token $access_token `
                -access_token_destination $access_token_destination
        } catch {
            Write-Warning "Failed to process chunk [$chunkId]: $($_.Exception.Message)"
            Add-ChunkMessage -buffer $summaryBuffer -message "❌ Failed to process chunk [$chunkId]: $($_.Exception.Message)" -isError $true
            $failedCount = $actionsToProcess.Count
        } finally {
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
    
    Add-ChunkMessage -buffer $summaryBuffer -message "✓ Chunk [$chunkId] processed [$($actionsToProcess.Count)] actions, found [$($processedForks.Count)] forks"
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

GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination -waitForRateLimit $false

Write-Host ""
Write-Host "✓ Chunk [$chunkId] forking processing complete"

# Explicitly exit with success code
exit 0
