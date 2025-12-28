# Copilot Custom Instructions for actions-marketplace-checks

## Project Overview

This repository contains PowerShell scripts that run checks on GitHub Actions in the marketplace. It processes a large dataset of marketplace actions to analyze their type, configuration, and security status.

## Technology Stack

- **Primary Language**: PowerShell (pwsh)
- **Testing Framework**: Pester
- **CI/CD**: GitHub Actions workflows
- **Data Storage**: JSON files

## Important Data Files

⚠️ **Large Data Files - Do Not Load Into Context**

The repository contains large JSON files that should never be loaded or processed by Copilot:

| File | Size | Description |
|------|------|-------------|
| `status.json` | ~29MB | Contains ~29,279 marketplace actions with processing status |
| `status-old.json` | ~8MB | Previous version of status data |
| `status-backup-*.json` | Various | Backup files |
| `actions.json` | External | Downloaded from Azure Blob during workflow runs |
| `failedForks.json` | Small | List of actions that failed to fork |

These files contain:
- **~29,279 GitHub Actions** from the marketplace
- **~23,050 repositories** with detailed information
- **~23,993 tags** loaded
- **~23,977 releases** loaded

## Code Structure

```
.github/workflows/     # Contains BOTH workflow YAML files AND PowerShell scripts (unusual but intentional)
├── library.ps1        # Core library functions for API calls
├── report.ps1         # Report generation script
├── repoInfo.ps1       # Repository information gathering
├── functions.ps1      # Utility functions
└── *.yml             # GitHub Actions workflow definitions

tests/                 # Pester test files (.Tests.ps1)
injectFiles/          # Files injected into forked repos
```

> **Note**: PowerShell scripts are co-located with workflow files in `.github/workflows/` rather than a separate scripts directory.

## PowerShell Code Style

1. **Function Naming**: PascalCase (e.g., `FilterActionsToProcess`)
2. **Variables**: camelCase (e.g., `$actionsFile`)
3. **Parameters**: Use `Param()` block at function start
4. **Error Handling**: Use try-catch for API calls and file operations
5. **Logging**: Use `Write-Host` for progress messages

## Key Patterns

### API Calls
```powershell
# Always use the ApiCall function from library.ps1
$result = ApiCall -url $apiUrl -access_token $token
```

### Authentication
```powershell
# Uses environment variable or parameter
$env:GITHUB_TOKEN
# Or passed as parameter
-access_token $token
```

## Testing

Run tests with Pester:
```powershell
Invoke-Pester -Output Detailed
```

Test files should:
- End with `.Tests.ps1`
- Import required functions in `BeforeAll` block
- Use `Describe` and `It` blocks

## Important Considerations

1. **Rate Limiting**: GitHub API calls need backoff strategies
2. **Large Dataset**: The project processes ~29,000 actions per run
3. **Fork Organization**: Uses `actions-marketplace-validations` org
4. **Workflow Duration**: Analyze workflow typically runs 45-60 minutes (varies based on data size and API rate limits)
5. **JSON Depth**: Be aware of JSON serialization depth limits

## Security

- Never commit secrets or tokens
- Use GitHub secrets for sensitive data
- Validate external inputs before processing
- The workflow uses GitHub App tokens for authentication

## What NOT to do

- Do not try to read or parse the large JSON data files
- Do not suggest changes to `status.json` or similar data files
- Do not increase memory usage when working with data operations
- Do not remove existing error handling or rate limiting code
- **Do not modify existing code unnecessarily** - only touch lines that are directly related to the feature or fix being implemented
- **Do not fix formatting, whitespace, or style issues** in existing code unless they are directly related to the changes being made
- **Make minimal, surgical changes** - the goal is to make the smallest possible change that solves the problem
