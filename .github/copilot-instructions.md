# GitHub Copilot Instructions for actions-marketplace-checks

## Project Overview

This repository contains PowerShell scripts that run automated checks on GitHub Actions in the marketplace. The system:

- Analyzes action types (Docker, Node, or Composite)
- Evaluates action declarations and Docker image configurations
- Forks actions to enable GitHub Dependabot for security vulnerability detection (Node actions only)
- Generates reports on vulnerabilities and action metadata

**Data Source**: Uses a private dataset of all public marketplace actions, sourced from [github-azure-devops-marketplace-extension-news](https://github.com/rajbos/github-azure-devops-marketplace-extension-news).

## Technology Stack

- **Primary Language**: PowerShell (pwsh)
- **Testing Framework**: Pester 5.x
- **CI/CD**: GitHub Actions
- **Target OS**: Linux (Ubuntu latest)
- **No External Package Managers**: Uses built-in PowerShell modules only

## Repository Structure

```
├── .github/
│   ├── workflows/          # Both workflow YAML files and PowerShell scripts
│   │   ├── library.ps1     # Core library with API calls and data processing
│   │   ├── report.ps1      # Main report generation logic
│   │   ├── repoInfo.ps1    # Repository information gathering
│   │   ├── functions.ps1   # Utility functions
│   │   └── *.yml           # GitHub Actions workflow definitions
│   └── dependabot.yml      # Dependabot configuration
├── tests/                  # Pester test files
├── injectFiles/            # Template files injected into forked repos
├── status.json             # Processing status (not in git - large file)
├── failedForks.json        # Failed fork tracking
└── README.md
```

## Code Style Guidelines

### PowerShell Conventions

1. **Function Names**: Use PascalCase (e.g., `FilterActionsToProcess`, `ApiCall`)
2. **Variables**: Use camelCase with descriptive names (e.g., `$actionsFile`, `$statusFile`)
3. **Parameters**: Always use the `Param()` block at the start of scripts/functions
4. **Error Handling**: 
   - Wrap API calls and file I/O in try-catch blocks
   - Use meaningful error messages with Write-Host
5. **Logging**: Use `Write-Host` for progress and diagnostic messages
6. **Comments**: Add comments for complex logic, API interactions, and data transformations

### Example Function Structure

```powershell
function Get-ActionMetadata {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$owner,
        
        [Parameter(Mandatory=$true)]
        [string]$repo,
        
        [Parameter(Mandatory=$false)]
        [string]$accessToken
    )
    
    try {
        Write-Host "Fetching metadata for $owner/$repo"
        # Function logic here
    }
    catch {
        Write-Host "Error fetching metadata: $_"
        throw
    }
}
```

## Key Functions and Patterns

### API Interactions

- **Always use**: `ApiCall` function from `library.ps1` for GitHub API requests
- **Authentication**: Uses `$env:GITHUB_TOKEN` or passed token parameters
- **Rate Limiting**: Implement backoff strategies for large dataset processing

### Data Files

- `actions.json` - List of all marketplace actions (not in git - generated externally)
- `status.json` - Processing status and fork information (not in git - large file)
- `failedForks.json` - Actions that failed to fork

**Important**: Do not commit large JSON files (`status.json`, `status-old.json`, `status-backup-*.json`) to the repository.

### Fork Operations

- Forks are created in the `actions-marketplace-validations` organization
- Temporary local clones are stored in `mirroredRepos/` directory
- Fork naming pattern: `{owner}_{repo}`

## Testing

### Pester Test Structure

```powershell
Import-Module Pester

BeforeAll {
    . $PSScriptRoot/../.github/workflows/library.ps1
    # Setup test data
}

Describe "FunctionName" {
    It "Should perform expected behavior" {
        # Arrange
        $input = "test"
        
        # Act
        $result = FunctionName -param $input
        
        # Assert
        $result | Should -Be "expected"
    }
}
```

### Running Tests

```bash
# Run all tests with detailed output
Invoke-Pester -Output Detailed

# Run specific test file
Invoke-Pester ./tests/filtering.Tests.ps1 -Output Detailed
```

**Note**: Some tests require `actions.json`, `status.json`, and `failedForks.json` files which are not in the repository. Tests may fail in fresh clones but the infrastructure is validated.

## GitHub Actions Workflows

### Workflow Structure

- Use `pwsh` shell for all PowerShell steps
- Set shell defaults at workflow or job level when appropriate
- Use GitHub secrets for sensitive data: `${{ secrets.GITHUB_TOKEN }}`, `${{ secrets.ACCESS_TOKEN }}`
- Include appropriate triggers: `push`, `schedule`, `workflow_dispatch`

### Example Workflow Step

```yaml
- shell: pwsh
  name: Run script
  run: |
    $token = "${{ secrets.ACCESS_TOKEN }}"
    ./.github/workflows/script.ps1 -accessToken $token
```

## Making Changes

### Core Principles

1. **Minimal Changes**: Make the smallest possible changes to achieve the goal
2. **Test Early**: Run Pester tests immediately after making changes
3. **Preserve Working Code**: Never modify unrelated working code
4. **Security First**: Always validate external inputs and handle secrets securely

### Change Workflow

1. Understand the existing code and its dependencies
2. Make focused, surgical changes
3. Run tests: `Invoke-Pester -Output Detailed`
4. Verify workflow syntax if modifying YAML files
5. Test manually if adding new functionality

## Security Considerations

- **Never commit**: Secrets, tokens, API keys
- **Always use**: GitHub secrets for sensitive data
- **Validate inputs**: Before processing external data
- **Secure API calls**: Use proper authentication and handle rate limiting
- **Code scanning**: Repository has CodeQL analysis configured

## Common Tasks

### Adding a New Function

1. Add function to appropriate file (`library.ps1` for core, `functions.ps1` for utilities)
2. Follow PowerShell naming conventions
3. Include `Param()` block with type hints
4. Add error handling (try-catch)
5. Create corresponding Pester test in `tests/` directory
6. Run tests to verify

### Modifying Workflows

1. Edit YAML file in `.github/workflows/`
2. Validate YAML syntax
3. Check for dependent scripts (e.g., `report.yml` uses `report.ps1`)
4. Test with `workflow_dispatch` trigger if possible
5. Monitor workflow runs in GitHub Actions tab

### Debugging

- Review workflow logs in GitHub Actions
- Use `Write-Host` for diagnostic output in scripts
- Check API rate limits if experiencing failures
- Verify file paths (use absolute paths in workflows)

## Files to Ignore

When making changes, typically ignore:

- Large data files: `status*.json`, `failedForks.json`
- Temporary directories: `mirroredRepos/`
- Build artifacts and generated files
- `.vscode/` (editor-specific settings)

## Getting Help

- **Core functions**: Check `library.ps1` and `functions.ps1`
- **Usage examples**: Review test files in `tests/`
- **Integration patterns**: Examine workflow files in `.github/workflows/`
- **Project context**: See `README.md` and this file

## Important Notes

- API rate limiting is a critical concern due to large dataset size
- Processing runs can take 1.5-2 hours for full dataset
- The `actions-marketplace-validations` organization is dedicated for validation forks
- Workflows use GitHub App tokens that expire after 1 hour (fallback to personal access token)
- Error handling is crucial for resilience with large-scale processing
