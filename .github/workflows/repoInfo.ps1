Param (
  $actions,
  $numberOfReposToDo = 10,
  $access_token = $env:GITHUB_TOKEN
)

. $PSScriptRoot/library.ps1

Import-Module powershell-yaml -Force

function GetRepoInfo {
    Param (
        $owner,
        $repo
    )

    $url = "/repos/$owner/$repo"
    $response = ApiCall -method GET -url $url
    $url = "/repos/$owner/$repo/releases/latest"
    $release = ApiCall -method GET -url $url
    return ($response.archived, $response.disabled, $response.$updated_at, $release.published_at)
}

function GetActionType {
    Param (
        $owner,
        $repo
    )

    # check repo for action.yml or action.yaml
    $response = ""
    $fileFound = ""
    $actionType = ""
    try {
        $url = "/repos/$owner/$repo/contents/action.yml"
        $response = ApiCall -method GET -url $url
        $fileFound = "action.yml"
    }
    catch {
        Write-Debug "No action.yml, checking for action.yaml"
        try {
            $url = "/repos/$owner/$repo/contents/action.yaml"
            $response = ApiCall -method GET -url $url
            $fileFound = "action.yaml"
        }
        catch {
            try {
                $url = "/repos/$owner/$repo/contents/Dockerfile"
                $response = ApiCall -method GET -url $url
                $fileFound = "Dockerfile"
                $actionDockerType = "Dockerfile"
                $actionType = "Docker"
    
                return ($actionType, $fileFound, $actionDockerType)
            }
            catch {
                # no files found
                return "Unknown"
            }
        }
    }

    # load the file
    $fileContent = ApiCall -method GET -url $response.download_url
    Write-Debug "response: $($fileContent)"
    try {
        $yaml = ConvertFrom-Yaml $fileContent
    }
    catch {
        Write-Host "Error converting to yaml: $($_.Exception.Message)"
        Write-Host "Yaml content repo [$owner/$repo]:"
        Write-Host $fileContent
        return "Unknown"
    }
    
    # find line that says "
    # runs:
    #   using: "docker"
    #   image: "Dockerfile""
    # or:
    # using: "node**"
    
    $using = $yaml.runs.using
    $actionDockerType = ""
    if ($using -eq "docker") {
        $actionType = "Docker"
        if ($yaml.runs.image -eq "Dockerfile") {
            $actionDockerType = "Dockerfile"
        }
        else {
            $actionDockerType = "Image"
        }
    }
    else {
        if ($using -like "node*") {
            $actionType = "Node"
        }
        elseif ($using -like "composite*") {
            $actionType = "Composite"
        }
        else {
            $actionType = "Unknown"
        }
    }

    return ($actionType, $fileFound, $actionDockerType)
}

$statusFile = "status.json"

Write-Host "Got $($actions.Length) actions to get the status information for"
GetRateLimitInfo

# default variables
$forkOrg = "actions-marketplace-validations"
$status = $null
if (Test-Path $statusFile) {
    Write-Host "Using existing status file"
    $status = Get-Content $statusFile | ConvertFrom-Json
    
    Write-Host "Found $($status.Count) existing repos in status file"
}
else {
    Write-Error "Cannot find status file, halting execution"
    return
}

# get information from the action files
$i = $status.Length
$max = $status.Length + ($numberOfReposToDo * 2)
foreach ($action in $status) {

    if ($i -ge $max) {
        # do not run to long
        Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
        break
    }

    # back fill the 'owner' field with info from the fork
    $hasField = Get-Member -inputobject $action -name "owner" -Membertype Properties
    if (!$hasField) {
        # load owner from repo info out of the fork
        $url = "/repos/$forkOrg/$($action.name)"
        try {
            $response = ApiCall -method GET -url $url
            if ($response -and $response.parent) {
                # load owner info from parent
                $action | Add-Member -Name owner -Value $response.parent.owner.login -MemberType NoteProperty
            }
        }
        catch {
            Write-Host "Error getting repo info for fork [$forkOrg/$($action.name)]: $($_.Exception.Message)"
        }
    }

    $hasField = Get-Member -inputobject $action -name "actionType" -Membertype Properties
    if (!$hasField -or ($null -eq $action.actionType.actionType)) {
        Write-Host "$i/$max - Checking action information for [$owner/$reponame]"
        ($actionTypeResult, $fileFoundResult, $actionDockerTypeResult) = GetActionType -owner $action.owner -repo $action.name

        If (!$hasField) {
            $actionType = @{
                actionType = $actionTypeResult 
                fileFound = $fileFoundResult
                actionDockerType = $actionDockerTypeResult
            }

            $action | Add-Member -Name actionType -Value $actionType -MemberType NoteProperty
        }
        else {
            $action.actionType.actionType = $actionTypeResult
            $action.actionType.fileFound = $fileFoundResult
            $action.actionType.actionDockerType = $actionDockerTypeResult
        }

        $i++ | Out-Null
    }
}

# get repo information
$i = $status.Length
$max = $status.Length + ($numberOfReposToDo * 2)
Write-Host "Loading repository information"
foreach ($action in $status) {

    if ($i -ge $max) {
        # do not run to long
        Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
        break
    }

    $hasField = Get-Member -inputobject $action -name "repoInfo" -Membertype Properties
    if (!$hasField -or ($null -eq $action.actionType.actionType)) {
        Write-Host "$i/$max - Checking action information for [$forkOrg/$($action.name)]"
        ($repo_archived, $repo_disabled, $repo_updated_at, $latest_release_published_at) = GetRepoInfo -owner $action. -repo $action.name

        If (!$hasField) {
            $repoInfo = @{
                archived = $repo_archived
                disabled = $repo_disabled
                updated_at = $repo_updated_at
                latest_release_published_at = $latest_release_published_at
            }

            $action | Add-Member -Name repoInfo -Value $repoInfo -MemberType NoteProperty
        }
        else {
            $action.archived.archived = $repo_archived
            $action.archived.disabled = $repo_disabled
            $action.archived.updated_at = $repo_updated_at
            $action.archived.latest_release_published_at = $latest_release_published_at
        }

        $i++ | Out-Null
    }
}

SaveStatus -existingForks $status
GetRateLimitInfo