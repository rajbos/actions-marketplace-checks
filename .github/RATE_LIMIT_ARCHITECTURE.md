# Rate Limit Architecture

## Overview

This repository uses **3 GitHub Apps** to manage API rate limits across multiple workflows. Each GitHub App has a rate limit of **12,500 requests per hour** for Core API operations, giving us a theoretical maximum of **37,500 requests/hour** across all apps.

## Workflow Scheduling Strategy

To minimize rate limit contention, the three main hourly workflows are scheduled at different times:

| Workflow | Schedule | Parallelism | Duration | Purpose |
|----------|----------|-------------|----------|---------|
| **Analyze** | `:05` (minute 5) | 10 chunks | ~30-40 min | Get repo data for mirrored actions |
| **Update Mirrors** | `:35` (minute 35) | 4 chunks | ~25-30 min | Sync mirrors with upstream repos |
| **Get repo info** | `:50` (minute 50) | 1 job | ~10-15 min | Fork new action repos |

### Rationale

1. **Staggered starts**: 30-minute gaps between workflows prevent peak concurrent usage
2. **Reduced parallelism**: Analyze reduced from 25 to 10 chunks to decrease contention
3. **Concurrency controls**: Each workflow uses `concurrency.group` to prevent overlapping runs

## Rate Limit Handling

### Token Rotation

The `library.ps1` module implements intelligent token rotation:

1. **Per-chunk tracking**: Each chunk resets its `triedAppIds` HashSet at startup
2. **Automatic switching**: When one app is exhausted, automatically switches to the next available app
3. **Reset detection**: Detects when a previously-tried app's rate limit has reset
4. **Graceful degradation**: Stops processing if all apps need >20 minutes to reset

### Key Functions

- `Get-GitHubAppRateLimitOverview`: Gets rate limit status for all configured apps
- `Select-BestGitHubAppTokenForOrganization`: Selects the app with the most remaining quota
- `Test-RateLimitResetIsValid`: Prevents false positive reset detections
- `Reset-TriedGitHubApps`: Clears tried apps tracking at chunk boundaries

### Rate Limit Monitoring

The code includes early warning system that alerts when rate limits drop below thresholds:

- **< 1000 remaining**: Notice (⚡)
- **< 500 remaining**: Warning (⚠️)
- **< 100 remaining**: Critical (🔴)

## Historical Context

### Before (2026-02-08)

**Problem**: Three workflows running at `:01`, `:12`, and `:20` within a 20-minute window created peak contention:
- Analyze: 25 parallel chunks
- Update Mirrors: 4 parallel chunks  
- Get repo info: 1 job
- **Total: Up to 30 concurrent jobs** competing for the same 3 apps

**Symptoms**: Frequent app switching/toggling, rate limit exhaustion, and workflow failures

### After (2026-02-08)

**Solution**: 
1. Spread schedules across full hour (`:05`, `:35`, `:50`)
2. Reduce Analyze parallelism from 25 to 10 chunks
3. Add concurrency controls to prevent workflow overlap

**Expected Result**: 
- Maximum ~14 concurrent jobs (10 Analyze + 4 Update Mirrors) at any moment
- Better app utilization with less contention
- Fewer rate limit exhaustion incidents

## Configuration

### GitHub App Credentials

Workflows use three apps configured via repository variables and secrets:

- `APP_ID`, `APP_ID_2`, `APP_ID_3` (variables)
- `APPLICATION_PRIVATE_KEY`, `APPLICATION_PRIVATE_KEY_2`, `APPLICATION_PRIVATE_KEY_3` (secrets)
- `APP_ORGANIZATION`: `actions-marketplace-validations`

### Tuning Parameters

If rate limit issues persist, consider:

1. **Further reduce parallelism**: Decrease `numberOfChunks` for Analyze (currently 10)
2. **Increase schedule gaps**: Spread workflows further apart (e.g., every 2 hours)
3. **Add more apps**: Configure additional GitHub Apps for higher total capacity
4. **Process fewer repos**: Reduce `numberOfRepos` or `numberOfReposToDo` in workflows

## Monitoring

Monitor rate limit health by:

1. Checking workflow run logs for rate limit warnings
2. Looking for "Rate limit exceeded" or "switching to GitHub App" messages
3. Tracking workflow run durations (increases may indicate contention)
4. Using the "Final Rate Limit Check" section in step summaries

## Troubleshooting

### Symptom: Frequent app switching

**Cause**: Too many concurrent jobs exhausting apps rapidly

**Fix**: Reduce parallelism or spread schedules further

### Symptom: "Stopped execution gracefully" errors

**Cause**: All apps exhausted with >20 minute wait times

**Fix**: 
- Check if other workflows are running concurrently
- Verify app credentials are valid
- Consider adding more GitHub Apps

### Symptom: Workflows timing out

**Cause**: Long waits for rate limit resets

**Fix**:
- Ensure workflows are properly staggered
- Check concurrency controls are working
- Review actual rate limit consumption patterns

## Related Files

- `.github/workflows/library.ps1` - Core rate limit handling logic
- `.github/workflows/github-app-token-manager.ps1` - Token management class
- `.github/workflows/get-github-app-token.ps1` - Low-level token acquisition
- `.github/workflows/*-chunk.ps1` - Chunk processing scripts that use token rotation
