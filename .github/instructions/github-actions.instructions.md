---
applyTo: ".github/workflows/**"
---

# Custom Instructions: GitHub Actions Usage in actions-marketplace-checks

## Project Context
- Primary automation is implemented in PowerShell and executed via GitHub Actions.
- PowerShell scripts and workflows live together under `.github/workflows/`.
- The repository processes a very large dataset of marketplace actions; avoid loading large JSON files into Copilot context.

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
- Do NOT read or expand the large JSON files into Copilot context:
	- `status.json` (~29MB), `status-old.json`, `status-backup-*.json`, external `actions.json`.
- Small helper JSONs like `failedForks.json` are acceptable.

## Authentication & Tokens
- Scripts read tokens from `GITHUB_TOKEN` or explicit parameters.
- Validate tokens early via `Test-AccessTokens` and report lengths (no secrets in logs).
- For GitHub App tokens, use `Get-TokenFromApp`; note 1-hour expiry.

## API Access & Rate Limiting
- All REST calls go through `ApiCall` (from `library.ps1`).
- Rate limit info is retrieved by `GetRateLimitInfo` and formatted using `Format-RateLimitTable`.
- Use `Test-RateLimitExceeded` to gracefully stop long runs when required.
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
	- `Invoke-Pester -Path tests/specificTest.Tests.ps1 -Output Detailed` to run a specific test file.
- Import required functions in `BeforeAll`; use `Describe`/`It` blocks.
- **Test failures in CI must be fixed before merging** - never ignore failing tests.
- Update tests if the function behavior or output format has changed intentionally.

## Safety & Security
- Never commit secrets; use GitHub Secrets.
- Validate external inputs; handle JSON depth limits with `ConvertTo-Json -Depth <n>`.

## What Copilot Should Do
- Keep changes minimal and focused on a single task.
- Use `Write-Message` for any content meant for the Step Summary.
- Reuse `ApiCall` for HTTP interactions; do not introduce redundant HTTP clients.
- Respect large file constraints; do not open or summarize `status.json` and similar in the editor.
- When parallelizing, use the provided chunking and partial merge helpers.

## Useful Commands
- Run tests:
	```powershell
	Invoke-Pester -Output Detailed
	```
- Analyze scripts:
	```powershell
	Invoke-ScriptAnalyzer -Path '.github/workflows' -Recurse
	```

