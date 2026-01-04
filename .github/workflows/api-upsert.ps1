Param (
  [Parameter(Mandatory = $true)]
  $status,
  [Parameter(Mandatory = $false)]
  [int]$numberOfRepos = 5,
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

Write-Message -message "API URL: [$apiUrl]" -logToSummary $true
Write-Message -message "Function key provided: [$($functionKey.Length) characters]" -logToSummary $true
Write-Message -message "Total repos in status.json: $(DisplayIntWithDots $status.Count)" -logToSummary $true

# Normalize numberOfRepos: treat 0 or empty as "all"; cap at total available
if ($numberOfRepos -le 0 -or $numberOfRepos -gt $status.Count) {
  $numberOfRepos = $status.Count
}

Write-Message -message "Number of repos to upload: [$numberOfRepos]" -logToSummary $true
Write-Message -message "" -logToSummary $true

# Filter repos that have the necessary data for the API
# Need: owner, name (from status), and additional metadata
$validRepos = $status | Where-Object {
  $_.name -and $_.owner
} | Select-Object -First $numberOfRepos

if ($validRepos.Count -eq 0) {
  Write-Message -message "⚠️ No valid repos found with required fields (name and owner)" -logToSummary $true
  exit 0
}

Write-Message -message "Found $(DisplayIntWithDots $validRepos.Count) valid repos to upload" -logToSummary $true
Write-Message -message "" -logToSummary $true

# Path to the external Node.js script
$nodeScriptPath = Join-Path $PSScriptRoot "node-scripts/upload-to-api.js"

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
  $output = node $nodeScriptPath $apiUrl $functionKey $actionsJsonPath 2>&1 | Out-String
  
  Write-Host "Node.js output:"
  Write-Host $output
  
  # Parse results from output
  if ($output -match '(?s)__RESULTS_JSON_START__(.*?)__RESULTS_JSON_END__') {
    $resultsJson = $matches[1].Trim()
    $results = $resultsJson | ConvertFrom-Json
    
    # Create summary table
    $successCount = ($results | Where-Object { $_.success -eq $true }).Count
    $failCount = ($results | Where-Object { $_.success -eq $false }).Count
    $createdCount = ($results | Where-Object { $_.created -eq $true }).Count
    $updatedCount = ($results | Where-Object { $_.updated -eq $true }).Count
    $allUploadsFailed = ($failCount -gt 0 -and $successCount -eq 0)
    
    Write-Message -message "| Status | Count |" -logToSummary $true
    Write-Message -message "|--------|-------|" -logToSummary $true
    Write-Message -message "| ✅ Successful | [$successCount] |" -logToSummary $true
    Write-Message -message "| ❌ Failed | [$failCount] |" -logToSummary $true
    Write-Message -message "| 🆕 Created | [$createdCount] |" -logToSummary $true
    Write-Message -message "| 📝 Updated | [$updatedCount] |" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Check if all uploads failed
    if ($allUploadsFailed) {
      Write-Message -message "⚠️ **All uploads failed!**" -logToSummary $true
      Write-Message -message "" -logToSummary $true
    }
    
    # Show details
    Write-Message -message "### Details" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    foreach ($result in $results) {
      if ($result.success) {
        $status = if ($result.created) { "created" } elseif ($result.updated) { "updated" } else { "no change" }
        Write-Message -message "- ✅ ``$($result.action)`` - $status" -logToSummary $true
      } else {
        Write-Message -message "- ❌ ``$($result.action)`` - $($result.error)" -logToSummary $true
      }
    }
    
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
