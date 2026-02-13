# Semver Check Rate Limit Handling

## Overview

The semver-check workflow now includes comprehensive rate limit handling to prevent failures due to GitHub API rate limits. This is particularly important because the workflow checks multiple repositories sequentially and can exhaust both REST API and GraphQL API rate limits.

## GitHub API Rate Limits

GitHub provides different rate limits for different API endpoints:

| API Type | Rate Limit (per GitHub App) | Notes |
|----------|----------------------------|-------|
| Core REST API | 12,500 requests/hour | Used for most GitHub operations |
| GraphQL API | 5,000 points/hour | Lower limit, used by some modules |
| Search API | 30 requests/minute | Very restrictive |

With 3 GitHub Apps configured, the theoretical maximum is:
- Core API: ~37,500 requests/hour
- GraphQL API: ~15,000 points/hour

## Rate Limit Handling Features

### 1. Pre-flight Rate Limit Checks

Before processing each repository, the workflow checks current rate limits:

```powershell
# Check Core API rate limit
if ($rateData.rate.remaining -lt 100) {
    Write-Warning "Core API rate limit is low"
}

# Check GraphQL API rate limit
if ($rateData.resources.graphql.remaining -lt 500) {
    Write-Warning "GraphQL API rate limit is low"
}
```

**Warning Thresholds:**
- Core API: Warning when < 100 remaining
- GraphQL API: Warning when < 500 remaining

### 2. Automatic Waiting for GraphQL Rate Limit

When GraphQL rate limit is critically low (< 100 remaining), the workflow automatically waits for the rate limit to reset:

```powershell
if ($rateData.resources.graphql.remaining -lt 100) {
    # Wait up to 15 minutes for reset
    $waitTime = [math]::Ceiling($timeUntilReset) + 5
    Start-Sleep -Seconds $waitTime
}
```

**Critical Threshold:** < 100 remaining  
**Maximum Wait Time:** 15 minutes (900 seconds)

### 3. Exponential Backoff Retry

When rate limit errors (403, 429) are encountered, the workflow retries with exponential backoff:

| Retry Attempt | Backoff Time |
|---------------|--------------|
| 1 | 60 seconds |
| 2 | 120 seconds |
| 3 | 240 seconds |

**Maximum Retries:** 3 attempts per repository

### 4. Detailed Rate Limit Logging

When rate limit errors occur, the workflow logs comprehensive rate limit information:

```
**Rate Limit Info After Error:**

**Core API:**
- Limit: 12,500
- Used: 12,400
- Remaining: 100
- Resets in: 45 minutes

**GraphQL API:**
- Limit: 5,000
- Used: 4,950
- Remaining: 50
- Resets in: 45 minutes

**Search API:**
- Limit: 30
- Used: 15
- Remaining: 15
- Resets in: 5 minutes
```

### 5. Wait Time Between Repositories

To reduce rate limit pressure, the workflow waits between processing repositories:

**Default Wait Time:** 5 seconds  
**Configurable:** Can be adjusted via workflow input parameter

## Workflow Parameters

The semver-check workflow accepts the following parameters:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `topActionsCount` | Number of top actions to check | 5 |
| `waitBetweenReposSeconds` | Wait time between repos (in seconds) | 5 |

### Example: Increase Wait Time

To reduce rate limit pressure, increase the wait time:

```yaml
workflow_dispatch:
  inputs:
    topActionsCount: '10'
    waitBetweenReposSeconds: '10'  # Wait 10 seconds between repos
```

## Rate Limit Status Display

The workflow now displays separate rate limit tables for Core API and GraphQL API:

### Core API Rate Limits
| # | App Id | Remaining | Used | Wait Time | Continue At (UTC) | Token Expires In |
|---:|-------:|----------:|-----:|-----------|-------------------|------------------|
| 1 | 123456 | 10,234 | 2,266 | 0 seconds | now | 45h 30m |
| 2 | 234567 | 11,500 | 1,000 | 0 seconds | now | 50h 15m |
| 3 | 345678 | 9,876 | 2,624 | 0 seconds | now | 42h 20m |

### GraphQL API Rate Limits
| # | App Id | Limit | Remaining | Used | Resets In |
|---:|-------:|------:|----------:|-----:|-----------|
| 1 | 123456 | 5,000 | 3,456 | 1,544 | 45 minutes |
| 2 | 234567 | 5,000 | 4,200 | 800 | 50 minutes |
| 3 | 345678 | 5,000 | 2,890 | 2,110 | 42 minutes |

## Troubleshooting

### Rate Limit Errors Continue to Occur

If rate limit errors persist despite these safeguards:

1. **Increase wait time between repos:**
   ```yaml
   waitBetweenReposSeconds: '15'  # Increase from 5 to 15 seconds
   ```

2. **Reduce number of actions checked:**
   ```yaml
   topActionsCount: '3'  # Check fewer actions per run
   ```

3. **Check other concurrent workflows:**
   - Ensure analyze, update-mirrors, and repoInfo workflows aren't running simultaneously
   - These workflows are scheduled with 30-minute gaps to avoid rate limit contention

4. **Review rate limit logs:**
   - Check the detailed rate limit info logged when errors occur
   - Identify which API endpoint (Core, GraphQL, Search) is exhausted

### GraphQL Rate Limit Exhaustion

If GraphQL rate limits are consistently being exhausted:

1. **The module may be making more GraphQL calls than expected**
   - Check if the GitHubActionVersioning module has been updated
   - Review module logs for GraphQL query patterns

2. **Other workflows may be using GraphQL**
   - dependabot-updates and repoInfo workflows use PSGraphQL module
   - Ensure these aren't running concurrently with semver-check

## Implementation Details

### Functions Added/Modified

1. **Get-GitHubAppRateLimitOverview** (library.ps1)
   - Enhanced to capture GraphQL rate limit info from `/rate_limit` endpoint
   - Added fields: `GraphQLRemaining`, `GraphQLUsed`, `GraphQLLimit`, `GraphQLReset`

2. **Write-GitHubAppRateLimitOverview** (library.ps1)
   - Modified to display separate tables for Core API and GraphQL API
   - Shows GraphQL limits only when available

3. **Write-DetailedRateLimitInfo** (library.ps1) - NEW
   - Logs comprehensive rate limit info for all API types
   - Includes Core API, GraphQL API, and Search API
   - Formats reset times in human-readable format

4. **Test-ActionSemver** (semver-check.ps1)
   - Added pre-flight rate limit checks
   - Automatic waiting for GraphQL rate limit reset
   - Exponential backoff retry logic
   - Detailed error logging with rate limit info
   - Configurable wait time between repos

## References

- [GitHub Rate Limits Documentation](https://docs.github.com/en/rest/overview/rate-limits-for-the-rest-api)
- [GraphQL API Rate Limits](https://docs.github.com/en/graphql/overview/resource-limitations)
- [Secondary Rate Limits](https://docs.github.com/en/rest/overview/rate-limits-for-the-rest-api#about-secondary-rate-limits)
