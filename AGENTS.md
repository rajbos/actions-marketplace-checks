# Agent Guidance

This file is the canonical repository-wide guidance for coding agents. Follow any more specific instructions under `.github/instructions/` when they apply to the files being changed.

## Project layout

- PowerShell scripts and GitHub Actions workflow YAML are co-located in `.github/workflows/`.
- Shared API, blob-storage, token, and processing helpers are primarily in `.github/workflows/library.ps1`.
- Pester tests live in `tests/`; Node.js uploader tests live in `.github/workflows/node-scripts/test/`.
- Files injected into mirror repositories live in `injectFiles/`.

## Data files and bounded reading

The workflows process a large, changing marketplace dataset. Never bulk-read, parse, summarize, or edit `status.json`, `status-old.json`, `status-backup-*.json`, downloaded `actions.json`, or other production dataset artifacts. Avoid hard-coded claims about their size or record counts; those change over time. For code investigation, use bounded excerpts, targeted searches, schemas, and small test fixtures instead of loading dataset contents.

- Root `status.json` is processing state downloaded from and uploaded to the `status/` area of Azure Blob Storage. Workflows update it as actions and repository metadata are processed.
- Workflow jobs save the full marketplace input snapshot locally as `actions.json`; the blob object is named `Actions-Full-Overview.Json`. This repository consumes that snapshot.
- `failedForks.json` is a separate helper/state file; do not confuse it with the marketplace input or main status dataset.

In source and older tests, terms such as "fork" and `existingForks` can be legacy names. Repositories in `actions-marketplace-validations` are clone-based mirrors named `<upstreamOwner>_<upstreamRepo>`; do not assume they are native GitHub forks.

## PowerShell and API conventions

- Use `ApiCall` from `library.ps1` for GitHub REST API requests. Do not add a separate HTTP path, ad-hoc retry loop, or sleep.
- For GitHub App authentication, use the shared token manager (`Get-GitHubAppTokenManagerInstance` / `New-GitHubAppTokenManagerFromEnvironment`) and pass its token through the existing API helpers. Do not introduce long-lived PAT dependencies or put credentials in source, logs, or fixtures.
- Preserve the shared rate-limit and token-expiration behavior: it rotates among configured GitHub App tokens, stops rather than waiting over 20 minutes for a rate-limit reset, and switches or stops when tokens are within 15 minutes of expiry.
- Use PascalCase function names, camelCase variables, a `Param()` block, explicit error handling for I/O and API operations, and concise `Write-Host` progress messages. Keep changes surgical and preserve existing error handling.

## Local validation

Use PowerShell 7 (`pwsh`) and have the Pester module available:

```powershell
Invoke-Pester -Output Normal
Invoke-Pester -Path '.\tests\specificTest.Tests.ps1' -Output Normal
```

Run the narrow relevant test file while iterating and the full Pester suite for PowerShell changes. These tests generally use fixtures and mocks; passing them does not validate live GitHub, Azure Blob Storage, API, mirror, or scanner behavior.

For changes to inline PowerShell in workflow YAML, validate the embedded `pwsh` blocks with:

```powershell
pwsh -File '.\.github\workflows\validate-workflow-pwsh.ps1'
```

The validator scans workflow YAML and requires `powershell-yaml`; it attempts to install that module if it is missing. For the Node uploader test, use Node.js 20:

```powershell
node --test '.\.github\workflows\node-scripts\test\upload-to-api.test.js'
```

The `pester-tests.yml` CI workflow downloads `actions.json` from Azure Blob Storage before running Pester. That workflow therefore includes a live storage read beyond the fixture-based test execution.

## Live operations and security

Treat GitHub API and Azure Blob Storage access, API uploads, mirror synchronization or deletion, and real scans as privileged operations against external systems. Do not run workflows or commands that read or change production data, publish API data, write/delete mirrors, or launch real scans unless the task explicitly asks for that operation and its scope is clear. Prefer fixture-based tests for local validation, and do not treat fixture results as evidence that a live integration succeeded.

Never commit secrets or tokens. Validate untrusted external input, preserve JSON serialization depth where relevant, and do not increase memory usage by loading large datasets unnecessarily.
