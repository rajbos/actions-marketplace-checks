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
  Write-Error "API URL not provided (ACTIONS_API secret)"
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
$nodeScriptPath = Join-Path $PSScriptRoot "temp-api-upload.js"

$nodeScript = @"
const { ActionsMarketplaceClient } = require('@devops-actions/actions-marketplace-client');

async function uploadActions() {
  const apiUrl = process.argv[2];
  const actionsJson = process.argv[3];
  
  if (!apiUrl) {
    console.error('API URL is required');
    process.exit(1);
  }
  
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

# Convert repos to JSON for Node.js
$actionsJson = $validRepos | ConvertTo-Json -Compress -Depth 10

Write-Message -message "### Upload Results" -logToSummary $true
Write-Message -message "" -logToSummary $true

try {
  # Run the Node.js script
  $output = node $nodeScriptPath $apiUrl $actionsJson 2>&1 | Out-String
  
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
  # Clean up temporary file
  if (Test-Path $nodeScriptPath) {
    Remove-Item $nodeScriptPath -Force
  }
}

Write-Message -message "" -logToSummary $true
Write-Message -message "✓ Upload process completed" -logToSummary $true
