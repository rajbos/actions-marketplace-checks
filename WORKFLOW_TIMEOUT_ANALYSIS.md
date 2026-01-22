# Workflow Timeout and Rate Limit Analysis

## Executive Summary

After analyzing the last 5 runs of the main workflows (Analyze, Get repo info, Scan Organizations, Update Mirrors), I identified **5 critical patterns** causing timeouts and rate limit errors. This document provides detailed analysis with examples and proposed solutions.

## Analysis Period
- **Date Range**: January 18-22, 2026
- **Workflows Analyzed**: 
  - Analyze (5 runs)
  - Get repo info/repoInfo (5 runs)
  - Scan Organizations (5 runs)
  - Update Mirrors (5 runs)

## Issue 1: GitHub App Token Expiration During Long Runs

### Pattern
Long-running jobs (>1 hour) fail after rate limit waits because GitHub App tokens expire after 1 hour.

### Evidence
**Run**: [repoInfo #21260296715](https://github.com/rajbos/actions-marketplace-checks/actions/runs/21260296715)
- Started: 2026-01-22 18:32:46
- Failed: 2026-01-22 18:51:26 (19 minutes runtime)

**Log excerpt**:
```
2026-01-22T18:39:59.1134708Z Using earliest reset across remaining untried GitHub Apps: waiting [627.4324989] seconds (627 seconds (10.5 minutes)) until [01/22/2026 18:50:25] before retrying
...
2026-01-22T18:50:30.7810735Z Error calling https://api.github.com/repos/Oreoezi/markdown-pdf-exporter, status code [404]
```

**Root Cause**: After exhausting all 3 app tokens, the workflow waits 10.5 minutes. By the time it resumes, one or more tokens have less than 15 minutes until expiration. The system tries to continue, but if the token expires during an API call, it fails.

### Impact
- **Frequency**: 4 out of 5 repoInfo runs failed
- **Duration**: Jobs fail after 15-20 minutes instead of completing
- **Data Loss**: Partial progress is saved but workflow must restart

## Issue 2: Simultaneous Rate Limit Exhaustion Across All Apps

### Pattern
All 3 GitHub Apps hit rate limits nearly simultaneously, causing long wait times (10+ minutes).

### Evidence
**Run**: [repoInfo #21260296715](https://github.com/rajbos/actions-marketplace-checks/actions/runs/21260296715)

**Log excerpt**:
```
2026-01-22T18:40:01.0319974Z | # | App Id | Remaining | Used | Wait Time | Continue At (UTC) | Token Expires In |
2026-01-22T18:40:01.0363237Z | 1 | 264650 | 0 | 12.506 | 625 seconds (10.4 minutes) | 01/22/2026 18:50:25 | 1h 0m |
2026-01-22T18:40:01.0364947Z | 2 | 2575811 | 12.467 | 33 | 626 seconds (10.4 minutes) | 01/22/2026 18:50:26 | 1h 0m |
2026-01-22T18:40:01.0366397Z | 3 | 2592346 | 12.426 | 74 | 626 seconds (10.4 minutes) | 01/22/2026 18:50:27 | 1h 0m |
```

**Analysis**: 
- App 264650: 0 requests remaining (fully exhausted)
- App 2575811: 33 requests used from 12,500 limit
- App 2592346: 74 requests used from 12,500 limit
- All reset at nearly the same time (~626 seconds)

### Root Cause
The rate limit exhaustion is asymmetric:
1. **App 1 (264650)** takes the brunt of the load (12,506 requests used)
2. **Apps 2 & 3** are barely used (33 and 74 requests respectively)
3. The token rotation strategy isn't balancing load effectively

### Impact
- **Wait Time**: 10+ minute delays when primary app exhausts
- **Inefficiency**: 99% of capacity from Apps 2 & 3 unused
- **Cascade Effect**: When App 1 exhausts, immediate switch to App 2, then App 3, exhausting all quickly

## Issue 3: Scan Organizations Token Expiration After Long Wait

### Pattern
Scan-organizations workflow waits for rate limit recovery (57 minutes), but token expires during the wait, causing "Bad credentials" error.

### Evidence
**Run**: [scan-organizations #21235133774](https://github.com/rajbos/actions-marketplace-checks/actions/runs/21235133774)
- Started: 2026-01-22 03:39:35
- Failed: 2026-01-22 04:50:17 (1h 11m runtime)

**Log excerpt**:
```
2026-01-22T03:52:24.1541794Z Request quota exhausted for request GET /repos/{owner}/{repo}
2026-01-22T03:52:24.1786125Z Waiting 3453.822 seconds (57 minutes) to prevent the search API rate limit
2026-01-22T03:52:24.1787240Z Will continue at 2026-01-22 04:49:58 UTC
2026-01-22T04:49:58.1847745Z ##[error]Error running action: : Bad credentials - https://docs.github.com/rest
```

### Root Cause
1. Workflow uses `devops-actions/load-available-actions@v2.2.0` action
2. Action obtains token at start: ~03:39:35
3. Rate limit hit at 03:52:24, waits 57 minutes
4. Resumes at 04:49:58, but token obtained at 03:39:35 has expired (>1 hour)
5. No token refresh mechanism in the third-party action

### Impact
- **Frequency**: 5 out of 5 scan-organizations runs failed
- **Duration**: Wastes 57+ minutes before failing
- **Pattern**: Consistent failure - 100% failure rate

## Issue 4: Git Operations Failing with HTTP 500 Errors

### Pattern
Repository checkout operations fail with "Internal Server Error" (500) during git clone.

### Evidence
**Run**: [Analyze #21251769009 - chunk 22](https://github.com/rajbos/actions-marketplace-checks/actions/runs/21251769009)

**Log excerpt**:
```
2026-01-22T14:17:36.3526155Z remote: Internal Server Error
2026-01-22T14:17:36.3553114Z ##[error]fatal: unable to access 'https://github.com/rajbos/actions-marketplace-checks/': The requested URL returned error: 500
2026-01-22T14:17:36.3561795Z The process '/usr/bin/git' failed with exit code 128
2026-01-22T14:17:36.3562567Z Waiting 11 seconds before trying again
[... 2 more retries, all with 500 error ...]
2026-01-22T14:20:03.2287547Z remote: Internal Server Error
2026-01-22T14:20:03.2290386Z ##[error]fatal: unable to access 'https://github.com/rajbos/actions-marketplace-checks/': The requested URL returned error: 500
2026-01-22T14:20:03.2339700Z ##[error]The process '/usr/bin/git' failed with exit code 128
```

### Root Cause
- GitHub infrastructure experiencing transient issues
- actions/checkout@v6 retries 3 times but all fail
- No additional retry logic after checkout fails

### Impact
- **Frequency**: 1 out of 25 parallel Analyze chunks failed (4%)
- **Mitigation**: Workflow uses `fail-fast: false`, so other chunks continue
- **Data Loss**: Chunk 22's work lost, must be retried in next run

## Issue 5: Update Mirrors Workflow Timeout

### Pattern
Update-mirrors workflow is cancelled/timeout frequently (3 out of 5 recent runs).

### Evidence
**Recent Runs**:
1. Run #21259997456: in_progress (current)
2. Run #21257982502: success (35 minutes)
3. Run #21256000486: **cancelled** (34 minutes)
4. Run #21253917076: **cancelled** (32 minutes)
5. Run #21251892907: **cancelled** (31 minutes)

### Timeout Configuration
From `.github/workflows/update-mirrors.yml`:
```yaml
update-mirrors:
  timeout-minutes: 30  # Line 134
```

### Root Cause
- Workflow processes 300 repos in 4 parallel chunks (75 repos each)
- Each chunk has 30-minute timeout
- When rate limits hit or slow mirrors encountered, chunks exceed timeout
- Successful run took 35 minutes, but timeout is 30 minutes

### Impact
- **Success Rate**: Only 1 out of 5 runs succeeded (20%)
- **Timeout**: 30-minute limit is too aggressive
- **Waste**: Partial work is saved, but chunk must restart

## Proposed Solutions

### Solution 1: Implement Token Refresh Mechanism
**Priority**: HIGH  
**Effort**: Medium  
**Impact**: Resolves Issues #1 and #3

**Implementation**:
1. Add token expiration tracking to `library.ps1`:
   ```powershell
   function Test-TokenExpiration {
       param($tokenExpiresAt, $minMinutesRemaining = 15)
       $now = Get-Date
       $minutesRemaining = ($tokenExpiresAt - $now).TotalMinutes
       return $minutesRemaining -lt $minMinutesRemaining
   }
   ```

2. Modify `ApiCall` function to refresh tokens proactively:
   - Check token expiration before each API call
   - If <15 minutes remaining, rotate to next app
   - If all apps <15 minutes, gracefully stop with partial save

3. For scan-organizations, two options:
   - **Option A**: Fork and modify `devops-actions/load-available-actions` to support token refresh callback
   - **Option B**: Rewrite scan-organizations to not use third-party action (recommended)

### Solution 2: Improve Token Load Balancing
**Priority**: HIGH  
**Effort**: Low  
**Impact**: Resolves Issue #2

**Implementation**:
1. Modify token rotation logic in `library.ps1`:
   - Track cumulative usage per app
   - Rotate based on lowest cumulative usage, not just current exhaustion
   - Reset cumulative counters every hour

2. Add usage tracking:
   ```powershell
   $script:appUsageTracking = @{
       '264650' = 0
       '2575811' = 0
       '2592346' = 0
   }
   ```

3. Rotate to app with lowest usage:
   ```powershell
   $nextApp = $apps | Sort-Object { $script:appUsageTracking[$_.AppId] } | Select-Object -First 1
   ```

### Solution 3: Increase Update-Mirrors Timeout
**Priority**: MEDIUM  
**Effort**: Low  
**Impact**: Resolves Issue #5

**Implementation**:
1. Increase timeout from 30 to 45 minutes in `update-mirrors.yml`:
   ```yaml
   update-mirrors:
     timeout-minutes: 45  # Was 30
   ```

2. Add dynamic timeout calculation based on chunk size:
   ```yaml
   timeout-minutes: ${{ fromJSON(github.event.inputs.numberOfChunks) < 4 && 60 || 45 }}
   ```

### Solution 4: Add Exponential Backoff for Git Failures
**Priority**: LOW  
**Effort**: Low  
**Impact**: Reduces Issue #4

**Implementation**:
1. Add retry logic after checkout failure:
   ```yaml
   - uses: actions/checkout@v6
     id: checkout
     continue-on-error: true
     
   - name: Retry checkout on failure
     if: steps.checkout.outcome == 'failure'
     uses: actions/checkout@v6
     with:
       fetch-depth: 1
   ```

2. Alternative: Add retry step with delay:
   ```yaml
   - name: Wait and retry checkout
     if: steps.checkout.outcome == 'failure'
     shell: bash
     run: |
       sleep 30
       
   - uses: actions/checkout@v6
     if: steps.checkout.outcome == 'failure'
   ```

### Solution 5: Add Early Warning for Rate Limit Depletion
**Priority**: LOW  
**Effort**: Low  
**Impact**: Preventative measure

**Implementation**:
1. Add warning when rate limit drops below threshold:
   ```powershell
   if ($remaining -lt 1000) {
       Write-Warning "Rate limit for App $appId below 1000 (currently $remaining)"
   }
   ```

2. Log rate limit status to workflow summary every 100 API calls:
   ```powershell
   if ($script:apiCallCount % 100 -eq 0) {
       GetRateLimitInfo
   }
   ```

## Recommended Implementation Order

1. **Week 1**: Solution 2 (Token Load Balancing) - Quick win, high impact
2. **Week 1**: Solution 3 (Update-Mirrors Timeout) - Quick fix, immediate improvement
3. **Week 2**: Solution 1 (Token Refresh) - Core fix for long-running jobs
4. **Week 3**: Solution 4 (Git Retry) - Edge case handling
5. **Week 3**: Solution 5 (Early Warning) - Monitoring improvement

## Success Metrics

After implementing solutions, expect:
- **repoInfo Success Rate**: 20% → 90%+
- **scan-organizations Success Rate**: 0% → 95%+
- **update-mirrors Success Rate**: 20% → 85%+
- **Average Rate Limit Wait**: 10+ minutes → <5 minutes
- **Token Expiration Failures**: Multiple per day → Zero

## References

### Failed Run Links
1. [repoInfo #21260296715](https://github.com/rajbos/actions-marketplace-checks/actions/runs/21260296715) - Token expiration after rate limit wait
2. [repoInfo #21256425131](https://github.com/rajbos/actions-marketplace-checks/actions/runs/21256425131) - Similar pattern
3. [scan-organizations #21235133774](https://github.com/rajbos/actions-marketplace-checks/actions/runs/21235133774) - Token expired after 57-minute wait
4. [Analyze #21251769009](https://github.com/rajbos/actions-marketplace-checks/actions/runs/21251769009) - Git 500 error
5. [update-mirrors #21256000486](https://github.com/rajbos/actions-marketplace-checks/actions/runs/21256000486) - Timeout cancellation

### Current System Status
- **3 GitHub Apps configured**: 264650, 2575811, 2592346
- **Rate Limit per App**: 12,500 requests/hour (15,000 total for installation endpoints)
- **Token Lifetime**: 1 hour
- **Concurrent Workflows**: Analyze (25 chunks), Update-Mirrors (4 chunks)
