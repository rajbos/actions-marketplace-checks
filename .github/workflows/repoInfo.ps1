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

    if ($null -eq $owner -or $owner.Length -eq 0) {
        return ($null, $null, $null)
    }

    $url = "/repos/$owner/$repo"
    Write-Host "Loading repository info for [$owner/$repo]"
    try {
        $response = ApiCall -method GET -url $url
        try {
            $url = "/repos/$owner/$repo/releases/latest"
            $release = ApiCall -method GET -url $url
            return ($response.archived, $response.disabled, $response.updated_at, $release.published_at)
        }
        catch {
            return ($response.archived, $response.disabled, $response.updated_at, $null)
        }
    }
    catch {
        Write-Error "Error loading repository info for [$owner/$repo]: $($_.Exception.Message)"
        return ($null, $null, $null)
    }
}

function GetRepoTagInfo {
    Param (
        $owner,
        $repo
    )
    
    if ($null -eq $owner -or $owner.Length -eq 0) {
        return $null
    }

    $url = "repos/$owner/$repo/git/matching-refs/tags"
    $response = ApiCall -method GET -url $url
    
    # filter the result array to only use the ref field
    $response = $response | ForEach-Object { SplitUrlLastPart($_.ref) }

    return $response
}

function GetRepoReleases {
    Param (
        $owner,
        $repo
    )
    
    if ($null -eq $owner -or $owner.Length -eq 0) {
        return $null
    }
    $url = "repos/$owner/$repo/releases"
    $response = ApiCall -method GET -url $url
    
    # filter the result array to only use the ref field
    $response = $response | ForEach-Object { SplitUrlLastPart($_.tag_name) }

    return $response
}

function GetActionType {
    Param (
        $owner,
        $repo
    )

    if ($null -eq $owner) {
        return ("No owner found", "No owner found", "No owner found")
    }

    if ($null -eq $repo) {
        return ("No repo found", "No repo found", "No repo found")
    }

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
                return ("No file found", "No file found", "No file found")
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
        $hasField = Get-Member -inputobject $action -name "forkFound" -Membertype Properties
        if ($hasField -and !$action.forkFound) {
            # skip this one to prevent us from keeping checking on erroneous repos
            continue
        }
        # load owner from repo info out of the fork
        Write-Host "Loading repo information for fork [$forkOrg/$($action.name)]"
        $url = "/repos/$forkOrg/$($action.name)"
        try {
            $response = ApiCall -method GET -url $url
            if ($response -and $response.parent) {
                # load owner info from parent
                $action | Add-Member -Name owner -Value $response.parent.owner.login -MemberType NoteProperty
                $action | Add-Member -Name forkFound -Value $true -MemberType NoteProperty
            }
        }
        catch {
            Write-Host "Error getting repo info for fork [$forkOrg/$($action.name)]: $($_.Exception.Message)"
            $hasField = Get-Member -inputobject $action -name "forkFound" -Membertype Properties
            if (!$hasField) {
                $action | Add-Member -Name forkFound -Value $false -MemberType NoteProperty
            }
        }
    }
    else {
        # owner field is filled, let's check if forkFound field already exists
        $hasField = Get-Member -inputobject $action -name "forkFound" -Membertype Properties
        if (!$hasField) {
            # owner is known, so this fork exists
            $action | Add-Member -Name forkFound -Value $true -MemberType NoteProperty
            $i++ | Out-Null
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
            $i++ | Out-Null
        }
        else {
            $action.actionType.actionType = $actionTypeResult
            $action.actionType.fileFound = $fileFoundResult
            $action.actionType.actionDockerType = $actionDockerTypeResult
        }

    }
}

function GetRepoDockerBaseImage {
    Param (
        $owner,
        $repo,
        $actionType
    )

    $dockerBaseImage = ""
    if ($actionType.actionDockerType -eq "Dockerfile") {
        $url = "/repos/$owner/$repo/contents/Dockerfile"
        $dockerFile = ApiCall -method GET -url $url
        $dockerFileContent = ApiCall -method GET -url $dockerFile.download_url
        # find first line with FROM in the Dockerfile
        $lines = $dockerFileContent.Split("`n") 
        $firstFromLine = $lines | Where-Object { $_ -like "FROM *" } 
        $dockerBaseImage = $firstFromLine | Select-Object -First 1
        if ($dockerBaseImage) {
            $dockerBaseImage = $dockerBaseImage.Split(" ")[1]
        }
    }

    return $dockerBaseImage
}
# save status in case the next part goes wrong, then we did not do all these calls for nothing
SaveStatus -existingForks $status

# get repo information
$i = $status.Length
$max = $status.Length + ($numberOfReposToDo * 4)
$hasRepoInfo = $($status | Where-Object {$null -ne $_.repoInfo})
Write-Host "Loading repository information, starting with [$($hasRepoInfo.Length)] already loaded"
"Loading repository information, starting with [$($hasRepoInfo.Length)] already loaded" >> $env:GITHUB_STEP_SUMMARY
$memberAdded = 0
$memberUpdate = 0 
$dockerBaseImageInfoAdded = 0
try {
    foreach ($action in $status) {

        if ($i -ge $max) {
            # do not run to long
            Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
            break
        }

        $hasField = Get-Member -inputobject $action -name "repoInfo" -Membertype Properties
        if (!$hasField -or ($null -eq $action.actionType.actionType) -or ($hasField -and ($null -eq $action.repoInfo.updated_at))) {
            Write-Host "$i/$max - Checking action information for [$forkOrg/$($action.name)]. hasField: [$hasField], actionType: [$($action.actionType.actionType)], updated_at: [$($action.repoInfo.updated_at)]"
            try {
                ($repo_archived, $repo_disabled, $repo_updated_at, $latest_release_published_at) = GetRepoInfo -owner $action.owner -repo $action.name

                if (!$hasField) {
                    Write-Host "Adding repo information object with archived:[$($repo_archived)], disabled:[$($repo_disabled)], updated_at:[$($repo_updated_at)], latest_release_published_at:[$($latest_release_published_at)]"
                    $repoInfo = @{
                        archived = $repo_archived
                        disabled = $repo_disabled
                        updated_at = $repo_updated_at
                        latest_release_published_at = $latest_release_published_at
                    }

                    $action | Add-Member -Name repoInfo -Value $repoInfo -MemberType NoteProperty
                    $memberAdded++ | Out-Null
                }
                else {
                    Write-Host "Updating repo information object with archived:[$($repo_archived)], disabled:[$($repo_disabled)], updated_at:[$($repo_updated_at)], latest_release_published_at:[$($latest_release_published_at)]"
                    $action.repoInfo.archived = $repo_archived
                    $action.repoInfo.disabled = $repo_disabled
                    $action.repoInfo.updated_at = $repo_updated_at
                    $action.repoInfo.latest_release_published_at = $latest_release_published_at
                    $memberUpdate++ | Out-Null
                }

                $i++ | Out-Null
            }
            catch {
                # continue with next one
            }
        }

        $hasField = Get-Member -inputobject $action -name "tagInfo" -Membertype Properties
        if (!$hasField -or ($null -eq $action.tagInfo)) {
            #Write-Host "$i/$max - Checking tag information for [$forkOrg/$($action.name)]. hasField: [$hasField], actionType: [$($action.actionType.actionType)], updated_at: [$($action.repoInfo.updated_at)]"
            try {
                $tagInfo = GetRepoTagInfo -owner $action.owner -repo $action.name
                if (!$hasField) {
                    #Write-Host "Adding tag information object with tags:[$($tagInfo.Length)]"
                    
                    $action | Add-Member -Name tagInfo -Value $tagInfo -MemberType NoteProperty
                }
                else {
                    #Write-Host "Updating tag information object with tags:[$($tagInfo.Length)]"
                    $action.tagInfo = $tagInfo
                }

                $i++ | Out-Null

            }
            catch {
                # continue with next one
            }
        }

        $hasField = Get-Member -inputobject $action -name "releaseInfo" -Membertype Properties
        if (!$hasField -or ($null -eq $action.releaseInfo)) {
            #Write-Host "$i/$max - Checking release information for [$forkOrg/$($action.name)]. hasField: [$hasField], actionType: [$($action.actionType.actionType)], updated_at: [$($action.repoInfo.updated_at)]"
            try {
                $releaseInfo = GetRepoReleases -owner $action.owner -repo $action.name
                if (!$hasField) {
                    #Write-Host "Adding release information object with releases:[$($releaseInfo.Length)]"
                    
                    $action | Add-Member -Name releaseInfo -Value $releaseInfo -MemberType NoteProperty
                }
                else {
                    #Write-Host "Updating release information object with releases:[$($releaseInfo.Length)]"
                    $action.releaseInfo = $releaseInfo
                }

                $i++ | Out-Null

            }
            catch {
                # continue with next one
            }
        }

        if ($action.actionType.actionType -eq "Docker") {
            $hasField = Get-Member -inputobject $action.actionType -name "dockerBaseImage" -Membertype Properties
            if (!$hasField -or ($null -eq $action.actionType.dockerBaseImage)) {
                #Write-Host "$i/$max - Checking Docker base image information for [$forkOrg/$($action.name)]. hasField: [$hasField], actionType: [$($action.actionType.actionType)], updated_at: [$($action.repoInfo.updated_at)]"
                try {
                    $dockerBaseImage = GetRepoDockerBaseImage -owner $action.owner -repo $action.name -actionType $action.actionType
                    if (!$hasField) {
                        #Write-Host "Adding release information object with releases:[$($releaseInfo.Length)]"
                        
                        $action.actionType | Add-Member -Name dockerBaseImage -Value $dockerBaseImage -MemberType NoteProperty
                        $i++ | Out-Null
                        $dockerBaseImageInfoAdded++ | Out-Null
                    }
                    else {
                        #Write-Host "Updating release information object with releases:[$($releaseInfo.Length)]"
                        $action.actionType.dockerBaseImage = $dockerBaseImage
                    }
                }
                catch {
                    # continue with next one
                }
            }
        }
    }
}
catch {
    Write-Host "Error getting all repo info: $($_.Exception.Message)"
    Write-Host "Continuing"
}

Write-Host "memberAdded : $memberAdded, memberUpdate: $memberUpdate"
$hasRepoInfo = $($status | Where-Object {$null -ne $_.repoInfo})
Write-Host "Loaded repository information, ended with [$($hasRepoInfo.Length)] already loaded"
"Loaded repository information, ended with [$($hasRepoInfo.Length)] already loaded" >> $env:GITHUB_STEP_SUMMARY

$hasTagInfo = $($status | Where-Object {$null -ne $_.tagInfo})
Write-Host "Loaded repository information, ended with [$($hasTagInfo.Length)] already loaded"
"Loaded tag information, ended with [$($hasTagInfo.Length)] already loaded" >> $env:GITHUB_STEP_SUMMARY

$hasReleaseInfo = $($status | Where-Object {$null -ne $_.releaseInfo})
Write-Host "Loaded repository information, ended with [$($hasReleaseInfo.Length)] already loaded"
"Loaded release information, ended with [$($hasReleaseInfo.Length)] already loaded" >> $env:GITHUB_STEP_SUMMARY

Write-Host "Docker base image information added for [$dockerBaseImageInfoAdded] actions"
"Docker base image information added for [$dockerBaseImageInfoAdded] actions" >> $env:GITHUB_STEP_SUMMARY

SaveStatus -existingForks $status
GetRateLimitInfo