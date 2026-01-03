# Rate Limit Fallback Feature - Behavior Summary

## Overview
This document describes the behavior of the rate limit fallback feature in the Update Mirrors workflow.

## Scenarios

### Scenario 1: Primary Token Has Sufficient Rate Limit
```
Primary Token Status:
- Remaining: 4000 calls
- Wait Time: 0 minutes
- Status: ✅ Good

Result:
- Uses primary token for all operations
- No fallback needed
- Step Summary: "Using primary token (remaining: 4000 calls)"
```

### Scenario 2: Primary Token Rate Limited, Secondary Available
```
Primary Token Status:
- Remaining: 10 calls
- Wait Time: 25 minutes
- Status: ❌ Rate Limited

Secondary Token Status:
- Remaining: 3500 calls
- Wait Time: 0 minutes
- Status: ✅ Good

Result:
- Automatically falls back to secondary token
- Processing continues without interruption
- Step Summary: "Fell back to secondary token (primary wait: 25 min, secondary remaining: 3500 calls)"
```

### Scenario 3: Primary Rate Limited, No Secondary Configured
```
Primary Token Status:
- Remaining: 5 calls
- Wait Time: 30 minutes
- Status: ❌ Rate Limited

Secondary Token:
- Not configured

Result:
- Cannot proceed with processing
- Chunk is skipped gracefully
- Will retry on next scheduled run
- Step Summary: "Primary token rate limited (wait: 30 min, remaining: 5). No secondary token configured."
```

### Scenario 4: Both Tokens Rate Limited
```
Primary Token Status:
- Remaining: 10 calls
- Wait Time: 25 minutes
- Status: ❌ Rate Limited

Secondary Token Status:
- Remaining: 5 calls
- Wait Time: 35 minutes
- Status: ❌ Rate Limited

Result:
- Cannot proceed with processing
- Chunk is skipped gracefully
- Will retry on next scheduled run
- Step Summary: "Both tokens rate limited. Primary: wait 25 min (remaining: 10). Secondary: wait 35 min (remaining: 5)."
```

### Scenario 5: Primary Low but Acceptable Wait Time
```
Primary Token Status:
- Remaining: 50 calls
- Wait Time: 5 minutes
- Status: ✅ Acceptable (wait < 20 minutes)

Result:
- Uses primary token (short wait time is acceptable)
- No fallback needed
- Processing continues normally
- Step Summary: "Using primary token (remaining: 50 calls)"
```

## Configuration

### Without Secondary Token (Current Behavior)
- Only primary token (GitHub App ID 264650) is used
- If rate limited, chunk is skipped
- No fallback available

### With Secondary Token (Enhanced Behavior)
- Primary token (GitHub App ID 264650) is checked first
- If rate limited, secondary token (GitHub App ID 264651) is used
- Both tokens must be rate limited before skipping
- Doubles the effective rate limit capacity

## Setup Instructions

To enable the secondary token fallback:

1. Create a second GitHub App with the same permissions as the primary app
2. Install the app on the `actions-marketplace-validations` organization
3. Add the app's private key as a repository secret named `Automation_App_Key_2`
4. Update the `application_id` in the workflow if different from 264651

The feature is backward compatible - if `Automation_App_Key_2` is not set, the workflow operates as before.

## Rate Limit Thresholds

The token selection logic uses the following thresholds (configurable):
- **Minimum Remaining Calls**: 50 (default: can be adjusted in the script)
- **Maximum Wait Time**: 20 minutes (default: matches existing behavior)

A token is considered usable if:
- It has >= 50 API calls remaining, OR
- The rate limit reset time is <= 20 minutes away

## Benefits

1. **Increased Resilience**: Workflow can continue processing even when one token is rate limited
2. **Better Throughput**: Effectively doubles the rate limit capacity
3. **Transparent Operation**: Clear step summary messages explain which token is being used
4. **Graceful Degradation**: If both tokens are exhausted, chunk is safely skipped with clear messaging
5. **Backward Compatible**: Works without changes if secondary token is not configured

## Testing

All functionality is covered by automated tests:
- `tests/tokenFallback.Tests.ps1`: 9 tests for token selection logic
- `tests/updateMirrorsChunkFallback.Tests.ps1`: 6 integration tests for chunk processing
- All 564 tests in the suite pass

## Monitoring

Check the workflow step summary after each run to see:
- Which token was selected and why
- Rate limit status of both tokens (if secondary is configured)
- Whether any chunks were skipped due to rate limits
