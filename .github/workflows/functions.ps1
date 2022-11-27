Param (
  $actions,
  $numberOfReposToDo = 10,
  $access_token = $env:GITHUB_TOKEN,
  $access_token_destination = $env:GITHUB_TOKEN
)

. $PSScriptRoot/library.ps1

#store the given access token as the environment variable GITHUB_TOKEN so that it will be used in the Workflow run
if ($access_token) {
    $env:GITHUB_TOKEN = $access_token
}
$statusFile = "status.json"
$failedStatusFile = "failedForks.json"
Write-Host "Got an access token with a length of [$($access_token.Length)], running for [$($numberOfReposToDo)] repos"

if ($access_token_destination -ne $access_token) {
    Write-Host "Got an access token for the destination with a length of [$($access_token_destination.Length)]"
}

function GetForkedActionRepos {

    # if file exists, read it
    $status = $null
    if (Test-Path $statusFile) {
        Write-Host "Using existing status file"
        $status = Get-Content $statusFile | ConvertFrom-Json
        if (Test-Path $failedStatusFile) {
            $failedForks = Get-Content $failedStatusFile | ConvertFrom-Json
            if ($null -eq $failedForks) {
                # init empty list
                $failedForks = New-Object System.Collections.ArrayList
            }
        }
        else {
            $failedForks = New-Object System.Collections.ArrayList
        }
        
        Write-Host "Found $($status.Count) existing repos in status file"
        Write-Host "Found $($failedForks.Count) existing records in the failed forks file"
    }
    else {
        # build up status from scratch
        Write-Host "Loading current forks and status from scratch"

        # get all existing repos in target org
        $forkedRepos = GetForkedActionRepoList
        Write-Host "Found $($forkedRepos.Count) existing repos in target org"
        # convert list of forkedRepos to a new array with only the name of the repo
        $status = New-Object System.Collections.ArrayList
        foreach ($repo in $forkedRepos) {
            $status.Add(@{name = $repo.name; dependabot = $null}) | Out-Null
        }
        Write-Host "Found $($status.Count) existing repos in target org"
        # for each repo, get the Dependabot status
        foreach ($repo in $status) {
            $repo.dependabot = $(GetDependabotStatus -owner $forkOrg -repo $repo.name)
        }
        
        $failedForks = New-Object System.Collections.ArrayList
    }
    return ($status, $failedForks)
}

function GetDependabotStatus {
    Param (
        $owner,
        $repo        
    )

    $url = "repos/$owner/$repo/vulnerability-alerts"
    $status = ApiCall -method GET -url $url -body $null -expected 204
    return $status
}

function GetForkedActionRepoList {
    # get all existing repos in target org
    #$repoUrl = "orgs/$forkOrg/repos?type=forks"
    $repoUrl = "orgs/$forkOrg/repos"
    $repoResponse = ApiCall -method GET -url $repoUrl -body "{`"organization`":`"$forkOrg`"}" -access_token $access_token_destination
    Write-Host "Found [$($repoResponse.Count)] existing repos in org [$forkOrg]"
    
    #foreach ($repo in $repoResponse) {
    #    Write-Host "Found $($repo | ConvertTo-Json)"
    #}
    return $repoResponse
}

function RunForActions {
    Param (
        $actions,
        $existingForks,
        $failedForks
    )

    Write-Host "Running for [$($actions.Count)] actions"
    # filter actions list to only the ones with a repoUrl
    $actions = $actions | Where-Object { $null -ne $_.repoUrl -and $_.repoUrl -ne "" }
    Write-Host "Found [$($actions.Count)] actions with a repoUrl"
    "Found [$($actions.Count)] actions with a repoUrl" >> $env:GITHUB_STEP_SUMMARY
    # do the work

    #TODO: check for existing repos first, or update the status.json with existing repos
    ($newlyForkedRepos, $existingForks, $failedForks) = ForkActionRepos -actions $actions -existingForks $existingForks -failedForks $failedForks
    SaveStatus -failedForks $failedForks
    Write-Host "Forked [$($newlyForkedRepos)] new repos in [$($existingForks.Count)] repos"
    "Forked [$($newlyForkedRepos)] new repos in [$($existingForks.Length)] repos" >> $env:GITHUB_STEP_SUMMARY
    SaveStatus -existingForks $existingForks

    # toggle for faster test runs
    if (1 -eq 1) {
        ($existingForks, $dependabotEnabled) = EnableDependabotForForkedActions -actions $actions -existingForks $existingForks -numberOfReposToDo $numberOfReposToDo
        Write-Host "Enabled Dependabot on [$($dependabotEnabled)] repos"
        "Enabled Dependabot on [$($dependabotEnabled)] repos" >> $env:GITHUB_STEP_SUMMARY

        SaveStatus -existingForks $existingForks

        $existingForks = GetDependabotAlerts -existingForks $existingForks
    }

    return $existingForks
}

function GetDependabotAlerts { 
    Param (
        $existingForks
    )

    Write-Host "Loading vulnerability alerts for repos"

    $i = $existingForks.Length
    $max = $existingForks.Length + ($numberOfReposToDo * 2)

    $highAlerts = 0
    $criticalAlerts = 0
    $vulnerableRepos = 0
    foreach ($repo in $existingForks) {

        if ($i -ge $max) {
            # do not run to long
            Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
            break
        }

        if ($repo.name -eq "" -or $null -eq $repo.name) {
            Write-Debug "Skipping repo with no name" $repo | ConvertTo-Json
            continue
        }

        if ($repo.vulnerabilityStatus) {
            $timeDiff = [DateTime]::UtcNow.Subtract($repo.vulnerabilityStatus.lastUpdated)
            if ($timeDiff.Hours -lt 72) {
                Write-Debug "Skipping repo [$($repo.name)] as it was checked less than 72 hours ago"
                continue
            }
        }

        Write-Debug "Loading vulnerability alerts for [$($repo.name)]"
        $dependabotStatus = $(GetDependabotVulnerabilityAlerts -owner $forkOrg -repo $repo.name -access_token $access_token_destination)
        if ($dependabotStatus.high -gt 0) {
            Write-Host "Found [$($dependabotStatus.high)] high alerts for repo [$($repo.name)]"
            $highAlerts++
        }
        if ($dependabotStatus.critical -gt 0) {
            Write-Host "Found [$($dependabotStatus.critical)] critical alerts for repo [$($repo.name)]"
            $criticalAlerts++
        }

        if ($dependabotStatus.high -gt 0 -or $dependabotStatus.critical -gt 0) {
            $vulnerableRepos++
        }

       $vulnerabilityStatus = @{
            high = $dependabotStatus.high
            critical = $dependabotStatus.critical
            lastUpdated = [DateTime]::UtcNow
        }
        #if ($repo.vulnerabilityStatus) {
        if (Get-Member -inputobject $repo -name "vulnerabilityStatus" -Membertype Properties) {
            $repo.vulnerabilityStatus = $vulnerabilityStatus
        }
        else {
            $repo | Add-Member -Name vulnerabilityStatus -Value $vulnerabilityStatus -MemberType NoteProperty
        }

        $i++ | Out-Null
    }

    Write-Host "Found [$($vulnerableRepos)] repos with a total of [$($highAlerts)] high alerts"
    Write-Host "Found [$($vulnerableRepos)] repos with a total of [$($criticalAlerts)] critical alerts"

    # todo: store this data in the status file?

    return $existingForks
}

function GetDependabotVulnerabilityAlerts {
    Param (
        $owner,
        $repo,
        $access_token = $env:GITHUB_TOKEN
    )

    $query = '
    query($name:String!, $owner:String!){
        repository(name: $name, owner: $owner) {
            vulnerabilityAlerts(first: 100) {
                nodes {
                    createdAt
                    dismissedAt
                    securityVulnerability {
                        package {
                            name
                        }
                        advisory {
                            description
                            severity
                        }
                    }
                }
            }
        }
    }'
    
    $variables = "
        {
            ""owner"": ""$owner"",
            ""name"": ""$repo""
        }
        "
    
    $uri = "https://api.github.com/graphql"
    $requestHeaders = @{
        Authorization = GetBasicAuthenticationHeader -access_token $access_token
    }
    
    Write-Debug "Loading vulnerability alerts for repo $repo"
    $response = (Invoke-GraphQLQuery -Query $query -Variables $variables -Uri $uri -Headers $requestHeaders -Raw | ConvertFrom-Json)
    #Write-Host ($response | ConvertTo-Json)
    $nodes = $response.data.repository.vulnerabilityAlerts.nodes
    #Write-Host "Found [$($nodes.Count)] vulnerability alerts"
    #Write-Host $nodes | ConvertTo-Json
    $moderate=0
    $high=0
    $critical=0
    foreach ($node in $nodes) {
        #Write-Host "Found $($node.securityVulnerability.advisory.severity)"
        #Write-Host $node.securityVulnerability.advisory.severity
        switch ($node.securityVulnerability.advisory.severity) {            
            "MODERATE" {
                $moderate++
            }
            "HIGH" {
                $high++
            }
            "CRITICAL" {
                $critical++
            }
        }
    }
    #Write-Host "Dependabot status: " $($response | ConvertTo-Json -Depth 10)
    return @{
        moderate = $moderate
        high = $high
        critical = $critical
    }
}

function ForkActionRepos {
    Param (
        $actions,
        $existingForks,
        $failedForks
    )

    $i = $existingForks.Count
    $max = $existingForks.Count + $numberOfReposToDo
    $newlyForkedRepos = 0
    $counter = 0
    # convert to a collection so we are able to add new items to it
    $failedForks = {$failedForks}.Invoke()    

    if (($null -ne $actions) -And ($null -ne $existingForks) -And ($existingForks.Count -gt 0)) {
        Write-Host "Filtering repos to the ones we still need to fork"

        $actionsToProcess = FilterActionsToProcess -actions $actionsToProcess -existingForks $existingForks
    }
    else {
        $actionsToProcess = $actions
    }

    Write-Host "Found [$($actionsToProcess.Count)] actions still to process for forking"

    # get existing forks with owner/repo values instead of full urls
    # declar variables outside of the loop to make it faster
    $owner = $null
    $repo = $null
    $forkedRepoName = $null
    $existingFork = $null
    foreach ($action in $actionsToProcess) {
        if ($i -ge $max) {
            # do not run to long
            Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
            break
        }

        # check if fork already exists
        $forkedRepoName = $action.forkedRepoName
        $existingFork = $existingForks | Where-Object {$_.name -eq $forkedRepoName}
        $owner = $action.owner
        $repo = $action.repo
        $failedFork = $failedForks | Where-Object {$_.name -eq $repo -And $_.owner -eq $owner}
        if ($null -eq $existingFork) {
            if (($null -ne $failedFork) -Or $failedFork.timesFailed -lt 5) {        
                Write-Host "$i/$max Checking repo [$owner/$repo]"
                try {
                    $forkResult = ForkActionRepo -owner $owner -repo $repo
                }
                catch {
                    # exception occured, break and continue with next repo
                    # exeption logged in the ForkActionRepo function
                    continue
                }
                if ($forkResult) {
                    # add the repo to the list of existing forks
                    Write-Debug "Repo forked"
                    $newlyForkedRepos++ | Out-Null
                    $newFork = @{ name = $forkedRepoName; dependabot = $null; owner = $owner }
                    $existingForks += $newFork
                        
                    $i++ | Out-Null
                }
                else {
                    if ($failedFork) {
                        # up the number of times we failed to fork this repo
                        $failedFork.timesFailed++ | Out-Null
                    }
                    else {
                        # let's store a list of failed forks
                        Write-Host "Failed to fork repo [$owner/$repo]"
                        Write-Host "failedForks object type: $($failedForks.GetType())"
                        $failedFork = @{ name = $repo; owner = $owner; timesFailed = 0 }
                        $failedForks.Add($failedFork)
                    }
                }
                $counter++ | Out-Null
            }
        }
        else {
            # Write-Host "Fake message for double check"
        }
    }

    return ($newlyForkedRepos, $existingForks, $failedForks)
}

function EnableDependabotForForkedActions {
    Param (
        $actions,
        $existingForks,
        $numberOfReposToDo    
    )
    # enable dependabot for all repos
    $i = $existingForks.Length
    $max = $existingForks.Length + $numberOfReposToDo
    $dependabotEnabled = 0

    Write-Host "Enabling dependabot on forked repos"
    # filter the actions to the ones we still need to enable dependabot for
    # todo: make faster!
    $actionsToProcess = FilterActionsToProcessDependabot -actions $actionsToProcess -existingForks $existingForks
    
    # $actionsToProcess = $actions | Where-Object { 
    #     ($owner, $repo) = SplitUrl -url $_.RepoUrl
    #     $forkedRepoName = GetForkedRepoName -owner $owner -repo $repo
    #     $existingFork = $existingForks | Where-Object { $_.name -eq $forkedRepoName }
    #     if ($null -ne $existingFork) {
    #         if ($null -eq $existingFork.dependabot) {
    #             return $true
    #         }
    #     }
    #     #return $existingForks.name -contains $repo -And $existingForks.owner -contains $owner
    # }
    foreach ($action in $actionsToProcess) {

        if ($i -ge $max) {
            # do not run to long
            break            
            Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
        }

        $repo = $action.repo
        $owner = $action.owner
        $forkedRepoName = GetForkedRepoName -owner $owner -repo $repo
        Write-Debug "Checking existing forks for an object with name [$repo] from [$($action.RepoUrl)]"
        $existingFork = $existingForks | Where-Object { $_.name -eq $forkedRepoName }

        if (($null -ne $existingFork) -And ($null -eq $existingFork.dependabot)) {
            if (EnableDependabot $existingFork) {
                Write-Host "Dependabot enabled on [$forkOrg/$($existingFork.name)]"
                $existingFork.dependabot = $true
                
                if (Get-Member -inputobject $repo -name "vulnerabilityStatus" -Membertype Properties) {
                    # reset lastUpdatedStatus
                    $repo.vulnerabilityStatus.lastUpdated = [DateTime]::UtcNow.AddYears(-1)
                }
                
                $dependabotEnabled++ | Out-Null
                $i++ | Out-Null

                # back off just a little
                #Start-Sleep 2 
            }
            else {
                # could not enable dependabot for some reason. Store it as false so we can skip it next time and save execution time
                $existingFork.dependabot = $false
            }
        }             
    }    
    return ($existingForks, $dependabotEnabled)
}

function EnableDependabot {
    Param ( 
      $existingFork
    )
    if ($existingFork.name -eq "" -or $null -eq $existingFork.name) {
        Write-Debug "No repo name found, skipping [$($existingFork.name)]" $existingFork | ConvertTo-Json
        return $false
    }

    # enable dependabot if not enabled yet
    if ($null -eq $existingFork.dependabot) {
        Write-Debug "Enabling Dependabot for [$($existingFork.name)]"
        $url = "repos/$forkOrg/$($existingFork.name)/vulnerability-alerts"
        $status = ApiCall -method PUT -url $url -body $null -expected 204
        if ($status -eq $true) {
            return $true
        }
        else {
            Write-Host "Failed to enable dependabot for [$($existingFork.name)]"
        }
        return $status
    }

    return $false
}

$tempDir = "mirroredRepos"

function ForkActionRepo {
    Param (
        $owner,
        $repo
    )

    if ($owner -eq "" -or $null -eq $owner -or $repo -eq "" -or $null -eq $repo) {
        return $false
    }

    # check if the source repo exists
    $url = "repos/$owner/$repo"
    $status = ApiCall -method GET -url $url -body $null -expected 200
    if ($status -eq $false) {
        Write-Host "Repo [$owner/$repo] does not exist"
        return $false
    }

    # check if the destination repo already exists
    $newRepoName = GetForkedRepoName -owner $owner -repo $repo
    $url = "repos/$forkOrg/$newRepoName"
    $status = ApiCall -method GET -url $url -body $null -expected 200
    if ($status -eq $true) {
        Write-Host "Repo [$forkOrg/$newRepoName] already exists"
        return $true
    }

    # fork the action repository to the actions-marketplace-validations organization on github
    $forkUrl = "orgs/$forkOrg/repos"
    $forkResponse = ApiCall -method POST -url $forkUrl -body "{`"name`":`"$newRepoName`"}" -expected 201 -access_token $access_token_destination
     
    # if temp directory does not exist, create it
    if (-not (Test-Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir | Out-null
    }

    if ($null -ne $forkResponse -and $forkResponse -eq "True") {    
        # there is a secondary rate limit for the creation api, so we need to wait a little if the call was successful
        Start-Sleep -Seconds 20
        
        Write-Host "Created destination for [$owner/$repo] to [$forkOrg/$($newRepoName)]"
        # disable actions on the new repo, to prevent them from running on push (not needed, actions disabled on org leve)
        # $url = "repos/$forkOrg/$newRepoName/actions/permissions"
        # $response = ApiCall -method PUT -url $url -body "{`"enabled`":false}" -expected 204
        
        try {
            # cd to temp directory
            Set-Location $tempDir | Out-Null
            Write-Host "Cloning from repo [https://github.com/$owner/$repo.git]"
            git clone "https://github.com/$owner/$repo.git" 
            Set-Location $repo  | Out-Null
            git remote remove origin  | Out-Null
            git remote add origin "https://x:$access_token@github.com/$forkOrg/$($newRepoName).git"  | Out-Null
            $branchName = $(git branch --show-current)
            Write-Host "Pushing to branch [$($branchName)]"
            git push --set-upstream origin $branchName | Out-Null
            # back to normal repo
            Set-Location ../.. | Out-Null
            # remove the temp directory to prevent disk build up
            Remove-Item -Path $tempDir/$repo -Recurse -Force | Out-Null
            Write-Host "Mirrored [$owner/$repo] to [$forkOrg/$($newRepoName)]"

            return $true
        }
        catch {
            Write-Host "Failed to mirror [$owner/$repo] to [$forkOrg/$($newRepoName)]"
            Write-Host $_.Exception.Message
            return $false
        }
    }
    else {
        # test if the repo already existed, to fix previous errors
        $url = "repos/$forkOrg/$newRepoName"
        $status = ApiCall -method GET -url $url -access_token $access_token_destination
        if ($null -ne $status) {
            Write-Host "Repo [$forkOrg/$newRepoName] already exists"
            return $true
        }
        else {
            Write-Host "Failed to create repo [$forkOrg/$newRepoName]"
            return $false
        }
    }
}

Write-Host "Got $($actions.Length) actions"
GetRateLimitInfo

# default variables
$forkOrg = "actions-marketplace-validations"

# load the list of forked repos
($existingForks, $failedForks) = GetForkedActionRepos
Write-Host "existingForks object type: $($existingForks.GetType())"
Write-Host "failedForks object type: $($failedForks.GetType())"

# run the functions for all actions
$existingForks = RunForActions -actions $actions -existingForks $existingForks -failedForks $failedForks
Write-Host "Ended up with $($existingForks.Count) forked repos"
# save the status
SaveStatus -existingForks $existingForks

GetRateLimitInfo

Write-Host "End of script, added [$numberOfReposToDo] forked repos"
# show the current location
Write-Host "Current location: $(Get-Location)"
