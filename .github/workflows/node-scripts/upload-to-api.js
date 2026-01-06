const { ActionsMarketplaceClient } = require('@devops-actions/actions-marketplace-client');
const fs = require('fs');

function formatDuration(ms) {
  if (ms < 1000) {
    return ms + ' ms';
  }

  const seconds = ms / 1000;
  if (seconds < 60) {
    return seconds.toFixed(1) + ' s';
  }

  const minutes = Math.floor(seconds / 60);
  const remainingSeconds = (seconds % 60).toFixed(1);
  return minutes + ' min ' + remainingSeconds + ' s';
}

function formatErrorForSummary(error) {
  if (!error) {
    return 'Unknown error';
  }

  const codePrefix = error.code ? error.code + ': ' : '';
  const message = error.message || 'Unknown error';
  let summary = codePrefix + message;

  const meta = [];
  if (typeof error.statusCode === 'number') {
    meta.push('statusCode=' + error.statusCode);
  }
  if (error.correlationId) {
    meta.push('correlationId=' + error.correlationId);
  }

  if (meta.length > 0) {
    summary += ' (' + meta.join(', ') + ')';
  }

  return summary;
}

async function uploadActions() {
  const apiUrl = process.argv[2];
  const functionKey = process.argv[3];
  const actionsJsonPath = process.argv[4];
  const maxUploadsArg = process.argv[5];
  
  // Validate arguments
  if (!apiUrl) {
    console.error('API URL is required');
    process.exit(1);
  }

  if (!functionKey) {
    console.error('Function key is required');
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

  // Validate function key format
  if (functionKey.length === 0) {
    console.error('Function key cannot be empty (length: 0)');
    process.exit(1);
  }

  console.log('Function key length: [' + functionKey.length + ']');

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
  const client = new ActionsMarketplaceClient({ apiUrl: apiUrl, functionKey: functionKey });
  
  // API connection will be tested with the first upsert call
  console.log('Testing API connection...');
  console.log('API client initialized successfully');
  
  // Determine optional maximum number of repos to actually upload
  let maxUploads = undefined;
  if (maxUploadsArg !== undefined) {
    const parsed = parseInt(maxUploadsArg, 10);
    if (!Number.isNaN(parsed) && parsed > 0) {
      maxUploads = parsed;
      console.log('Maximum uploads to perform: [' + maxUploads + ']');
    }
  }

  // Get current actions from the API so we can detect which ones have not
  // changed since the last upload based on repoInfo.updated_at.
  let existingIndex = new Map();
  try {
    console.log('Retrieving existing actions from API for comparison...');
    const listStart = Date.now();
    const existingActions = await client.listActions();
    const listDurationMs = Date.now() - listStart;
    if (Array.isArray(existingActions)) {
      for (const existing of existingActions) {
        if (!existing || !existing.owner || !existing.name) {
          continue;
        }
        const key = existing.owner + '/' + existing.name;
        existingIndex.set(key, existing);
      }
      const formattedDuration = formatDuration(listDurationMs);
      console.log('Indexed [' + existingIndex.size + '] existing actions for comparison in [' + formattedDuration + '].');

      // Emit structured stats so the PowerShell wrapper can surface this
      // information in the GitHub Actions step summary.
      console.log('__LIST_STATS_START__');
      console.log(JSON.stringify({
        existingCount: existingIndex.size,
        listDurationMs: listDurationMs,
        listDurationHuman: formattedDuration
      }, null, 2));
      console.log('__LIST_STATS_END__');
    } else {
      console.log('Existing actions list was not an array; skipping pre-comparison.');
    }
  } catch (error) {
    const summary = formatErrorForSummary(error);
    console.error('Warning: failed to retrieve existing actions for comparison: ' + summary);
    if (error && error.details) {
      try {
        console.error('  Details: ' + JSON.stringify(error.details));
      } catch {
        // ignore JSON stringify issues
      }
    }
    existingIndex = new Map();
  }

  console.log('Uploading from candidate set of [' + actions.length + '] actions...');
  
  const results = [];
  let uploadedCount = 0;
  let skippedNotUpdatedCount = 0;

  for (const action of actions) {
    if (maxUploads !== undefined && uploadedCount >= maxUploads) {
      console.log('Reached maximum uploads limit of [' + maxUploads + ']; stopping.');
      break;
    }

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

      const key = action.owner + '/' + action.name;

      // Check if this action exists already and whether the last updated
      // timestamp matches; if so, skip uploading it.
      const existing = existingIndex.get(key);
      let skippedNotUpdated = false;
      if (existing && existing.repoInfo && existing.repoInfo.updated_at &&
          actionData.repoInfo && actionData.repoInfo.updated_at) {
        try {
          const existingUpdated = new Date(existing.repoInfo.updated_at).toISOString();
          const candidateUpdated = new Date(actionData.repoInfo.updated_at).toISOString();
          if (existingUpdated === candidateUpdated) {
            skippedNotUpdated = true;
          }
        } catch (dateError) {
          console.error('  ⚠️ Date comparison failed for [' + key + ']: ' + dateError.message);
        }
      }

      if (skippedNotUpdated) {
        skippedNotUpdatedCount++;
        console.log('  ↷ Skipped - not updated since last upload');
        continue;
      }

      const result = await client.upsertAction(actionData);
      uploadedCount++;
      
      results.push({
        success: true,
        action: key,
        created: result.created,
        updated: result.updated,
        skippedNotUpdated: false
      });
      
      console.log('  ✓ Success - ' + (result.created ? 'created' : result.updated ? 'updated' : 'no change'));
    } catch (error) {
      const summary = formatErrorForSummary(error);
      console.error('  ✗ Failed: ' + summary);
      if (error && error.details) {
        try {
          console.error('  Details: ' + JSON.stringify(error.details));
        } catch {
          // ignore JSON stringify issues
        }
      }
      results.push({
        success: false,
        action: action.owner + '/' + action.name,
        error: summary
      });
    }
  }
  
  // Output skip statistics separately so the PowerShell wrapper can show
  // the total number of skipped (not updated) actions without including
  // each skipped item in the detailed results JSON.
  console.log('__SKIP_STATS_START__');
  console.log(JSON.stringify({
    skippedNotUpdatedCount: skippedNotUpdatedCount
  }, null, 2));
  console.log('__SKIP_STATS_END__');

  // Output results as JSON for PowerShell to parse
  console.log('__RESULTS_JSON_START__');
  console.log(JSON.stringify(results, null, 2));
  console.log('__RESULTS_JSON_END__');
}

uploadActions().catch(error => {
  console.error('Fatal error:', error);
  process.exit(1);
});
