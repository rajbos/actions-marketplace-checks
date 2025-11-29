Param (
  $actions,
  $numberOfReposToDo = 100,
  $access_token = $env:GITHUB_TOKEN,
  $access_token_destination = $env:GITHUB_TOKEN
)

. $PSScriptRoot/library.ps1

Test-AccessTokens -accessToken $access_token -access_token_destination $access_token_destination -numberOfReposToDo $numberOfReposToDo

function UpdateForkedRepos {
    Param (
        $existingForks,
        [int] $numberOfReposToDo
    )

    Write-Message -message "Running mirror sync for [$($existingForks.Count)] mirrors" -logToSummary $true
    
    $i = 0
    $max = $numberOfReposToDo
    $synced = 0
    $failed = 0
    $upToDate = 0
    $conflicts = 0
    $upstreamNotFound = 0
    $skipped = 0

    foreach ($existingFork in $existingForks) {

        if ($i -ge $max) {
            # do not run too long
            Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
            break
        }

        # Skip repos that don't have forkFound property or where it's false
        if ($null -eq $existingFork.forkFound -or $existingFork.forkFound -eq $false) {
            Write-Debug "Mirror not found for [$($existingFork.name)], skipping"
            $skipped++
            continue
        }

        # Get the upstream owner and repo from the mirror name
        # Mirror name format: upstreamOwner_upstreamRepo
        ($upstreamOwner, $upstreamRepo) = GetOrgActionInfo -forkedOwnerRepo $existingFork.name
        
        if ([string]::IsNullOrEmpty($upstreamOwner) -or [string]::IsNullOrEmpty($upstreamRepo)) {
            Write-Warning "Could not parse upstream owner/repo from mirror name [$($existingFork.name)], skipping"
            $skipped++
            continue
        }

        Write-Host "($i+1)/$max Syncing mirror [actions-marketplace-validations/$($existingFork.name)] with upstream [$upstreamOwner/$upstreamRepo]"
        
        $result = SyncMirrorWithUpstream -owner $forkOrg -repo $existingFork.name -upstreamOwner $upstreamOwner -upstreamRepo $upstreamRepo -access_token $access_token_destination
        
        if ($result.success) {
            if ($result.message -like "*Already up to date*") {
                Write-Debug "Mirror [$($existingFork.name)] already up to date"
                $upToDate++
            }
            else {
                Write-Host "$i/$max Successfully synced mirror [$($existingFork.name)]"
                $synced++
                # Update the sync timestamp
                $existingFork | Add-Member -Name lastSynced -Value (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ") -MemberType NoteProperty -Force
            }
            # Clear any previous sync errors on success
            if (Get-Member -InputObject $existingFork -Name "lastSyncError" -MemberType Properties) {
                $existingFork.lastSyncError = $null
            }
        }
        else {
            # Handle different error types
            $errorType = $result.error_type
            
            if ($errorType -eq "upstream_not_found") {
                Write-Warning "$i/$max Upstream repository not found for mirror [$($existingFork.name)] - marking as unavailable"
                $upstreamNotFound++
                # Mark the upstream as not found so we skip it in future runs
                $existingFork | Add-Member -Name upstreamAvailable -Value $false -MemberType NoteProperty -Force
            }
            elseif ($errorType -eq "mirror_not_found") {
                Write-Warning "$i/$max Mirror repository not found [$($existingFork.name)] - marking forkFound as false"
                $existingFork.forkFound = $false
                $failed++
            }
            elseif ($errorType -eq "merge_conflict" -or $result.message -like "*Merge conflict*") {
                Write-Warning "$i/$max Merge conflict detected for mirror [$($existingFork.name)]"
                $conflicts++
            }
            elseif ($errorType -eq "auth_error") {
                Write-Warning "$i/$max Authentication error for mirror [$($existingFork.name)]: $($result.message)"
                $failed++
            }
            elseif ($errorType -eq "git_reference_error" -or $errorType -eq "ambiguous_refspec") {
                Write-Warning "$i/$max Git reference error for mirror [$($existingFork.name)]: $($result.message)"
                $failed++
            }
            else {
                Write-Warning "$i/$max Failed to sync mirror [$($existingFork.name)]: $($result.message)"
                $failed++
            }
            
            # Track failed sync with error details
            $existingFork | Add-Member -Name lastSyncError -Value $result.message -MemberType NoteProperty -Force
            $existingFork | Add-Member -Name lastSyncErrorType -Value $errorType -MemberType NoteProperty -Force
            $existingFork | Add-Member -Name lastSyncAttempt -Value (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ") -MemberType NoteProperty -Force
        }
        
        $i++ | Out-Null
    }

    Write-Message -message "Mirror sync complete: Synced=[$synced], UpToDate=[$upToDate], Conflicts=[$conflicts], UpstreamNotFound=[$upstreamNotFound], Failed=[$failed], Skipped=[$skipped]" -logToSummary $true
    return $existingForks
}

GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination
$existingForks = UpdateForkedRepos -existingForks $actions -numberOfReposToDo $numberOfReposToDo
SaveStatus -existingForks $existingForks
GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination
