Param (
    # Local path to a status.json to clean. Defaults to the repo-root status.json
    # that library.ps1 uses. Download a fresh copy first (from blob storage or the
    # 'status-updated' artifact of a recent repoInfo.yml / analyze.yml run) when
    # running this outside the normal workflow.
    $statusFilePath = $null,

    # By default this script is a DRY RUN: it reports what it would clear and
    # writes nothing. Pass -Apply to actually rewrite the status file in place.
    [switch] $Apply,

    # Only meaningful together with -Apply. When set, the cleaned status.json is
    # uploaded back to Azure Blob Storage using $env:BLOB_SAS_TOKEN. Do NOT use
    # this against production data without explicit human approval - the intended
    # path is: run dry-run -> review -> a human decides when to -Apply and upload.
    [switch] $UploadToBlob
)

# One-off migration: clear stale actionType.containerScan records from status.json.
#
# Context (see PR https://github.com/rajbos/actions-marketplace-checks/pull/257):
# Trivy container scans only apply to Docker actions built from a repo-local
# Dockerfile (actionType.actionDockerType -eq "Dockerfile"). A few hundred entries
# still carry a containerScan populated from when they were Dockerfile-based, but
# their current actionDockerType is "Image", or they are now Node/Composite, or
# their action definition can no longer be found. Those scan records no longer
# describe the current action.
#
# repoInfo.ps1 now clears these automatically on every run (Run -> after GetInfo,
# via Remove-StaleContainerScans in library.ps1). This script exists for a
# controlled one-off pass over the full production status.json without waiting for
# the incremental sweep, and for local verification of the cleanup logic.

. $PSScriptRoot/library.ps1

if ([string]::IsNullOrWhiteSpace($statusFilePath)) {
    $statusFilePath = $statusFile
}

Write-Host "Cleanup: stale containerScan records"
Write-Host "  status file : [$statusFilePath]"
Write-Host "  mode        : $(if ($Apply) { 'APPLY (will rewrite file)' } else { 'DRY RUN (no changes written)' })"
Write-Host "  upload      : $(if ($Apply -and $UploadToBlob) { 'yes (blob storage)' } else { 'no' })"

if (-not (Test-Path $statusFilePath)) {
    Write-Error "Status file not found at [$statusFilePath]. Download a fresh status.json first (blob storage or the 'status-updated' workflow artifact)."
    exit 1
}

$existingForks = Get-Content -Path $statusFilePath -Raw | ConvertFrom-Json
Write-Host "Loaded [$($existingForks.Count)] entries"

# Report what will be affected before touching anything.
$affected = $existingForks | Where-Object {
    $null -ne $_.actionType -and
    $null -ne $_.actionType.containerScan -and
    $_.actionType.actionDockerType -ne 'Dockerfile'
}
$affectedCount = @($affected).Count

Write-Host ""
Write-Host "Entries with a containerScan that is NOT Dockerfile-based: [$affectedCount]"
if ($affectedCount -gt 0) {
    $affected |
        Group-Object { "$($_.actionType.actionType) / $($_.actionType.actionDockerType)" } |
        Sort-Object -Property Count -Descending |
        ForEach-Object { Write-Host ("  {0,5}  {1}" -f $_.Count, $_.Name) }

    Write-Host ""
    Write-Host "First 15 affected entries:"
    $affected | Select-Object -First 15 | ForEach-Object {
        Write-Host "  - $($_.name) (type=$($_.actionType.actionType), dockerType=$($_.actionType.actionDockerType), lastScanned=$($_.actionType.containerScan.lastScanned))"
    }
}

$result = Remove-StaleContainerScans -existingForks $existingForks -logToSummary $false
Write-Host ""
Write-Host "Would clear / cleared: [$($result.Cleared)] record(s)"

if (-not $Apply) {
    Write-Host ""
    Write-Host "DRY RUN complete - no changes written. Re-run with -Apply to persist."
    exit 0
}

if ($result.Cleared -eq 0) {
    Write-Host "Nothing to write."
    exit 0
}

$json = ConvertTo-Json -InputObject $existingForks -Depth 10
[System.IO.File]::WriteAllText($statusFilePath, $json, [System.Text.Encoding]::UTF8)
Write-Host "Wrote cleaned status file to [$statusFilePath]"

if ($UploadToBlob) {
    if ([string]::IsNullOrWhiteSpace($env:BLOB_SAS_TOKEN)) {
        Write-Error "UploadToBlob requested but BLOB_SAS_TOKEN is not set."
        exit 1
    }
    if ($statusFilePath -ne $statusFile) {
        Write-Error "UploadToBlob only supports the default status file path [$statusFile] (Set-StatusToBlobStorage reads from there). Copy your cleaned file there first, or upload manually."
        exit 1
    }
    Write-Host "Uploading cleaned status.json to blob storage..."
    Set-StatusToBlobStorage -sasToken $env:BLOB_SAS_TOKEN
    Write-Host "Upload complete."
}

exit 0
