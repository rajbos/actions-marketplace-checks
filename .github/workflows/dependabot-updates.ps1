Param (
  $actions,
  $numberOfReposToDo = 10,
  $access_token = $env:GITHUB_TOKEN,
  $access_token_destination = $env:GITHUB_TOKEN
)

. $PSScriptRoot/library.ps1

Test-AccessTokens -accessToken $accessToken -access_token_destination $access_token_destination -numberOfReposToDo $numberOfReposToDo

function RunForAllForkedActions {
    Param (
        $existingForks,
        [int] $numberOfReposToDo
    )

    Write-Host "Running for [$($existingForks.Count)] forks"
    # filter actions list to only the ones with a repoUrl
    "Found [$($existingForks.Count)] forks to check" >> $env:GITHUB_STEP_SUMMARY

    EnableDependabotForForkedActions -existingForks $existingForks -numberOfReposToDo $numberOfReposToDo

    # todo: store this state in a separate file
    #SaveStatus -existingForks $existingForks
    #return $existingForks
}

function EnableDependabotForForkedActions {
    Param (
        $existingForks,
        [int] $numberOfReposToDo
    )

    $i = 0
    $max = $numberOfReposToDo
    $dependabotEnabled = 0

    foreach ($existingFork in $existingForks) {

        if ($i -ge $max) {
            # do not run to long
            break            
            Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
        }

        if ($existingFork.dependabotEnabled -or ($existingFork.dependabotEnabled -eq $true)) {
            Write-Debug "Dependabot already enabled for [$($existingFork.name)]" #todo: convert to Write-Debug
            continue
        }
        
        if (EnableDependabot -existingFork $existingFork -access_token_destination $access_token_destination) {
            Write-Host "$i - Dependabot enabled for [$($existingFork.name)]"
            $existingFork | Add-Member -Name dependabotEnabled -Value $true -MemberType NoteProperty
            $i++ | Out-Null
            $dependabotEnabled++ | Out-Null
        }
    }

    Write-Host "Enabled Dependabot on [$($dependabotEnabled)] repos"
    "Enabled Dependabot on [$($dependabotEnabled)] repos" >> $env:GITHUB_STEP_SUMMARY
}

GetRateLimitInfo
RunForAllForkedActions -existingForks $existingForks -numberOfReposToDo $numberOfReposToDo
SaveStatus -existingForks $existingForks

GetRateLimitInfo
