#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Documents the current state of the actions marketplace checks environment.

.DESCRIPTION
    This script provides a comprehensive overview of the environment state including:
    - Delta between actions.json (full marketplace data) and status.json (tracked actions)
    - Percentage of repos checked in the last week
    - Repos that still need updates
    - Overall statistics and health metrics

.PARAMETER actions
    The array of actions from the full marketplace data (actions.json)

.PARAMETER existingForks
    The array of existing forks from status.json

.PARAMETER access_token_destination
    GitHub App token for API calls to the marketplace validations org

.EXAMPLE
    ./environment-state.ps1 -actions $actions -existingForks $existingForks -access_token_destination $token
#>

Param (
    [Parameter(Mandatory=$true)]
    $actions,

    [Parameter(Mandatory=$true)]
    $existingForks,

    [Parameter(Mandatory=$false)]
    [string] $access_token_destination = ""
)

# Import library functions
. "$PSScriptRoot/library.ps1"

# Helper function to extract the actual actionType value from both string and object formats
function Get-ActionTypeValue {
    param(
        [Parameter(Mandatory=$false)]
        $data
    )
    
    if (-not $data) {
        return "Unknown"
    }
    
    # Check if data is a hash table or PSCustomObject with nested actionType property
    if ($data -is [hashtable] -or $data -is [PSCustomObject]) {
        # Extract the nested actionType property
        if ($data.actionType) {
            return $data.actionType
        } elseif ($data.PSObject.Properties["actionType"]) {
            return $data.PSObject.Properties["actionType"].Value
        }
        return "Unknown"
    }
    
    # It's already a string
    return $data
}

Write-Message -message "# Environment State Documentation" -logToSummary $true
Write-Message -message "" -logToSummary $true
Write-Message -message "_Report generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')_" -logToSummary $true
Write-Message -message "" -logToSummary $true

# ============================================================================
# 1. DATASET OVERVIEW
# ============================================================================
Write-Message -message "## Dataset Overview" -logToSummary $true
Write-Message -message "" -logToSummary $true

$totalActionsInMarketplace = $actions.Count
$totalTrackedActions = $existingForks.Count

Write-Message -message "| Dataset | Count |" -logToSummary $true
Write-Message -message "|---------|------:|" -logToSummary $true
Write-Message -message "| **Actions in Marketplace** (actions.json) | $(DisplayIntWithDots $totalActionsInMarketplace) |" -logToSummary $true
Write-Message -message "| **Tracked Actions** (status.json) | $(DisplayIntWithDots $totalTrackedActions) |" -logToSummary $true
Write-Message -message "" -logToSummary $true

# ============================================================================
# 2. DELTA ANALYSIS
# ============================================================================
Write-Message -message "## Delta Analysis" -logToSummary $true
Write-Message -message "" -logToSummary $true

# Helper function to normalize action names to owner_repo format
function Get-NormalizedActionName {
    param($action)
    
    $normalizedName = $null
    
    # Try forkedRepoName first (should be in owner_repo format, but check to be safe)
    if ($action.forkedRepoName -and $action.forkedRepoName -ne "") {
        if ($action.forkedRepoName -match '/') {
            $normalizedName = $action.forkedRepoName.Replace('/', '_').ToLower()
        }
        else {
            $normalizedName = $action.forkedRepoName.ToLower()
        }
    }
    # Try name field (might be in owner/repo or owner_repo format)
    elseif ($action.name -and $action.name -ne "") {
        # Convert owner/repo to owner_repo if needed
        if ($action.name -match '/') {
            $normalizedName = $action.name.Replace('/', '_').ToLower()
        }
        else {
            $normalizedName = $action.name.ToLower()
        }
    }
    # Fallback: derive from repoUrl
    elseif ($action.repoUrl -and $action.repoUrl -ne "") {
        ($owner, $repo) = SplitUrl -url $action.repoUrl
        if ($owner -and $repo) {
            $normalizedName = "${owner}_${repo}".ToLower()
        }
    }
    
    return $normalizedName
}

# Get action names from marketplace data
# Normalize action names to owner_repo format for consistent comparison
$marketplaceActionNames = @{}
foreach ($action in $actions) {
    $normalizedName = Get-NormalizedActionName -action $action
    if ($normalizedName) {
        $marketplaceActionNames[$normalizedName] = $true
    }
}

# Get action names from status (already in owner_repo format)
$trackedActionNames = @{}
foreach ($fork in $existingForks) {
    if ($fork.name) {
        $trackedActionNames[$fork.name.ToLower()] = $true
    }
}

# Find actions in marketplace but not tracked
$actionsNotTracked = @()
foreach ($action in $actions) {
    $normalizedName = Get-NormalizedActionName -action $action
    if ($normalizedName -and -not $trackedActionNames.ContainsKey($normalizedName)) {
        $actionsNotTracked += $action
    }
}

# Find actions tracked but not in marketplace anymore
$actionsNoLongerInMarketplace = @()
foreach ($fork in $existingForks) {
    if ($fork.name) {
        $normalizedName = $fork.name.ToLower()
        if (-not $marketplaceActionNames.ContainsKey($normalizedName)) {
            $actionsNoLongerInMarketplace += $fork
        }
    }
}

$actionsInBoth = $totalTrackedActions - $actionsNoLongerInMarketplace.Count

Write-Message -message "| Status | Count | Percentage |" -logToSummary $true
Write-Message -message "|--------|------:|-----------:|" -logToSummary $true
Write-Message -message "| ✅ Actions in Both Datasets | $(DisplayIntWithDots $actionsInBoth) | $([math]::Round(($actionsInBoth / $totalActionsInMarketplace) * 100, 2))% |" -logToSummary $true
Write-Message -message "| 🆕 Not Yet Tracked | $(DisplayIntWithDots $($actionsNotTracked.Count)) | $([math]::Round(($actionsNotTracked.Count / $totalActionsInMarketplace) * 100, 2))% |" -logToSummary $true
Write-Message -message "| 🗑️ Tracked but No Longer in Marketplace | $(DisplayIntWithDots $($actionsNoLongerInMarketplace.Count)) | $([math]::Round(($actionsNoLongerInMarketplace.Count / $totalTrackedActions) * 100, 2))% |" -logToSummary $true
Write-Message -message "" -logToSummary $true
Write-Message -message "*To improve this coverage, run this workflow: [Analyze]($(Get-WorkflowUrl 'analyze.yml'))*" -logToSummary $true
Write-Message -message "" -logToSummary $true

# Show sample of untracked actions (console only, not in summary to save space)
if ($actionsNotTracked.Count -gt 0) {
    Write-Host ""
    Write-Host "Sample of Actions Not Yet Tracked (up to 20):"
    $sampleCount = [Math]::Min(20, $actionsNotTracked.Count)
    for ($i = 0; $i -lt $sampleCount; $i++) {
        $action = $actionsNotTracked[$i]
        $repoUrl = if ($action.repoUrl) { $action.repoUrl } else { "N/A" }
        Write-Host "  - $($action.name) | $repoUrl"
    }
    Write-Host ""
}

# ============================================================================
# 3. MIRROR STATUS
# ============================================================================
Write-Message -message "## Mirror Status" -logToSummary $true
Write-Message -message "" -logToSummary $true

$reposWithMirrors = ($existingForks | Where-Object { $_.mirrorFound -eq $true }).Count
$reposWithoutMirrors = ($existingForks | Where-Object { $_.mirrorFound -ne $true }).Count

Write-Message -message "| Mirror Type | Count | Percentage |" -logToSummary $true
Write-Message -message "|-------------|------:|-----------:|" -logToSummary $true
Write-Message -message "| ✅ Has Valid Mirror | $(DisplayIntWithDots $reposWithMirrors) | $([math]::Round(($reposWithMirrors / $totalTrackedActions) * 100, 2))% |" -logToSummary $true
Write-Message -message "| ❌ No Mirror | $(DisplayIntWithDots $reposWithoutMirrors) | $([math]::Round(($reposWithoutMirrors / $totalTrackedActions) * 100, 2))% |" -logToSummary $true
Write-Message -message "" -logToSummary $true
Write-Message -message "*To improve this coverage, run this workflow: [Analyze]($(Get-WorkflowUrl 'analyze.yml'))*" -logToSummary $true
Write-Message -message "" -logToSummary $true

# ============================================================================
# 4. SYNC ACTIVITY
# ============================================================================
Write-Message -message "## Sync Activity" -logToSummary $true
Write-Message -message "" -logToSummary $true

$sevenDaysAgo = (Get-Date).AddDays(-7)
$thirtyDaysAgo = (Get-Date).AddDays(-30)

# Count repos synced in different time windows
$reposSyncedLast7Days = ($existingForks | Where-Object {
    if ($_.lastSynced) {
        try {
            $syncDate = [DateTime]::Parse($_.lastSynced)
            return $syncDate -gt $sevenDaysAgo
        } catch {
            return $false
        }
    }
    return $false
}).Count

$reposSyncedLast30Days = ($existingForks | Where-Object {
    if ($_.lastSynced) {
        try {
            $syncDate = [DateTime]::Parse($_.lastSynced)
            return $syncDate -gt $thirtyDaysAgo
        } catch {
            return $false
        }
    }
    return $false
}).Count

$reposNeverSynced = ($existingForks | Where-Object {
    -not $_.lastSynced -or $_.lastSynced -eq $null -or $_.lastSynced -eq ""
}).Count

# Calculate percentages based on repos with mirrors
$percentLast7Days = if ($reposWithMirrors -gt 0) { [math]::Round(($reposSyncedLast7Days / $reposWithMirrors) * 100, 2) } else { 0 }
$percentLast30Days = if ($reposWithMirrors -gt 0) { [math]::Round(($reposSyncedLast30Days / $reposWithMirrors) * 100, 2) } else { 0 }
$percentNeverSynced = if ($totalTrackedActions -gt 0) { [math]::Round(($reposNeverSynced / $totalTrackedActions) * 100, 2) } else { 0 }

Write-Message -message "| Time Window | Count | % of Mirrors |" -logToSummary $true
Write-Message -message "|-------------|------:|-------------:|" -logToSummary $true
Write-Message -message "| 🟢 Synced in Last 7 Days | $(DisplayIntWithDots $reposSyncedLast7Days) | ${percentLast7Days}% |" -logToSummary $true
Write-Message -message "| 🟡 Synced in Last 30 Days | $(DisplayIntWithDots $reposSyncedLast30Days) | ${percentLast30Days}% |" -logToSummary $true
Write-Message -message "| ⚪ Never Synced | $(DisplayIntWithDots $reposNeverSynced) | ${percentNeverSynced}% |" -logToSummary $true
Write-Message -message "" -logToSummary $true

# Repos that need updates (have mirrors but not synced in last 7 days)
$reposNeedingUpdate = $reposWithMirrors - $reposSyncedLast7Days
$percentNeedingUpdate = if ($reposWithMirrors -gt 0) { [math]::Round(($reposNeedingUpdate / $reposWithMirrors) * 100, 2) } else { 0 }

Write-Message -message "### Repos Needing Updates" -logToSummary $true
Write-Message -message "" -logToSummary $true
Write-Message -message "**$(DisplayIntWithDots $reposNeedingUpdate)** repos with mirrors have not been synced in the last 7 days (${percentNeedingUpdate}% of mirrored repos)" -logToSummary $true
Write-Message -message "" -logToSummary $true
Write-Message -message "*To improve this coverage, run this workflow: [Update Mirrors]($(Get-WorkflowUrl 'update-forks.yml'))*" -logToSummary $true
Write-Message -message "" -logToSummary $true

# ============================================================================
# 5. REPO INFO STATUS
# ============================================================================
Write-Message -message "## Repo Info Collection Status" -logToSummary $true
Write-Message -message "" -logToSummary $true

# Count repos with various info collected
$reposWithTags = ($existingForks | Where-Object {
    $_.tagInfo -and $_.tagInfo.Count -gt 0
}).Count

$reposWithReleases = ($existingForks | Where-Object {
    $_.releaseInfo -and $_.releaseInfo.Count -gt 0
}).Count

$reposWithRepoInfo = ($existingForks | Where-Object {
    $_.repoInfo -ne $null
}).Count

$reposWithActionType = ($existingForks | Where-Object {
    $type = Get-ActionTypeValue -data $_.actionType
    # Consider it valid if it's not empty, "Unknown", or "No file found"
    return ($type -and $type -ne "" -and $type -ne "Unknown" -and $type -ne "No file found")
}).Count

Write-Message -message "| Info Type | Count | Percentage |" -logToSummary $true
Write-Message -message "|-----------|------:|-----------:|" -logToSummary $true
Write-Message -message "| 📦 Has Tags | $(DisplayIntWithDots $reposWithTags) | $([math]::Round(($reposWithTags / $totalTrackedActions) * 100, 2))% |" -logToSummary $true
Write-Message -message "| 🎯 Has Releases | $(DisplayIntWithDots $reposWithReleases) | $([math]::Round(($reposWithReleases / $totalTrackedActions) * 100, 2))% |" -logToSummary $true
Write-Message -message "| ℹ️ Has Repo Info | $(DisplayIntWithDots $reposWithRepoInfo) | $([math]::Round(($reposWithRepoInfo / $totalTrackedActions) * 100, 2))% |" -logToSummary $true
Write-Message -message "| 🎭 Has Valid Action Type | $(DisplayIntWithDots $reposWithActionType) | $([math]::Round(($reposWithActionType / $totalTrackedActions) * 100, 2))% |" -logToSummary $true

# Count repos with funding info
$reposWithFunding = ($existingForks | Where-Object {
    $_.fundingInfo -and $_.fundingInfo.hasFunding -eq $true
}).Count

Write-Message -message "| 💰 Has Funding Info | $(DisplayIntWithDots $reposWithFunding) | $([math]::Round(($reposWithFunding / $totalTrackedActions) * 100, 2))% |" -logToSummary $true
Write-Message -message "" -logToSummary $true
Write-Message -message "*To improve this coverage, run this workflow: [Get repo info]($(Get-WorkflowUrl 'repoInfo.yml'))*" -logToSummary $true
Write-Message -message "" -logToSummary $true

# ============================================================================
# 6. ACTION TYPE BREAKDOWN
# ============================================================================
Write-Message -message "## Action Type Breakdown" -logToSummary $true
Write-Message -message "" -logToSummary $true

$actionTypeCount = @{}
foreach ($fork in $existingForks) {
    $type = Get-ActionTypeValue -data $fork.actionType
    
    if ($actionTypeCount.ContainsKey($type)) {
        $actionTypeCount[$type]++
    } else {
        $actionTypeCount[$type] = 1
    }
}

Write-Message -message "| Action Type | Count | Percentage |" -logToSummary $true
Write-Message -message "|-------------|------:|-----------:|" -logToSummary $true
# Sort by count descending and display all types (reuse for console output below)
$sortedTypes = $actionTypeCount.Keys | Sort-Object -Descending { $actionTypeCount[$_] }
foreach ($type in $sortedTypes) {
    $count = DisplayIntWithDots($actionTypeCount[$type])
    $percentage = [math]::Round(($count / $totalTrackedActions) * 100, 2)
    Write-Message -message "| $type | $count | ${percentage}% |" -logToSummary $true
}
Write-Message -message "" -logToSummary $true

# Output full breakdown to console for reference (reuses sorted types from above)
Write-Host ""
Write-Host "Full Action Type Breakdown (console only):"
foreach ($type in $sortedTypes) {
    $count = $actionTypeCount[$type]
    $percentage = [math]::Round(($count / $totalTrackedActions) * 100, 2)
    Write-Host "  $type : $count (${percentage}%)"
}
Write-Message -message "" -logToSummary $true
Write-Message -message "*To improve this coverage, run this workflow: [Analyze]($(Get-WorkflowUrl 'analyze.yml'))*" -logToSummary $true
Write-Message -message "" -logToSummary $true

# ============================================================================
# 6.1. DOCKER COMPOSITION STATUS
# ============================================================================
Write-Message -message "## Docker Composition Status" -logToSummary $true
Write-Message -message "" -logToSummary $true

# Count Docker actions and their composition types
$dockerActionsTotal = 0
$dockerWithCompositionInfo = 0
$dockerLocalDockerfile = 0
$dockerRemoteImage = 0
$dockerLocalWithCustomCode = 0
$dockerLocalWithoutCustomCode = 0
$dockerLocalWithCustomCodeInfo = 0

foreach ($fork in $existingForks) {
    # Check if this is a Docker action
    if ($fork.actionType -and $fork.actionType.actionType -eq "Docker") {
        $dockerActionsTotal++
        
        # Check if we have composition info (actionDockerType field)
        if ($fork.actionType.actionDockerType) {
            $dockerWithCompositionInfo++
            
            if ($fork.actionType.actionDockerType -eq "Dockerfile") {
                $dockerLocalDockerfile++
                
                # Check if we have custom code information
                if ($null -ne $fork.actionType.dockerfileHasCustomCode) {
                    $dockerLocalWithCustomCodeInfo++
                    if ($fork.actionType.dockerfileHasCustomCode -eq $true) {
                        $dockerLocalWithCustomCode++
                    }
                    else {
                        $dockerLocalWithoutCustomCode++
                    }
                }
            }
            elseif ($fork.actionType.actionDockerType -eq "Image") {
                $dockerRemoteImage++
            }
        }
    }
}

# Calculate percentages
$percentWithInfo = if ($dockerActionsTotal -gt 0) {
    [math]::Round(($dockerWithCompositionInfo / $dockerActionsTotal) * 100, 2)
} else {
    0
}

$percentLocalDockerfile = if ($dockerWithCompositionInfo -gt 0) {
    [math]::Round(($dockerLocalDockerfile / $dockerWithCompositionInfo) * 100, 2)
} else {
    0
}

$percentRemoteImage = if ($dockerWithCompositionInfo -gt 0) {
    [math]::Round(($dockerRemoteImage / $dockerWithCompositionInfo) * 100, 2)
} else {
    0
}

Write-Message -message "Discovery status for Docker-based actions:" -logToSummary $true
Write-Message -message "" -logToSummary $true
Write-Message -message "| Metric | Count | Percentage |" -logToSummary $true
Write-Message -message "|--------|------:|-----------:|" -logToSummary $true
Write-Message -message "| 🐳 **Total Docker Actions** | **$(DisplayIntWithDots $dockerActionsTotal)** | **100%** |" -logToSummary $true
Write-Message -message "| ✅ With Composition Info | $(DisplayIntWithDots $dockerWithCompositionInfo) | ${percentWithInfo}% |" -logToSummary $true

# Calculate missing info percentage with better readability
$missingCompositionInfo = $dockerActionsTotal - $dockerWithCompositionInfo
$divisor = [math]::Max($dockerActionsTotal, 1)
$percentMissing = [math]::Round(($missingCompositionInfo / $divisor) * 100, 2)
Write-Message -message "| ❓ Missing Composition Info | $(DisplayIntWithDots $missingCompositionInfo) | ${percentMissing}% |" -logToSummary $true
Write-Message -message "" -logToSummary $true

if ($dockerWithCompositionInfo -gt 0) {
    Write-Message -message "### Docker Composition Breakdown" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "For actions where we have composition information:" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "| Composition Type | Count | Percentage |" -logToSummary $true
    Write-Message -message "|-----------------|------:|-----------:|" -logToSummary $true
    Write-Message -message "| 📦 Local Dockerfile | $(DisplayIntWithDots $dockerLocalDockerfile) | ${percentLocalDockerfile}% |" -logToSummary $true
    Write-Message -message "| 🌐 Remote Image | $(DisplayIntWithDots $dockerRemoteImage) | ${percentRemoteImage}% |" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Show custom code analysis for local Dockerfiles
    if ($dockerLocalDockerfile -gt 0) {
        Write-Message -message "#### Local Dockerfile Analysis" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        
        $percentWithCodeInfo = if ($dockerLocalDockerfile -gt 0) {
            [math]::Round(($dockerLocalWithCustomCodeInfo / $dockerLocalDockerfile) * 100, 2)
        } else {
            0
        }
        
        Write-Message -message "| Analysis Status | Count | Percentage |" -logToSummary $true
        Write-Message -message "|----------------|------:|-----------:|" -logToSummary $true
        Write-Message -message "| 📊 Analyzed for Custom Code | $(DisplayIntWithDots $dockerLocalWithCustomCodeInfo) | ${percentWithCodeInfo}% |" -logToSummary $true
        Write-Message -message "| ⏳ Not Yet Analyzed | $(DisplayIntWithDots ($dockerLocalDockerfile - $dockerLocalWithCustomCodeInfo)) | $([math]::Round((($dockerLocalDockerfile - $dockerLocalWithCustomCodeInfo) / [math]::Max($dockerLocalDockerfile, 1)) * 100, 2))% |" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        
        if ($dockerLocalWithCustomCodeInfo -gt 0) {
            $percentWithCode = [math]::Round(($dockerLocalWithCustomCode / $dockerLocalWithCustomCodeInfo) * 100, 2)
            $percentWithoutCode = [math]::Round(($dockerLocalWithoutCustomCode / $dockerLocalWithCustomCodeInfo) * 100, 2)
            
            Write-Message -message "**Of the $dockerLocalWithCustomCodeInfo analyzed local Dockerfiles:**" -logToSummary $true
            Write-Message -message "" -logToSummary $true
            Write-Message -message "| Type | Count | Percentage |" -logToSummary $true
            Write-Message -message "|------|------:|-----------:|" -logToSummary $true
            Write-Message -message "| 🔧 With Custom Code (COPY/ADD) | $(DisplayIntWithDots $dockerLocalWithCustomCode) | ${percentWithCode}% |" -logToSummary $true
            Write-Message -message "| 📦 Base Image Only | $(DisplayIntWithDots $dockerLocalWithoutCustomCode) | ${percentWithoutCode}% |" -logToSummary $true
            Write-Message -message "" -logToSummary $true
        }
    }
}
Write-Message -message "" -logToSummary $true
Write-Message -message "*To improve this coverage, run this workflow: [Analyze]($(Get-WorkflowUrl 'analyze.yml'))*" -logToSummary $true
Write-Message -message "" -logToSummary $true

# ============================================================================
# 6.2. FUNDING INFORMATION STATUS
# ============================================================================
Write-Message -message "## Funding Information Status" -logToSummary $true
Write-Message -message "" -logToSummary $true

# Count repos with funding information
$reposWithFundingInfo = 0
$totalPlatforms = 0
$platformCounts = @{}

foreach ($fork in $existingForks) {
    if ($fork.fundingInfo -and $fork.fundingInfo.hasFunding -eq $true) {
        $reposWithFundingInfo++
        $totalPlatforms += $fork.fundingInfo.platformCount
        
        # Count each platform type
        if ($fork.fundingInfo.platforms) {
            foreach ($platform in $fork.fundingInfo.platforms) {
                if ($platformCounts.ContainsKey($platform)) {
                    $platformCounts[$platform]++
                } else {
                    $platformCounts[$platform] = 1
                }
            }
        }
    }
}

$percentWithFunding = if ($totalTrackedActions -gt 0) {
    [math]::Round(($reposWithFundingInfo / $totalTrackedActions) * 100, 2)
} else {
    0
}

$averagePlatformsPerRepo = if ($reposWithFundingInfo -gt 0) {
    [math]::Round(($totalPlatforms / $reposWithFundingInfo), 2)
} else {
    0
}

Write-Message -message "| Metric | Count | Percentage |" -logToSummary $true
Write-Message -message "|--------|------:|-----------:|" -logToSummary $true
Write-Message -message "| 💰 Actions with FUNDING.yml | $(DisplayIntWithDots $reposWithFundingInfo) | ${percentWithFunding}% |" -logToSummary $true
Write-Message -message "| 📊 Total Funding Platforms | $(DisplayIntWithDots $totalPlatforms) | - |" -logToSummary $true
Write-Message -message "| 📈 Avg Platforms per Funded Action | $averagePlatformsPerRepo | - |" -logToSummary $true
Write-Message -message "" -logToSummary $true

Write-Message -message "" -logToSummary $true
Write-Message -message "*To improve this coverage, run this workflow: [Analyze]($(Get-WorkflowUrl 'analyze.yml'))*" -logToSummary $true
Write-Message -message "" -logToSummary $true

# ============================================================================
# 7. RATE LIMIT STATUS (if token provided) - console only
# ============================================================================
if ($access_token_destination -ne "") {
    Write-Host ""
    Write-Host "Rate Limit Status (console only):"
    Write-Host ""
    
    # Get rate limit info but don't log to summary to save space
    # Use waitForRateLimit = $false since this is optional info and shouldn't block the report
    $url = "rate_limit"
    $response = ApiCall -method GET -url $url -access_token $access_token_destination -waitForRateLimit $false
    
    if ($null -ne $response -and $null -ne $response.rate) {
        $resetTime = [DateTimeOffset]::FromUnixTimeSeconds($response.rate.reset).UtcDateTime
        $timeUntilReset = $resetTime - (Get-Date).ToUniversalTime()
        
        if ($timeUntilReset.TotalMinutes -lt 1) {
            $resetDisplay = "< 1 minute"
        } elseif ($timeUntilReset.TotalHours -lt 1) {
            $resetDisplay = "$([math]::Floor($timeUntilReset.TotalMinutes)) minutes"
        } else {
            $hours = [math]::Floor($timeUntilReset.TotalHours)
            $minutes = [math]::Floor($timeUntilReset.TotalMinutes % 60)
            if ($minutes -eq 0) {
                $resetDisplay = "$hours hours"
            } else {
                $resetDisplay = "$hours hours $minutes minutes"
            }
        }
        
        Write-Host "  Limit: $($response.rate.limit)"
        Write-Host "  Used: $($response.rate.used)"
        Write-Host "  Remaining: $($response.rate.remaining)"
        Write-Host "  Resets in: $resetDisplay"
    }
    elseif ($null -eq $response) {
        Write-Host "  (Rate limit information unavailable - API rate limit may be exceeded)"
    }
    
    Write-Host ""
}

# ============================================================================
# 8. HEALTH METRICS
# ============================================================================
Write-Message -message "## Health Metrics" -logToSummary $true
Write-Message -message "" -logToSummary $true

# Calculate coverage percentage
$coveragePercentage = if ($totalActionsInMarketplace -gt 0) {
    [math]::Round(($totalTrackedActions / $totalActionsInMarketplace) * 100, 2)
} else {
    0
}

# Calculate freshness percentage (repos synced in last 7 days)
$freshnessPercentage = if ($reposWithMirrors -gt 0) {
    [math]::Round(($reposSyncedLast7Days / $reposWithMirrors) * 100, 2)
} else {
    0
}

# Calculate completion percentage (repos with action type identified)
$completionPercentage = if ($totalTrackedActions -gt 0) {
    [math]::Round(($reposWithActionType / $totalTrackedActions) * 100, 2)
} else {
    0
}

Write-Message -message "| Metric | Value | Status |" -logToSummary $true
Write-Message -message "|--------|------:|:-------|" -logToSummary $true

$coverageStatus = if ($coveragePercentage -ge 90) { "🟢 Excellent" } elseif ($coveragePercentage -ge 75) { "🟡 Good" } else { "🔴 Needs Attention" }
Write-Message -message "| **Coverage** (Tracked vs Marketplace) | ${coveragePercentage}% | $coverageStatus |" -logToSummary $true

$freshnessStatus = if ($freshnessPercentage -ge 80) { "🟢 Excellent" } elseif ($freshnessPercentage -ge 60) { "🟡 Good" } else { "🔴 Needs Attention" }
Write-Message -message "| **Freshness** (Synced in Last 7 Days) | ${freshnessPercentage}% | $freshnessStatus |" -logToSummary $true

$completionStatus = if ($completionPercentage -ge 90) { "🟢 Excellent" } elseif ($completionPercentage -ge 75) { "🟡 Good" } else { "🔴 Needs Attention" }
Write-Message -message "| **Completion** (Action Type Identified) | ${completionPercentage}% | $completionStatus |" -logToSummary $true

Write-Message -message "" -logToSummary $true

# ============================================================================
# 9. SUMMARY
# ============================================================================
Write-Message -message "## Summary" -logToSummary $true
Write-Message -message "" -logToSummary $true
Write-Message -message "- **$(DisplayIntWithDots($totalActionsInMarketplace))** actions in the marketplace" -logToSummary $true
Write-Message -message "- **$(DisplayIntWithDots($totalTrackedActions))** actions tracked in our system" -logToSummary $true
Write-Message -message "- **$(DisplayIntWithDots($reposWithMirrors))** valid mirrors maintained" -logToSummary $true
Write-Message -message "- **$(DisplayIntWithDots($reposSyncedLast7Days))** repos synced in the last 7 days" -logToSummary $true
Write-Message -message "- **$(DisplayIntWithDots($reposNeedingUpdate))** repos need updates (not synced in last 7 days)" -logToSummary $true
Write-Message -message "- **$(DisplayIntWithDots($($actionsNotTracked.Count)))** new actions to track" -logToSummary $true
Write-Message -message "" -logToSummary $true

Write-Host ""
Write-Host "Environment state documentation complete!"
