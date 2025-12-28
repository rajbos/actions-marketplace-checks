Param (
  $actions,
  $numberOfReposToDo = 10,
  $access_token = $env:GITHUB_TOKEN,
  $access_token_destination = $env:GITHUB_TOKEN
)

. $PSScriptRoot/library.ps1

Test-AccessTokens -accessToken $access_token -access_token_destination $access_token_destination -numberOfReposToDo $numberOfReposToDo

function RunForAllForkedActions {
    Param (
        $existingForks,
        [int] $numberOfReposToDo
    )

    Write-Message -message "Running for [$($existingForks.Count)] forks"  -logToSummary $true
    
    $existingForks = EnableDependabotForForkedActions -existingForks $existingForks -numberOfReposToDo $numberOfReposToDo
    return $existingForks
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

    Write-Message -message "Enabled Dependabot on [$($dependabotEnabled)] repos" -logToSummary $true
    return $existingForks
}

GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination
$existingForks = RunForAllForkedActions -existingForks $actions -numberOfReposToDo $numberOfReposToDo
SaveStatus -existingForks $existingForks

$existingForks = GetDependabotAlerts -existingForks $actions -numberOfReposToDo $numberOfReposToDo
SaveStatus -existingForks $existingForks

GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination -waitForRateLimit $false
