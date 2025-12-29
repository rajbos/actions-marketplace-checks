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
Write-Message -message "| **Actions in Marketplace** (actions.json) | $totalActionsInMarketplace |" -logToSummary $true
Write-Message -message "| **Tracked Actions** (status.json) | $totalTrackedActions |" -logToSummary $true
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
Write-Message -message "| ✅ Actions in Both Datasets | $actionsInBoth | $([math]::Round(($actionsInBoth / $totalActionsInMarketplace) * 100, 2))% |" -logToSummary $true
Write-Message -message "| 🆕 Not Yet Tracked | $($actionsNotTracked.Count) | $([math]::Round(($actionsNotTracked.Count / $totalActionsInMarketplace) * 100, 2))% |" -logToSummary $true
Write-Message -message "| 🗑️ Tracked but No Longer in Marketplace | $($actionsNoLongerInMarketplace.Count) | $([math]::Round(($actionsNoLongerInMarketplace.Count / $totalTrackedActions) * 100, 2))% |" -logToSummary $true
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
$reposWithForks = ($existingForks | Where-Object { $_.forkFound -eq $true }).Count
$reposWithoutForks = ($existingForks | Where-Object { $_.forkFound -ne $true }).Count

Write-Message -message "| Mirror Type | Count | Percentage |" -logToSummary $true
Write-Message -message "|-------------|------:|-----------:|" -logToSummary $true
Write-Message -message "| ✅ Has Valid Mirror | $reposWithMirrors | $([math]::Round(($reposWithMirrors / $totalTrackedActions) * 100, 2))% |" -logToSummary $true
Write-Message -message "| ❌ No Mirror | $reposWithoutMirrors | $([math]::Round(($reposWithoutMirrors / $totalTrackedActions) * 100, 2))% |" -logToSummary $true
Write-Message -message "| 🔄 Has Fork | $reposWithForks | $([math]::Round(($reposWithForks / $totalTrackedActions) * 100, 2))% |" -logToSummary $true
Write-Message -message "| ⚠️ No Fork | $reposWithoutForks | $([math]::Round(($reposWithoutForks / $totalTrackedActions) * 100, 2))% |" -logToSummary $true
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
Write-Message -message "| 🟢 Synced in Last 7 Days | $reposSyncedLast7Days | ${percentLast7Days}% |" -logToSummary $true
Write-Message -message "| 🟡 Synced in Last 30 Days | $reposSyncedLast30Days | ${percentLast30Days}% |" -logToSummary $true
Write-Message -message "| ⚪ Never Synced | $reposNeverSynced | ${percentNeverSynced}% |" -logToSummary $true
Write-Message -message "" -logToSummary $true

# Repos that need updates (have mirrors but not synced in last 7 days)
$reposNeedingUpdate = $reposWithMirrors - $reposSyncedLast7Days
$percentNeedingUpdate = if ($reposWithMirrors -gt 0) { [math]::Round(($reposNeedingUpdate / $reposWithMirrors) * 100, 2) } else { 0 }

Write-Message -message "### Repos Needing Updates" -logToSummary $true
Write-Message -message "" -logToSummary $true
Write-Message -message "**$reposNeedingUpdate** repos with mirrors have not been synced in the last 7 days (${percentNeedingUpdate}% of mirrored repos)" -logToSummary $true
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
    $_.actionType -and $_.actionType -ne "" -and $_.actionType -ne "No file found"
}).Count

Write-Message -message "| Info Type | Count | Percentage |" -logToSummary $true
Write-Message -message "|-----------|------:|-----------:|" -logToSummary $true
Write-Message -message "| 📦 Has Tags | $reposWithTags | $([math]::Round(($reposWithTags / $totalTrackedActions) * 100, 2))% |" -logToSummary $true
Write-Message -message "| 🎯 Has Releases | $reposWithReleases | $([math]::Round(($reposWithReleases / $totalTrackedActions) * 100, 2))% |" -logToSummary $true
Write-Message -message "| ℹ️ Has Repo Info | $reposWithRepoInfo | $([math]::Round(($reposWithRepoInfo / $totalTrackedActions) * 100, 2))% |" -logToSummary $true
Write-Message -message "| 🎭 Has Valid Action Type | $reposWithActionType | $([math]::Round(($reposWithActionType / $totalTrackedActions) * 100, 2))% |" -logToSummary $true
Write-Message -message "" -logToSummary $true

# ============================================================================
# 6. ACTION TYPE BREAKDOWN
# ============================================================================
Write-Message -message "## Action Type Breakdown" -logToSummary $true
Write-Message -message "" -logToSummary $true

$actionTypeCount = @{}
foreach ($fork in $existingForks) {
    $type = if ($fork.actionType) { $fork.actionType } else { "Unknown" }
    if ($actionTypeCount.ContainsKey($type)) {
        $actionTypeCount[$type]++
    } else {
        $actionTypeCount[$type] = 1
    }
}

Write-Message -message "| Action Type | Count | Percentage |" -logToSummary $true
Write-Message -message "|-------------|------:|-----------:|" -logToSummary $true
# Show only top 10 action types to keep summary size manageable (was causing 1983KB summary with thousands of types)
$topTypes = $actionTypeCount.Keys | Sort-Object -Descending { $actionTypeCount[$_] } | Select-Object -First 10
foreach ($type in $topTypes) {
    $count = $actionTypeCount[$type]
    $percentage = [math]::Round(($count / $totalTrackedActions) * 100, 2)
    Write-Message -message "| $type | $count | ${percentage}% |" -logToSummary $true
}
# If there are more types, show a summary line
$remainingTypes = $actionTypeCount.Keys.Count - $topTypes.Count
if ($remainingTypes -gt 0) {
    Write-Message -message "| _(${remainingTypes} other types)_ | ... | ... |" -logToSummary $true
}
Write-Message -message "" -logToSummary $true

# Output full breakdown to console for reference
Write-Host ""
Write-Host "Full Action Type Breakdown (console only):"
foreach ($type in ($actionTypeCount.Keys | Sort-Object -Descending { $actionTypeCount[$_] })) {
    $count = $actionTypeCount[$type]
    $percentage = [math]::Round(($count / $totalTrackedActions) * 100, 2)
    Write-Host "  $type : $count (${percentage}%)"
}

# ============================================================================
# 7. RATE LIMIT STATUS (if token provided) - console only
# ============================================================================
if ($access_token_destination -ne "") {
    Write-Host ""
    Write-Host "Rate Limit Status (console only):"
    Write-Host ""
    
    # Get rate limit info but don't log to summary to save space
    $url = "rate_limit"
    $response = ApiCall -method GET -url $url -access_token $access_token_destination
    
    if ($null -ne $response) {
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
Write-Message -message "|--------|------:|:------:|" -logToSummary $true

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
Write-Message -message "- **$totalActionsInMarketplace** actions in the marketplace" -logToSummary $true
Write-Message -message "- **$totalTrackedActions** actions tracked in our system" -logToSummary $true
Write-Message -message "- **$reposWithMirrors** valid mirrors maintained" -logToSummary $true
Write-Message -message "- **$reposSyncedLast7Days** repos synced in the last 7 days" -logToSummary $true
Write-Message -message "- **$reposNeedingUpdate** repos need updates (not synced in last 7 days)" -logToSummary $true
Write-Message -message "- **$($actionsNotTracked.Count)** new actions to track" -logToSummary $true
Write-Message -message "" -logToSummary $true

Write-Host ""
Write-Host "Environment state documentation complete!"
