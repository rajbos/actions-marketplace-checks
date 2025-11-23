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

    Write-Message -message "Running fork sync for [$($existingForks.Count)] forks" -logToSummary $true
    
    $i = 0
    $max = $numberOfReposToDo
    $synced = 0
    $failed = 0
    $upToDate = 0
    $conflicts = 0

    foreach ($existingFork in $existingForks) {

        if ($i -ge $max) {
            # do not run too long
            Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
            break
        }

        # Skip repos that don't have forkFound property or where it's false
        if ($null -eq $existingFork.forkFound -or $existingFork.forkFound -eq $false) {
            Write-Debug "Fork not found for [$($existingFork.name)], skipping"
            continue
        }

        # Get the owner and repo from the fork name
        ($owner, $repo) = GetOrgActionInfo -forkedOwnerRepo $existingFork.name
        
        if ([string]::IsNullOrEmpty($owner) -or [string]::IsNullOrEmpty($repo)) {
            Write-Warning "Could not parse owner/repo from fork name [$($existingFork.name)], skipping"
            continue
        }

        Write-Host "$i/$max Syncing fork [$forkOrg/$($existingFork.name)] with upstream [$owner/$repo]"
        
        $result = SyncForkWithUpstream -owner $forkOrg -repo $existingFork.name -access_token $access_token_destination
        
        if ($result.success) {
            if ($result.message -like "*Already up to date*") {
                Write-Debug "Fork [$($existingFork.name)] already up to date"
                $upToDate++
            }
            else {
                Write-Host "$i/$max Successfully synced fork [$($existingFork.name)]"
                $synced++
                # Update the sync timestamp
                $existingFork | Add-Member -Name lastSynced -Value (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ") -MemberType NoteProperty -Force
            }
        }
        else {
            if ($result.message -like "*Merge conflict*") {
                Write-Warning "$i/$max Merge conflict detected for fork [$($existingFork.name)]"
                $conflicts++
            }
            else {
                Write-Warning "$i/$max Failed to sync fork [$($existingFork.name)]: $($result.message)"
                $failed++
            }
            # Track failed sync
            $existingFork | Add-Member -Name lastSyncError -Value $result.message -MemberType NoteProperty -Force
            $existingFork | Add-Member -Name lastSyncAttempt -Value (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ") -MemberType NoteProperty -Force
        }
        
        $i++ | Out-Null
    }

    Write-Message -message "Fork sync complete: Synced=[$synced], UpToDate=[$upToDate], Conflicts=[$conflicts], Failed=[$failed]" -logToSummary $true
    return $existingForks
}

GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination
$existingForks = UpdateForkedRepos -existingForks $actions -numberOfReposToDo $numberOfReposToDo
SaveStatus -existingForks $existingForks
GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination
