Param (
  $actions,
  $numberOfReposToDo = 10,
  $access_token = $env:GITHUB_TOKEN,
  $access_token_destination = $env:GITHUB_TOKEN
)

. $PSScriptRoot/library.ps1
. $PSScriptRoot/dependents.ps1

if ($env:APP_PEM_KEY) {
    Write-Host "GitHub App information found, using GitHub App"
    # todo: move into codespace variable
    $env:APP_ID = 264650
    $env:INSTALLATION_ID = 31486141
    # get a token to use from the app
    $accessToken = Get-TokenFromApp -appId $env:APP_ID -installationId $env:INSTALLATION_ID -pemKey $env:APP_PEM_KEY
}
else {
  # use the one send in as a file param
  $accessToken = $access_token
}

Test-AccessTokens -accessToken $accessToken -access_token_destination $access_token_destination -numberOfReposToDo $numberOfReposToDo

Import-Module powershell-yaml -Force

# default variables
$forkOrg = "actions-marketplace-validations"

function GetRepoInfo {
    Param (
        $owner,
        $repo,
        [Parameter(Mandatory=$true)]
        $access_token,
        $startTime
    )

    if ($null -eq $owner -or $owner.Length -eq 0) {
        return ($null, $null, $null, $null, $null)
    }

    # Check if we are nearing the 50-minute mark
    $timeSpan = (Get-Date) - $startTime
    if ($timeSpan.TotalMinutes -gt 50) {
        Write-Host "Stopping the run, since we are nearing the 50-minute mark"
        return
    }

    $url = "/repos/$owner/$repo"
    Write-Host "Loading repository info for [$owner/$repo]"
    try {
        $response = ApiCall -method GET -url $url -access_token $access_token
        try {
            $url = "/repos/$owner/$repo/releases/latest"
            $release = ApiCall -method GET -url $url -access_token $access_token
            return ($response.archived, $response.disabled, $response.updated_at, $release.published_at, $null)
        }
        catch {
            return ($response.archived, $response.disabled, $response.updated_at, $null, $null)
        }
    }
    catch {
        Write-Error "Error loading repository info for [$owner/$repo]: $($_.Exception.Message)"
        return ($null, $null, $null, $null, $_.Exception.Response.StatusCode)
    }
}

function GetRepoTagInfo {
    Param (
        $owner,
        $repo,
        $access_token,
        $startTime
    )

    if ($null -eq $owner -or $owner.Length -eq 0) {
        return $null
    }

    # Check if we are nearing the 50-minute mark
    $timeSpan = (Get-Date) - $startTime
    if ($timeSpan.TotalMinutes -gt 50) {
        Write-Host "Stopping the run, since we are nearing the 50-minute mark"
        return
    }

    $url = "repos/$owner/$repo/git/matching-refs/tags"
    $response = ApiCall -method GET -url $url -access_token $access_token

    # filter the result array to only use the ref field
    $response = $response | ForEach-Object { SplitUrlLastPart($_.ref) }

    return $response
}

function GetRepoReleases {
    Param (
        $owner,
        $repo,
        $access_token,
        $startTime
    )

    if ($null -eq $owner -or $owner.Length -eq 0) {
        return $null
    }

    # Check if we are nearing the 50-minute mark
    $timeSpan = (Get-Date) - $startTime
    if ($timeSpan.TotalMinutes -gt 50) {
        Write-Host "Stopping the run, since we are nearing the 50-minute mark"
        return
    }

    $url = "repos/$owner/$repo/releases"
    $response = ApiCall -method GET -url $url -access_token $access_token

    # filter the result array to only use the ref field
    $response = $response | ForEach-Object { SplitUrlLastPart($_.tag_name) }

    return $response
}

function GetActionType {
    Param (
        $owner,
        $repo,
        $access_token,
        $startTime
    )

    if ($null -eq $owner) {
        return ("No owner found", "No owner found", "No owner found", $null)
    }

    if ($null -eq $repo) {
        return ("No repo found", "No repo found", "No repo found", $null)
    }

    # Check if we are nearing the 50-minute mark
    $timeSpan = (Get-Date) - $startTime
    if ($timeSpan.TotalMinutes -gt 50) {
        Write-Host "Stopping the run, since we are nearing the 50-minute mark"
        return
    }

    # check repo for action.yml or action.yaml
    $response = ""
    $fileFound = ""
    $actionType = ""
    try {
        $url = "/repos/$owner/$repo/contents/action.yml"
        $response = ApiCall -method GET -url $url -hideFailedCall $true -access_token $access_token
        $fileFound = "action.yml"
    }
    catch {
        Write-Debug "No action.yml, checking for action.yaml"
        try {
            $url = "/repos/$owner/$repo/contents/action.yaml"
            $response = ApiCall -method GET -url $url -hideFailedCall $true -access_token $access_token
            $fileFound = "action.yaml"
        }
        catch {
            try {
                $url = "/repos/$owner/$repo/contents/Dockerfile"
                $response = ApiCall -method GET -url $url -hideFailedCall $true -access_token $access_token
                $fileFound = "Dockerfile"
                $actionDockerType = "Dockerfile"
                $actionType = "Docker"

                return ($actionType, $fileFound, $actionDockerType)
            }
            catch {
                try {
                    $url = "/repos/$owner/$repo/contents/dockerfile"
                    $response = ApiCall -method GET -url $url -hideFailedCall $true -access_token $access_token
                    $fileFound = "dockerfile"
                    $actionDockerType = "Dockerfile"
                    $actionType = "Docker"

                    return ($actionType, $fileFound, $actionDockerType)
                }
                catch {
                    Write-Debug "No action.yml or action.yaml or Dockerfile or dockerfile found in repo [$owner/$repo]"
                    return ("No file found", "No file found", "No file found")
                }
            }
        }
    }

    if ($response.Length -eq 0 -or $response.download_url.Length -eq 0) {
        Write-Debug "No action definition found in repo [$owner/$repo]"
        return ("No file found", "No file found", "No file found")
    }

    # load the file
    Write-Message "Downloading the action definition file for repo [$owner/$repo] from url [$($response.download_url)]"
    $fileContent = ApiCall -method GET -url $response.download_url -access_token $access_token
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
        if ($yaml.runs.image -eq "Dockerfile" -or $yaml.runs.image -eq "./Dockerfile" -or $yaml.runs.image -eq ".\Dockerfile") {
            $actionDockerType = "Dockerfile"
        }
        else {
            $actionDockerType = "Image"
        }
    }
    else {
        if ($using -like "node*") {
            $actionType = "Node"
            $nodeVersion = $using.Replace("node", "")
        }
        elseif ($using -like "composite*") {
            $actionType = "Composite"
        }
        else {
            $actionType = "Unknown"
        }
    }

    return ($actionType, $fileFound, $actionDockerType, $nodeVersion)
}

function CheckForInfoUpdateNeeded {
    Param (
        $action,
        $hasActionTypeField,
        $hasNodeVersionField,
        $startTime
    )

    # skip actions where we cannot find the fork anymore
    if (!$action.ForkFound) {
        return $false
    }
    # check actionType field missing or not filled actionType in it
    if (!$hasActionTypeField -or ($null -eq $action.actionType.actionType)) {
        return $true
    }

    # check nodeVersion field missing or not filled actionType in it
    if (("No file found" -eq $action.actionType.actionType) -or ("No repo found" -eq $action.actionType.actionType)) {
        return $true
    }

    # check nodeVersion field missing for Node actionType
    if (("Node" -eq $action.actionType.actionType) -and !$hasNodeVersionField) {
        return $true
    }

    # Check if we are nearing the 50-minute mark
    $timeSpan = (Get-Date) - $startTime
    if ($timeSpan.TotalMinutes -gt 50) {
        Write-Host "Stopping the run, since we are nearing the 50-minute mark"
        return
    }

    return $false
}

function MakeRepoInfoCall {
    Param (
        $action,
        $forkOrg,
        $access_token,
        $startTime
    )

    # Check if we are nearing the 50-minute mark
    $timeSpan = (Get-Date) - $startTime
    if ($timeSpan.TotalMinutes -gt 50) {
        Write-Host "Stopping the run, since we are nearing the 50-minute mark"
        return
    }

    $url = "/repos/$forkOrg/$($action.name)"
    try {
        $response = ApiCall -method GET -url $url -access_token $access_token
    }
    catch {
        Write-Host "Error getting last updated repo info for fork [$forkOrg/$($action.name)]: $($_.Exception.Message)"
    }

    return $response
}
function GetInfo {
    Param (
        $existingForks,
        $access_token,
        $startTime
    )

    # get information from the action files
    $i = $existingForks.Count
    $max = $existingForks.Count + ($numberOfReposToDo * 1)
    foreach ($action in $existingForks) {

        # Check if we are nearing the 50-minute mark
        $timeSpan = (Get-Date) - $startTime
        if ($timeSpan.TotalMinutes -gt 50) {
            Write-Host "Stopping the run, since we are nearing the 50-minute mark"
            break
        }

        if ($i -ge $max) {
            # do not run to long
            Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
            break
        }

        $response = $null

        # back fill the 'owner' field with info from the fork
        $hasField = Get-Member -inputobject $action -name "owner" -Membertype Properties
        if (!$hasField) {
            $hasField = Get-Member -inputobject $action -name "forkFound" -Membertype Properties
            if ($hasField -and !$action.forkFound) {
                # skip this one to prevent us from keeping checking on erroneous repos
                continue
            }
            # load owner from repo info out of the fork
            $response = MakeRepoInfoCall -action $action -forkOrg $forkOrg -access_token $access_token -startTime $startTime
            Write-Host "Loading repo information for fork [$forkOrg/$($action.name)]"
                if ($response -and $response.parent) {
                    # load owner info from parent
                    $action | Add-Member -Name owner -Value $response.parent.owner.login -MemberType NoteProperty
                    $action | Add-Member -Name forkFound -Value $true -MemberType NoteProperty
                } else {
                    # new entry with leading owner name
                    $action | Add-Member -Name owner -Value $forkOrg -MemberType NoteProperty
                    $action | Add-Member -Name forkFound -Value $true -MemberType NoteProperty
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

        # check when the mirror was last updated
        $hasField = Get-Member -inputobject $action -name "mirrorLastUpdated" -Membertype Properties
        if (!$hasField) {
            if ($null -eq $response) {
                $response = MakeRepoInfoCall -action $action -forkOrg $forkOrg -access_token $access_token -startTime $startTime
            }
            if ($response -and $response.updated_at) {
                # add the new field
                $action | Add-Member -Name mirrorLastUpdated -Value $response.updated_at -MemberType NoteProperty
                $i++ | Out-Null
            }
        }
        else {
            $action.mirrorLastUpdated = $response.updated_at
        }

        # store repo size
        $hasField = Get-Member -inputobject $action -name repoSize -Membertype Properties
        if (!$hasField) {
            if ($null -eq $response) {
                $response = MakeRepoInfoCall -action $action -forkOrg $forkOrg -access_token $access_token -startTime $startTime
            }
            $action | Add-Member -Name repoSize -Value $response.size -MemberType NoteProperty
        }
        else {
            $action.repoSize = $response.size
        }

        # store dependent information
        # todo: do we need to check if the repo still exists and/or is archived?
        $hasField = Get-Member -inputobject $action -name dependents -Membertype Properties
        if (!$hasField) {
            ($owner, $repo) = GetOrgActionInfo($action.name)
            if ($repo -ne "" -and $owner -ne "") {
            $dependentsNumber = GetDependentsForRepo -repo $repo -owner $owner
            if ("" -ne $dependents) {
                    $dependents = @{
                        dependents = $dependentsNumber
                        dependentsLastUpdated = Get-Date
                    }
                    $action | Add-Member -Name dependents -Value $dependents -MemberType NoteProperty
                    $i++ | Out-Null
                }
            }
        }
        else {
            # check if the last update was more than 7 days ago
            $lastUpdated = $action.dependents.dependentsLastUpdated
            $daysSinceLastUpdate = (Get-Date) - $lastUpdated
            if ($daysSinceLastUpdate.Days -gt 7) {
                # update the dependents info
                ($owner, $repo) = GetOrgActionInfo($action.name)
                $dependentsNumber = GetDependentsForRepo -repo $repo -owner $owner
                if ("" -ne $dependents) {
                    $action.dependents.dependents = $dependentsNumber
                    $action.dependents.dependentsLastUpdated = Get-Date
                    $i++ | Out-Null
                }
            }
        }

        $hasActionTypeField = Get-Member -inputobject $action -name "actionType" -Membertype Properties
        $hasNodeVersionField = $null -ne $action.actionType.nodeVersion
        $updateNeeded = CheckForInfoUpdateNeeded -action $action -hasActionTypeField $hasActionTypeField -hasNodeVersionField $hasNodeVersionField -startTime $startTime
        if ($updateNeeded) {
            ($owner, $repo) = GetOrgActionInfo($action.name)
            Write-Host "$i/$max - Checking action information for [$($owner)/$($repo)]"
            ($actionTypeResult, $fileFoundResult, $actionDockerTypeResult, $nodeVersion) = GetActionType -owner $owner -repo $repo -access_token $access_token -startTime $startTime

            If (!$hasActionTypeField) {
                $actionType = @{
                    actionType = $actionTypeResult
                    fileFound = $fileFoundResult
                    actionDockerType = $actionDockerTypeResult
                    nodeVersion = $nodeVersion
                }

                $action | Add-Member -Name actionType -Value $actionType -MemberType NoteProperty
                $i++ | Out-Null
            }
            else {
                $action.actionType.actionType = $actionTypeResult
                $action.actionType.fileFound = $fileFoundResult
                $action.actionType.actionDockerType = $actionDockerTypeResult
                if (!$hasNodeVersionField) {
                    $action.actionType | Add-Member -Name nodeVersion -Value $nodeVersion -MemberType NoteProperty -Force
                }
                else {
                    $action.actionType.nodeVersion = $nodeVersion
                }
                $i++ | Out-Null
            }

        }
    }

    return $existingForks
}

function GetDockerBaseImageNameFromContent {
    param (
        $dockerFileContent
    )

    if ($null -eq $dockerFileContent -or "" -eq $dockerFileContent) {
        return ""
    }

    # find first line with FROM in the Dockerfile
    $lines = $dockerFileContent.Split("`n")
    $firstFromLine = $lines | Where-Object { $_ -like "FROM *" }
    $dockerBaseImage = $firstFromLine | Select-Object -First 1
    if ($dockerBaseImage) {
        $dockerBaseImage = $dockerBaseImage.Split(" ")[1]
    }

    # remove \r from the end
    $dockerBaseImage = $dockerBaseImage.TrimEnd("`r")

    return $dockerBaseImage
}

function GetRepoDockerBaseImage {
    Param (
        [string] $owner,
        [string] $repo,
        $actionType,
        $access_token
    )

    $dockerBaseImage = ""
    if ($actionType.actionDockerType -eq "Dockerfile") {
        $url = "/repos/$owner/$repo/contents/Dockerfile"
        try {
            $dockerFile = ApiCall -method GET -url $url -hideFailedCall $true -access_token $access_token
            $dockerFileContent = ApiCall -method GET -url $dockerFile.download_url -$access_token $access_token
            $dockerBaseImage = GetDockerBaseImageNameFromContent -dockerFileContent $dockerFileContent
        }
        catch {
            Write-Host "Error getting Dockerfile for [$owner/$repo]: $($_.Exception.Message), trying lowercase file"
            # retry with lowercase dockerfile name
            $url = "/repos/$owner/$repo/contents/dockerfile"
            try {
                $dockerFile = ApiCall -method GET -url $url -hideFailedCall $true -access_token $access_token
                $dockerFileContent = ApiCall -method GET -url $dockerFile.download_url -access_token $access_token
                $dockerBaseImage = GetDockerBaseImageNameFromContent -dockerFileContent $dockerFileContent
            }
            catch {
                Write-Host "Error getting dockerfile for [$owner/$repo]: $($_.Exception.Message)"
            }
        }
    }
    else {
        Write-Host "Cant load docker base image for action type [$($actionType.actionType)] with [$($actionType.actionDockerType)] in [$owner/$repo]"
    }

    return $dockerBaseImage
}

function EnableSecretScanning {
    param (
        [string] $owner,
        [string] $repo,
        [string] $access_token
    )

    $url = "/repos/$owner/$repo"
    $body = "{""security_and_analysis"": {""secret_scanning"": {""status"": ""enabled""}}}"
    $patchResult = ApiCall -method PATCH -url $url -body $body access_token $access_token -expected 200

    return $patchResult
}

function GetMoreInfo {
    param (
        $existingForks,
        $access_token,
        $startTime
    )
    # get repo information
    $i = $existingForks.Length
    $max = $existingForks.Length + ($numberOfReposToDo * 1)
    $hasRepoInfo = $($existingForks | Where-Object {$null -ne $_.repoInfo})
    Write-Host "Loading repository information, starting with [$($hasRepoInfo.Length)] already loaded"
    "Loading repository information, starting with [$($hasRepoInfo.Length)] already loaded" >> $env:GITHUB_STEP_SUMMARY
    $memberAdded = 0
    $memberUpdate = 0
    $dockerBaseImageInfoAdded = 0
    # store the repos that no longer exists
    $originalRepoDoesNotExists = New-Object System.Collections.ArrayList
    # store the timestamp
    $startTime = Get-Date
    try {
        foreach ($action in $existingForks) {

            # Check if we are nearing the 50-minute mark
            $timeSpan = (Get-Date) - $startTime
            if ($timeSpan.TotalMinutes -gt 50) {
                Write-Host "Stopping the run, since we are nearing the 50-minute mark"
                break
            }

            if ($i -ge $max) {
                # do not run to long
                Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
                break
            }

            if (!$action.forkFound) {
                Write-Debug "Skipping this repo, since the fork was not found: [$($action.owner)/$($action.name)]"
                continue
            }

            # if we are already running for 55 minutes, stop
            $timeSpan = (Get-Date) - $startTime
            if ($timeSpan.Minutes -gt 55) {
                Write-Host "Stopping the run, since we are running for more than 55 minutes"
                break
            }

            # load info that is needed for most checks
            ($owner, $repo) = GetOrgActionInfo($action.name)

            $hasField = Get-Member -inputobject $action -name "repoInfo" -Membertype Properties
            if (!$hasField -or ($null -eq $action.actionType.actionType) -or ($hasField -and ($null -eq $action.repoInfo.updated_at))) {
                Write-Host "$i/$max - Checking extended action information for [$forkOrg/$($action.name)]. hasField: [$($null -ne $hasField)], actionType: [$($action.actionType.actionType)], updated_at: [$($action.repoInfo.updated_at)]"
                try {
                    ($repo_archived, $repo_disabled, $repo_updated_at, $latest_release_published_at, $statusCode) = GetRepoInfo -owner $owner -repo $repo -access_token $access_token -startTime $startTime
                    if ($statusCode -and ($statusCode -eq "NotFound")) {
                        $action.forkFound = $false
                        # todo: remove this repo from the list (and push it back into the original actions list!)
                        $actionNoLongerExists = @{
                            action = $($action.name)
                            owner = $owner
                            repo = $repo
                        }
                        $originalRepoDoesNotExists.Add($actionNoLongerExists) | Out-Null
                        continue
                    }

                    if ($repo_updated_at) {
                        if (!$hasField) {
                            Write-Host "Adding repo information object with archived:[$($repo_archived)], disabled:[$($repo_disabled)], updated_at:[$($repo_updated_at)], latest_release_published_at:[$($latest_release_published_at)] for [$($action.owner)/$($action.name)]"
                            $repoInfo = @{
                                archived = $repo_archived
                                disabled = $repo_disabled
                                updated_at = $repo_updated_at
                                latest_release_published_at = $latest_release_published_at
                            }

                            $action | Add-Member -Name repoInfo -Value $repoInfo -MemberType NoteProperty
                            $memberAdded++ | Out-Null
                            $i++ | Out-Null
                        }
                        else {
                            Write-Host "Updating repo information object with archived:[$($repo_archived)], disabled:[$($repo_disabled)], updated_at:[$($repo_updated_at)], latest_release_published_at:[$($latest_release_published_at)]"
                            $action.repoInfo.archived = $repo_archived
                            $action.repoInfo.disabled = $repo_disabled
                            $action.repoInfo.updated_at = $repo_updated_at
                            $action.repoInfo.latest_release_published_at = $latest_release_published_at
                            $memberUpdate++ | Out-Null
                        }
                    }
                }
                catch {
                    Write-Host "Error calling GetRepoInfo for [$owner/$repo]: $($_.Exception.Message)"
                    
                    # Check if our forked copy exists
                    try {
                        $forkCheckUrl = "/repos/$forkOrg/$($action.name)"
                        $forkResponse = ApiCall -method GET -url $forkCheckUrl -access_token $access_token -hideFailedCall $true
                        if ($null -ne $forkResponse -and $forkResponse.id -and $forkResponse.id -gt 0) {
                            Write-Host "Our forked copy exists at [$forkOrg/$($action.name)] (id: $($forkResponse.id)), but upstream repo [$owner/$repo] may not exist or is inaccessible"
                        }
                        else {
                            Write-Host "Fork check returned unexpected response for [$forkOrg/$($action.name)]"
                        }
                    }
                    catch {
                        Write-Host "Our forked copy does not exist at [$forkOrg/$($action.name)]: $($_.Exception.Message)"
                    }
                    # continue with next one
                }
            }

            $hasField = Get-Member -inputobject $action -name "tagInfo" -Membertype Properties
            if (!$hasField -or ($null -eq $action.tagInfo)) {
                #Write-Host "$i/$max - Checking tag information for [$forkOrg/$($action.name)]. hasField: [$hasField], actionType: [$($action.actionType.actionType)], updated_at: [$($action.repoInfo.updated_at)]"
                try {
                    $tagInfo = GetRepoTagInfo -owner $owner -repo $repo -access_token $access_token -startTime $startTime
                    if (!$hasField) {
                        Write-Host "Adding tag information object with tags:[$($tagInfo.Length)] for [$($owner)/$($repo)]"

                        $action | Add-Member -Name tagInfo -Value $tagInfo -MemberType NoteProperty
                        $i++ | Out-Null
                    }
                    else {
                        #Write-Host "Updating tag information object with tags:[$($tagInfo.Length)]"
                        $action.tagInfo = $tagInfo
                    }
                }
                catch {
                    # continue with next one
                }
            }

            $hasField = Get-Member -inputobject $action -name "secretScanningEnabled" -Membertype Properties
            if (!$hasField -or ($null -eq $action.secretScanningEnabled) -or !$action.secretScanningEnabled) {
                Write-Host "$i/$max - Enabling secret scanning information for [$forkOrg/$($action.name)]. hasField: [$hasField], action.secretScanningEnabled: [$($action.secretScanningEnabled)]]"
                try {
                    $secretScanningEnabled = EnableSecretScanning -owner $forkOrg -repo $action.name -access_token $access_token
                    if (!$hasField) {
                        Write-Host "Adding secret scanning information object with enabled:[$($secretScanningEnabled)] for [$($forkOrg)/$($action.name)]"

                        $action | Add-Member -Name secretScanningEnabled -Value $secretScanningEnabled -MemberType NoteProperty
                        $i++ | Out-Null
                    }
                    else {
                        Write-Host "Updating secret scanning information object with enabled:[$($secretScanningEnabled)] for [$($forkOrg)/$($repo)]"
                        $action.secretScanningEnabled = $secretScanningEnabled
                    }
                }
                catch {
                    # continue with next one
                }
            }

            $hasField = Get-Member -inputobject $action -name "releaseInfo" -Membertype Properties
            if (!$hasField -or ($null -eq $action.releaseInfo)) {
                #Write-Host "$i/$max - Checking release information for [$forkOrg/$($action.name)]. hasField: [$hasField], actionType: [$($action.actionType.actionType)], updated_at: [$($action.repoInfo.updated_at)]"
                try {
                    $releaseInfo = GetRepoReleases -owner $owner -repo $repo -access_token $access_token -startTime $startTime
                    if (!$hasField) {
                        Write-Host "Adding release information object with releases:[$($releaseInfo.Length)] for [$($owner)/$($repo))]"

                        $action | Add-Member -Name releaseInfo -Value $releaseInfo -MemberType NoteProperty
                        $i++ | Out-Null
                    }
                    else {
                        #Write-Host "Updating release information object with releases:[$($releaseInfo.Length)]"
                        $action.releaseInfo = $releaseInfo
                    }
                }
                catch {
                    # continue with next one
                }
            }

            if ($action.actionType.actionType -eq "Docker") {
                $hasField = Get-Member -inputobject $action.actionType -name "dockerBaseImage" -Membertype Properties
                if (!$hasField -or (($null -eq $action.actionType.dockerBaseImage) -And $action.actionType.actionDockerType -ne "Image")) {
                    Write-Host "$i/$max - Checking Docker base image information for [$($owner)/$($repo)]. hasField: [$hasField], actionType: [$($action.actionType.actionType)], actionDockerType: [$($action.actionType.actionDockerType)]"
                    try {
                        # search for the docker file in the fork organization, since the original repo might already have seen updates
                        $dockerBaseImage = GetRepoDockerBaseImage -owner $owner -repo $repo -actionType $action.actionType -access_token $access_token
                        if ($dockerBaseImage -ne "") {
                            if (!$hasField) {
                                Write-Host "Adding Docker base image information object with image:[$dockerBaseImage] for [$($action.owner)/$($action.name))]"

                                $action.actionType | Add-Member -Name dockerBaseImage -Value $dockerBaseImage -MemberType NoteProperty
                                $i++ | Out-Null
                                $dockerBaseImageInfoAdded++ | Out-Null
                            }
                            else {
                                Write-Host "Updating Docker base image information object with image:[$dockerBaseImage] for [$($owner)/$($repo))]"
                                $action.actionType.dockerBaseImage = $dockerBaseImage
                            }
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
    $hasRepoInfo = $($existingForks | Where-Object {$null -ne $_.repoInfo})
    Write-Message -message "Loaded repository information, ended with [$($hasRepoInfo.Length)] already loaded" -logToSummary $true

    $hasTagInfo = $($existingForks | Where-Object {$null -ne $_.tagInfo})
    Write-Message -message "Loaded tag information, ended with [$($hasTagInfo.Length)] already loaded" -logToSummary $true

    $hasReleaseInfo = $($existingForks | Where-Object {$null -ne $_.releaseInfo})
    Write-Message -message "Loaded release information, ended with [$($hasReleaseInfo.Length)] already loaded" -logToSummary $true

    Write-Message -message "Docker base image information added for [$dockerBaseImageInfoAdded] actions"  -logToSummary $true

    Write-Host "Starting the cleanup with [$($existingForks.Count)] actions and [$($originalRepoDoesNotExists.Count)] original repos that do not exist"
    foreach ($action in $originalRepoDoesNotExists) {
        # remove the action from the actions lists

        # find the action based on the $action.action field
        # this remove currently fails: "Collection was of a fixed size"
        #$repoUrl = $action["owner"] + "/" + $action["repo"]
        #$existingAction = $actions | Where-Object {$_.RepoUrl -eq $repoUrl}
        #$actions.Remove($existingAction)

        # remove the action from the status list
        # this remove currently fails: "Collection was of a fixed size"
        # $repoName = $action["owner"] + "_" + $action["repo"]
        # $existingFork = $existingForks | Where-Object {$_.name -eq $repoName}
        # $existingForks.Remove($existingFork)
    }
    Write-Host "Ended the cleanup with [$($existingForks.Count)] actions"

    #return ($actions, $existingForks) ? where does this $actions come from?
    return ($null, $existingForks)
}

function Run {
    Param (
        $actions,

        [Parameter(Mandatory=$true)]
        $access_token,

        [Parameter(Mandatory=$true)]
        $access_token_destination
    )

    $startTime = Get-Date
    Write-Host "Run started at [$startTime]"

    Write-Host "Got $($actions.Length) actions to get the repo information for"
    GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination

    ($existingForks, $failedForks) = GetForkedActionRepos -actions $actions -access_token $access_token_destination

    $existingForks = GetInfo -existingForks $existingForks -access_token $access_token -startTime $startTime
    # save status in case the next part goes wrong, then we did not do all these calls for nothing
    SaveStatus -existingForks $existingForks

    # make it findable in the log to see where the second part starts
    Write-Host ""
    Write-Host ""
    Write-Host ""
    Write-Host "Calling for more info"
    Write-Host ""
    Write-Host ""
    Write-Host ""
    ($actions, $existingForks) = GetMoreInfo -existingForks $existingForks -access_token $access_token_destination -startTime $startTime
    SaveStatus -existingForks $existingForks

    GetFoundSecretCount -access_token_destination $access_token_destination
    GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination
}

# main call
Run -actions $actions -access_token $access_token -access_token_destination $access_token_destination
