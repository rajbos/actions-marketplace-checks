
. $PSScriptRoot/.github/workflows/library.ps1

GetRateLimitInfo -access_token $env:GITHUB_TOKEN

$actionsFile = "actions.json"
if ((Test-Path $actionsFile)) {
    $actions=(Get-Content $actionsFile | ConvertFrom-Json)
}
else {
    $actions=$null
}
$numberofReposToDo = 10

#./.github/workflows/functions.ps1 -actions $actions -numberofReposToDo $numberofReposToDo
#./.github/workflows/repoInfo.ps1  -actions $actions -numberofReposToDo $numberofReposToDo

$statusFile = "status.json"
if ((Test-Path $statusFile)) {
    $status = ( Get-Content $statusFile | ConvertFrom-Json)
}
else {
    $status=$null
}
./.github/workflows/report.ps1 -actions $status
#./.github/workflows/cleanup-all-repos.ps1 -numberOfReposToDo $numberofReposToDo
#./tests/filtering.Tests.ps1 -actions $actions
#./.github/workflows/dependabot-updates.ps1 -actions $status -numberOfReposToDo $numberofReposToDo
#./.github/workflows/ossf-scan.ps1 -actions $actions -numberofReposToDo $numberofReposToDo