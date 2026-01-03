const { ActionsMarketplaceClient } = require('@devops-actions/actions-marketplace-client');
const fs = require('fs');

async function uploadActions() {
  const apiUrl = process.argv[2];
  const actionsJsonPath = process.argv[3];
  
  // Validate arguments
  if (!apiUrl) {
    console.error('API URL is required');
    process.exit(1);
  }
  
  if (!actionsJsonPath) {
    console.error('Actions JSON file path is required');
    process.exit(1);
  }
  
  // Validate URL format
  if (apiUrl.length === 0) {
    console.error('API URL cannot be empty (length: 0)');
    process.exit(1);
  }
  
  console.log('API URL length: [' + apiUrl.length + ']');
  
  // Validate file path
  if (actionsJsonPath.length === 0) {
    console.error('Actions JSON file path cannot be empty (length: 0)');
    process.exit(1);
  }
  
  console.log('Actions JSON file path length: [' + actionsJsonPath.length + ']');
  
  // Read actions from file instead of command line argument
  const actionsJson = fs.readFileSync(actionsJsonPath, 'utf8');
  const actions = JSON.parse(actionsJson);
  
  console.log('Initializing Actions Marketplace Client...');
  const client = new ActionsMarketplaceClient({ apiUrl: apiUrl });
  
  // API connection will be tested with the first upsert call
  console.log('Testing API connection...');
  console.log('API client initialized successfully');
  
  console.log('Uploading [' + actions.length + '] actions...');
  
  const results = [];
  
  for (const action of actions) {
    try {
      console.log('Uploading: [' + action.owner + '/' + action.name + ']');
      
      // Build the action data for the API
      // Only use fields that exist in the status.json schema
      const actionData = {
        owner: action.owner,
        name: action.name
      };
      
      // Add optional fields if they exist in the schema
      // Based on status.json schema documented in validate-status-schema.ps1:
      // - actionType (object/string)
      // - repoInfo (object)
      // - tagInfo, releaseInfo (version information)
      // - forkFound, mirrorLastUpdated, repoSize
      // - secretScanningEnabled, dependabotEnabled, dependabot
      // - vulnerabilityStatus, ossf, ossfScore, ossfDateLastUpdate
      // - dependents, verified
      
      if (action.actionType) actionData.actionType = action.actionType;
      if (action.repoInfo) actionData.repoInfo = action.repoInfo;
      if (action.tagInfo) actionData.tagInfo = action.tagInfo;
      if (action.releaseInfo) actionData.releaseInfo = action.releaseInfo;
      if (action.forkFound !== undefined) actionData.forkFound = action.forkFound;
      if (action.mirrorLastUpdated) actionData.mirrorLastUpdated = action.mirrorLastUpdated;
      if (action.repoSize !== undefined) actionData.repoSize = action.repoSize;
      if (action.secretScanningEnabled !== undefined) actionData.secretScanningEnabled = action.secretScanningEnabled;
      if (action.dependabotEnabled !== undefined) actionData.dependabotEnabled = action.dependabotEnabled;
      if (action.dependabot) actionData.dependabot = action.dependabot;
      if (action.vulnerabilityStatus) actionData.vulnerabilityStatus = action.vulnerabilityStatus;
      if (action.ossf !== undefined) actionData.ossf = action.ossf;
      if (action.ossfScore !== undefined) actionData.ossfScore = action.ossfScore;
      if (action.ossfDateLastUpdate) actionData.ossfDateLastUpdate = action.ossfDateLastUpdate;
      if (action.dependents) actionData.dependents = action.dependents;
      if (action.verified !== undefined) actionData.verified = action.verified;
      
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
