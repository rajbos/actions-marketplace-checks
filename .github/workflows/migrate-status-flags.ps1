Param(
    [Parameter(Mandatory=$true)]
    [string] $statusFile
)

Write-Host "Starting status flags migration for file: [$statusFile]"
if (-not (Test-Path $statusFile)) {
    Write-Error "Status file not found at [$statusFile]"
    exit 1
}

# Load JSON
$jsonContent = Get-Content -Path $statusFile -Raw
$jsonContent = $jsonContent -replace '^\uFEFF', ''
$status = $jsonContent | ConvertFrom-Json

if ($null -eq $status) {
    Write-Error "Failed to parse status JSON from [$statusFile]"
    exit 1
}

$updatedCount = 0
foreach ($item in $status) {
    # Default missing flags to true
    if ($null -eq $item.mirrorFound) {
        $item | Add-Member -Name mirrorFound -Value $true -MemberType NoteProperty -Force
        $updatedCount++
    }
    if ($null -eq $item.upstreamFound) {
        $item | Add-Member -Name upstreamFound -Value $true -MemberType NoteProperty -Force
        $updatedCount++
    }
}

Write-Host "Updated [$updatedCount] missing flag entries (counts both fields)."

# Save back with sufficient depth
$json = ConvertTo-Json -InputObject $status -Depth 12
[System.IO.File]::WriteAllText($statusFile, $json, [System.Text.Encoding]::UTF8)

Write-Host "✓ Migration complete. Saved back to [$statusFile]"