---
applyTo: ".github/workflows/**"
---

# Custom Instructions: GitHub Actions Usage in actions-marketplace-checks

Repository-wide guidance is in the root [AGENTS.md](../../AGENTS.md). Keep this file focused on workflow-specific conventions.

## Project Context
- Primary automation is implemented in PowerShell and executed via GitHub Actions.
- PowerShell scripts and workflows live together under `.github/workflows/`.
- The repository processes a large, changing marketplace dataset; use bounded reads and avoid loading production JSON data into context.

## Workflow & Script Layout
- Workflows call PowerShell entry scripts co-located in `.github/workflows/`;
	core helpers are defined in `library.ps1` and imported using `. $PSScriptRoot/library.ps1`.
- Key scripts: `library.ps1`, `report.ps1`, `repoInfo.ps1`, `functions.ps1`, and task-specific scripts (e.g., `cleanup-invalid-repos.ps1`).
- Tests are in `tests/` and use Pester.

## Logging & Step Summary
- Use the helper `Write-Message -message <text> -logToSummary $true` to write to the GitHub Step Summary.
- Prefer concise, human-readable sections with tables for counts and outcome summaries.
- Continue using `Write-Host` for console output; use `Write-Message` when content should appear in the workflow summary.
- When showing limited detail lists, format headings as `first X of Y` (no slashes) and avoid trailing "... and X more" lines.

## Data Files Handling
- Do NOT bulk-read, parse, summarize, or edit production dataset files:
	- `status.json`, `status-old.json`, `status-backup-*.json`, and downloaded `actions.json`.
- Treat helper JSONs such as `failedForks.json` separately from the marketplace datasets; inspect only when directly relevant.
- Avoid hard-coded size or record-count assertions; the dataset changes over time.
- Root `status.json` is processing state synchronized with the `status/` area of Azure Blob Storage. Workflow jobs save the full marketplace snapshot locally as `actions.json`; the blob object is named `Actions-Full-Overview.Json`.
- Repositories in `actions-marketplace-validations` are clone-based mirrors named `<upstreamOwner>_<upstreamRepo>`; legacy "fork" names in code do not mean these are native GitHub forks.

## Authentication & Tokens
- For GitHub App authentication, use the shared token manager (`Get-GitHubAppTokenManagerInstance` / `New-GitHubAppTokenManagerFromEnvironment`) and existing helpers. Do not introduce long-lived PAT dependencies or log token values.

## API Access & Rate Limiting
- All GitHub REST calls go through `ApiCall` (from `library.ps1`).
- Rate limit info is retrieved by `GetRateLimitInfo` and formatted using `Format-RateLimitTable`.
- Use `Test-RateLimitExceeded` to gracefully stop long runs when required.
- Preserve shared rate-limit handling, GitHub App token rotation, and proactive token-expiration checks (including stopping for waits over 20 minutes or tokens within 15 minutes of expiry); do not add ad-hoc sleeps or retries.
- Backoff strategies are present in `Invoke-GitCommandWithRetry` for git operations.

## Chunking & Partial Results
- To process at scale, split work:
	- `Split-ActionsIntoChunks` for marketplace action sets.
	- `Split-ForksIntoChunks` for fork lists (`mirrorFound = true`).
- Save per-chunk updates via `Save-PartialStatusUpdate` and merge later using `Merge-PartialStatusUpdates`.

## Mirrors & Syncing
- Mirrors in `actions-marketplace-validations` are named `<upstreamOwner>_<upstreamRepo>`.
- Use `Compare-RepositoryCommitHashes` to avoid unnecessary clones.
- `SyncMirrorWithUpstream` safely merges upstream changes and pushes with retries, disabling Actions temporarily via `Disable-GitHubActions` before push.

## Cleanup & Maintenance
- `cleanup-invalid-repos.ps1` identifies repos to remove (e.g., upstream missing and empty content) and writes a summary to the Step Summary.
- When `dryRun = $true`, list actions only; when false, delete and update `status.json` accordingly.

## PowerShell Style & Conventions
- Functions: PascalCase (e.g., `FilterActionsToProcess`).
- Variables: camelCase.
- Always use a `Param` block; add try/catch for IO/API operations.
- Prefer minimal, clear logging; avoid leaking secrets.

## Testing
- **ALWAYS run Pester tests when making any changes to PowerShell scripts** (`.ps1` files in `.github/workflows/` or tests).
- Use Pester tests under `tests/`:
	- `Invoke-Pester -Output Detailed` for CI/local validation.
	- `Invoke-Pester -Path '.\tests\specificTest.Tests.ps1' -Output Normal` to run a specific test file.
- For inline PowerShell in workflow YAML, run `pwsh -File '.\.github\workflows\validate-workflow-pwsh.ps1'` to parse embedded `pwsh` blocks. The validator uses `powershell-yaml` and attempts to install it if missing.
- For the Node uploader unit tests, use Node.js 20 and run `node --test '.\.github\workflows\node-scripts\test\upload-to-api.test.js'`.
- Pester fixtures/mocks do not validate live integrations. The `pester-tests.yml` workflow downloads `actions.json` from Azure Blob Storage before running the tests.
- Import required functions in `BeforeAll`; use `Describe`/`It` blocks.
- **Test failures in CI must be fixed before merging** - never ignore failing tests.
- Update tests if the function behavior or output format has changed intentionally.

## Safety & Security
- Never commit secrets; use GitHub Secrets.
- Validate external inputs; handle JSON depth limits with `ConvertTo-Json -Depth <n>`.
- Treat GitHub API and Azure Blob Storage access, API uploads, mirror synchronization/deletion, and real scans as privileged live operations. Do not trigger them unless the task explicitly requests them and the scope is clear.

## What Copilot Should Do
- Keep changes minimal and focused on a single task.
- Use `Write-Message` for any content meant for the Step Summary.
- Reuse `ApiCall` for HTTP interactions; do not introduce redundant HTTP clients.
- Respect large file constraints; do not open or summarize `status.json` and similar in the editor.
- When parallelizing, use the provided chunking and partial merge helpers.

## Useful Commands
- Run tests:
	```powershell
	Invoke-Pester -Output Normal
	```
- Analyze scripts:
	```powershell
	Invoke-ScriptAnalyzer -Path '.github/workflows' -Recurse
	```

## Report Generation (report.ps1)
### Count Consistency Rules
- **ALWAYS use `$actions.Count` as the single source of truth for "total actions"** across all report sections.
- Subset counts (e.g., actions with repoInfo, actions with actionType) should be clearly labeled as subsets.
- **ALWAYS use `DisplayIntWithDots` function** for formatting numbers in reports to ensure consistent thousand separators.
- Key count variables and their meanings:
	- `$actions.Count`: Total number of actions in the dataset (primary source of truth)
	- `$global:repoInfo`: Count of actions that have `repoInfo.updated_at` data
	- `$nodeBasedActions + $dockerBasedActions + $compositeAction + $unknownActionType`: Count of actions with actionType defined
	- When displaying totals in mermaid diagrams, use `$actions.Count` not the sum of individual categories
- Clarify subset relationships in section headers (e.g., "With repo info: X of Y total")

