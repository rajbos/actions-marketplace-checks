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

The dataset is scraped in this repo: [rajbos/github-azure-devops-marketplace-extension-news](https://github.com/rajbos/github-azure-devops-marketplace-extension-news)
