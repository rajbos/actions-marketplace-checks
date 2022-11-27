$actionsFile = "actions.json"
if ((Test-Path $actionsFile)) {
    $actions=(Get-Content $actionsFile | ConvertFrom-Json)
}
else {
    $actions=$null
}
./.github/workflows/functions.ps1 -actions $actions -numberofReposToDo 50
#./.github/workflows/repoInfo.ps1  -actions $actions -numberofReposToDo 50
#./.github/workflows/report.ps1 -actions $actions

#./.github/workflows/cleanup-all-repos.ps1 -numberOfReposToDo 90
#./tests/filtering.Tests.ps1 -actions $actions