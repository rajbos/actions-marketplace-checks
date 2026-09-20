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

function parseSemverLike(tag) {
  if (typeof tag !== 'string') {
    return null;
  }

  const match = tag.match(/^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z\.-]+))?/);
  if (!match) {
    return null;
  }

  return {
    major: parseInt(match[1], 10),
    minor: match[2] ? parseInt(match[2], 10) : 0,
    patch: match[3] ? parseInt(match[3], 10) : 0,
    prerelease: match[4] || ''
  };
}

function compareTagStringsDesc(a, b) {
  const pa = parseSemverLike(a);
  const pb = parseSemverLike(b);

  if (pa && pb) {
    if (pa.major !== pb.major) {
      return pb.major - pa.major;
    }
    if (pa.minor !== pb.minor) {
      return pb.minor - pa.minor;
    }
    if (pa.patch !== pb.patch) {
      return pb.patch - pa.patch;
    }
    if (pa.prerelease !== pb.prerelease) {
      if (!pa.prerelease) {
        return -1;
      }
      if (!pb.prerelease) {
        return 1;
      }
      return pb.prerelease.localeCompare(pa.prerelease);
    }
    return 0;
  }

  if (pa && !pb) {
    return -1;
  }
  if (!pa && pb) {
    return 1;
  }

  return b.localeCompare(a);
}

function isNoiseTag(tag) {
  if (typeof tag !== 'string') return false;
  // Filter out CI/run-style tags like "+run2368-attempt1"
  return /^\+run\d+(?:-attempt\d+)?$/i.test(tag);
}

function trimTagInfoToLatest(actionData, maxTags) {
  if (!actionData || !actionData.tagInfo) {
    return;
  }

  const tagInfo = actionData.tagInfo;
  if (!Array.isArray(tagInfo) || tagInfo.length <= maxTags) {
    return;
  }

  const isObjectArray = typeof tagInfo[0] === 'object' && tagInfo[0] !== null && Object.prototype.hasOwnProperty.call(tagInfo[0], 'tag');

  // Remove noise tags (e.g., "+run...-attempt...") before considering SemVer
  const filtered = tagInfo.filter(item => {
    const t = isObjectArray ? item.tag : item;
    return !isNoiseTag(t);
  });

  // Partition into semver and non-semver
  const semverItems = [];
  const nonSemverItems = [];
  for (const item of filtered) {
    const t = isObjectArray ? item.tag : item;
    if (parseSemverLike(t)) {
      semverItems.push(item);
    } else {
      nonSemverItems.push(item);
    }
  }

  let selected;
  if (semverItems.length > 0) {
    // Prefer SemVer tags when available
    semverItems.sort((a, b) => {
      const tagA = isObjectArray ? a.tag : a;
      const tagB = isObjectArray ? b.tag : b;
      return compareTagStringsDesc(tagA, tagB);
    });
    selected = semverItems.slice(0, maxTags);
  } else {
    // Fallback to non-SemVer, sorted with alphabetic-desc comparator
    nonSemverItems.sort((a, b) => {
      const tagA = isObjectArray ? a.tag : a;
      const tagB = isObjectArray ? b.tag : b;
      return compareTagStringsDesc(tagA, tagB);
    });
    selected = nonSemverItems.slice(0, maxTags);
  }

  actionData.tagInfo = selected;
}

function trimReleaseInfoToLatest(actionData, maxReleases) {
  if (!actionData || !actionData.releaseInfo) {
    return;
  }

  const releaseInfo = actionData.releaseInfo;
  if (!Array.isArray(releaseInfo) || releaseInfo.length <= maxReleases) {
    return;
  }

  // Release objects typically have tag_name or name field
  const getReleaseName = (release) => {
    if (typeof release === 'string') return release;
    if (release && typeof release === 'object') {
      return release.tag_name || release.name || '';
    }
    return '';
  };

  // Remove noise releases (e.g., "+run...-attempt...")
  const filtered = releaseInfo.filter(item => {
    const name = getReleaseName(item);
    return !isNoiseTag(name);
  });

  // Partition into semver and non-semver
  const semverItems = [];
  const nonSemverItems = [];
  for (const item of filtered) {
    const name = getReleaseName(item);
    if (parseSemverLike(name)) {
      semverItems.push(item);
    } else {
      nonSemverItems.push(item);
    }
  }

  let selected;
  if (semverItems.length > 0) {
    // Prefer SemVer releases when available
    semverItems.sort((a, b) => {
      const nameA = getReleaseName(a);
      const nameB = getReleaseName(b);
      return compareTagStringsDesc(nameA, nameB);
    });
    selected = semverItems.slice(0, maxReleases);
  } else {
    // Fallback to non-SemVer, sorted with alphabetic-desc comparator
    nonSemverItems.sort((a, b) => {
      const nameA = getReleaseName(a);
      const nameB = getReleaseName(b);
      return compareTagStringsDesc(nameA, nameB);
    });
    selected = nonSemverItems.slice(0, maxReleases);
  }

  actionData.releaseInfo = selected;
}

/**
 * Checks whether the append-only immutableReleaseObservations history differs
 * between what the API already has and the current status.json candidate.
 *
 * repoInfo.updated_at (the primary needsUpdate signal below) only changes when
 * the upstream repo itself is pushed to - it does not change just because a new
 * release observation (or a "deleted" observation for a removed release) was
 * appended. Without this check, newly appended observations would silently
 * never reach the API whenever repoInfo.updated_at happens to be unchanged,
 * which would defeat the point of persisting this history at all.
 *
 * @param {object|null} existingAction - The action from API storage (or null if not exists)
 * @param {object} candidateAction - The action from status.json
 * @returns {boolean} - true if the observation history differs (or could not be compared safely)
 */
function immutableReleaseObservationsChanged(existingAction, candidateAction) {
  const existingObservations = (existingAction && existingAction.immutableReleaseObservations) || [];
  const candidateObservations = (candidateAction && candidateAction.immutableReleaseObservations) || [];

  if (existingObservations.length !== candidateObservations.length) {
    return true;
  }

  if (existingObservations.length > 0) {
    try {
      if (JSON.stringify(existingObservations) !== JSON.stringify(candidateObservations)) {
        return true;
      }
    } catch (jsonError) {
      // If we can't safely compare, assume it changed so the observation history
      // is never silently left stale.
      return true;
    }
  }

  return immutableReleaseCoverageChanged(existingAction, candidateAction);
}

/**
 * Checks whether the derived immutableReleaseCoverage summary (issue #266)
 * differs between what the API already has and the current status.json
 * candidate.
 *
 * This is checked independently of the observation-history comparison above
 * because coverage is a derived field that can go from absent to present (or
 * otherwise change) without the underlying observations array itself
 * changing length or content on this particular pass - e.g. an existing API
 * record uploaded before this field existed. Without this check, such a
 * record would never pick up the new field once repoInfo.updated_at and the
 * observation history both happen to be unchanged.
 *
 * @param {object|null} existingAction - The action from API storage (or null if not exists)
 * @param {object} candidateAction - The action from status.json
 * @returns {boolean} - true if the coverage summary differs (or could not be compared safely)
 */
function immutableReleaseCoverageChanged(existingAction, candidateAction) {
  const existingCoverage = (existingAction && existingAction.immutableReleaseCoverage) || null;
  const candidateCoverage = (candidateAction && candidateAction.immutableReleaseCoverage) || null;

  if (!existingCoverage && !candidateCoverage) {
    return false;
  }

  if (!existingCoverage || !candidateCoverage) {
    return true;
  }

  try {
    return JSON.stringify(existingCoverage) !== JSON.stringify(candidateCoverage);
  } catch (jsonError) {
    // If we can't safely compare, assume it changed so the coverage summary
    // is never silently left stale.
    return true;
  }
}

/**
 * Checks whether any of the immutable-release policy fields (issue #264) or
 * the derived immutableReleaseSummary (issue #267) differ between what the
 * API already has and the current status.json candidate.
 *
 * These are refreshed on their own 30-day cadence in repoInfo.ps1 and can
 * therefore change (e.g. a policy flips from "unknown" to "enabled", or the
 * summary string is recomputed) without repoInfo.updated_at changing at all,
 * since that field only reflects the upstream repo being pushed to. Without
 * this check, a policy-only refresh would be silently skipped by needsUpdate.
 *
 * @param {object|null} existingAction - The action from API storage (or null if not exists)
 * @param {object} candidateAction - The action from status.json
 * @returns {boolean} - true if any of these fields differ
 */
function immutableReleasePolicyChanged(existingAction, candidateAction) {
  const fields = [
    'immutableReleasePolicy',
    'immutableReleasePolicyCheckedAt',
    'immutableReleasePolicyReason',
    'immutableReleasePolicySource',
    'immutableReleasePolicyChangedAt',
    'immutableReleaseSummary'
  ];

  for (const field of fields) {
    const existingValue = (existingAction && existingAction[field]) || null;
    const candidateValue = (candidateAction && candidateAction[field]) || null;
    if (existingValue !== candidateValue) {
      return true;
    }
  }

  return false;
}

/**
 * Checks if an action needs to be updated based on repoInfo.updated_at comparison
 * (or, failing that, whether the append-only immutableReleaseObservations history,
 * the derived immutableReleaseCoverage, the immutable-release policy fields, or
 * the immutableReleaseSummary have changed - see the helpers above).
 *
 * @param {object|null} existingAction - The action from API storage (or null if not exists)
 * @param {object} candidateAction - The action from status.json
 * @returns {boolean} - true if the action needs to be created or updated, false if up-to-date
 */
function needsUpdate(existingAction, candidateAction) {
  if (!existingAction) {
    // Action is in status.json but not in API - needs to be created
    return true;
  }

  if (existingAction.repoInfo && existingAction.repoInfo.updated_at &&
      candidateAction.repoInfo && candidateAction.repoInfo.updated_at) {
    try {
      const existingUpdated = new Date(existingAction.repoInfo.updated_at).toISOString();
      const candidateUpdated = new Date(candidateAction.repoInfo.updated_at).toISOString();
      if (existingUpdated !== candidateUpdated) {
        return true;
      }
      if (immutableReleaseObservationsChanged(existingAction, candidateAction)) {
        return true;
      }
      return immutableReleasePolicyChanged(existingAction, candidateAction);
    } catch (dateError) {
      // If date comparison fails, assume it needs update to be safe
      return true;
    }
  }

  // If either side is missing updated_at, assume it needs update
  return true;
}

/**
 * Checks if an action has the required fields (owner and name).
 *
 * @param {object} action - The action object to validate
 * @returns {boolean} - true if the action has both owner and name, false otherwise
 */
function isValidAction(action) {
  return !!(action && action.owner && action.name);
}

/**
 * Builds the API payload for a single action from the raw status.json entry.
 * Only fields documented in the status.json schema (validate-status-schema.ps1)
 * are copied through, and tag/release lists are trimmed to the latest entries
 * so the payload stays well under the Azure Table Storage per-property limit.
 *
 * Extracted from the upload loop so it can be unit tested directly without
 * mocking the API client (issue #267 added the immutable-release policy/summary
 * pass-through below and needed a way to verify field-by-field behavior).
 *
 * @param {object} action - The raw action entry from status.json
 * @returns {object} - The actionData payload ready to send to the API
 */
function buildActionData(action) {
  // Only use fields that exist in the status.json schema
  const actionData = {
    owner: action.owner,
    name: action.name
  };

  // Add optional fields if they exist in the schema
  // Based on status.json schema documented in validate-status-schema.ps1:
  // - actionType (object/string)
  // - description (string)
  // - repoInfo (object)
  // - tagInfo, releaseInfo (version information)
  // - forkFound, mirrorLastUpdated, repoSize
  // - secretScanningEnabled, dependabotEnabled, dependabot
  // - vulnerabilityStatus, ossf, ossfScore, ossfDateLastUpdate
  // - dependents, verified

  if (action.actionType) actionData.actionType = action.actionType;
  if (action.description) actionData.description = action.description;
  // AI-generated description (separate field from the real `description`
  // parsed from action.yml) - generated by ai-description-generation.ps1
  // from README + action.yml/yaml content via a local language model.
  if (action.aiDescription) actionData.aiDescription = action.aiDescription;
  if (action.aiDescriptionGeneratedAt) actionData.aiDescriptionGeneratedAt = action.aiDescriptionGeneratedAt;
  if (action.aiDescriptionModel) actionData.aiDescriptionModel = action.aiDescriptionModel;
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

  // Current immutable-release policy tri-state (issue #264) - "enabled",
  // "disabled" or "unknown". A missing/unavailable API result must never be
  // collapsed into "disabled", so this is passed through exactly as recorded,
  // together with its provenance (source/reason) and timestamps.
  if (action.immutableReleasePolicy) actionData.immutableReleasePolicy = action.immutableReleasePolicy;
  if (action.immutableReleasePolicyCheckedAt) actionData.immutableReleasePolicyCheckedAt = action.immutableReleasePolicyCheckedAt;
  if (action.immutableReleasePolicyReason) actionData.immutableReleasePolicyReason = action.immutableReleasePolicyReason;
  if (action.immutableReleasePolicySource) actionData.immutableReleasePolicySource = action.immutableReleasePolicySource;
  // When the policy was last observed to actually change value (issue #266) -
  // distinct from immutableReleasePolicyCheckedAt, which is bumped on every
  // check regardless of whether the value changed.
  if (action.immutableReleasePolicyChangedAt) actionData.immutableReleasePolicyChangedAt = action.immutableReleasePolicyChangedAt;

  // Append-only per-release immutable-release observation history (issue #265).
  // Passed through as-is - the API upsert path must not drop or collapse this
  // history. (Unlike tagInfo/releaseInfo below, this is intentionally not
  // trimmed here: trimming would mean silently dropping observations for
  // releases that are no longer "latest", which the append-only/no-erase
  // acceptance criteria for this history explicitly rules out.)
  if (action.immutableReleaseObservations) actionData.immutableReleaseObservations = action.immutableReleaseObservations;
  if (action.immutableReleaseObservationsCheckedAt) actionData.immutableReleaseObservationsCheckedAt = action.immutableReleaseObservationsCheckedAt;
  // Derived immutable-release coverage summary for the ten newest releases
  // (issue #266) - a small object, passed through as-is so #267's reports/API
  // can consume it without recomputing it from the raw observation history.
  if (action.immutableReleaseCoverage) actionData.immutableReleaseCoverage = action.immutableReleaseCoverage;
  // Concise human-readable rendering combining the current policy with the
  // recent-release coverage summary (issue #267), e.g. "Enabled; 7 of 8 known
  // releases immutable (last 10; 2 unknown)". Computed by
  // Get-ImmutableReleaseSummary (library.ps1) and persisted alongside the
  // fields above - never recomputed here, so the API always reflects exactly
  // what was last observed.
  if (action.immutableReleaseSummary) actionData.immutableReleaseSummary = action.immutableReleaseSummary;

  // Trim tag list to the latest tags, preferring SemVer ordering and
  // falling back to alphabetical if SemVer parsing fails.
  trimTagInfoToLatest(actionData, 10);

  // Trim release list to the latest releases, using same SemVer logic
  trimReleaseInfoToLatest(actionData, 10);

  return actionData;
}

async function uploadActions() {
  const apiUrl = process.argv[2];
  const functionKey = process.argv[3];
  const actionsJsonPath = process.argv[4];
  const maxUploadsArg = process.argv[5];
  const { ActionsMarketplaceClient } = require('@devops-actions/actions-marketplace-client');
  
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

    const key = action.owner + '/' + action.name;

    // Build the action data for the API outside try block so it's accessible in catch
    const actionData = buildActionData(action);

    try {
      console.log('Uploading: [' + key + ']');

      // Check if this action needs to be updated based on repoInfo.updated_at
      const existing = existingIndex.get(key);
      if (!needsUpdate(existing, actionData)) {
        skippedNotUpdatedCount++;
        console.log('  ↷ Skipped - not updated since last upload');
        continue;
      }

      // Compute payload length so we can more easily detect when we are
      // approaching the Azure Table Storage per-property limit (~32K
      // characters for UTF-16 strings, i.e. 64KB).
      try {
        const payloadLength = JSON.stringify(actionData).length;
        if (payloadLength > 32000) {
          console.warn('  ⚠️ Payload size [' + payloadLength + '] characters may exceed Azure Table 32K-character limit per property (64KB UTF-16).');
        }
      } catch (jsonError) {
        console.error('  ⚠️ Failed to compute payload size: ' + jsonError.message);
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
      
      // Log array sizes for diagnostic purposes
      const tagCount = Array.isArray(actionData.tagInfo) ? actionData.tagInfo.length : 0;
      const releaseCount = Array.isArray(actionData.releaseInfo) ? actionData.releaseInfo.length : 0;
      console.error('  📊 tagInfo count: ' + tagCount + ', releaseInfo count: ' + releaseCount);
      
      if (error && error.details) {
        try {
          console.error('  Details: ' + JSON.stringify(error.details));
        } catch {
          // ignore JSON stringify issues
        }
      }
      
      // Write failing action to file for debugging
      try {
        const path = require('path');
        const failedDir = 'failed-uploads';
        if (!fs.existsSync(failedDir)) {
          fs.mkdirSync(failedDir, { recursive: true });
        }
        const safeName = (action.owner + '_' + action.name).replace(/[^a-zA-Z0-9_-]/g, '_');
        const failedFile = path.join(failedDir, safeName + '.json');
        fs.writeFileSync(failedFile, JSON.stringify(actionData, null, 2));
        console.error('  💾 Failed action data written to: ' + failedFile);
      } catch (writeError) {
        console.error('  ⚠️ Could not write failed action to file: ' + writeError.message);
      }
      
      results.push({
        success: false,
        action: action.owner + '/' + action.name,
        error: summary
      });
    }
  }
  
  // Calculate delta: how many actions in the full list would need updates
  // based on the same updated_at comparison criteria.
  let actionsNeedingUpdates = 0;
  let actionsInApiNotInStatus = 0;
  let actionsUpToDate = 0;
  let totalValidActions = 0;
  
  // Build statusKeys set once for efficient lookup
  const statusKeys = new Set();
  
  // Count actions from status.json that need updates
  for (const action of actions) {
    if (!isValidAction(action)) {
      continue;
    }
    totalValidActions++;
    const key = action.owner + '/' + action.name;
    statusKeys.add(key);
    
    const existing = existingIndex.get(key);
    if (needsUpdate(existing, action)) {
      actionsNeedingUpdates++;
    } else {
      actionsUpToDate++;
    }
  }
  
  // Count actions in API that are not in status.json (orphaned)
  for (const key of existingIndex.keys()) {
    if (!statusKeys.has(key)) {
      actionsInApiNotInStatus++;
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
  
  // Output delta statistics for reconciliation tracking
  console.log('__DELTA_STATS_START__');
  console.log(JSON.stringify({
    totalInStatusJson: totalValidActions,
    totalInApi: existingIndex.size,
    actionsNeedingUpdates: actionsNeedingUpdates,
    actionsUpToDate: actionsUpToDate,
    actionsInApiNotInStatus: actionsInApiNotInStatus
  }, null, 2));
  console.log('__DELTA_STATS_END__');

  // Output results as JSON for PowerShell to parse
  console.log('__RESULTS_JSON_START__');
  console.log(JSON.stringify(results, null, 2));
  console.log('__RESULTS_JSON_END__');
}

if (require.main === module) {
  uploadActions().catch(error => {
    console.error('Fatal error:', error);
    process.exit(1);
  });
}

module.exports = {
  uploadActions,
  formatDuration,
  formatErrorForSummary,
  parseSemverLike,
  compareTagStringsDesc,
  immutableReleaseObservationsChanged,
  immutableReleaseCoverageChanged,
  immutableReleasePolicyChanged,
  trimTagInfoToLatest,
  trimReleaseInfoToLatest,
  needsUpdate,
  isValidAction,
  buildActionData
};
