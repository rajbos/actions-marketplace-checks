Param (
  $numberOfReposToDo = 10,
  $access_token = $env:GITHUB_TOKEN,
  $owner = "actions-marketplace-validations"
)
. $PSScriptRoot/library.ps1

function GetAllRepos {
    try {
        Write-Host "Loading repositories for [$owner]"

        $url = "/orgs/$owner/repos"
        $repos = ApiCall -method GET -url $url -backOff 5 -maxResultCount $numberOfReposToDo
        return $repos
    }
    catch {
        Write-Error "Error retrieving repo list for [$owner]"
    }
}

function RemoveRepos {
    Param (
        $repos
    )

    $i=1
    $repoCount = $repos.Count
    foreach ($repo in $repos) 
    {
        $repoName = $repo.name
        Write-Host "$($i)/$($repoCount) Deleting repo [$($owner)/$($repo.name)]"
        $url = "/repos/$owner/$repoName"
        ApiCall -method DELETE -url $url
        $i++
    }
}


# main code
GetRateLimitInfo

$repos = GetAllRepos
RemoveRepos $repos

GetRateLimitInfo
