Param (
  [Parameter(Mandatory = $true)]
  $status,
  [Parameter(Mandatory = $false)]
  [int]$numberOfRepos = 5,
  [Parameter(Mandatory = $true)]
  [string]$apiUrl
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

Write-Message -message "API URL: $apiUrl" -logToSummary $true
Write-Message -message "Number of repos to upload: $numberOfRepos" -logToSummary $true
Write-Message -message "Total repos in status.json: $(DisplayIntWithDots $status.Count)" -logToSummary $true
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

# Create a temporary Node.js script to use the npm package
# Use the current working directory ($PWD) since:
# 1. We're running in a GitHub Actions runner with a known workspace
# 2. The npm package is installed in node_modules in this directory
# 3. The temp files are in .gitignore and will be cleaned up
$nodeScriptPath = Join-Path $PWD "temp-api-upload.js"

$nodeScript = @"
const { ActionsMarketplaceClient } = require('@devops-actions/actions-marketplace-client');
const fs = require('fs');

async function uploadActions() {
  const apiUrl = process.argv[2];
  const actionsJsonPath = process.argv[3];
  
  if (!apiUrl) {
    console.error('API URL is required');
    process.exit(1);
  }
  
  if (!actionsJsonPath) {
    console.error('Actions JSON file path is required');
    process.exit(1);
  }
  
  // Read actions from file instead of command line argument
  const actionsJson = fs.readFileSync(actionsJsonPath, 'utf8');
  const actions = JSON.parse(actionsJson);
  
  console.log('Initializing Actions Marketplace Client...');
  const client = new ActionsMarketplaceClient({ apiUrl: apiUrl });
  
  console.log('Uploading ' + actions.length + ' actions...');
  
  const results = [];
  
  for (const action of actions) {
    try {
      console.log('Uploading: ' + action.owner + '/' + action.name);
      
      // Build the action data for the API
      const actionData = {
        owner: action.owner,
        name: action.name
      };
      
      // Add optional fields if they exist
      if (action.description) actionData.description = action.description;
      if (action.actionType) actionData.type = action.actionType;
      if (action.icon) actionData.icon = action.icon;
      if (action.color) actionData.color = action.color;
      if (action.version) actionData.version = action.version;
      if (action.repoUrl) actionData.repoUrl = action.repoUrl;
      if (action.lastSyncedUtc) actionData.lastSyncedUtc = action.lastSyncedUtc;
      
      const result = await client.upsertAction(actionData);
      
      results.push({
        success: true,
        action: action.owner + '/' + action.name,
        created: result.created,
        updated: result.updated
      });
      
      console.log('  ✓ Success - ' + (result.created ? 'created' : result.updated ? 'updated' : 'no change'));
    } catch (error) {
      console.error('  ✗ Failed: ' + error.message);
      results.push({
        success: false,
        action: action.owner + '/' + action.name,
        error: error.message
      });
    }
  }
  
  // Output results as JSON for PowerShell to parse
  console.log('__RESULTS_JSON_START__');
  console.log(JSON.stringify(results, null, 2));
  console.log('__RESULTS_JSON_END__');
}

uploadActions().catch(error => {
  console.error('Fatal error:', error);
  process.exit(1);
});
"@

# Write the Node.js script
Set-Content -Path $nodeScriptPath -Value $nodeScript -Force

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
  Write-Host "Using Node.js version: $nodeVersion"
  
  # Run the Node.js script with JSON file path instead of inline JSON
  $output = node $nodeScriptPath $apiUrl $actionsJsonPath 2>&1 | Out-String
  
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
    
    Write-Message -message "| Status | Count |" -logToSummary $true
    Write-Message -message "|--------|-------|" -logToSummary $true
    Write-Message -message "| ✅ Successful | $successCount |" -logToSummary $true
    Write-Message -message "| ❌ Failed | $failCount |" -logToSummary $true
    Write-Message -message "| 🆕 Created | $createdCount |" -logToSummary $true
    Write-Message -message "| 📝 Updated | $updatedCount |" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
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
  if (Test-Path $nodeScriptPath) {
    Remove-Item $nodeScriptPath -Force
  }
  if (Test-Path $actionsJsonPath) {
    Remove-Item $actionsJsonPath -Force
  }
}

Write-Message -message "" -logToSummary $true
Write-Message -message "✓ Upload process completed" -logToSummary $true
