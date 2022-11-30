Param (
  $actions,
  $numberOfReposToDo = 10,
  $access_token = $env:GITHUB_TOKEN,
  $access_token_destination = $env:GITHUB_TOKEN
)

. $PSScriptRoot/library.ps1

function RunForAllForkedActions {
    Param (
        $existingForks,
        [int] $numberOfReposToDo
    )

    Write-Host "Running for [$($existingForks.Count)] forks"
    # filter actions list to only the ones with a repoUrl
    "Found [$($existingForks.Count)] forks to check" >> $env:GITHUB_STEP_SUMMARY

    ($existingForks, $dependabotEnabled) = EnableDependabotForForkedActions -existingForks $existingForks -numberOfReposToDo $numberOfReposToDo
    Write-Host "Enabled Dependabot on [$($dependabotEnabled)] repos"
    "Enabled Dependabot on [$($dependabotEnabled)] repos" >> $env:GITHUB_STEP_SUMMARY

    # todo: store this state in a separate file
    #SaveStatus -existingForks $existingForks
    #return $existingForks
}

RunForAllForkedActions -existingForks $existingForks -numberOfReposToDo $numberOfReposToDo