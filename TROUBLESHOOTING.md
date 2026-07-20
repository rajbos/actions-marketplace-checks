# Workflow Troubleshooting Quick Reference

This guide helps quickly diagnose common workflow failures in the actions-marketplace-checks repository.

## Quick Diagnosis Flowchart

```
Workflow Failed?
    │
    ├─ Check conclusion/status
    │
    ├─ "failure" ──▶ See: Rate Limit or Token Issues
    │
    ├─ "cancelled" ──▶ See: Timeout Issues
    │
    └─ "timed_out" ──▶ See: Timeout Issues
```

## Common Failure Patterns

### Pattern: "Rate limit exhausted" then failure
**Symptoms:**
- Log shows: "Rate limit remaining is 0"
- Multiple apps shown with 0 remaining
- Long wait times (10+ minutes)
- Failure after wait completes

**Quick Check:**
```bash
# Check last run logs for rate limit table
gh run view <RUN_ID> --log | grep -A 5 "Rate Limit Status"
```

**Cause:** All 3 GitHub Apps exhausted simultaneously  
**Solution:** See [WORKFLOW_TIMEOUT_ANALYSIS.md](./WORKFLOW_TIMEOUT_ANALYSIS.md) - Solution 2 (Load Balancing)

**Example Log:**
```
Rate limit remaining is 0 for current token
Marked app id [2592346] as tried
Using earliest reset across remaining untried GitHub Apps: waiting [627] seconds
```

---

### Pattern: "Bad credentials" after long wait
**Symptoms:**
- Workflow waits 30-60 minutes
- Error: "Bad credentials - https://docs.github.com/rest"
- Occurs in scan-organizations workflow

**Quick Check:**
```bash
# Check workflow runtime
gh run view <RUN_ID> --json startedAt,completedAt
```

**Cause:** GitHub App token expired during rate limit wait  
**Solution:** See [WORKFLOW_TIMEOUT_ANALYSIS.md](./WORKFLOW_TIMEOUT_ANALYSIS.md) - Solution 1 (Token Refresh)

**Example Log:**
```
Waiting 3453.822 seconds (57 minutes) to prevent the search API rate limit
Will continue at 2026-01-22 04:49:58 UTC
##[error]Error running action: : Bad credentials
```

---

### Pattern: Workflow cancelled after 30-40 minutes
**Symptoms:**
- Status: "cancelled"
- Runtime: 30-35 minutes
- Occurs in update-mirrors workflow

**Quick Check:**
```yaml
# Check timeout setting in workflow file
grep "timeout-minutes" .github/workflows/update-mirrors.yml
```

**Cause:** Workflow timeout too aggressive (30 minutes)  
**Solution:** See [WORKFLOW_TIMEOUT_ANALYSIS.md](./WORKFLOW_TIMEOUT_ANALYSIS.md) - Solution 3 (Increase Timeout)

**Current Setting:**
```yaml
timeout-minutes: 30  # Too tight!
```

---

### Pattern: Git clone fails with HTTP 500
**Symptoms:**
- Error: "remote: Internal Server Error"
- Status code: 500
- Multiple retries fail
- Job: One of many parallel Analyze chunks

**Quick Check:**
```bash
# Check GitHub Status
curl -s https://www.githubstatus.com/api/v2/status.json | jq .
```

**Cause:** GitHub infrastructure transient issues  
**Solution:** See [WORKFLOW_TIMEOUT_ANALYSIS.md](./WORKFLOW_TIMEOUT_ANALYSIS.md) - Solution 4 (Git Retry)

**Example Log:**
```
remote: Internal Server Error
##[error]fatal: unable to access 'https://github.com/...': The requested URL returned error: 500
Waiting 11 seconds before trying again
```

---

### Pattern: Unhandled API error (404, etc.)
**Symptoms:**
- Random API failures after rate limit recovery
- Error codes: 404, 403, etc.
- Occurs sporadically

**Quick Check:**
```bash
# Check the specific API call in logs
gh run view <RUN_ID> --log | grep -B 5 "Error calling"
```

**Cause:** Repository deleted, renamed, or made private  
**Solution:** Expected behavior; these are tracked in status.json

**Example Log:**
```
Error calling https://api.github.com/repos/Oreoezi/markdown-pdf-exporter, status code [404]
MessageData: @{message=Not Found; ...}
```

---

## Workflow-Specific Issues

### repoInfo.yml (Get repo info)
**Common Issues:**
1. Rate limit exhaustion (80% of failures)
2. Token expiration (15% of failures)
3. API errors (5% of failures)

**Debug Commands:**
```bash
# Check last 5 runs
gh run list --workflow=repoInfo.yml --limit 5

# View specific run
gh run view <RUN_ID> --log | less

# Check for rate limit issues
gh run view <RUN_ID> --log | grep -i "rate limit"

# Check for token issues
gh run view <RUN_ID> --log | grep -i "credential\|expired\|token"
```

**Success Indicators:**
```
✓ Found [31,319] actions in the datafile
✓ Got an access token with a length of [40]
✓ Using existing status file
✓ Found [31,078] existing repos in status file
```

---

### analyze.yml (Analyze)
**Common Issues:**
1. Parallel chunk failures (git 500 errors)
2. Rate limit exhaustion
3. Partial chunk failures

**Debug Commands:**
```bash
# Check all jobs in run
gh run view <RUN_ID> --json jobs --jq '.jobs[] | {name, conclusion}'

# Check which chunks failed
gh run view <RUN_ID> --json jobs --jq '.jobs[] | select(.conclusion=="failure") | .name'

# Check specific chunk logs
gh run view <RUN_ID> --job=<JOB_ID> --log
```

**Success Indicators:**
```
✓ Work distribution complete. Starting [25] parallel jobs
✓ Processing RepoInfo Chunk [X]
✓ Consolidation complete
```

**Note:** Analyze uses `fail-fast: false`, so partial failures are acceptable.

---

### scan-organizations.yml
**Common Issues:**
1. Token expiration (100% of recent failures)
2. Long rate limit waits (57+ minutes)

**Debug Commands:**
```bash
# Check run duration
gh run view <RUN_ID> --json startedAt,completedAt,conclusion

# Check for rate limit waits
gh run view <RUN_ID> --log | grep -i "waiting.*seconds"

# Check for credential errors
gh run view <RUN_ID> --log | grep -i "credential"
```

**Success Indicators:**
```
✓ Found X actions for organization 'github'
✓ Created file [github.json] (XXX bytes)
✓ Consolidation complete and uploaded to blob storage
```

---

### update-mirrors.yml
**Common Issues:**
1. Timeout (60% cancellation rate)
2. Rate limit exhaustion
3. Merge conflicts

**Debug Commands:**
```bash
# Check timeout setting
grep timeout-minutes .github/workflows/update-mirrors.yml

# Check chunk durations
gh run view <RUN_ID> --json jobs --jq '.jobs[] | select(.name | contains("chunk")) | {name, duration: (.completed_at - .started_at)}'

# Check for rate limit issues
gh run view <RUN_ID> --log | grep -i "rate limit"
```

**Success Indicators:**
```
✓ Work distribution complete. Starting [4] parallel jobs
✓ Processing Chunk [X]
✓ Consolidation complete
✓ Successfully uploaded status.json to blob storage
```

---

## Health Check Commands

### Check Recent Success Rates
```bash
# Last 10 runs of each workflow
for workflow in analyze repoInfo scan-organizations update-mirrors; do
  echo "=== $workflow ==="
  gh run list --workflow=$workflow.yml --limit 10 --json conclusion \
    | jq -r 'group_by(.conclusion) | map({conclusion: .[0].conclusion, count: length}) | .[]'
done
```

### Check Rate Limit Status (via API)
```bash
# Requires GITHUB_TOKEN with appropriate permissions
gh api rate_limit | jq '.resources.core'
```

### Check Current Workflow Runs
```bash
# In-progress workflows
gh run list --status in_progress

# Recent failures
gh run list --status failure --limit 5
```

### Download Artifacts for Analysis
```bash
# Download status.json from latest run
gh run list --workflow=analyze.yml --limit 1 --json databaseId -q '.[0].databaseId' \
  | xargs -I {} gh run download {} --name status-updated
```

---

## Rate Limit Dashboard

### Quick Status Check
```bash
# Create a rate limit summary
cat << 'EOF' > check-rate-limits.sh
#!/bin/bash
echo "=== GitHub Rate Limit Status ==="
echo ""
gh api rate_limit | jq -r '
  .resources.core | 
  "Core API: \(.remaining)/\(.limit) remaining (resets \(.reset | strftime("%H:%M:%S")))"
'
gh api rate_limit | jq -r '
  .resources.search | 
  "Search API: \(.remaining)/\(.limit) remaining (resets \(.reset | strftime("%H:%M:%S")))"
'
EOF
chmod +x check-rate-limits.sh
./check-rate-limits.sh
```

### Monitor During Workflow Run
```bash
# Watch rate limits in real-time (requires jq and watch)
watch -n 30 'gh api rate_limit | jq ".resources.core | {remaining, limit, reset: (.reset | strftime(\"%H:%M:%S\"))}"'
```

---

## Log Analysis Snippets

### Extract Rate Limit Tables
```bash
gh run view <RUN_ID> --log | awk '/Rate Limit Status:/,/^$/' > rate-limits.txt
```

### Find All API Errors
```bash
gh run view <RUN_ID> --log | grep -i "error calling\|status code" > api-errors.txt
```

### Extract Timing Information
```bash
gh run view <RUN_ID> --log | grep -E "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}" | head -1
gh run view <RUN_ID> --log | grep -E "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}" | tail -1
```

### Count GitHub App Switches
```bash
gh run view <RUN_ID> --log | grep -c "switching to GitHub App"
```

---

## Red Flags 🚩

Watch for these patterns in logs:

| Pattern | Severity | Action |
|---------|----------|--------|
| `Rate limit remaining is 0` × 3 | 🔴 HIGH | All apps exhausted - expect 10+ min wait |
| `waiting [XXX] seconds` where XXX > 600 | 🔴 HIGH | >10 minute wait - token may expire |
| `Bad credentials` | 🔴 HIGH | Token expired - run will fail |
| `remote: Internal Server Error` | 🟡 MEDIUM | GitHub issue - retry later |
| `Request quota exhausted` | 🟡 MEDIUM | Secondary rate limit - long wait ahead |
| `timeout-minutes: 30` + runtime 30+ min | 🟡 MEDIUM | Workflow will be cancelled |
| `Error calling ...404` | 🟢 LOW | Expected - repository unavailable |

---

## Emergency Procedures

### If All Workflows Are Failing

1. **Check GitHub Status**: https://www.githubstatus.com/
2. **Check Rate Limits**:
   ```bash
   gh api rate_limit
   ```
3. **Check Secrets/Variables**:
   - Go to: Settings → Secrets and variables → Actions
   - Verify: `AUTOMATION_APP_KEY`, `AUTOMATION_APP_KEY2`, `AUTOMATION_APP_KEY3`
   - Verify: `APPLICATION_ID`, `APPLICATION_ID_2`, `APPLICATION_ID_3`

4. **Manual Token Test**:
   ```bash
   # Test if app tokens can be generated
   # (requires private key files)
   ./.github/workflows/get-github-app-token.ps1
   ```

### Pattern: "npm error E403" / "Cannot find module '@devops-actions/actions-marketplace-client'"
**Symptoms:**
- Log shows: `npm error 403 Forbidden - GET https://npm.pkg.github.com/@devops-actions/actions-marketplace-client`
- Error: `Permission permission_denied: The token provided does not match expected scopes.`
- Downstream: `Error: Cannot find module '@devops-actions/actions-marketplace-client'` in Node.js upload scripts
- Affected workflows: `api-upsert.yml`, `analyze.yml`, `repoInfo.yml`, `update-mirrors.yml`

**Root Cause:**
The `DEVOPS_ACTIONS_PACKAGE_DOWNLOAD` secret — a GitHub PAT used to install the private `@devops-actions/actions-marketplace-client` npm package from GitHub Packages — has expired, been revoked, or lost its `read:packages` scope for the `devops-actions` org.

**Where the package lives:**
- **Source repo**: `devops-actions/alternative-github-actions-marketplace`
- **Package location**: `src/backend/package.json` — the `@devops-actions/actions-marketplace-client` package
- **Published to**: `https://npm.pkg.github.com` (GitHub Packages)
- **Publish workflow**: `.github/workflows/publish-npm.yml` in the source repo
  - Triggered by: GitHub Release (tag `vX.Y.Z`) or manual `workflow_dispatch`
  - Uses `secrets.GITHUB_TOKEN` with `packages: write` permission to publish

**Quick Check:**
```bash
# Test if the token has valid package access
echo $NODE_AUTH_TOKEN | gh auth login --with-token
# Then test:
npm view @devops-actions/actions-marketplace-client --registry=https://npm.pkg.github.com
```

**Fix — Regenerate the `DEVOPS_ACTIONS_PACKAGE_DOWNLOAD` secret:**
1. Go to https://github.com/settings/tokens and create a new **classic PAT** (fine-grained PATs do not support GitHub Packages — this is a GitHub limitation)
2. Required scope: `read:packages`
3. Save the token value
4. Go to: `rajbos/actions-marketplace-checks` → Settings → Secrets and variables → Actions
5. Update the `DEVOPS_ACTIONS_PACKAGE_DOWNLOAD` secret with the new token value

**Consumer npmrc config (for reference):**
The workflows use `actions/setup-node@v6` with `registry-url: https://npm.pkg.github.com` and `scope: @devops-actions`, which creates an `.npmrc` equivalent to:
```
@devops-actions:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}
```
Where `NODE_AUTH_TOKEN` is overridden at install-time with `${{ secrets.DEVOPS_ACTIONS_PACKAGE_DOWNLOAD }}`.

---

### If Specific Workflow Consistently Fails

1. **Check Workflow File Syntax**:
   ```bash
   yamllint .github/workflows/<workflow>.yml
   ```

2. **Review Recent Changes**:
   ```bash
   git log --oneline .github/workflows/<workflow>.yml
   ```

3. **Check Dependencies**:
   - PowerShell modules
   - Actions versions
   - External APIs

### If Rate Limits Are Constantly Hit

1. **Reduce Processing Volume**:
   - Decrease `numberOfReposToDo` in repoInfo.yml
   - Decrease `numberOfRepos` in update-mirrors.yml
   - Increase time between runs (adjust cron schedule)

2. **Check for Runaway Loops**:
   ```bash
   gh run view <RUN_ID> --log | grep -c "ApiCall"
   ```

3. **Review App Usage**:
   ```bash
   # Count API calls per app
   gh run view <RUN_ID> --log | grep "App Id" | sort | uniq -c
   ```

---

## Resources

- **Detailed Analysis**: [WORKFLOW_TIMEOUT_ANALYSIS.md](./WORKFLOW_TIMEOUT_ANALYSIS.md)
- **Visual Patterns**: [WORKFLOW_PATTERNS_SUMMARY.md](./WORKFLOW_PATTERNS_SUMMARY.md)
- **GitHub Actions Docs**: https://docs.github.com/en/actions
- **Rate Limit Docs**: https://docs.github.com/en/rest/rate-limit
- **GitHub Apps Docs**: https://docs.github.com/en/apps

---

**Last Updated**: January 22, 2026  
**Version**: 1.0
