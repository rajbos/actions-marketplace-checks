# GitHub Actions Marketplace information

Goal: Run checks on actions in the marketplace: I have a private datasource of all actions found in the public marketplace that is created and used by my [GitHub Actions Marketplace news](https://devops-actions.github.io/github-actions-marketplace-news/) website, that blogs out updated and new actions (RSS feed available). 

Information being loaded (see the [report workflow](.github/workflows/report.yml)) for all actions in that dataset:

|Information|Description|
|---|---|
|Type of Action|Docker, Node or Composite action|
|Node versions|Node version used (e.g., node12, node16, node20) for Node-based actions|
|Declaration of the Action|action.yml, action.yaml, Dockerfile|
|Docker image setup|Dockerfile in repo or remote image url (e.g. Docker hub, GitHub Container Registry, etc.|
|Security alerts|Fork the Action and enabling Dependabot (works only for Node actions), then read back the security alerts|
|Funding information|Checks for FUNDING.yml file in .github folder, parses it to count funding platforms|

## Cleanup of Invalid Repos

The repository includes a cleanup workflow that automatically identifies and removes forked repos that are no longer valid. This helps keep the `actions-marketplace-validations` organization clean.

### Cleanup Criteria

Repos are marked for cleanup if they meet any of the following criteria:

1. **Original repo no longer exists**: The `forkFound` field is `false`, indicating the original repository has been deleted or is no longer accessible.

2. **Invalid action type**: The action type is marked as "No file found", "No owner found", or "No repo found", indicating the repo doesn't contain a valid action definition.

3. **Empty repo with no content**: The repo has zero size (or null size) AND has no tags/releases AND meets one of the above criteria.

### Running the Cleanup

The cleanup can be run manually via the GitHub Actions workflow:

1. Go to the Actions tab in the repository
2. Select "Cleanup Invalid Repos" workflow
3. Click "Run workflow"
4. Configure the options:
   - **numberOfReposToDo**: Number of repos to process (default: 10)
   - **dryRun**: Set to `true` to preview what would be deleted without actually deleting (default: `true`)

The cleanup also runs automatically on a weekly schedule (Sundays at 2 AM UTC) in dry-run mode.

### Testing

Tests for the cleanup functionality are located in `tests/cleanup.Tests.ps1` and can be run using Pester:

```powershell
Invoke-Pester -Path ./tests/cleanup.Tests.ps1
```
## Workflows

This repository includes several automated workflows:

- **[Analyze](.github/workflows/analyze.yml)**: Forks new action repositories and collects repo data (runs hourly)
- **[Enable Dependabot](.github/workflows/dependabot-updates.yml)**: Automatically enables Dependabot on mirrored repositories to detect security vulnerabilities
- **[Update Mirrors](.github/workflows/update-forks.yml)**: Automatically syncs all mirrored repositories with their upstream sources (runs every 15 minutes)
- **[Generate Report](.github/workflows/report.yml)**: Generates reports on action types, versions, and security status (runs daily)
- **[Environment State Documentation](.github/workflows/environment-state.yml)**: Documents the current state of the environment including coverage, freshness, and health metrics (runs daily at 10 AM UTC)
- **[Validate Status JSON Schema](.github/workflows/validate-status-schema.yml)**: Validates the schema of status.json to detect changes in data structure (runs every Friday at 9 AM UTC)

### Status JSON Schema Validation

The Validate Status JSON Schema workflow ensures the structure of `status.json` remains consistent and alerts maintainers when schema changes are detected. This workflow:

1. **Downloads status.json** from Azure Blob Storage
2. **Validates each object** against the expected schema defined in the validation script
3. **Reports warnings** for minor inconsistencies (e.g., missing optional fields)
4. **Fails the workflow** if critical schema violations are detected (e.g., wrong data types)

The workflow runs automatically every Friday and can also be triggered manually for testing. If the workflow fails, it indicates that the data structure has changed and dependent scripts may need to be updated.

#### Running the Validation

To run the validation manually:

1. Go to the Actions tab in the repository
2. Select "Validate Status JSON Schema" workflow
3. Click "Run workflow"

Tests for the validation functionality are located in `tests/validateStatusSchema.Tests.ps1` and can be run using Pester:

```powershell
Invoke-Pester -Path ./tests/validateStatusSchema.Tests.ps1
```

### Mirror Sync Behavior

The Update Mirrors workflow maintains synchronized copies of upstream GitHub Actions repositories. When syncing:

1. **Normal Sync**: If changes can be merged cleanly, the mirror is updated via a standard merge
2. **Merge Conflicts**: When a merge conflict is detected, the mirror is **force updated** to match the upstream repository exactly
   - The upstream repository is always considered the source of truth
   - Conflicts are resolved by resetting the mirror to the upstream state using `git reset --hard`
   - A force push is used to update the mirror repository
   - This ensures mirrors never become out of sync due to conflicts

This force update behavior ensures that mirrors remain accurate copies of their upstream sources, even when there are conflicting changes.

#### Rate Limit Fallback

The Update Mirrors workflow includes intelligent rate limit handling with automatic fallback to a secondary GitHub App when the primary app is rate limited:

1. **Token Selection**: Before processing each chunk, the workflow checks the rate limit status of available tokens
2. **Primary Token**: Uses the primary GitHub App token (ID 264650) when rate limit is sufficient
3. **Automatic Fallback**: If the primary token is rate limited (>20 minute wait), automatically falls back to the secondary token (if configured)
4. **Graceful Handling**: If both tokens are rate limited, the chunk is skipped and will be retried in the next scheduled run
5. **Step Summary**: The workflow summary clearly shows which token is being used and provides rate limit details for both tokens

**Configuring a Secondary GitHub App:**

To enable rate limit fallback, configure a second GitHub App and add its credentials as repository secrets:
- `Automation_App_Key_2`: Private key for the secondary GitHub App (ID 264651)

If the secondary app is not configured, the workflow will continue to use only the primary token.

**Example Step Summary Messages:**
- "Using primary token (remaining: 4000 calls)"
- "Fell back to secondary token (primary wait: 25 min, secondary remaining: 3500 calls)"
- "Both tokens rate limited. Primary: wait 25 min (remaining: 10). Secondary: wait 35 min (remaining: 5)."

### Environment State Documentation

The Environment State Documentation workflow provides a comprehensive overview of the system's current state:

- **Delta Analysis**: Shows the difference between actions in the marketplace (actions.json) and tracked actions (status.json)
- **Mirror Status**: Reports on repos with valid mirrors, forks, and sync status
- **Sync Activity**: Tracks repos synced in the last 7 days and 30 days, identifying repos needing updates
- **Repo Info Status**: Monitors collection of tags, releases, repo info, and action types
- **Action Type Breakdown**: Categorizes actions by type (Node, Docker, Composite, etc.)
- **Health Metrics**: Provides coverage, freshness, and completion percentages with status indicators
- **Summary**: Quick overview of key statistics and pending work

The workflow runs daily and generates a detailed report in the GitHub Actions step summary.

The dataset is scraped in this repo: [rajbos/github-azure-devops-marketplace-extension-news](https://github.com/rajbos/github-azure-devops-marketplace-extension-news)
