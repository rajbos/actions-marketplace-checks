# Refresh tagInfo/releaseInfo for the actions whose version data is the most stale.
#
# Why this script exists (see Decision Records / troubleshooting notes for the
# full writeup): GetMoreInfo in repoInfo.ps1 walks the existingForks array in a
# fixed, unrotated order and stops once it has done ~numberOfReposToDo units of
# work for the run. It has no per-field freshness ordering, so a fork with
# complete data (owner/actionType/etc already filled in) is exactly as likely
# to be reached as one that is missing critical fields - there is no
# guarantee a repo's tagInfo/releaseInfo gets revisited within any bounded
# time, even though CheckForInfoUpdateNeeded-style logic elsewhere treats 30
# days as "stale". Popular, fully-enriched actions (the ones most likely to
# ship frequent releases) are the ones with the least other work left to do,
# so they are not structurally favored by that scan - they just don't have a
# dedicated mechanism guaranteeing periodic revisits either.
#
# This script is intentionally narrow: it only touches tagInfo/releaseInfo,
# using a single cheap GitHub API call per field (releases list + matching-refs
# tags), and it always processes the actions with the oldest
# tagInfoCheckedAt/releaseInfoCheckedAt first - so every action is guaranteed
# to be revisited within roughly (total eligible actions / numberOfReposToDo)
# runs, regardless of what else is or isn't filled in on the record.
Param (
  $numberOfReposToDo = 800,
  $access_token = $env:GITHUB_TOKEN,
  $access_token_destination = $env:GITHUB_TOKEN
)

. $PSScriptRoot/library.ps1

$accessToken = $access_token

if ([string]::IsNullOrWhiteSpace($accessToken)) {
    try {
        $tokenManager = New-GitHubAppTokenManagerFromEnvironment
        # Share the token manager instance with library.ps1 so ApiCall can
        # coordinate app switching and failover across all requests in this run.
        $script:GitHubAppTokenManagerInstance = $tokenManager
        $tokenResult = $tokenManager.GetTokenForOrganization($env:APP_ORGANIZATION)
        $accessToken = $tokenResult.Token
    }
    catch {
        Write-Error "Failed to obtain GitHub App token for organization [$($env:APP_ORGANIZATION)]: $($_.Exception.Message)"
        throw
    }
}
$env:GITHUB_TOKEN = $accessToken
$accessTokenDestination = $access_token_destination
if ([string]::IsNullOrWhiteSpace($accessTokenDestination)) {
    $accessTokenDestination = $accessToken
}

Test-AccessTokens -accessToken $accessToken -numberOfReposToDo $numberOfReposToDo

function Get-VersionInfoStalenessHours {
    <#
    .SYNOPSIS
        Returns how many hours it has been since tagInfo/releaseInfo were last
        checked for this action - the older of the two wins, since we refresh
        both together. Never-checked actions sort as "infinitely" stale so
        they are always prioritized over anything with a real timestamp.
    #>
    Param (
        $action
    )

    $now = Get-Date
    $maxHours = [double]0

    foreach ($fieldName in @("tagInfoCheckedAt", "releaseInfoCheckedAt")) {
        $checkedAt = $action.$fieldName
        if ($null -eq $checkedAt) {
            return [double]::MaxValue
        }
        try {
            $hours = ($now - [datetime]$checkedAt).TotalHours
        }
        catch {
            # unparsable timestamp - treat the same as never checked
            return [double]::MaxValue
        }
        if ($hours -gt $maxHours) {
            $maxHours = $hours
        }
    }

    return $maxHours
}

function Get-EligibleActionsForVersionRefresh {
    <#
    .SYNOPSIS
        Actions we can meaningfully fetch tags/releases for: the mirror needs
        to have been found and the upstream owner resolved. Anything missing
        those fields is still being enriched by repoInfo.ps1's GetInfo pass
        and isn't ready for this script yet.
    #>
    Param (
        $existingForks
    )

    return $existingForks | Where-Object {
        $_.mirrorFound -and
        (Get-Member -InputObject $_ -Name "owner" -MemberType Properties) -and
        (-not [string]::IsNullOrWhiteSpace($_.owner))
    }
}

function Update-VersionInfoForAction {
    Param (
        $action,
        [Alias('access_token')]
        $accessToken,
        $startTime
    )

    ($owner, $repo) = GetOrgActionInfo($action.name)
    if ([string]::IsNullOrWhiteSpace($owner) -or [string]::IsNullOrWhiteSpace($repo)) {
        Write-Host "Could not resolve owner/repo for [$($action.name)], skipping"
        return $false
    }

    Write-Host "Refreshing tag/release info for [$owner/$repo]"

    # Sending back the ETag we stored last time turns an unchanged repo's tags/releases
    # into a free 304 (not counted against the core rate limit) instead of a full call -
    # this is the dominant case for the vast majority of the ~29k tracked actions on any
    # given hourly run, since most repos don't cut a new tag/release every hour.
    $existingTagEtagField = Get-Member -InputObject $action -Name "tagInfoEtag" -MemberType Properties
    $existingTagEtag = if ($existingTagEtagField) { $action.tagInfoEtag } else { $null }
    $tagResult = GetRepoTagInfo -owner $owner -repo $repo -accessToken $accessToken -startTime $startTime -etag $existingTagEtag
    $tagInfoChanged = $false
    if ($null -ne $tagResult) {
        if (-not $tagResult.NotModified) {
            $tagInfo = $tagResult.Data
            if (Get-Member -InputObject $action -Name "tagInfo" -MemberType Properties) {
                $action.tagInfo = $tagInfo
            }
            else {
                $action | Add-Member -Name tagInfo -Value $tagInfo -MemberType NoteProperty
            }
            $tagInfoChanged = $true
        }

        if ($tagResult.ETag) {
            if ($existingTagEtagField) {
                $action.tagInfoEtag = $tagResult.ETag
            }
            else {
                $action | Add-Member -Name tagInfoEtag -Value $tagResult.ETag -MemberType NoteProperty
            }
        }

        # Always bump the checked-at timestamp, even on a 304, so priority scoring
        # (oldest tagInfoCheckedAt first) doesn't keep reselecting the same entries.
        if (Get-Member -InputObject $action -Name "tagInfoCheckedAt" -MemberType Properties) {
            $action.tagInfoCheckedAt = Get-Date
        }
        else {
            $action | Add-Member -Name tagInfoCheckedAt -Value (Get-Date) -MemberType NoteProperty
        }
    }

    $existingReleaseEtagField = Get-Member -InputObject $action -Name "releaseInfoEtag" -MemberType Properties
    $existingReleaseEtag = if ($existingReleaseEtagField) { $action.releaseInfoEtag } else { $null }
    $releaseResult = GetRepoReleases -owner $owner -repo $repo -accessToken $accessToken -startTime $startTime -etag $existingReleaseEtag
    $releaseInfoChanged = $false
    if ($null -ne $releaseResult) {
        if (-not $releaseResult.NotModified) {
            $releaseInfo = $releaseResult.Data
            if (Get-Member -InputObject $action -Name "releaseInfo" -MemberType Properties) {
                $action.releaseInfo = $releaseInfo
            }
            else {
                $action | Add-Member -Name releaseInfo -Value $releaseInfo -MemberType NoteProperty
            }
            $releaseInfoChanged = $true
        }

        if ($releaseResult.ETag) {
            if ($existingReleaseEtagField) {
                $action.releaseInfoEtag = $releaseResult.ETag
            }
            else {
                $action | Add-Member -Name releaseInfoEtag -Value $releaseResult.ETag -MemberType NoteProperty
            }
        }

        # Always bump the checked-at timestamp, even on a 304, so priority scoring
        # (oldest releaseInfoCheckedAt first) doesn't keep reselecting the same entries.
        if (Get-Member -InputObject $action -Name "releaseInfoCheckedAt" -MemberType Properties) {
            $action.releaseInfoCheckedAt = Get-Date
        }
        else {
            $action | Add-Member -Name releaseInfoCheckedAt -Value (Get-Date) -MemberType NoteProperty
        }
    }

    return ($tagInfoChanged -or $releaseInfoChanged)
}

function Run {
    Param (
        [Parameter(Mandatory=$true)]
        [Alias('access_token')]
        $accessToken,

        [Parameter(Mandatory=$true)]
        [Alias('access_token_destination')]
        $accessTokenDestination,

        $numberOfReposToDo
    )

    $startTime = Get-Date
    Write-Host "Run started at [$startTime]"

    # Load the current status file directly - we are only ever refreshing
    # already-known, already-mirrored actions, so there's no need to
    # reconcile against actions.json here the way repoInfo.ps1 does.
    if (-not (Test-Path $statusFile)) {
        Write-Error "No status file found at [$statusFile]; nothing to refresh"
        exit 1
    }

    $existingForks = Get-Content $statusFile | ConvertFrom-Json
    $existingForks = Normalize-ActionDates -actions $existingForks
    Write-Host "Loaded [$(DisplayIntWithDots $existingForks.Count)] known actions from the status file"

    $eligibleActions = @(Get-EligibleActionsForVersionRefresh -existingForks $existingForks)
    Write-Host "Found [$(DisplayIntWithDots $eligibleActions.Count)] actions eligible for a version refresh (mirror found + owner resolved)"

    if ($eligibleActions.Count -eq 0) {
        Write-Message -message "No eligible actions found for a version info refresh." -logToSummary $true
        SaveStatus -existingForks $existingForks
        return
    }

    # Oldest tagInfo/releaseInfo checked-at first. This is the piece that was
    # previously missing: a genuine, unconditional freshness ordering that
    # does not compete with - or get starved by - unrelated field backlogs.
    $prioritized = $eligibleActions |
        Sort-Object -Property @{ Expression = { Get-VersionInfoStalenessHours -action $_ }; Descending = $true } |
        Select-Object -First $numberOfReposToDo

    $oldestStalenessHours = Get-VersionInfoStalenessHours -action $prioritized[0]
    $oldestStalenessDisplay = if ([double]::IsPositiveInfinity($oldestStalenessHours) -or $oldestStalenessHours -eq [double]::MaxValue) {
        "never checked"
    } else {
        "$([Math]::Round($oldestStalenessHours / 24, 1)) days ago"
    }

    Write-Message -message "# Release/Tag Info Refresh" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "| Metric | Value |" -logToSummary $true
    Write-Message -message "|--------|-------|" -logToSummary $true
    Write-Message -message "| Eligible actions | $(DisplayIntWithDots $eligibleActions.Count) |" -logToSummary $true
    Write-Message -message "| Selected for this run | $(DisplayIntWithDots $prioritized.Count) |" -logToSummary $true
    Write-Message -message "| Stalest entry selected | $oldestStalenessDisplay |" -logToSummary $true
    Write-Message -message "" -logToSummary $true

    $updated = 0
    $skipped = 0
    $processed = 0
    foreach ($action in $prioritized) {
        $timeSpan = (Get-Date) - $startTime
        if ($timeSpan.TotalMinutes -gt 50) {
            Write-Host "Stopping the run, since we are nearing the 50-minute mark"
            break
        }

        $processed++
        $didUpdate = Update-VersionInfoForAction -action $action -accessToken $accessTokenDestination -startTime $startTime
        if ($didUpdate) {
            $updated++
        }
        else {
            $skipped++
        }
    }

    Write-Host ""
    Write-Host "Release/Tag Info Refresh Summary:"
    Write-Host "  Actions processed: $processed"
    Write-Host "  Actions updated: $updated"
    Write-Host "  Actions skipped (could not resolve owner/repo): $skipped"
    Write-Host ""

    Write-Message -message "| Processed this run | $(DisplayIntWithDots $processed) |" -logToSummary $true
    Write-Message -message "| Updated | $(DisplayIntWithDots $updated) |" -logToSummary $true
    Write-Message -message "| Skipped | $(DisplayIntWithDots $skipped) |" -logToSummary $true
    Write-Message -message "" -logToSummary $true

    SaveStatus -existingForks $existingForks

    GetRateLimitInfo -access_token $accessToken -access_token_destination $accessTokenDestination -waitForRateLimit $false
}

# main call
Run -accessToken $accessToken -accessTokenDestination $accessTokenDestination -numberOfReposToDo $numberOfReposToDo

# Explicitly exit with success code to prevent PowerShell from inheriting exit codes from previous commands
exit 0
