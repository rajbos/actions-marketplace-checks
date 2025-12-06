# Analyze Workflow Parallelization - Implementation Summary

## Overview

The analyze workflow has been successfully parallelized to significantly reduce execution time by distributing work across multiple parallel runners. This follows the same proven pattern used in the update-forks workflow.

## Architecture

### Before (Sequential)
```
check-em-all job:
  1. Download data
  2. Process 250 repos for forking (sequential)
  3. Process 250 repos for repo info (sequential)
  4. Upload results
Total time: ~45-60 minutes
```

### After (Parallel)
```
prepare job:
  - Download data
  - Split work into chunks
  - Upload chunk definitions

fork-repos job (matrix: 4 parallel runners):
  - Each processes 1/4 of the forking work
  - Uploads partial status updates

repo-info job (matrix: 4 parallel runners):
  - Merges forking updates first
  - Each processes 1/4 of the repo info work
  - Uploads partial status updates

consolidate job:
  - Merges all partial updates
  - Uploads final results to blob storage
Total time: Expected ~15-20 minutes (3-4x faster)
```

## Key Components

### 1. Workflow File: `.github/workflows/analyze.yml`

**Changes:**
- Replaced single `check-em-all` job with 4 jobs: `prepare`, `fork-repos`, `repo-info`, `consolidate`
- Added matrix strategy for parallel execution
- Added artifact management for partial status updates
- Added workflow inputs for configuration:
  - `numberOfReposForking` (default: 250)
  - `numberOfReposRepoInfo` (default: 250)
  - `numberOfChunks` (default: 4)

### 2. Chunk Scripts

**`.github/workflows/functions-chunk.ps1`:**
- Processes a subset of actions for forking
- Calls the existing `functions.ps1` script for each action
- Outputs partial status updates as artifacts
- Design: Calls functions.ps1 as separate process to maintain isolation

**`.github/workflows/repoInfo-chunk.ps1`:**
- Processes a subset of forks for repo information gathering
- Calls the existing `repoInfo.ps1` script for the chunk
- Outputs partial status updates as artifacts
- Design: Calls repoInfo.ps1 as separate process to maintain isolation

### 3. Library Updates: `.github/workflows/library.ps1`

**New Function: `Split-ActionsIntoChunks`**
- Splits actions array into N chunks for parallel processing
- Returns hashtable mapping chunk ID to action names
- Consistent with existing `Split-ForksIntoChunks` function

### 4. Tests: `tests/analyzeChunking.Tests.ps1`

**Test Coverage:**
- Validates chunking splits work evenly
- Handles uneven splits correctly
- Filters actions with repoUrl when requested
- Handles edge cases (empty lists, more chunks than items)
- Integration tests with existing `Split-ForksIntoChunks`

## Workflow Execution Flow

1. **Prepare Job:**
   - Downloads actions.json, status.json, failedForks.json from blob storage
   - Splits work into chunks using `Split-ActionsIntoChunks` and `Split-ForksIntoChunks`
   - Saves chunk definitions to JSON files
   - Uploads chunk files as artifacts
   - Sets matrix configuration for parallel jobs

2. **Fork-Repos Jobs (Parallel):**
   - Each job downloads:
     - actions.json, status.json, failedForks.json from blob storage
     - Work chunks from artifacts
   - Gets GitHub App token
   - Processes its assigned chunk using `functions-chunk.ps1`
   - Uploads partial status updates as artifacts:
     - `status-partial-functions-{chunk-id}.json`
     - `failedForks-partial-{chunk-id}.json`

3. **Repo-Info Jobs (Parallel):**
   - Each job downloads:
     - actions.json, status.json from blob storage
     - Work chunks from artifacts
     - Partial forking updates from fork-repos jobs
   - Merges forking updates into status.json
   - Gets GitHub App token
   - Processes its assigned chunk using `repoInfo-chunk.ps1`
   - Uploads partial status updates as artifacts:
     - `status-partial-repoinfo-{chunk-id}.json`

4. **Consolidate Job:**
   - Downloads status.json, failedForks.json from blob storage
   - Downloads all partial status updates from artifacts
   - Merges all partial updates using `Merge-PartialStatusUpdates`
   - Shows overall statistics
   - Checks rate limit status
   - Uploads final status.json and failedForks.json to blob storage

## Configuration

### Environment Variables (defaults)
```yaml
numberOfReposForking: 250
numberOfReposRepoInfo: 250
numberOfChunks: 4
```

### Workflow Inputs (for manual runs)
- Override any of the above values
- Allows testing with different configurations

## Benefits

1. **Performance:** 3-4x faster execution through parallelization
2. **Scalability:** Easily adjust number of chunks based on workload
3. **Resilience:** `fail-fast: false` means one chunk failure doesn't stop others
4. **Maintainability:** Reuses existing functions.ps1 and repoInfo.ps1 scripts
5. **Safety:** Proper isolation between chunks prevents data corruption
6. **Consistency:** Follows proven pattern from update-forks workflow

## Testing

- **174 tests pass** (all existing tests + 8 new chunking tests)
- **CodeQL security scan:** 0 alerts
- **Code review:** All feedback addressed
- **YAML validation:** Syntax correct
- **PowerShell validation:** All scripts have valid syntax

## Design Decisions

### Why call parent scripts as separate processes?

The chunk scripts call `functions.ps1` and `repoInfo.ps1` as separate processes (`&` operator) rather than sourcing them (`.` operator) because:

1. **Isolation:** Each invocation gets its own scope and state
2. **Safety:** Avoids issues with main execution code in parent scripts
3. **Simplicity:** Reuses existing logic without complex refactoring
4. **Maintainability:** Changes to parent scripts automatically apply to chunks

Trade-off: Some overhead from process spawning, but this is acceptable for correctness.

### Why use artifacts for partial updates?

1. **Data consistency:** Ensures all chunks' work is preserved
2. **Observability:** Can inspect partial updates for debugging
3. **Flexibility:** Easy to add more chunks or change processing logic
4. **Pattern consistency:** Matches update-forks workflow

## Migration Notes

### For Users

- No changes required to existing workflows
- The workflow will automatically use the new parallel structure
- Can customize via workflow_dispatch inputs if needed

### For Developers

- Chunk scripts are self-contained and independent
- Partial status updates follow the existing status.json schema
- The consolidation logic handles missing/malformed partial updates gracefully

## Future Enhancements

Potential improvements (not required for MVP):

1. **Dynamic chunk sizing:** Adjust chunks based on workload
2. **Progress tracking:** Report progress from each chunk
3. **Retry logic:** Automatically retry failed chunks
4. **Performance metrics:** Track execution time improvements
5. **Optimize single-action processing:** Batch multiple actions per functions.ps1 call

## Files Changed

- `.github/workflows/analyze.yml` - Complete rewrite for parallelization (655 lines)
- `.github/workflows/library.ps1` - Added `Split-ActionsIntoChunks` function
- `.github/workflows/functions-chunk.ps1` - New chunk processor for forking
- `.github/workflows/repoInfo-chunk.ps1` - New chunk processor for repo info
- `tests/analyzeChunking.Tests.ps1` - New tests for chunking functionality
- `.gitignore` - Added patterns for temp/partial files

## Rollback Plan

If issues are discovered:

1. Revert to `.github/workflows/analyze-old.yml` (backup of original)
2. The old workflow is still in the repository for reference
3. No changes to blob storage schema - data format is compatible

## Security

- All jobs have minimal permissions (`contents: read`)
- Secrets are properly scoped to individual jobs
- No new secrets required
- GitHub App token generation follows existing pattern
- CodeQL security scan passes with 0 alerts
