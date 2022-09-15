Param (
  $actions,
  $numberOfReposToDo = 10,
  $access_token = $env:GITHUB_TOKEN
)

. $PSScriptRoot/library.ps1

Import-Module powershell-yaml -Force

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

$i = $status.Length
$max = $status.Length + $numberOfReposToDo
foreach ($action in $status) {

    if ($i -ge $max) {
        # do not run to long
        Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
        break
    }

    if (!(Get-Member -inputobject $action -name "actionType" -Membertype Properties) -or $null -eq $action.actionType) {
        ($actionTypeResult, $fileFoundResult, $actionDockerTypeResult) = GetActionType -owner $forkOrg -repo $action.name

        $actionType = @{
            actionType = $actionTypeResult 
            fileFound = $fileFoundResult
            actionDockerType = $actionDockerTypeResult
        }

        $action | Add-Member -Name actionType -Value $actionType -MemberType NoteProperty
        $i++ | Out-Null
    }
}

SaveStatus -existingForks $status
GetRateLimitInfo