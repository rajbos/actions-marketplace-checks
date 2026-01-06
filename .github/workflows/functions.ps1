Param (
    $actions,
    $numberOfReposToDo = 10,
    $access_token = $env:GITHUB_TOKEN,
    $access_token_destination = $env:GITHUB_TOKEN
)

. $PSScriptRoot/library.ps1

Test-AccessTokens -accessToken $access_token -numberOfReposToDo $numberOfReposToDo

function FilterInvalidMarketplaceLinks {
    Param (
        $actions
    )

    if ($null -eq $actions -or $actions.Count -eq 0) {
        return $actions
    }

    $validActions = @()
    $invalidActions = @()

    foreach ($action in $actions) {
        $hasRepoUrl = $null -ne $action.RepoUrl -and $action.RepoUrl -ne ""

        # Support both Url and URL property names
        $urlValue = $null
        if ($null -ne $action.Url -and $action.Url -ne "") {
            $urlValue = $action.Url
        }
        elseif ($null -ne $action.URL -and $action.URL -ne "") {
            $urlValue = $action.URL
        }

        $hasUrl = $null -ne $urlValue -and $urlValue -ne ""

        if (-not $hasRepoUrl -and $hasUrl) {
            if ($urlValue.StartsWith("https://github.com/marketplace/actions")) {
                $validActions += $action
            }
            else {
                $invalidActions += $action
            }
        }
        else {
            $validActions += $action
        }
    }

    if ($invalidActions.Count -gt 0) {
        $totalInvalid = $invalidActions.Count
        $displayCount = [Math]::Min(10, $totalInvalid)

        Write-Host "Found [$totalInvalid] actions with RepoUrl = null and non-marketplace Url; skipping them as non valid marketplace links (forking phase)"

        Write-Message -message "" -logToSummary $true
        Write-Message -message "Skipped [$(DisplayIntWithDots $totalInvalid)] actions with RepoUrl = null and non marketplace Url (non valid marketplace links - forking phase)" -logToSummary $true
        Write-Message -message "<details>" -logToSummary $true
        Write-Message -message "<summary>Non valid marketplace links (forking phase, showing first $(DisplayIntWithDots $displayCount) of $(DisplayIntWithDots $totalInvalid))</summary>" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        Write-Message -message "| # | Title | Publisher | Url |" -logToSummary $true
        Write-Message -message "|---:|-------|----------|-----|" -logToSummary $true

        $index = 1
        foreach ($invalid in ($invalidActions | Select-Object -First $displayCount)) {
            $title = if ($null -ne $invalid.Title -and $invalid.Title -ne "") { $invalid.Title } else { "(no title)" }
            $publisher = if ($null -ne $invalid.Publisher -and $invalid.Publisher -ne "") { $invalid.Publisher } else { "(no publisher)" }
            $url = if ($null -ne $invalid.Url -and $invalid.Url -ne "") { $invalid.Url }
                   elseif ($null -ne $invalid.URL -and $invalid.URL -ne "") { $invalid.URL }
                   else { "(no url)" }

            Write-Message -message "| $index | $title | $publisher | $url |" -logToSummary $true
            $index++
        }

        Write-Message -message "" -logToSummary $true
        Write-Message -message "</details>" -logToSummary $true
        Write-Message -message "" -logToSummary $true
    }

    return ,$validActions
}

function GetForkedActionRepoList {
    Param (
        $access_token
    )
    # get all existing repos in target org
    #$repoUrl = "orgs/$forkOrg/repos?type=forks"
    $repoUrl = "orgs/$forkOrg/repos"
    $repoResponse = ApiCall -method GET -url $repoUrl -body "{`"organization`":`"$forkOrg`"}" -access_token $access_token
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

    $actions = FilterInvalidMarketplaceLinks -actions $actions

    Write-Host "Running for [$($actions.Count)] actions"
    # filter actions list to only the ones with a repoUrl
    $actions = $actions | Where-Object { $null -ne $_.repoUrl -and $_.repoUrl -ne "" }
    Write-Message "Found [$(DisplayIntWithDots $actions.Count)] actions with a repoUrl" -logToSummary $true
    # do the work
    ($newlyForkedRepos, $existingForks, $failedForks) = ForkActionRepos -actions $actions -existingForks $existingForks -failedForks $failedForks
    SaveStatus -failedForks $failedForks
    Write-Message -message "Forked [$(DisplayIntWithDots $newlyForkedRepos)] new repos in [$(DisplayIntWithDots $existingForks.Count)] repos" -logToSummary $true
    SaveStatus -existingForks $existingForks

    return $existingForks
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

        $actionsToProcess = FilterActionsToProcess -actions $actions -existingForks $existingForks
    }
    else {
        $actionsToProcess = $actions
    }

    Write-Message -message "Found [$(DisplayIntWithDots $actionsToProcess.Count)] actions still to process for forking" -logToSummary $true

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
        
        # Check if token is about to expire (less than 5 minutes remaining)
        if ($null -ne $script:tokenExpirationTime) {
            if (Test-TokenExpiration -expirationTime $script:tokenExpirationTime -warningMinutes 5) {
                $timeRemaining = $script:tokenExpirationTime - [DateTime]::UtcNow
                Write-Message -message "Stopping repo processing loop: Token will expire in $([math]::Round($timeRemaining.TotalMinutes, 1)) minutes (less than 5 minutes). Processed $i repos." -logToSummary $true
                Write-Host "Breaking loop to prevent token expiration issues. This is not an error."
                break
            }
        }
        
        Write-Host "$i/$max Checking repo [$owner/$repo]"
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

        # Check if token is about to expire (less than 5 minutes remaining)
        if ($null -ne $script:tokenExpirationTime) {
            if (Test-TokenExpiration -expirationTime $script:tokenExpirationTime -warningMinutes 5) {
                $timeRemaining = $script:tokenExpirationTime - [DateTime]::UtcNow
                Write-Message -message "Stopping dependabot enablement loop: Token will expire in $([math]::Round($timeRemaining.TotalMinutes, 1)) minutes (less than 5 minutes)." -logToSummary $true
                Write-Host "Breaking loop to prevent token expiration issues. This is not an error."
                break
            }
        }

        $repo = $action.repo
        $owner = $action.owner
        $forkedRepoName = GetForkedRepoName -owner $owner -repo $repo
        Write-Debug "Checking existing forks for an object with name [$repo] from [$($action.RepoUrl)]"
        $existingFork = $existingForks | Where-Object { $_.name -eq $forkedRepoName }

        if (($null -ne $existingFork) -And ($null -eq $existingFork.dependabot)) {
            if (EnableDependabot -existingFork $existingFork -access_token_destination $access_token_destination) {
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
    $status = ApiCall -method GET -url $url -body $null -expected 200 -access_token $access_token
    if ($status -eq $false) {
        Write-Host "Repo [$owner/$repo] does not exist"
        return $false
    }

    # check if the destination repo already exists
    $newRepoName = GetForkedRepoName -owner $owner -repo $repo
    $url = "repos/$forkOrg/$newRepoName"
    $status = ApiCall -method GET -url $url -body $null -expected 200 -access_token $access_token_destination
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
        
        # Disable GitHub Actions on the new repo before pushing code to prevent workflows from running
        Write-Host "Disabling GitHub Actions for [$forkOrg/$newRepoName] before push"
        $disableResult = Disable-GitHubActions -owner $forkOrg -repo $newRepoName -access_token $access_token_destination
        if (-not $disableResult) {
            Write-Warning "Could not disable GitHub Actions for [$forkOrg/$newRepoName], continuing with push anyway"
        }
        
        try {
            # cd to temp directory
            Set-Location $tempDir | Out-Null
            Write-Host "Cloning from repo [https://github.com/$owner/$repo.git]"
            git clone "https://github.com/$owner/$repo.git" 
            Set-Location $repo | Out-Null
            git remote remove origin | Out-Null
            git remote add origin "https://x:$access_token@github.com/$forkOrg/$($newRepoName).git" | Out-Null

            $branchName = $(git branch --show-current)
            Write-Host "Pushing to branch [$($branchName)]"
            git push --set-upstream origin $branchName | Out-Null

            try {
                # inject the CodeQL file
                Write-Host "Injecting CodeQL file"
                Write-Host "Current location: $(Get-Location)"
                # check if there is a .github/workflows directory, if not, create it
                if (-not (Test-Path ".github/workflows")) {
                    Write-Host "Creating directory .github/workflows"
                    New-Item -ItemType Directory -Path ".github/workflows" | Out-null
                }
                $codeQLFile = "$PSScriptRoot/../../injectFiles/codeql-analysis-injected.yml"
                # copy the file to the repo
                Copy-Item -Path $codeQLFile -Destination "$tempDir/$repo/.github/workflows/codeql-analysis-injected.yml" -Force -Recurse | Out-Null
                git config --global user.email "actions-marketplace-checks@example.com"
                git config --global user.name "actions-marketplace-checks"
                Write-Host "Adding file to git"
                git add .github/workflows/codeql-analysis-injected.yml
                Write-Host "Committing file to git"
                git commit -m "Inject CodeQL file" | Out-Null
                git push | Out-Null
                Write-Host "Injected CodeQL file pushed to repo"
            }
            catch {
                Write-Host "Failed to inject CodeQL file"
                Write-Host $_.Exception.Message
            }
            # back to normal repo
            Set-Location "$PSScriptRoot\..\..\" | Out-Null
            # remove the temp directory to prevent disk build up
            Remove-Item -Path $tempDir/$repo -Recurse -Force | Out-Null
            Write-Host "Mirrored [$owner/$repo] to [$forkOrg/$($newRepoName)]"

            return $true
        }
        catch {
            Write-Host "Failed to mirror [$owner/$repo] to [$forkOrg/$($newRepoName)]"
            Write-Host $_.Exception.Message
            # make sure we are back in the correct directory
            Set-Location "$PSScriptRoot\..\..\" | Out-Null
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
GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination

# Get token expiration time and store it for checking during the loop
$script:tokenExpirationTime = Get-TokenExpirationTime -access_token $access_token_destination
if ($null -eq $script:tokenExpirationTime) {
    Write-Warning "Could not determine token expiration time. Continuing without expiration checks."
}
else {
    $timeUntilExpiration = $script:tokenExpirationTime - [DateTime]::UtcNow
    Write-Host "Token will expire in $([math]::Round($timeUntilExpiration.TotalMinutes, 1)) minutes at $($script:tokenExpirationTime) UTC"
}

# load the list of forked repos
($existingForks, $failedForks) = GetForkedActionRepos -access_token $access_token_destination
#Write-Host "existingForks object type: $($existingForks.GetType())"
#Write-Host "failedForks object type: $($failedForks.GetType())"

# run the functions for all actions
$existingForks = RunForActions -actions $actions -existingForks $existingForks -failedForks $failedForks
Write-Host "Ended up with $($existingForks.Count) forked repos"
# save the status
SaveStatus -existingForks $existingForks

GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination -waitForRateLimit $false

Write-Host "End of script, added [$numberOfReposToDo] forked repos"
# show the current location
Write-Host "Current location: $(Get-Location)"

# Explicitly exit with success code to prevent PowerShell from inheriting exit codes from previous commands
exit 0
