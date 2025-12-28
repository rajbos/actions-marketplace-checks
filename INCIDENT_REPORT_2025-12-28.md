# Incident Report: Status File Data Loss on 2025-12-28

## Summary
On December 28, 2025, workflow run #20555604985 removed over 3,000 repositories from the status.json file. This document explains the root cause and the fix that was implemented.

## Timeline
- **2025-12-28 11:39** - PR #113 merged with cleanup workflow improvements
- **2025-12-28 15:10** - Workflow run #20555604985 executed with dryRun=false
- **2025-12-28 15:11** - Over 3,000 repos removed from status.json
- **2025-12-28 (later)** - Root cause identified and fixed

## Root Cause Analysis

### The Bug
PR #113 introduced a critical bug in the `GetReposToCleanup` function in `.github/workflows/cleanup-invalid-repos.ps1`.

When the function encounters:
1. Invalid entries (null/empty names, owner="_", etc.), OR
2. Repos with null/empty owners that need to be fixed

It saves an updated status.json file to remove invalid entries and persist owner fixes.

**The bug:** When building the `$validCombined` array to save, it included:
- `$validStatus` - ArrayList of **full repository objects** with all properties (repoSize, tagInfo, releaseInfo, upstreamFound, upstreamAvailable, mirrorFound, etc.)
- `$reposToCleanup` - ArrayList of **simplified hashtables** with only 4 properties (name, owner, reason, upstreamFullName)

### Why This Caused Data Loss

The `$reposToCleanup` array was created for reporting/display purposes at lines 180-185:

```powershell
$reposToCleanup.Add(@{
    name = $repo.name
    owner = $repo.owner
    reason = $reason
    upstreamFullName = $upstreamFullName
}) | Out-Null
```

These simplified objects contained **only** the information needed for display tables in the GitHub Step Summary.

However, at lines 215 and 227, when saving the status file:

```powershell
# BEFORE (BUGGY CODE)
$validCombined = @()
$validCombined += $validStatus           # Full objects ✓
$validCombined += $reposToCleanup        # Simplified objects ✗ BUG!
$validCombined | ConvertTo-Json -Depth 10 | Out-File -FilePath $statusFile
```

This meant that repos eligible for cleanup lost ALL their metadata properties:
- Lost: `repoSize`, `tagInfo`, `releaseInfo`, `upstreamFound`, `upstreamAvailable`, `mirrorFound`
- Kept: Only `name`, `owner`, `reason`, `upstreamFullName`

When the status.json file was saved with this corrupted data and later processed, these incomplete objects caused issues in subsequent workflow runs.

### Why Over 3,000 Repos Were Affected

The workflow run that triggered this had:
1. A significant number of invalid entries or repos with null/empty owners
2. This triggered the status file save at lines 209-219 or 221-232
3. ALL repos that were eligible for cleanup (upstreamFound=false or upstreamAvailable=false) were converted to simplified 4-property objects
4. The corrupted status.json was uploaded to blob storage
5. Subsequent operations couldn't properly process these incomplete objects

## The Fix

The fix adds a separate ArrayList to track full repository objects for repos to be cleaned up:

```powershell
# NEW (FIXED CODE)
$reposToCleanup = New-Object System.Collections.ArrayList  # Simplified for display
$reposToCleanupFullObjects = New-Object System.Collections.ArrayList  # Full objects for status file
```

When a repo should be cleaned up:
```powershell
# Add simplified info for reporting/display
$reposToCleanup.Add(@{
    name = $repo.name
    owner = $repo.owner
    reason = $reason
    upstreamFullName = $upstreamFullName
}) | Out-Null

# Keep full original repo object for status file saving
$reposToCleanupFullObjects.Add($repo) | Out-Null
```

When saving the status file:
```powershell
$validCombined = @()
$validCombined += $validStatus                    # Full objects ✓
$validCombined += $reposToCleanupFullObjects      # Full objects ✓
$validCombined | ConvertTo-Json -Depth 10 | Out-File -FilePath $statusFile
```

Now the status file maintains full repository objects with all metadata intact, while still using simplified objects for display purposes.

## Testing

Three new test files were created to validate the fix:

1. **cleanup-status-file-integrity.Tests.ps1** - Verifies that full objects are preserved when saving the status file
2. **cleanup-display-counts.Tests.ps1** - Validates display count logic (from PR #113)
3. Enhanced existing **cleanup.Tests.ps1** - Continues to validate core cleanup logic

All 26 cleanup-related tests pass with the fix.

## Prevention

To prevent similar issues in the future:

1. ✅ **Separation of Concerns**: Display/reporting data structures are now separate from persistence data structures
2. ✅ **Test Coverage**: Added specific tests for status file integrity
3. ✅ **Code Comments**: Added explicit comments marking which objects are for display vs. persistence
4. 🔄 **Future Work**: Consider adding status.json schema validation to catch structure issues early

## Impact Assessment

### Positive Outcomes
- The bug was caught relatively quickly
- No permanent data loss (status.json can be rebuilt from upstream sources)
- Fix is minimal and focused
- Test coverage improved

### Lessons Learned
1. When working with data that has different representations (display vs. storage), keep them strictly separate
2. Always verify data structure integrity when saving to files, especially large JSON files
3. Test early saves triggered by edge cases (invalid entries, owner fixes)

## Related Files Changed
- `.github/workflows/cleanup-invalid-repos.ps1` - The main fix
- `tests/cleanup-status-file-integrity.Tests.ps1` - New test file
- This incident report

## References
- PR #113: Fix cleanup workflow display counts, status file removal mismatch, and owner extraction
- Workflow Run #20555604985: https://github.com/rajbos/actions-marketplace-checks/actions/runs/20555604985
