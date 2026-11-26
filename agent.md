# Project Reference: actions-marketplace-checks

Repository-wide agent guidance is maintained in [AGENTS.md](AGENTS.md); this file is supplemental storage and workflow reference.

## Project Overview

This repository contains PowerShell scripts that run checks on GitHub Actions in the marketplace. It uses a private data source of all actions found in the public marketplace to:

- Identify the type of action (Docker, Node, or Composite)
- Analyze action declarations (action.yml, action.yaml, Dockerfile)
- Check Docker image setup
- Create clone-based mirrors of action repositories and enable GitHub Dependabot to detect security alerts (Node actions only)

## Data Storage Architecture

### Azure Blob Storage for State Management

**Important:** All state JSON files are stored in Azure Blob Storage in the `status` subfolder, NOT in the Git repository. This design decision improves:

- **Concurrency**: Multiple workflow runs can operate without Git merge conflicts
- **Performance**: Eliminates slow Git operations on large files
- **Scalability**: Blob storage handles large files more efficiently
- **Repo hygiene**: Keeps the repository clean and focused on code

#### Files Stored in Blob Storage

The blob storage structure uses two different patterns:

1. **Root-level file** (legacy pattern):
   - `Actions-Full-Overview.Json` - Marketplace actions snapshot consumed by workflows; workflows save it locally as `actions.json`

2. **Status subfolder files** (current pattern):
   - `status/status.json` - Main processing state for tracked actions and repository metadata
   - `status/failedForks.json` - Helper state for repository mirror failures
   - `status/secretScanningAlerts.json` - Secret scanning alerts data

#### SAS Token Structure and URL Construction

The `BLOB_SAS_TOKEN` secret contains a **blob storage level SAS URL** with the following structure:

```
https://{storage-account}.blob.core.windows.net/{container}/data?{sas-query-string}
```

**Example:**
```
https://{storage-account}.blob.core.windows.net/{container}/data?{sas-query-string}
```

**Key Components:**
- **Base URL**: `https://{storage-account}.blob.core.windows.net/{container}/data` (the storage container's data path)
- **SAS Query**: `?sp=racwdl&st=...&se=...` (permissions, start time, expiry, etc.)

#### How File URLs Are Constructed

Files are accessed by constructing URLs from the SAS token:

1. **Parse the SAS token** to separate base URL from query string:
   ```powershell
   $baseUrlWithQuery = $env:BLOB_SAS_TOKEN
   $queryStart = $baseUrlWithQuery.IndexOf('?')
   $baseUrl = $baseUrlWithQuery.Substring(0, $queryStart)
   $sasQuery = $baseUrlWithQuery.Substring($queryStart)
   ```

2. **For root-level files** (like `Actions-Full-Overview.Json`):
   ```powershell
   # Append file name to base URL, then add SAS query
   $blobUrl = "${baseUrl}/${actionsBlobFileName}${sasQuery}"
   # Result: https://.../{container}/data/Actions-Full-Overview.Json?{sas-query-string}
   ```

3. **For status subfolder files** (like `status.json`):
   ```powershell
   # Append /status/{filename} to base URL, then add SAS query
   $blobUrl = "${baseUrl}/status/${blobFileName}${sasQuery}"
   # Result: https://.../{container}/data/status/status.json?{sas-query-string}
   ```

**Important Notes:**
- The base URL ends with `/data`; appending the blob name or `/status/{filename}` creates the full path.
- The SAS query string is always appended AFTER the complete file path
- All status files are in the `status/` subfolder relative to the base path

#### Blob Storage Workflow Pattern

All workflows that use blob storage follow this pattern:

1. **At workflow start**: Download JSON files from blob storage using helper functions
   ```yaml
   - name: Download status.json from blob storage
     shell: pwsh
     env:
       BLOB_SAS_TOKEN: "${{ secrets.BLOB_SAS_TOKEN }}"
     run: |
       . ./.github/workflows/library.ps1
       $result = Get-StatusFromBlobStorage -sasToken $env:BLOB_SAS_TOKEN
       if (-not $result) {
         Write-Error "Failed to download status.json"
         exit 1
       }
   ```

2. **During execution**: Process actions and update local files
   - Files are downloaded to the repository root (e.g., `status.json`, `failedForks.json`)
   - Scripts read and modify these local files
   - Changes are made in-memory or written back to local files

3. **At workflow end**: Upload modified files back to blob storage
   ```yaml
   - name: Upload status.json to blob storage
     shell: pwsh
     env:
       BLOB_SAS_TOKEN: "${{ secrets.BLOB_SAS_TOKEN }}"
     run: |
       . ./.github/workflows/library.ps1
       $result = Set-StatusToBlobStorage -sasToken $env:BLOB_SAS_TOKEN
       if (-not $result) {
         Write-Error "Failed to upload status.json"
         exit 1
       }
   ```

#### Helper Functions in library.ps1

**Download Functions:**
- `Get-ActionsJsonFromBlobStorage -sasToken $token` - Downloads `Actions-Full-Overview.Json` from root
- `Get-StatusFromBlobStorage -sasToken $token` - Downloads `status/status.json`
- `Get-FailedForksFromBlobStorage -sasToken $token` - Downloads `status/failedForks.json`

**Upload Functions:**
- `Set-StatusToBlobStorage -sasToken $token` - Uploads `status/status.json` (fails if file missing)
- `Set-FailedForksToBlobStorage -sasToken $token` - Uploads `status/failedForks.json`
- `Set-SecretScanningAlertsToBlobStorage -sasToken $token` - Uploads `status/secretScanningAlerts.json`

**Common Helper Functions:**
- `Get-JsonFromBlobStorage -sasToken $token -blobFileName "status.json" -localFilePath $statusFile`
  - Downloads any JSON file from the `status/` subfolder
  - Creates empty JSON array `[]` locally if file doesn't exist (404)
  
- `Set-JsonToBlobStorage -sasToken $token -blobFileName "status.json" -localFilePath $statusFile -failIfMissing $false`
  - Uploads any JSON file to the `status/` subfolder
  - Sets Content-Type header to `application/json`
  - Uses `x-ms-blob-type: BlockBlob` header

#### Validation: validate-blob-token.yml Workflow

This workflow validates blob storage access. It tests:

1. **SAS Token Format Validation:**
   - Checks if `BLOB_SAS_TOKEN` is set and non-empty
   - Validates it matches expected URL format with query string (`https://...?...`)

2. **File Download Tests:**
   - Downloads `Actions-Full-Overview.Json` and validates it's valid JSON
   - Downloads `status.json` and validates:
     - File size exceeds the workflow's corruption guard
     - Content is valid JSON (handles UTF-8 BOM)
     - The parsed array is non-empty
   - Downloads `failedForks.json` and validates it's valid JSON

3. **URL Construction Verification:**
   - Tests the URL parsing logic (separating base URL from SAS query)
   - Validates all expected file paths can be constructed
   - Shows constructed URLs (with SAS redacted) for debugging

**Example validation output:**
```
✅ BLOB_SAS_TOKEN secret is configured
✅ BLOB_SAS_TOKEN format looks valid
✅ Successfully downloaded Actions-Full-Overview.Json (X bytes)
✅ Actions-Full-Overview.Json is valid JSON
✅ Successfully downloaded status.json
✅ status.json size and JSON checks passed
```

#### Required Secrets

| Secret Name | Description |
|-------------|-------------|
| `BLOB_SAS_TOKEN` | Full SAS URL for blob storage (read/write access). Format: `https://{storage}.blob.core.windows.net/{container}/{base-path}?{sas-params}` |
| `DEVOPS_ACTIONS_PACKAGE_DOWNLOAD` | GitHub **classic** PAT with `read:packages` scope for the `devops-actions` org. Used to install `@devops-actions/actions-marketplace-client` from GitHub Packages during workflow runs. Fine-grained PATs do not support GitHub Packages (GitHub limitation). If this expires, all API-upload workflows will fail with npm 403 errors. See TROUBLESHOOTING.md for regeneration steps. |

Note: do not introduce new secrets without asking for approval first. We use the secrets that are available in the existing workflows.

#### Local Development with Blob Storage

For local testing, set environment variables before running scripts:

```powershell
# Set the SAS token for blob storage (blob storage level URL)
$env:BLOB_SAS_TOKEN = "https://{storage-account}.blob.core.windows.net/{container}/data?{sas-query-string}"
```

Use the helper script `blob-helper.ps1` for manual operations:

```powershell
# Download all JSON files from blob storage
./blob-helper.ps1 -Action download

# View status.json info (works without BLOB_SAS_TOKEN for local files)
./blob-helper.ps1 -Action info

# Upload all JSON files to blob storage (with confirmation prompt)
./blob-helper.ps1 -Action upload
```

**blob-helper.ps1 Features:**
- **Download**: Fetches `status.json` and `failedForks.json` from blob storage
- **Info**: Shows local file statistics (size, entry count, last modified)
- **Upload**: Pushes local files back to blob storage (requires confirmation)
- Automatically uses functions from `library.ps1`
- Shows detailed statistics about the downloaded files

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
7. When logging variables, we wrap the variable part in brackets: `Log string with [@value] in the middle` to improve readability

### Key Functions and Patterns

- **API Calls**: Use the `ApiCall` function from `library.ps1` for all GitHub API interactions
- **Authentication**: Use the shared GitHub App token manager and pass the token through `ApiCall` for GitHub REST API requests.
- **Blob Storage**: Use `Get-StatusFromBlobStorage` and `Set-StatusToBlobStorage` for status.json operations
- **Data Files**: 
  - Local `actions.json` - Full marketplace input snapshot downloaded from the `Actions-Full-Overview.Json` blob
  - `status.json` - Current processing state synchronized with the `status/` blob-storage path
  - `failedForks.json` - Helper state for repository mirror failures

### Testing

- Use Pester for unit tests
- Test files should end with `.Tests.ps1`
- Import required modules and functions in `BeforeAll` block
- Use `Describe` blocks for test suites and `It` blocks for individual tests
- Run tests with: `Invoke-Pester -Output Normal`

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
- Use GitHub secrets for sensitive values; use the shared GitHub App token manager for API authentication.
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
- Treat workflow dispatches as live operations unless confirmed otherwise; follow [AGENTS.md](AGENTS.md) before triggering workflows.
- Check workflow runs in the GitHub Actions tab
- Review job logs for debugging

### Important Notes

- The project processes a large, changing marketplace dataset; avoid hard-coded size and record-count assumptions
- API rate limiting is a concern - use backoff strategies
- Clone-based mirrors use the `actions-marketplace-validations` organization; legacy "fork" names in code do not mean these are native GitHub forks
- Temporary repositories are stored in `mirroredRepos` directory
- **status.json is stored in Azure Blob Storage, not in Git**

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
