
$actions=(cat status.json | ConvertFrom-Json)
#./.github/workflows/functions.ps1 -actions $actions -numberofReposToDo 5
#./.github/workflows/repoInfo.ps1  -actions $actions -numberofReposToDo 5
#./.github/workflows/report.ps1 -actions $actions

./.github/workflows/cleanup-all-repos.ps1