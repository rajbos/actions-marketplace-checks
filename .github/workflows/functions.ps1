Param (
  $actions,
  $numberOfReposToDo = 10,
  $access_token = $env:GITHUB_TOKEN
)

$statusFile = "status.json"
Write-Host "Got an access token with length of [$($access_token.Length)], running for [$($numberOfReposToDo)] repos"

function SaveStatus {
    Param (
        $existingForks
    )
    $existingForks | ConvertTo-Json | Out-File -FilePath $statusFile -Encoding UTF8
}
function GetForkedActionRepos {

    # if file exists, read it
    $status = $null
    if (Test-Path $statusFile) {
        Write-Host "Using existing status file"
        $status = Get-Content $statusFile | ConvertFrom-Json
        
        Write-Host "Found $($status.Count) existing repos in status file"
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
            $status.Add(@{name = $repo.name; dependabot = $null})
        }
        Write-Host "Found $($status.Count) existing repos in target org"
        # for each repo, get the Dependabot status
        foreach ($repo in $status) {
            $repo.dependabot = $(GetDependabotStatus -owner $forkOrg -repo $repo.name)
        }
    }
    return $status
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
    $repoUrl = "orgs/$forkOrg/repos?type=forks"
    $repoResponse = ApiCall -method GET -url $repoUrl -body "{`"organization`":`"$forkOrg`"}"
    Write-Host "Found [$($repoResponse.Count)] existing repos in org [$forkOrg]"
    
    #foreach ($repo in $repoResponse) {
    #    Write-Host "Found $($repo | ConvertTo-Json)"
    #}
    return $repoResponse
}
function RunForActions {
    Param (
        $actions,
        $existingForks
    )

    Write-Host "Running for [$($actions.Count)] actions"
    # filter actions list to only the ones with a repoUrl
    $actions = $actions | Where-Object { $null -ne $_.repoUrl -and $_.repoUrl -ne "" }
    Write-Host "Found [$($actions.Count)] actions with a repoUrl"

    # do the work
    ($newlyForkedRepos, $existingForks) = ForkActionRepos -actions $actions -existingForks $existingForks
    Write-Host "Forked [$($newlyForkedRepos)] new repos in [$($existingForks.Length)] repos"
    SaveStatus -existingForks $existingForks

    ($existingForks, $dependabotEnabled) = EnableDependabotForForkedActions -actions $actions -existingForks $existingForks -numberOfReposToDo $numberOfReposToDo
    Write-Host "Enabled Dependabot on [$($dependabotEnabled)] repos"
    SaveStatus -existingForks $existingForks

    $existingForks = GetDependabotAlerts -existingForks $existingForks

    return $existingForks
}

function GetDependabotAlerts { 
    Param (
        $existingForks
    )

    Write-Host "Loading vulnerability alerts for repos"

    $i = $existingForks.Length
    $max = $existingForks.Length + $numberOfReposToDo

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
            Write-Host "Skipping repo with no name" $repo | ConvertTo-Json
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
        $dependabotStatus = $(GetDependabotVulnerabilityAlerts -owner $forkOrg -repo $repo.name)
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
        $repo
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
        Authorization = GetBasicAuthenticationHeader
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
        $existingForks
    )

    $i = $existingForks.Length
    $max = $existingForks.Length + $numberOfReposToDo
    $newlyForkedRepos = 0

    Write-Host "Forking repos"
    # get existing forks with owner/repo values instead of full urls
    foreach ($action in $actions) {
        if ($i -ge $max) {
            # do not run to long
            Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
            break
        }

        ($owner, $repo) = $(SplitUrl $action.RepoUrl)
        # check if fork already exists
        $existingFork = $existingForks | Where-Object { $_.name -eq $repo }
        if ($null -eq $existingFork) {        
            Write-Host " $i Checking repo [$repo]"
            $forkResult = ForkActionRepo -owner $owner -repo $repo
            if ($forkResult) {
                # add the repo to the list of existing forks
                Write-Debug "Repo forked"
                $newlyForkedRepos++
                $newFork = @{ name = $repo; dependabot = $null }
                $existingForks += $newFork
            }
            # back off just a little
            Start-Sleep 2
            $i++ | Out-Null
        }        
    }

    return ($newlyForkedRepos, $existingForks)
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
    foreach ($action in $actions) {

        if ($i -ge $max) {
            # do not run to long
            break            
            Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
        }

        ($owner, $repo) = $(SplitUrl $action.RepoUrl)
        Write-Debug "Checking existing forks for an object with name [$repo] from [$($action.RepoUrl)]"
        $existingFork = $existingForks | Where-Object { $_.name -eq $repo }

        if ($existingFork) {
            if (EnableDependabot $existingFork) {
                Write-Debug "Dependabot enabled on [$repo]"
                $existingFork.dependabot = $true
                
                if (Get-Member -inputobject $repo -name "vulnerabilityStatus" -Membertype Properties) {
                    # reset lastUpdatedStatus
                    $repo.vulnerabilityStatus.lastUpdated = [DateTime]::UtcNow.AddYears(-1)
                }
                
                $dependabotEnabled++ | Out-Null
                $i++ | Out-Null

                # back off just a little
                Start-Sleep 2 
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
        Write-Host "No repo name found, skipping [$($existingFork.name)]" $existingFork | ConvertTo-Json
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
        return $status
    }

    return $false
}

function SplitUrl {
    Param (
        $url
    )

    # this fails when finding the repo name from this url
    #if ($url.StartsWith("https://github.com/marketplace/actions")) {
    #    return "";
    #}

    # split the url into the last 2 parts
    $urlParts = $url.Split('/')
    $repo = $urlParts[-1]
    $owner = $urlParts[-2]
    # return repo and org
    return $owner, $repo
}

function GetBasicAuthenticationHeader(){
    $CredPair = "x:$access_token"
    $EncodedCredentials = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($CredPair))
    
    return "Basic $EncodedCredentials";
}

function ApiCall {
    Param (
        $method,
        $url,
        $body,
        $expected,
        [int] $backOff = 5
    )
    $headers = @{
        Authorization = GetBasicAuthenticationHeader
    }
    if ($null -ne $body) {
        $headers.Add('Content-Type', 'application/json')
    }
    # prevent errors with starting slashes
    if ($url.StartsWith("/")) {
        $url = $url.Substring(1)
    }
    # auto prepend with api url
    if (!$url.StartsWith('https://api.github.com/')) {
        $url = "https://api.github.com/"+$url
    }

    try
    {
        #$response = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -Body $body -ContentType 'application/json'
        if ($method -eq "GET") {
            $result = Invoke-WebRequest -Uri $url -Headers $headers -Method $method -ErrorVariable $errvar -ErrorAction Continue
        }
        else {
            $result = Invoke-WebRequest -Uri $url -Headers $headers -Method $method -Body $body -ContentType 'application/json' -ErrorVariable $errvar -ErrorAction Continue
        }

        $response = $result.Content | ConvertFrom-Json
        #Write-Host "Got this response: $($response | ConvertTo-Json)"
        # todo: check and handle the rate limit headers
        Write-Debug "  StatusCode: $($result.StatusCode)"
        Write-Debug "  RateLimit-Limit: $($result.Headers["X-RateLimit-Limit"])"
        Write-Debug "  RateLimit-Remaining: $($result.Headers["X-RateLimit-Remaining"])"
        Write-Debug "  RateLimit-Reset: $($result.Headers["X-RateLimit-Reset"])"
        Write-Debug "  RateLimit-Used: $($result.Headers["X-Ratelimit-used"])"
        Write-Debug "  Retry-After: $($result.Headers["Retry-After"])"
        
        if ($result.Headers["Link"]) {
            #Write-Host "Found pagination link: $($result.Headers["Link"])"
            # load next link from header
            $result.Headers["Link"].Split(',') | ForEach-Object {
                # search for the 'next' link in this list
                $link = $_.Split(';')[0].Trim()
                if ($_.Split(';')[1].Contains("next")) {
                    $nextUrl = $link.Substring(1, $link.Length - 2)
                    # and get the results
                    $nextResult = ApiCall -method $method -url $nextUrl -body $body -expected $expected
                    $response += $nextResult
                }
            }            
        }
        
        $rateLimitRemaining = $result.Headers["X-RateLimit-Remaining"]
        $rateLimitReset = $result.Headers["X-RateLimit-Reset"]
        if ($rateLimitRemaining -lt 10) {
            Write-Host "Rate limit is low, waiting for [$rateLimitReset] ms before continuing"
            # convert rateLimitReset from epoch to ms
            $rateLimitReset = [DateTime]::FromBinary($rateLimitReset).ToUniversalTime()
            $rateLimitReset = $rateLimitReset - [DateTime]::Now
            Write-Host "Waiting [$rateLimitReset] for rate limit reset"
            Start-Sleep -Milliseconds $rateLimitReset
        }

        if ($null -ne $expected) {
            if ($result.StatusCode -ne $expected) {
                Write-Host "  Expected status code [$expected] but got [$($result.StatusCode)]"
                return $false
            }
            else {
                return $true
            }
        }

        return $response
    }
    catch
    {
        $messageData = $_.ErrorDetails.Message | ConvertFrom-Json
        
        if ($messageData.message -eq "was submitted too quickly") {
            Write-Host "Rate limit exceeded, waiting for [$backOff] seconds before continuing"
            Start-Sleep -Seconds $backOff
            GetRateLimitInfo
            return ApiCall -method $method -url $url -body $body -expected $expected -backOff ($backOff*2)
        }
        else {
            Write-Host "Log message: $($messageData.message)"
        }

        if ($null -ne $expected)
        {
            Write-Host "Expected status code [$expected] but got [$($_.Exception.Response.StatusCode)] for [$url]"
            if ($_.Exception.Response.StatusCode -eq $expected) {
                # expected error
                return $true
            }
            else {
                return $false
            }
        }
        else {
            Write-Host "Error calling $url, status code [$($result.StatusCode)]"
            Write-Host "MessageData: " $messageData 
            Write-Host "Error: " $_
            if ($result.Content.Length -gt 100) {
                Write-Host "Content: " $result.Content.Substring(0, 100) + "..."
            }
            else {
                Write-Host "Content: " $result.Content
            }

            throw
        }
    }
}

function ForkActionRepo {
    Param (
        $owner,
        $repo
    )

    if ($owner -eq "" -or $repo -eq "") {
        return $false
    }
    # fork the action repository to the actions-marketplace-validations organization on github
    $forkUrl = "repos/$owner/$repo/forks"
    # call the fork api
    $forkResponse = ApiCall -method POST -url $forkUrl -body "{`"organization`":`"$forkOrg`"}" -expected 202

    if ($null -ne $forkResponse -and $forkResponse -eq "True") {    
        Write-Host "Forked [$owner/$repo] to [$forkOrg/$($forkResponse.name)]"
        if ($null -eq $forkResponse.name){
            # response is just 'True' since we pass in expected, could be improved by returning both the response and the check on status code
            #Write-Host "Full fork response: " $forkResponse | ConvertTo-Json
        }
        return $true
    }
    else {
        return $false
    }
}

function GetRateLimitInfo {
    $url = "rate_limit"	
    $response = ApiCall -method GET -url $url

    #Write-Host "Ratelimit info: $($response.rate | ConvertTo-Json)"
    Write-Host "Ratelimit info: $($response.rate | ConvertTo-Json)"
    Write-Host " - GraphQL: $($response.resources.graphql | ConvertTo-Json)"
    #Write-Host " - GraphQL: $($response | ConvertTo-Json)"
}

Write-Host "Got $($actions.Length) actions"
GetRateLimitInfo

# default variables
$forkOrg = "actions-marketplace-validations"

# todo: store which repos got forked already
# load the list of forked repos
$existingForks = GetForkedActionRepos

# run the functions for all actions
$existingForks = RunForActions -actions $actions -existingForks $existingForks
Write-Host "Ended up with $($existingForks.Count) forked repos"
# save the status
SaveStatus -existingForks $existingForks

GetRateLimitInfo

Write-Host "End of script, added [$numberOfReposToDo] forked repos"