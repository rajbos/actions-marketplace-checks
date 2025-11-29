
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

# Download status.json from blob storage if BLOB_SAS_TOKEN is set
if ($null -ne $env:BLOB_SAS_TOKEN -and $env:BLOB_SAS_TOKEN -ne "") {
    Write-Host "BLOB_SAS_TOKEN found, downloading status.json from blob storage"
    $result = Get-StatusFromBlobStorage -sasToken $env:BLOB_SAS_TOKEN
    if (-not $result) {
        Write-Warning "Failed to download status.json from blob storage. Using local file if available."
    }
}
else {
    Write-Host "BLOB_SAS_TOKEN not set. To work with blob storage, set this environment variable."
    Write-Host "Example: `$env:BLOB_SAS_TOKEN = 'https://intostorage.blob.core.windows.net/intostorage/status.json?sv=...'"
}

# Download actions.json from blob storage if BLOB_SAS_TOKEN is set
$actionsFile = "actions.json"
if ($null -ne $env:BLOB_SAS_TOKEN -and $env:BLOB_SAS_TOKEN -ne "") {
    Write-Host "BLOB_SAS_TOKEN found, downloading actions.json from blob storage"
    try {
        Invoke-WebRequest -Uri $env:BLOB_SAS_TOKEN -OutFile $actionsFile -UseBasicParsing
        Write-Host "Successfully downloaded actions.json"
    }
    catch {
        Write-Warning "Failed to download actions.json: $($_.Exception.Message)"
    }
}

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

# Upload status.json back to blob storage after processing
if ($null -ne $env:BLOB_SAS_TOKEN -and $env:BLOB_SAS_TOKEN -ne "") {
    Write-Host "Uploading status.json back to blob storage"
    $result = Set-StatusToBlobStorage -sasToken $env:BLOB_SAS_TOKEN
    if (-not $result) {
        Write-Warning "Failed to upload status.json to blob storage"
    }
}

#./.github/workflows/report.ps1 -actions $status
#./.github/workflows/cleanup-all-repos.ps1 -numberOfReposToDo $numberofReposToDo
#./tests/filtering.Tests.ps1 -actions $actions
#./.github/workflows/dependabot-updates.ps1 -actions $status -numberOfReposToDo $numberofReposToDo
#./.github/workflows/ossf-scan.ps1 -actions $actions -numberofReposToDo $numberofReposToDo

#. ./.github/workflows/dependents.ps1
#GetDependentsForRepo -owner "pozil" -repo "auto-assign-issue"
#GetDependentsForRepo -owner "devops-action" -repo "get-tag"