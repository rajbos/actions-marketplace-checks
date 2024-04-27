
. $PSScriptRoot/.github/workflows/library.ps1

GetRateLimitInfo -access_token $env:GITHUB_TOKEN

if ($null -ne $env:APP_PEM_KEY) {
    Write-Host "GitHub App information found, using GitHub App"
    # todo: move into codespace variable
    $env:APP_ID = 264650
    $env:INSTALLATION_ID = 31486141
    # get a token to use from the app
    $accessToken = Get-TokenFromApp -appId $env:APP_ID -installationId $env:INSTALLATION_ID -pemKey $env:APP_PEM_KEY
}

# to add: how to refresh the actions.json from the storage account?

$actionsFile = "actions.json"
if ((Test-Path $actionsFile)) {
    $actions=(Get-Content $actionsFile | ConvertFrom-Json)
}
else {
    $actions=$null
}
$numberofReposToDo = 10

#./.github/workflows/functions.ps1 -actions $actions -numberofReposToDo $numberofReposToDo
./.github/workflows/repoInfo.ps1 -actions $actions -numberofReposToDo $numberofReposToDo -access_token $accessToken -access_token_destination $accessToken

$statusFile = "status.json"
if ((Test-Path $statusFile)) {
    $status = ( Get-Content $statusFile | ConvertFrom-Json)
}
else {
    $status=$null
}
#./.github/workflows/report.ps1 -actions $status
#./.github/workflows/cleanup-all-repos.ps1 -numberOfReposToDo $numberofReposToDo
#./tests/filtering.Tests.ps1 -actions $actions
#./.github/workflows/dependabot-updates.ps1 -actions $status -numberOfReposToDo $numberofReposToDo
#./.github/workflows/ossf-scan.ps1 -actions $actions -numberofReposToDo $numberofReposToDo

#. ./.github/workflows/dependents.ps1
#GetDependentsForRepo -owner "pozil" -repo "auto-assign-issue"
#GetDependentsForRepo -owner "devops-action" -repo "get-tag"