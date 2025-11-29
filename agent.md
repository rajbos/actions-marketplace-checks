# Custom Instructions for actions-marketplace-checks

## Project Overview

This repository contains PowerShell scripts that run checks on GitHub Actions in the marketplace. It uses a private data source of all actions found in the public marketplace to:

- Identify the type of action (Docker, Node, or Composite)
- Analyze action declarations (action.yml, action.yaml, Dockerfile)
- Check Docker image setup
- Fork actions and enable GitHub Dependabot to detect security alerts (Node actions only)

## Data Storage Architecture

### Azure Blob Storage for State Management

**Important:** All state JSON files are stored in Azure Blob Storage in the `status` subfolder, NOT in the Git repository. This design decision improves:

- **Concurrency**: Multiple workflow runs can operate without Git merge conflicts
- **Performance**: Eliminates slow Git operations on large files
- **Scalability**: Blob storage handles large files more efficiently
- **Repo hygiene**: Keeps the repository clean and focused on code

#### Files Stored in Blob Storage

All files are stored in the `status/` subfolder:
- `status/status.json` - Main status tracking file (~29MB)
- `status/failedForks.json` - List of repos that failed to fork
- `status/secretScanningAlerts.json` - Secret scanning alerts data

#### Blob Storage Workflow

1. **At workflow start**: Download JSON files from blob storage using helper functions
2. **During execution**: Process actions and update local files
3. **At workflow end**: Upload modified files back to blob storage

Helper functions in `library.ps1`:
- `Get-StatusFromBlobStorage` / `Set-StatusToBlobStorage` - For status.json
- `Get-FailedForksFromBlobStorage` / `Set-FailedForksToBlobStorage` - For failedForks.json
- `Set-SecretScanningAlertsToBlobStorage` - For secretScanningAlerts.json

#### Required Secrets

| Secret Name | Description |
|-------------|-------------|
| `BLOB_SAS_TOKEN` | Full SAS URL for blob storage (read/write access) |

#### Local Development with Blob Storage

For local testing, set environment variables before running scripts:

```powershell
# Set the SAS token for blob storage
$env:BLOB_SAS_TOKEN = "https://intostorage.blob.core.windows.net/intostorage/actions.json?sv=..."
```

Use the helper script for manual operations:

```powershell
# Download all JSON files from blob storage
./blob-helper.ps1 -Action download

# View status.json info
./blob-helper.ps1 -Action info

# Upload all JSON files to blob storage (with confirmation)
./blob-helper.ps1 -Action upload
```

## Technology Stack

- **Primary Language**: PowerShell (pwsh)
- **Testing Framework**: Pester
- **CI/CD**: GitHub Actions workflows
- **Package Manager**: None (uses built-in PowerShell modules)
- **State Storage**: Azure Blob Storage (status/ subfolder)

## Code Structure

- `.github/workflows/` - Contains both GitHub Actions workflow definitions and PowerShell scripts
  - `library.ps1` - Core library functions for API calls, data processing, and blob storage operations
  - `report.ps1` - Main report generation script
  - `repoInfo.ps1` - Repository information gathering
  - `functions.ps1` - Utility functions
  - Various workflow YAML files for automation
- `tests/` - Pester test files
- `blob-helper.ps1` - Developer helper script for blob storage operations
- Root directory - Contains failedForks.json (small file still in Git)

## Development Guidelines

### PowerShell Code Style

1. **Function Naming**: Use PascalCase for function names (e.g., `FilterActionsToProcess`)
2. **Variables**: Use camelCase for variable names (e.g., `$actionsFile`)
3. **Parameters**: Use the `Param()` block at the start of functions
4. **Error Handling**: Use try-catch blocks for API calls and file operations
5. **Comments**: Add descriptive comments for complex logic
6. **Write-Host**: Use for logging and progress messages

### Key Functions and Patterns

- **API Calls**: Use the `ApiCall` function from `library.ps1` for all GitHub API interactions
- **Authentication**: Uses `$env:GITHUB_TOKEN` for GitHub API authentication
- **Blob Storage**: Use `Get-StatusFromBlobStorage` and `Set-StatusToBlobStorage` for status.json operations
- **Data Files**: 
  - `actions.json` - List of marketplace actions (from blob storage)
  - `status.json` - Current status of processed actions (from blob storage)
  - `failedForks.json` - Actions that failed to fork (in Git)

### Testing

- Use Pester for unit tests
- Test files should end with `.Tests.ps1`
- Import required modules and functions in `BeforeAll` block
- Use `Describe` blocks for test suites and `It` blocks for individual tests
- Run tests with: `Invoke-Pester -Output Detailed`

Example test structure:
```powershell
Import-Module Pester

BeforeAll {
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "FunctionName" {
    It "Should perform expected behavior" {
        # Test logic
        $result | Should -Be $expected
    }
}
```

### Workflow Development

- Use `pwsh` shell for all PowerShell jobs
- Set defaults at the workflow level when appropriate
- Use secrets for sensitive data (e.g., `${{ secrets.GITHUB_TOKEN }}`)
- Add appropriate triggers (push, schedule, workflow_dispatch)
- **Always download status.json at the start of jobs that need it**
- **Always upload status.json at the end of jobs that modify it**

### Making Changes

1. **Minimal Changes**: Make the smallest possible changes to achieve the goal
2. **Test Early**: Run Pester tests after making changes
3. **Preserve Working Code**: Don't modify unrelated working code
4. **Data Files**: Be careful with large JSON files (status.json, etc.)
5. **Dependencies**: This project uses minimal external dependencies

### Common Tasks

#### Running Tests Locally
```powershell
# Navigate to repository root
cd /path/to/actions-marketplace-checks
# Run all tests
Invoke-Pester -Output Detailed
```

#### Testing Workflows
- Use workflow_dispatch triggers for manual testing
- Check workflow runs in the GitHub Actions tab
- Review job logs for debugging

### Important Notes

- The project processes a large dataset of GitHub Actions (~29,000 actions)
- API rate limiting is a concern - use backoff strategies
- Fork operations use the organization `actions-marketplace-validations` (dedicated org for validation forks)
- Temporary repositories are stored in `mirroredRepos` directory
- **status.json is stored in Azure Blob Storage, not in Git**
- Only `failedForks.json` is committed to the repository

## Security Considerations

- Never commit secrets or tokens
- Use GitHub secrets for sensitive data
- Validate external inputs before processing
- Follow secure coding practices for API calls
- SAS tokens should have appropriate expiration and minimal required permissions

## File Patterns to Ignore

When making changes, typically ignore:
- Large data files: `status.json`, `status-old.json`, `status-backup-*.json`
- Temporary directories: `mirroredRepos/`
- Build artifacts

## Getting Help

- Check existing functions in `library.ps1` and `functions.ps1`
- Review test files in `tests/` for usage examples
- Examine workflow files for integration patterns
- Use `blob-helper.ps1` for blob storage operations during development
