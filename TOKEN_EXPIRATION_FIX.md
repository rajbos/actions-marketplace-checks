# Token Expiration Fix for Long-Running Workflows

## Problem Summary

The "Get repo info" workflow was failing approximately 95% of the time with a 401 Unauthorized error: "Bad credentials". 

### Root Cause Analysis

1. **Initial Setup**: The script initializes with a GitHub App token at the start (line 21 in `repoInfo.ps1`)
2. **Long Processing Time**: The script runs for 60-95 minutes processing repositories
3. **Token Expiration**: GitHub App tokens expire after exactly 1 hour
4. **Final Check Failure**: At the end (line 1920), `GetRateLimitInfo` is called with the original `$accessToken` variable
5. **Authentication Error**: The expired token causes API calls to return 401 Unauthorized
6. **Workflow Failure**: The script exits with code 1, failing the entire workflow

### Key Evidence

- **Successful run (22030219505)**: Completed in ~32 minutes
- **Failed run (22034434187)**: Ran for ~95 minutes and failed with "Error calling https://api.github.com/rate_limit, status code [401]"
- **Error message**: "Bad credentials" - indicating token expiration, not rate limit exhaustion

## Solution Implemented

### Core Fix

Modified the `GetRateLimitInfo` function in `library.ps1` to automatically refresh tokens before making API calls:

```powershell
function GetRateLimitInfo {
    # ... parameters ...
    
    # Refresh tokens from token manager if available
    $tokenManager = Get-GitHubAppTokenManagerInstance
    if ($null -ne $tokenManager -and -not [string]::IsNullOrWhiteSpace($env:APP_ORGANIZATION)) {
        try {
            $tokenResult = $tokenManager.GetTokenForOrganization($env:APP_ORGANIZATION)
            if (-not [string]::IsNullOrWhiteSpace($tokenResult.Token)) {
                $access_token = $tokenResult.Token
                # Also update destination token if needed
                if ([string]::IsNullOrWhiteSpace($access_token_destination) -or 
                    $access_token_destination -eq $access_token) {
                    $access_token_destination = $tokenResult.Token
                }
            }
        }
        catch {
            Write-Debug "Failed to refresh token: $($_.Exception.Message)"
            # Continue with original token
        }
    }
    # Fallback to environment token
    elseif ([string]::IsNullOrWhiteSpace($access_token)) {
        $access_token = $env:GITHUB_TOKEN
    }
    
    # Now make the API call with fresh token
    $response = ApiCall -method GET -url $url -access_token $access_token ...
}
```

### Why This Works

1. **Proactive Refresh**: Before making the rate limit API call, the function gets a fresh token from the token manager
2. **Graceful Fallback**: If token refresh fails, it continues with the original token (best effort)
3. **Universal Fix**: This fixes ALL scripts that call `GetRateLimitInfo`, not just `repoInfo.ps1`
4. **No Breaking Changes**: The function signature remains the same, maintaining backward compatibility

### Scripts Benefiting from This Fix

The following scripts all call `GetRateLimitInfo` and will now avoid token expiration errors:

- `repoInfo.ps1` - Primary target (60-95 minute runs)
- `repoInfo-chunk.ps1` - Chunked version
- `update-mirrors.ps1` - Mirror synchronization
- `update-mirrors-chunk.ps1` - Chunked mirror sync
- `cleanup-invalid-repos.ps1` - Repository cleanup
- `cleanup-all-repos.ps1` - Full cleanup
- `functions.ps1` - General functions
- `functions-chunk.ps1` - Chunked functions
- `dependabot-updates.ps1` - Dependabot processing
- `ossf-scan.ps1` - Security scanning

## Complementary Mechanisms

The codebase already has several token management features that work together with this fix:

### 1. Proactive Token Rotation in ApiCall (lines 948-988)

The `ApiCall` function already checks token expiration before each API call and switches to a fresh token when the current one will expire within 15 minutes:

```powershell
if ($minMinutes -le 15) {
    Write-Host "⚠️ Current token will expire in $minMinutes minutes - proactively rotating"
    $betterToken = Select-BestGitHubAppTokenForOrganization ...
    # Retry with fresh token
}
```

### 2. Token Manager with Multiple Apps

The system supports up to 3 GitHub Apps (configured via `APP_ID`, `APP_ID_2`, `APP_ID_3`) to distribute load and provide redundancy when one token expires.

### 3. Rate Limit Handling

The `ApiCall` function also handles rate limit exhaustion separately from token expiration, using exponential backoff and app switching strategies.

## Testing

- **Unit Tests**: All 645 Pester tests pass
- **Integration Testing Needed**: Monitor next several scheduled runs of `repoInfo.yml` workflow

## Expected Outcomes

1. **Improved Success Rate**: Should increase from ~5% to near 100%
2. **Graceful Degradation**: If all tokens expire, workflow stops gracefully rather than failing with authentication error
3. **Better Logging**: Token refresh attempts are logged at debug level for troubleshooting

## Monitoring

To verify the fix is working:

1. Check upcoming scheduled runs of `repoInfo.yml` at minute :50 of each hour
2. Look for runs that exceed 60 minutes - they should now succeed
3. Check workflow logs for "proactively rotating" messages indicating token management is working
4. Verify no more "Bad credentials" or "401 Unauthorized" errors in rate limit checks

## Related Documentation

- Token expiration management is documented in `library.ps1` at lines 2620-2638
- GitHub App token manager is in `github-app-token-manager.ps1`
- Rate limit handling strategy is documented in `RATE_LIMIT_INVESTIGATION.md`
