# Custom Instructions for actions-marketplace-checks

## Project Overview

This repository contains PowerShell scripts that run checks on GitHub Actions in the marketplace. It uses a private data source of all actions found in the public marketplace to:

- Identify the type of action (Docker, Node, or Composite)
- Analyze action declarations (action.yml, action.yaml, Dockerfile)
- Check Docker image setup
- Fork actions and enable Dependabot to detect security alerts (Node actions only)

## Technology Stack

- **Primary Language**: PowerShell (pwsh)
- **Testing Framework**: Pester
- **CI/CD**: GitHub Actions workflows
- **Package Manager**: None (uses built-in PowerShell modules)

## Code Structure

- `.github/workflows/` - Contains both GitHub Actions workflow definitions and PowerShell scripts
  - `library.ps1` - Core library functions for API calls, data processing
  - `report.ps1` - Main report generation script
  - `repoInfo.ps1` - Repository information gathering
  - `functions.ps1` - Utility functions
  - Various workflow YAML files for automation
- `tests/` - Pester test files
- Root directory - Contains data files (JSON) for actions, status, and failed forks

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
- **Data Files**: 
  - `actions.json` - List of marketplace actions
  - `status.json` - Current status of processed actions
  - `failedForks.json` - Actions that failed to fork

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

- The project processes a large dataset of GitHub Actions
- API rate limiting is a concern - use backoff strategies
- Fork operations use the organization `actions-marketplace-validations`
- Temporary repositories are stored in `mirroredRepos` directory
- Large data files (status.json) should not be committed unnecessarily

## Security Considerations

- Never commit secrets or tokens
- Use GitHub secrets for sensitive data
- Validate external inputs before processing
- Follow secure coding practices for API calls

## File Patterns to Ignore

When making changes, typically ignore:
- Large data files: `status.json`, `status-old.json`, `status-backup-*.json`
- Temporary directories: `mirroredRepos/`
- Build artifacts

## Getting Help

- Check existing functions in `library.ps1` and `functions.ps1`
- Review test files in `tests/` for usage examples
- Examine workflow files for integration patterns
