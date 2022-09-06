Param (
  $actions,
  $numberOfReposToDo = 10,
  $access_token = $env:GITHUB_TOKEN
)

$statusFile = "status.json"
Write-Host "Got an access token with length of [$($access_token.Length)], running for [$($numberOfReposToDo)] repos"

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
    $i = $existingForks.Length
    $max = $i
    # get existing forks with owner/repo values instead of full urls
    foreach ($action in $actions) {
        if (($null -eq $action.RepoUrl) -or ($action.RepoUrl -eq ""))
        {
            # skip actions without a url
            continue
        }

        if ($i -gt $max + $numberOfReposToDo) {
            # do not run to long
            break
        }

        ($owner, $repo) = $(SplitUrl $action.RepoUrl)
        Write-Debug "Checking existing forks for an object with name [$repo] from [$($action.RepoUrl)]"
        $existingFork = $existingForks | Where-Object { $_.name -eq $repo }
        if ($null -ne $($existingFork)) {
            if (EnableDependabot $existingFork) {
                $existingFork.dependabot = $true
            }

            # skip existing forks
            continue
        }

        Write-Host "$i Checking [$($action.url)] with owner [$forkOrg] and repo [$repo]"
        $forkResult = ForkActionRepo -owner $owner -repo $repo
        if ($forkResult) {
            # add the repo to the list of existing forks
            Write-Debug "Repo forked"
            $newFork = @{ name = $repo; dependabot = $null }
            $existingForks += $newFork
        }
        # back off just a little
        Start-Sleep 5
        $i++ | Out-Null
    }

    # enable dependabot for all repos
    $i = $existingForks.Length
    foreach ($action in $actions) {
        if (($null -eq $action.RepoUrl) -or ($action.RepoUrl -eq ""))
        {
            # skip actions without a url
            continue
        }

        if ($i -gt $max + $numberOfReposToDo) {
            # do not run to long
            break
        }

        ($owner, $repo) = $(SplitUrl $action.RepoUrl)
        Write-Debug "Checking existing forks for an object with name [$repo] from [$($action.RepoUrl)]"
        $existingFork = $existingForks | Where-Object { $_.name -eq $repo }

        if (EnableDependabot $existingFork) {
            Write-Debug "Dependabot enabled on [$repo]"
            $existingFork.dependabot = $true
        }
        
        # back off just a little
        Start-Sleep 2
        $i++ | Out-Null

    }    

    return $existingForks
}

function EnableDependabot {
    Param ( 
      $existingFork
    )

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
            $result = Invoke-WebRequest -Uri $url -Headers $headers -Method $method -ErrorAction Stop
        }
        else {
            $result = Invoke-WebRequest -Uri $url -Headers $headers -Method $method -ErrorAction Stop -Body $body -ContentType 'application/json'
        }

        $response = $result.Content | ConvertFrom-Json
        #Write-Host "Got this response: $($response | ConvertTo-Json)"
        # todo: check and handle the rate limit headers
        Write-Debug "  StatusCode: $($result.StatusCode)"
        Write-Debug "  RateLimit-Limit: $($result.Headers["X-RateLimit-Limit"])"
        Write-Debug "  RateLimit-Remaining: $($result.Headers["X-RateLimit-Remaining"])"
        Write-Debug "  RateLimit-Reset: $($result.Headers["X-RateLimit-Reset"])"
        Write-Debug "  RateLimit-Used: $($result.Headers["X-Ratelimit-used"])"
        
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

    if ($null -ne $forkResponse) {    
        Write-Host "Forked [$owner/$repo] to [$forkOrg/$($forkResponse.name)]"
        # give the back end some time before we continue and start enabling Dependabot, to prevent failure from 'eventual consistency'
        Start-Sleep -Seconds 5
        return $true
    }
    else {
        return $false
    }
}

function GetRateLimitInfo {
    $url = "rate_limit"	
    $response = ApiCall -method GET -url $url

    Write-Host "Ratelimit info: $($response | ConvertTo-Json)"
}

Write-Host "Got $($actions.Length) actions"

# default variables
$forkOrg = "actions-marketplace-validations"

# todo: store which repos got forked already
# load the list of forked repos
$existingForks = GetForkedActionRepos

# run the functions for all actions
$existingForks = RunForActions -actions $actions -existingForks $existingForks
Write-Host "Ended up with $($existingForks.Count) forked repos"
# save the status
$existingForks | ConvertTo-Json | Out-File $statusFile

GetRateLimitInfo

Write-Host "End of script, added [$numberOfReposToDo] forked repos"