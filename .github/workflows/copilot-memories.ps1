#!/usr/bin/env pwsh
<#
.SYNOPSIS
Fetches Copilot memories for a list of repositories.

.DESCRIPTION
This script calls the GitHub Copilot API to retrieve recent memories for specified repositories.
It requires a GitHub PAT with appropriate repo access permissions.

.PARAMETER repositories
Array of repositories in "owner/repo" format to check for memories.

.PARAMETER githubToken
GitHub Personal Access Token with repo scope or fine-grained read access.

.PARAMETER limit
Number of recent memories to fetch per repository (default: 20).

.EXAMPLE
.\copilot-memories.ps1 -repositories @("owner/repo1", "owner/repo2") -githubToken $env:GITHUB_TOKEN

.EXAMPLE
.\copilot-memories.ps1 -repositories @("rajbos/actions-marketplace-checks") -githubToken $token -limit 10
#>

Param (
    [Parameter(Mandatory=$true)]
    [string[]] $repositories,
    
    [Parameter(Mandatory=$true)]
    [string] $githubToken,
    
    [Parameter(Mandatory=$false)]
    [int] $limit = 20
)

# Import library functions for logging
. $PSScriptRoot/library.ps1

<#
.SYNOPSIS
Fetches Copilot memories for a single repository.

.DESCRIPTION
Calls the GitHub Copilot API to retrieve recent memories for a given repository.

.PARAMETER owner
The repository owner.

.PARAMETER repo
The repository name.

.PARAMETER token
GitHub authentication token.

.PARAMETER memoryLimit
Number of memories to retrieve.

.RETURNS
Hashtable with repository info and memories array, or null if API call fails.
#>
function Get-CopilotMemories {
    Param (
        [Parameter(Mandatory=$true)]
        [string] $owner,
        
        [Parameter(Mandatory=$true)]
        [string] $repo,
        
        [Parameter(Mandatory=$true)]
        [string] $token,
        
        [Parameter(Mandatory=$false)]
        [int] $memoryLimit = 20
    )
    
    $apiUrl = "https://api.githubcopilot.com/agents/swe/internal/memory/v0/$owner/$repo/recent?limit=$memoryLimit"
    
    try {
        Write-Host "Fetching memories for $owner/$repo..."
        
        $headers = @{
            "Accept" = "application/json"
            "Authorization" = "Bearer $token"
        }
        
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get -ErrorAction Stop
        
        Write-Host "  Successfully retrieved memories for $owner/$repo"
        
        return @{
            repository = "$owner/$repo"
            owner = $owner
            repo = $repo
            memories = $response
            memoriesCount = if ($response -is [array]) { $response.Count } else { if ($response) { 1 } else { 0 } }
            success = $true
        }
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errorMessage = $_.Exception.Message
        
        Write-Host "  Failed to fetch memories for $owner/$repo - Status: $statusCode, Error: $errorMessage"
        
        return @{
            repository = "$owner/$repo"
            owner = $owner
            repo = $repo
            memories = @()
            memoriesCount = 0
            success = $false
            error = $errorMessage
            statusCode = $statusCode
        }
    }
}

# Main execution
Write-Host "==================================="
Write-Host "Copilot Memories Fetcher"
Write-Host "==================================="
Write-Host ""
Write-Host "Checking [$($repositories.Count)] repositories for Copilot memories..."
Write-Host ""

$results = @()

foreach ($repoFullName in $repositories) {
    if ([string]::IsNullOrWhiteSpace($repoFullName)) {
        Write-Host "Skipping empty repository entry"
        continue
    }
    
    $parts = $repoFullName.Trim().Split('/')
    if ($parts.Count -ne 2) {
        Write-Host "Invalid repository format: '$repoFullName'. Expected 'owner/repo'"
        continue
    }
    
    $owner = $parts[0]
    $repo = $parts[1]
    
    $result = Get-CopilotMemories -owner $owner -repo $repo -token $githubToken -memoryLimit $limit
    $results += $result
}

# Summary
Write-Host ""
Write-Host "==================================="
Write-Host "Summary"
Write-Host "==================================="

$successCount = ($results | Where-Object { $_.success }).Count
$failedCount = ($results | Where-Object { -not $_.success }).Count
$totalMemories = ($results | Where-Object { $_.success } | Measure-Object -Property memoriesCount -Sum).Sum

Write-Host "Repositories checked: $($results.Count)"
Write-Host "Successful: $successCount"
Write-Host "Failed: $failedCount"
Write-Host "Total memories found: $totalMemories"
Write-Host ""

# List repos with memories
$reposWithMemories = $results | Where-Object { $_.success -and $_.memoriesCount -gt 0 }
if ($reposWithMemories.Count -gt 0) {
    Write-Host "Repositories with memories:"
    foreach ($result in $reposWithMemories) {
        Write-Host "  - $($result.repository): $($result.memoriesCount) memories"
    }
    Write-Host ""
}

# Output results as JSON for workflow consumption
$outputFile = "copilot-memories-results.json"
$results | ConvertTo-Json -Depth 10 | Set-Content -Path $outputFile
Write-Host "Results saved to: $outputFile"
Write-Host ""

# Set output for GitHub Actions
if ($env:GITHUB_OUTPUT) {
    $hasMemories = $reposWithMemories.Count -gt 0
    Add-Content -Path $env:GITHUB_OUTPUT -Value "has_memories=$($hasMemories.ToString().ToLower())"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "total_memories=$totalMemories"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "repos_with_memories=$($reposWithMemories.Count)"
    Write-Host "GitHub Actions outputs set:"
    Write-Host "  has_memories: $($hasMemories.ToString().ToLower())"
    Write-Host "  total_memories: $totalMemories"
    Write-Host "  repos_with_memories: $($reposWithMemories.Count)"
}

# Exit with appropriate code
if ($failedCount -gt 0 -and $successCount -eq 0) {
    Write-Host "All API calls failed!"
    exit 1
}

exit 0
