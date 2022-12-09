$actionsFile = "actions.json"
if ((Test-Path $actionsFile)) {
    $actions=(Get-Content $actionsFile | ConvertFrom-Json)
}
else {
    $actions=$null
}
$numberofReposToDo = 10

#./.github/workflows/functions.ps1 -actions $actions -numberofReposToDo $numberofReposToDo
./.github/workflows/repoInfo.ps1  -actions $actions -numberofReposToDo $numberofReposToDo
#./.github/workflows/report.ps1 -actions $actions

#./.github/workflows/cleanup-all-repos.ps1 -numberOfReposToDo $numberofReposToDo
#./tests/filtering.Tests.ps1 -actions $actions

$existingForks=(Get-Content "status.json" | ConvertFrom-Json)
#./.github/workflows/dependabot-updates.ps1 -actions $existingForks -numberOfReposToDo $numberofReposToDo