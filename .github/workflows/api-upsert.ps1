Param (
  [Parameter(Mandatory = $true)]
  $status,
  [Parameter(Mandatory = $false)]
  [int]$numberOfRepos = 500,
  [Parameter(Mandatory = $true)]
  [string]$apiUrl,
  [Parameter(Mandatory = $true)]
  [string]$functionKey
)

. $PSScriptRoot/library.ps1

Write-Message -message "# Uploading Actions to Alternative Marketplace API" -logToSummary $true
Write-Message -message "" -logToSummary $true

# Validate inputs
if (-not $status -or $status.Count -eq 0) {
  Write-Error "No status data provided"
  exit 1
}

if (-not $apiUrl) {
  Write-Error "API URL not provided (AZ_FUNCTION_URL secret)"
  exit 1
}

if (-not $functionKey) {
  Write-Error "Function key not provided (AZ_FUNCTION_TOKEN secret)"
  exit 1
}

Write-Message -message "### Configuration" -logToSummary $true
Write-Message -message "" -logToSummary $true

# Cap numberOfRepos at total available (0 means "upload none" if explicitly passed)
if ($numberOfRepos -gt $status.Count) {
  $numberOfRepos = $status.Count
}

# Get initial count of known actions in table storage
$getCountScriptPath = Join-Path $PSScriptRoot "node-scripts/src/get-actions-count.js"
$initialKnownCount = $null
$initialKnownCountFetched = $false
$initialCountExitCode = $null

if (Test-Path $getCountScriptPath) {
  try {
    Write-Host "Getting initial count of known actions from API..."
    $countOutput = node $getCountScriptPath $apiUrl $functionKey 2>&1 | Out-String
    $initialCountExitCode = $LASTEXITCODE
    
    Write-Host "Node.js output:"
    Write-Host $countOutput
    Write-Host "Count script exit code: [$initialCountExitCode]"
    
    if ($countOutput -match '(?s)__COUNT_START__(.*?)__COUNT_END__') {
      $initialKnownCount = [int]$matches[1].Trim()
      $initialKnownCountFetched = $true
      Write-Host "Initial known actions count: [$initialKnownCount]"
    } else {
      Write-Warning "Could not parse count from API response. Continuing without count."
      Write-Warning "Full output was:"
      Write-Warning $countOutput
    }
  } catch {
    Write-Warning "Failed to get initial actions count: $($_.Exception.Message). Continuing without count."
    Write-Warning "Exception details: $($_.Exception | Format-List -Force | Out-String)"
  }
} else {
  Write-Warning "Count script not found at [$getCountScriptPath]. Continuing without count."
}

$initialKnownCountDisplay = if ($initialKnownCountFetched) { "$(DisplayIntWithDots $initialKnownCount)" } else { "unknown" }
Write-Host "Known actions in table storage (start): [$initialKnownCountDisplay]"

if (-not $initialKnownCountFetched -and $initialCountExitCode -ne $null -and $initialCountExitCode -ne 0) {
  Write-Message -message "⚠️ Failed to retrieve initial known actions count from API (see logs above for details)." -logToSummary $true
  Write-Message -message "" -logToSummary $true
}

Write-Message -message "| Setting | Value |" -logToSummary $true
Write-Message -message "|---------|-------|" -logToSummary $true
Write-Message -message "| API URL | $apiUrl |" -logToSummary $true
Write-Message -message "| Function key length | $($functionKey.Length) characters |" -logToSummary $true
Write-Message -message "| Total repos in status.json | $(DisplayIntWithDots $status.Count) |" -logToSummary $true
Write-Message -message "| Number of repos to upload | $numberOfRepos |" -logToSummary $true
Write-Message -message "| Known actions in table storage (start) | $initialKnownCountDisplay |" -logToSummary $true
Write-Message -message "" -logToSummary $true

# Filter repos that have the necessary data for the API
# Need: owner, name (from status), and additional metadata
# Sort by last repo update (repoInfo.updated_at) so we consistently start
# with the most recently updated repos when deciding which ones to upload
$validRepos = $status |
  Where-Object { $_.name -and $_.owner } |
  Sort-Object -Property @{ Expression = { $_.repoInfo.updated_at }; Descending = $true }

if ($validRepos.Count -eq 0) {
  Write-Message -message "⚠️ No valid repos found with required fields (name and owner)" -logToSummary $true
  exit 0
}

Write-Message -message "Found $(DisplayIntWithDots $validRepos.Count) valid repos in status.json to consider for upload" -logToSummary $true
Write-Message -message "" -logToSummary $true

# Path to the external Node.js script (use src implementation directly)
$nodeScriptPath = Join-Path $PSScriptRoot "node-scripts/src/upload-to-api.js"

if (-not (Test-Path $nodeScriptPath)) {
  Write-Error "Node.js script not found at [$nodeScriptPath]"
  exit 1
}

# Write repos to a temp JSON file to avoid command line length limits
# Using $PWD since we need the file in the working directory where node_modules is located
$actionsJsonPath = Join-Path $PWD "temp-actions-data.json"
$validRepos | ConvertTo-Json -Depth 10 | Set-Content -Path $actionsJsonPath -Force

Write-Message -message "### Upload Results" -logToSummary $true
Write-Message -message "" -logToSummary $true

try {
  # Check if Node.js is available
  $nodeVersion = node --version 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Node.js is not installed or not in PATH. Please ensure Node.js is installed."
  }
  Write-Host "Using Node.js version: [$nodeVersion]"
  
  # Run the Node.js script with JSON file path instead of inline JSON
  # Pass numberOfRepos as a max uploads limit; the script will stop once that
  # many repos have actually been uploaded (created/updated), skipping any
  # that have not changed since the last upload.
  $output = node $nodeScriptPath $apiUrl $functionKey $actionsJsonPath $numberOfRepos 2>&1 | Out-String
  
  Write-Host "Node.js output:"
  Write-Host $output
  
  # Try to parse list statistics (existing actions count and list duration)
  # emitted by the Node.js script so we can surface them in the step summary.
  $listStats = $null
  if ($output -match '(?s)__LIST_STATS_START__(.*?)__LIST_STATS_END__') {
    $statsJson = $matches[1].Trim()
    try {
      $listStats = $statsJson | ConvertFrom-Json
    } catch {
      Write-Warning "Failed to parse list stats JSON from Node.js output: $($_.Exception.Message)"
    }
  }

  # Try to parse skip statistics (number of actions skipped because they
  # were not updated since the last upload) emitted by the Node.js script.
  $skipStats = $null
  if ($output -match '(?s)__SKIP_STATS_START__(.*?)__SKIP_STATS_END__') {
    $skipJson = $matches[1].Trim()
    try {
      $skipStats = $skipJson | ConvertFrom-Json
    } catch {
      Write-Warning "Failed to parse skip stats JSON from Node.js output: $($_.Exception.Message)"
    }
  }

  # Try to parse delta statistics (reconciliation status) emitted by the Node.js script.
  $deltaStats = $null
  if ($output -match '(?s)__DELTA_STATS_START__(.*?)__DELTA_STATS_END__') {
    $deltaJson = $matches[1].Trim()
    try {
      $deltaStats = $deltaJson | ConvertFrom-Json
    } catch {
      Write-Warning "Failed to parse delta stats JSON from Node.js output: $($_.Exception.Message)"
    }
  }

  # Parse results from output
  if ($output -match '(?s)__RESULTS_JSON_START__(.*?)__RESULTS_JSON_END__') {
    $resultsJson = $matches[1].Trim()
    $results = $resultsJson | ConvertFrom-Json
    
    # Create summary table
    $successCount = ($results | Where-Object { $_.success -eq $true }).Count
    $failCount = ($results | Where-Object { $_.success -eq $false }).Count
    $createdCount = ($results | Where-Object { $_.created -eq $true }).Count
    $updatedCount = ($results | Where-Object { $_.updated -eq $true }).Count
    if ($skipStats -and $null -ne $skipStats.skippedNotUpdatedCount) {
      $skippedNotUpdatedCount = [int]$skipStats.skippedNotUpdatedCount
    } else {
      $skippedNotUpdatedCount = 0
    }
    $allUploadsFailed = ($failCount -gt 0 -and $successCount -eq 0)
    
    # Log list statistics if available
    if ($listStats) {
      $existingCountDisplay = if ($null -ne $listStats.existingCount) {
        try { $(DisplayIntWithDots([int]$listStats.existingCount)) } catch { "$($listStats.existingCount)" }
      } else {
        "unknown"
      }

      $durationDisplay = if ($listStats.listDurationHuman) {
        $listStats.listDurationHuman
      } elseif ($null -ne $listStats.listDurationMs) {
        "$($listStats.listDurationMs) ms"
      } else {
        "unknown"
      }

      Write-Message -message "Indexed $existingCountDisplay existing actions from API in [$durationDisplay]" -logToSummary $true
      Write-Message -message "" -logToSummary $true
      Write-Message -message "> ℹ️ **Note:** The count of existing actions in the API (above) may differ from valid repos in status.json because:" -logToSummary $true
      Write-Message -message "> - The API may contain actions not in status.json (orphaned)" -logToSummary $true
      Write-Message -message "> - status.json may contain repos not yet uploaded to the API" -logToSummary $true
      Write-Message -message "" -logToSummary $true
    }

    Write-Message -message "| Status | Count |" -logToSummary $true
    Write-Message -message "|--------|-------|" -logToSummary $true
    Write-Message -message "| ✅ Successful | $successCount |" -logToSummary $true
    Write-Message -message "| ❌ Failed | $failCount |" -logToSummary $true
    Write-Message -message "| 🆕 Created | $createdCount |" -logToSummary $true
    Write-Message -message "| 📝 Updated | $updatedCount |" -logToSummary $true
    Write-Message -message "| ⏭️ Skipped (not updated) | $skippedNotUpdatedCount |" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Calculate and display processing summary
    $totalProcessed = $successCount + $failCount + $skippedNotUpdatedCount
    $validReposCount = $validRepos.Count
    if ($totalProcessed -lt $validReposCount) {
      $notProcessed = $validReposCount - $totalProcessed
      Write-Message -message "> **Note:** Started with $(DisplayIntWithDots $validReposCount) valid repos from status.json. Processed $(DisplayIntWithDots $totalProcessed) repos ($successCount successful uploads + $skippedNotUpdatedCount skipped). Stopped after reaching the upload limit of $numberOfRepos successful uploads. $(DisplayIntWithDots $notProcessed) repos were not checked." -logToSummary $true
      Write-Message -message "" -logToSummary $true
    }
    
    # Check if all uploads failed
    if ($allUploadsFailed) {
      Write-Message -message "⚠️ **All uploads failed!**" -logToSummary $true
      Write-Message -message "" -logToSummary $true
    }
    
    # Show details - group by status and limit to top 10 per status
    Write-Message -message "<details>" -logToSummary $true
    Write-Message -message "<summary>Details</summary>" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Group results by status
    $createdActions = @($results | Where-Object { $_.success -and $_.created })
    $updatedActions = @($results | Where-Object { $_.success -and $_.updated })
    $noChangeActions = @($results | Where-Object { $_.success -and -not $_.created -and -not $_.updated -and -not $_.skippedNotUpdated })
    $failedActions = @($results | Where-Object { -not $_.success })
    
    # Helper function to display action list with limit
    $displayActionGroup = {
      param($actions, $statusEmoji, $statusLabel, $limit = 10)
      if ($actions.Count -eq 0) { return }
      
      $displayCount = [Math]::Min($actions.Count, $limit)
      $remaining = $actions.Count - $displayCount
      
      Write-Message -message "**$statusEmoji $statusLabel** (first $displayCount of $($actions.Count))" -logToSummary $true
      Write-Message -message "" -logToSummary $true
      
      for ($i = 0; $i -lt $displayCount; $i++) {
        $action = $actions[$i]
        if ($statusLabel -eq "Failed") {
          Write-Message -message "- ❌ ``$($action.action)`` - $($action.error)" -logToSummary $true
        } else {
          Write-Message -message "- ✅ ``$($action.action)``" -logToSummary $true
        }
      }
      Write-Message -message "" -logToSummary $true
    }
    
    # Display each group (top 10 only)
    & $displayActionGroup $createdActions "🆕" "Created"
    & $displayActionGroup $updatedActions "📝" "Updated"
    & $displayActionGroup $noChangeActions "⏭️" "No Change"
    & $displayActionGroup $failedActions "❌" "Failed"
    
    Write-Message -message "</details>" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Exit with error if all uploads failed
    if ($allUploadsFailed) {
      Write-Error "All $failCount uploads failed"
      exit 1
    }
  } else {
    Write-Warning "Could not parse results from Node.js output"
    Write-Message -message "⚠️ Upload completed but could not parse results" -logToSummary $true
  }
  
} catch {
  Write-Error "Failed to upload actions: $($_.Exception.Message)"
  Write-Message -message "❌ Upload failed: $($_.Exception.Message)" -logToSummary $true
  exit 1
} finally {
  # Clean up temporary files
  if (Test-Path $actionsJsonPath) {
    Remove-Item $actionsJsonPath -Force
  }
}

Write-Message -message "" -logToSummary $true
Write-Message -message "✓ Upload process completed" -logToSummary $true

# Get final count of known actions in table storage
$finalKnownCount = $null
$finalKnownCountFetched = $false
$finalCountExitCode = $null

if (Test-Path $getCountScriptPath) {
  try {
    Write-Host "Getting final count of known actions from API..."
    $countOutput = node $getCountScriptPath $apiUrl $functionKey 2>&1 | Out-String
    $finalCountExitCode = $LASTEXITCODE
    
    Write-Host "Node.js output:"
    Write-Host $countOutput
    Write-Host "Count script exit code: [$finalCountExitCode]"
    
    if ($countOutput -match '(?s)__COUNT_START__(.*?)__COUNT_END__') {
      $finalKnownCount = [int]$matches[1].Trim()
      $finalKnownCountFetched = $true
      Write-Host "Final known actions count: [$finalKnownCount]"
      Write-Message -message "" -logToSummary $true
      Write-Message -message "📊 Known actions in table storage (end): **$(DisplayIntWithDots $finalKnownCount)**" -logToSummary $true
      
      # Display delta statistics if available
      if ($deltaStats) {
        Write-Message -message "" -logToSummary $true
        Write-Message -message "### Reconciliation Status" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        Write-Message -message "Based on comparing \`repoInfo.updated_at\` timestamps:" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        Write-Message -message "| Metric | Count |" -logToSummary $true
        Write-Message -message "|--------|-------|" -logToSummary $true
        Write-Message -message "| Actions in status.json | $(DisplayIntWithDots $deltaStats.totalInStatusJson) |" -logToSummary $true
        Write-Message -message "| Actions in API storage | $(DisplayIntWithDots $deltaStats.totalInApi) |" -logToSummary $true
        Write-Message -message "| **Actions needing updates** | **$(DisplayIntWithDots $deltaStats.actionsNeedingUpdates)** |" -logToSummary $true
        Write-Message -message "| Actions up-to-date | $(DisplayIntWithDots $deltaStats.actionsUpToDate) |" -logToSummary $true
        
        if ($deltaStats.actionsInApiNotInStatus -gt 0) {
          Write-Message -message "| ⚠️ Actions in API but not in status.json | $(DisplayIntWithDots $deltaStats.actionsInApiNotInStatus) |" -logToSummary $true
        }
        
        Write-Message -message "" -logToSummary $true
        
        if ($deltaStats.actionsNeedingUpdates -gt 0) {
          Write-Message -message "> 📝 **$(DisplayIntWithDots $deltaStats.actionsNeedingUpdates) actions still need to be reconciled** (either created or updated in API storage based on updated timestamps)." -logToSummary $true
        } else {
          Write-Message -message "> ✅ All actions in status.json are up-to-date in API storage!" -logToSummary $true
        }
      }
    } else {
      Write-Warning "Could not parse final count from API response."
      Write-Warning "Full output was:"
      Write-Warning $countOutput
    }
  } catch {
    Write-Warning "Failed to get final actions count: $($_.Exception.Message)"
    Write-Warning "Exception details: $($_.Exception | Format-List -Force | Out-String)"
  }
} else {
  Write-Warning "Count script not found at [$getCountScriptPath]."
}

if (-not $finalKnownCountFetched) {
  if ($null -ne $finalCountExitCode -and $finalCountExitCode -ne 0) {
    Write-Error "Final count lookup failed with exit code $finalCountExitCode"
    Write-Message -message "❌ Final known actions count lookup failed with exit code $finalCountExitCode (see logs above for details)." -logToSummary $true
  } else {
    Write-Error "Final count lookup failed: no count markers found in output"
    Write-Message -message "❌ Final known actions count lookup failed: no count markers found in output (see logs above for details)." -logToSummary $true
  }
  Write-Message -message "" -logToSummary $true
  Write-Message -message "📊 Known actions in table storage (end): unavailable (count step failed)" -logToSummary $true
  exit 1
}

exit 0
