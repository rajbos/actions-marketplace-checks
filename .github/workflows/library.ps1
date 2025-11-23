
# default variables
$forkOrg = "actions-marketplace-validations"
$tempDir = "$((Get-Item $PSScriptRoot).parent.parent.FullName)/mirroredRepos"
$actionsFile = "$((Get-Item $PSScriptRoot).parent.parent.FullName)/actions.json"
$statusFile = "$((Get-Item $PSScriptRoot).parent.parent.FullName)/status.json"
$failedStatusFile = "$((Get-Item $PSScriptRoot).parent.parent.FullName)/failedForks.json"
Write-Host "tempDir location: [$tempDir]"
Write-Host "actionsFile location: [$actionsFile]"
Write-Host "statusFile location: [$statusFile]"
Write-Host "failedStatusFile location: [$failedStatusFile]"

function ApiCall {
    Param (
        $method,
        $url,
        $body,
        $expected,
        [int] $currentResultCount,
        [int] $backOff = 5,
        [int] $maxResultCount = 0,
        [bool] $hideFailedCall = $false,
        $access_token = $env:GITHUB_TOKEN
    )
    
    # Validate that access token is not null or empty before making API calls
    if ([string]::IsNullOrWhiteSpace($access_token)) {
        Write-Error "Missing GitHub access token. API call to [$url] cannot proceed without valid credentials."
        throw "No access token available for API call. Please ensure ACCESS_TOKEN or Automation_App_Key secrets are properly configured."
    }
    
    $headers = @{
        Authorization = GetBasicAuthenticationHeader -access_token $access_token
    }
    if ($null -ne $body) {
        $headers.Add('Content-Type', 'application/json')
        $headers.Add('User-Agent', 'rajbos')
    }

    # prevent errors with empty urls
    if ($null -eq $url -or $url -eq "") {
        Write-Message -message "ApiCall Url is empty" -logToSummary $true
        # show the method that called this function
        Write-Message -message "ApiCall was called from: $(Get-PSCallStack | Select-Object -Skip 1 | Select-Object -First 1 | ForEach-Object { $_.Command })" -logToSummary $true
        return false
    }
    # prevent errors with starting slashes
    if ($url.StartsWith("/")) {
        $url = $url.Substring(1)
    }
    # auto prepend with api url
    if (!$url.StartsWith('https://api.github.com/')) {
        if (!$url.StartsWith('https://raw.githubusercontent.com')) {
            $url = "https://api.github.com/"+$url
        }
    }
    try
    {
        #$response = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -Body $body -ContentType 'application/json'
        if ($method -eq "GET" -or $method -eq "DELETE") {
            $result = Invoke-WebRequest -Uri $url -Headers $headers -Method $method -ErrorVariable $errvar -ErrorAction Continue
        }
        else {
            $result = Invoke-WebRequest -Uri $url -Headers $headers -Method $method -Body $body -ContentType 'application/json' -ErrorVariable $errvar -ErrorAction Continue
        }

        if (!$url.StartsWith('https://raw.githubusercontent.com')) {
            $response = $result.Content | ConvertFrom-Json
        }
        else {
            $response = $result.Content
        }
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

                    $currentResultCount = $currentResultCount + $response.Count
                    if ($maxResultCount -ne 0) {
                        Write-Host "Loading next page of data, where at [$($currentResultCount)] of max [$maxResultCount]"
                    }
                    # and get the results
                    if ($maxResultCount -ne 0) {
                        # check if we need to stop getting more pages
                        if ($currentResultCount -gt $maxResultCount) {
                            Write-Host "Stopping with [$($currentResultCount)] results, which is more then the max result count [$maxResultCount]"
                            return $response
                        }
                    }

                    # continue fetching next page
                    $nextResult = ApiCall -method $method -url $nextUrl -body $body -expected $expected -backOff $backOff -maxResultCount $maxResultCount -currentResultCount $currentResultCount -access_token $access_token
                    $response += $nextResult
                }
            }
        }

        $rateLimitRemaining = $result.Headers["X-RateLimit-Remaining"]
        $rateLimitReset = $result.Headers["X-RateLimit-Reset"]
        $rateLimitUsed = $result.Headers["X-Ratelimit-Used"]
        if ($rateLimitRemaining -And $rateLimitRemaining[0] -lt 100) {
            # convert rateLimitReset from epoch to ms
            $rateLimitResetInt = [int]$rateLimitReset[0]
            $oUNIXDate=(Get-Date 01.01.1970)+([System.TimeSpan]::fromseconds($rateLimitResetInt))
            $rateLimitReset = $oUNIXDate - [DateTime]::UtcNow
            if ($rateLimitReset.TotalMilliseconds -gt 0) {
                Write-Host ""
                if ($rateLimitReset.TotalSeconds -gt 1200) {
                    $message = "Rate limit is low or hit (Remaining/Used) [$($rateLimitRemaining)/$($rateLimitUsed)], and we need to wait for [$([math]::Round($rateLimitReset.TotalSeconds, 0))] seconds before continuing, which would mean continuing at [$oUNIXDate UTC]. This is longer then 20 minutes, so we are stopping the execution"
                    Write-Message -message $message -logToSummary $true
                    throw $message
                }
                $message = "Rate limit is low or hit (Remaining/Used) [$($rateLimitRemaining)/$($rateLimitUsed)], waiting for [$([math]::Round($rateLimitReset.TotalSeconds, 0))] seconds before continuing. Continuing at [$oUNIXDate UTC]"
                Write-Message -message $message -logToSummary $true
                Write-Host ""
                Start-Sleep -Milliseconds $rateLimitReset.TotalMilliseconds
            }
            return ApiCall -method $method -url $url -body $body -expected $expected -backOff ($backOff*2) -access_token $access_token
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
        $messageData
        try {
            $messageData = $_.ErrorDetails.Message | ConvertFrom-Json
        }
        catch {
            $messageData = $_.ErrorDetails.Message
        }

        if ($messageData.message -eq "was submitted too quickly") {
            Write-Host "Rate limit exceeded, waiting for [$backOff] seconds before continuing"
            Start-Sleep -Seconds $backOff
            GetRateLimitInfo -access_token $access_token -access_token_destination $access_token
            return ApiCall -method $method -url $url -body $body -expected $expected -backOff ($backOff*2) -access_token $access_token
        }
        else {
            Write-Host "Log message: $($messageData.message)"
        }

        if ($messageData.message -And ($messageData.message.StartsWith("You have exceeded a secondary rate limit"))) {
            if ($backOff -eq 5) {
                # start the initial backoff bigger, might give more change to continue faster
                $backOff = 120
            }
            else {
                $backOff = $backOff*2
            }
            Write-Host "Secondary rate limit exceeded, waiting for [$backOff] seconds before continuing"
            Start-Sleep -Seconds $backOff

            return ApiCall -method $method -url $url -body $body -expected $expected -backOff $backOff -access_token $access_token
        }

        if ($messageData.message -And ($messageData.message.StartsWith("API rate limit exceeded for user ID"))) {
            $rateLimitReset = $_.Exception.Response.Headers["X-RateLimit-Reset"]
            $rateLimitRemaining = $result.Headers["X-RateLimit-Remaining"]
            if ($rateLimitRemaining -And $rateLimitRemaining[0] -lt 10) {
                # convert rateLimitReset from epoch to ms
                $rateLimitResetInt = [int]$rateLimitReset[0]
                $oUNIXDate=(Get-Date 01.01.1970)+([System.TimeSpan]::fromseconds($rateLimitResetInt))
                $rateLimitReset = $oUNIXDate - [DateTime]::UtcNow
                if ($rateLimitReset.TotalMilliseconds -gt 0) {
                    Write-Host "Rate limit is low or hit, waiting for [$($rateLimitReset.TotalSeconds)] seconds before continuing"
                    Start-Sleep -Milliseconds $rateLimitReset.TotalMilliseconds
                }
            }
            return ApiCall -method $method -url $url -body $body -expected $expected -backOff ($backOff*2) -access_token $access_token
        }

        if ($null -ne $expected)
        {
            Write-Host "Expected status code [$expected] but got [$($_.Exception.Response.StatusCode)] for [$url]"
            if ($_.Exception.Response.StatusCode -eq $expected) {
                # expected error
                Write-Host "Returning true"
                return $true
            }
            else {
                Write-Host "Returning false"
                return $false
            }
        }
        else {
            # if the call failure is expected, suppress the error
            if (!$hideFailedCall) {
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
}

function GetBasicAuthenticationHeader(){
    Param (
        $access_token = $env:GITHUB_TOKEN
    )

    $CredPair = "x:$access_token"
    $EncodedCredentials = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($CredPair))

    return "Basic $EncodedCredentials";
}

function SplitUrl {
    Param (
        $url
    )

    # this fails when finding the repo name from this url
    #if ($url.StartsWith("https://github.com/marketplace/actions")) {
    #    return "";
    #}
    if ($null -eq $url) {
        return $null
    }

    # split the url into the last 2 parts
    $urlParts = $url.Split('/')
    $repo = $urlParts[-1]
    $owner = $urlParts[-2]
    # return repo and org
    return $owner, $repo
}

function GetForkedRepoName {
    Param (
        $owner,
        $repo
     )
    return "$($owner)_$($repo)"
}

function GetOrgActionInfo {
    Param (
        $forkedOwnerRepo
    )

    if ($null -ne $forkedOwnerRepo -And $forkedOwnerRepo -ne "") {
        $forkedOwnerRepoParts = $forkedOwnerRepo.Split('_')
        $owner = $forkedOwnerRepoParts[0]
        $repo = $forkedOwnerRepo.Substring($owner.Length + 1)

        return $owner, $repo
    }

    return "", ""
}

function SplitUrlLastPart {
    Param (
        $url
    )

    # this fails when finding the repo name from this url
    #if ($url.StartsWith("https://github.com/marketplace/actions")) {
    #    return "";
    #}

    # split the url into the last part
    $urlParts = $url.Split('/')
    $repo = $urlParts[-1]
    # return repo
    return $repo
}

function GetRateLimitInfo {
    Param (
        $access_token,
        $access_token_destination
    )
    $url = "rate_limit"
    $response = ApiCall -method GET -url $url -access_token $access_token

    #Write-Host "Ratelimit info: $($response.rate | ConvertTo-Json)"
    Write-Message -message "Ratelimit info: $($response.rate | ConvertTo-Json)"  -logToSummary $true
    #Write-Host " - GraphQL: $($response.resources.graphql | ConvertTo-Json)"
    #Write-Host " - GraphQL: $($response | ConvertTo-Json)"

    if ($access_token -ne $access_token_destination) {
        # check the ratelimit for the destination token as well:
        $response2 = ApiCall -method GET -url $url -access_token $access_token_destination
        Write-Message -message "Access token destination ratelimit info: $($response2.rate | ConvertTo-Json -Depth 5)" -logToSummary $true
    }

    if ($response.rate.limit -eq 60) {
        throw "Rate limit is 60, this is not enough to run this script, check the token that is used"
    }
}

function SaveStatus {
    Param (
        $existingForks,
        $failedForks
    )
    Write-Host "SaveStatus"
    if ("" -ne "$($env:CI)") {
        # We are running in CI, so let's pull before we overwrite the file
        git pull --quiet | Out-Null
    }
    if ($existingForks) {
        Write-Host "Storing the information of [$($existingForks.Count)] existing forks to the status file"
        $existingForks | ConvertTo-Json -Depth 10 | Out-File -FilePath $statusFile -Encoding UTF8
        Write-Host "Saved"

        # get number of forks that have repo information
        $existingForksWithRepoInfo = $existingForks | Where-Object { $_.repoInfo -And ($null -ne $_.repoInfo.updated_at) }
        Write-Message -message "Found [$($existingForksWithRepoInfo.Count) out of $($existingForks.Count)] repos that have repo information" -logToSummary $true
    }

    if ($failedForks) {
        Write-Host "Storing the information of [$($failedForks.Count)] failed forks to the failed status file"
        $failedForks | ConvertTo-Json -Depth 10 | Out-File -FilePath $failedStatusFile -Encoding UTF8
        Write-Host "Saved"
    }
}

function FilterActionsToProcess {
    Param (
        $actionsToProcess,
        $existingForks
    )

    # flatten the list for faster processing
    $actionsToProcess = FlattenActionsList -actions $actionsToProcess | Sort-Object -Property forkedRepoName
    # for faster searching, convert to single string array instead of objects
    $existingForksNames = $existingForks | ForEach-Object { $_.name } | Sort-Object
    # filter the actions list down to the set we still need to fork (not known in the existingForks list)
    $lastIndex = 0
    $actionsToProcess = $actionsToProcess | ForEach-Object {
        $forkedRepoName = $_.forkedRepoName
        $found = $false
        # for loop since the existingForksNames is a sorted array
        for ($j = $lastIndex; $j -lt $existingForksNames.Count; $j++) {
            if ($existingForksNames[$j] -eq $forkedRepoName) {
                $found = $true
                $lastIndex = $j
                break
            }
            # check first letter, since we sorted we do not need to go any further
            if ($existingForksNames[$j].ToLower()[0] -gt $forkedRepoName.ToLower()[0]) {
                $lastIndex = $j
                break
            }
        }
        if (!$found) {
           return $_
        }
    }

    return $actionsToProcess
}

function FilterActionsToProcessDependabot {
    Param (
        $actionsToProcess,
        $existingForks
    )

    # flatten the list for faster processing
    $actionsToProcess = FlattenActionsList -actions $actionsToProcess | Sort-Object -Property forkedRepoName
    # for faster searching, convert to single string array instead of objects
    $existingForksNames = $existingForks | ForEach-Object { $_.name } | Sort-Object
    # filter the actions list down to the set we still need to fork (not known in the existingForks list)
    $j = 0
    $existingFork = $null
    $forkedRepoName = ""
    $found = $false
    $actionsToProcess = $actionsToProcess | ForEach-Object {
        $forkedRepoName = $_.forkedRepoName
        $found = $false
        # for loop since the existingForksNames is a sorted array
        for ($j = 0; $j -lt $existingForksNames.Count; $j++) {
            if ($existingForksNames[$j] -eq $forkedRepoName) {
                $existingFork = $existingForks | Where-Object { $_.name -eq $forkedRepoName }
                if ($existingFork.dependabot) {
                    $found = $true
                }
                break
            }
            # check first letter, since we sorted we do not need to go any further
            if ($existingForksNames[$j][0] -gt $forkedRepoName[0]) {
                break
            }
        }
        if (!$found) {
           return $_
        }
    }

    return $actionsToProcess
}

function FilterActionsToProcessDependabot-Improved {
    Param (
        $actionsToProcess,
        $existingForks
    )

    # flatten the list for faster processing
    $actionsToProcess = FlattenActionsList -actions $actionsToProcess | Sort-Object -Property forkedRepoName
    # for faster searching, convert to single string array instead of objects
    $existingForksNames = $existingForks | ForEach-Object { $_.name } | Sort-Object
    # filter the actions list down to the set we still need to fork (not known in the existingForks list)
    $j = 0
    $existingFork = $null
    $forkedRepoName = ""
    $found = $false
    $lastIndex = 0
    $actionsToProcess = $actionsToProcess | ForEach-Object {
        $forkedRepoName = $_.forkedRepoName
        $found = $false
        # for loop since the existingForksNames is a sorted array
        for ($j = $lastIndex = 0; $j -lt $existingForksNames.Count; $j++) {
            if ($existingForksNames[$j] -eq $forkedRepoName) {
                $existingFork = $existingForks | Where-Object { $_.name -eq $forkedRepoName }
                if ($existingFork.dependabot) {
                    $found = $true
                    $lastIndex = $j
                }
                break
            }
            # check first letter, since we sorted we do not need to go any further
            if ($existingForksNames[$j][0] -gt $forkedRepoName[0]) {
                $lastIndex = $j
                break
            }
        }
        if (!$found) {
           return $_
        }
    }

    return $actionsToProcess
}

function FlattenActionsList {
    Param (
        $actions
    )
    $owner = ""
    $repo = ""
    $action = @{
        owner = ""
        repo = ""
        forkedRepoName = ""
    }

    # get a full list with the info we actually need
    $flattenedList = $actions | ForEach-Object {
        if ($_.RepoUrl){
            ($owner, $repo) = SplitUrl -url $_.RepoUrl
            $action = @{
                owner = $owner
                repo = $repo
                forkedRepoName = GetForkedRepoName -owner $owner -repo $repo
            }
            return $action
        }
    }

    return $flattenedList
}

function GetDependabotStatus {
    Param (
        $owner,
        $repo,
        $access_token = $env:GITHUB_TOKEN
    )

    $url = "repos/$owner/$repo/vulnerability-alerts"
    $status = ApiCall -method GET -url $url -body $null -expected 204 -access_token $access_token
    return $status
}

function EnableDependabot {
    Param (
      $existingFork,
      $access_token_destination
    )
    if ($existingFork.name -eq "" -or $null -eq $existingFork.name) {
        Write-Debug "No repo name found, skipping [$($existingFork.name)]:"
        Write-Debug ($existingFork | ConvertTo-Json)
        return $false
    }

    # enable dependabot if not enabled yet
    if ($null -eq $existingFork.dependabotEnabled) {
        Write-Debug "Enabling Dependabot for [$($existingFork.name)]"
        $url = "repos/$forkOrg/$($existingFork.name)/vulnerability-alerts"
        $status = ApiCall -method PUT -url $url -body $null -expected 204 -access_token $access_token_destination
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

function GetDependabotAlerts {
    Param (
        $existingForks,
        [int] $numberOfReposToDo
    )

    Write-Message -message "Loading vulnerability alerts for repos" -logToSummary $true

    $i = $existingForks.Length
    $max = $existingForks.Length + $numberOfReposToDo

    $highAlerts = 0
    $criticalAlerts = 0
    $vulnerableRepos = 0
    $skipping = 0
    foreach ($repo in $existingForks) {

        if ($i -ge $max) {
            # do not run to long
            Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
            break
        }

        if ($repo.name -eq "" -or $null -eq $repo.name) {
            if ($null -eq $repo) {
                Write-Debug "Skipping repo with no name" $repo | ConvertTo-Json
            }
            else {
                Write-Debug "Skipping null repo"
            }
            continue
        }

        if ($repo.vulnerabilityStatus) {
            $timeDiff = [DateTime]::UtcNow.Subtract($repo.vulnerabilityStatus.lastUpdated)
            if ($timeDiff.Hours -lt 72) {
                Write-Debug "Skipping repo [$($repo.name)] as it was checked less than 72 hours ago"
                $skipping++
                continue
            }
        }

        Write-Host "$i / $max Loading vulnerability alerts for [$($repo.name)]"
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

    Write-Message -message "Skipped [$($skipping)] repos as they were checked less than 72 hours ago" -logToSummary $true
    Write-Message -message "Found [$($vulnerableRepos)] new repos with a total of [$($highAlerts)] repos with high alerts" -logToSummary $true
    Write-Message -message "Found [$($vulnerableRepos)] new repos with a total of [$($criticalAlerts)] repos with critical alerts" -logToSummary $true

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
                    fixedAt
                    dependencyScope
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
    # todo: check for dismissed or fixed alerts: if we start regularly updating the repo, there might be old reports that are not relevant anymore for the analysis
    # todo: group by $node.dependencyScope [DEVELOPMENT, RUNTIME]
    foreach ($node in $nodes) {
        #Write-Host "Found $($node.securityVulnerability.advisory.severity)"
        #Write-Host $node.securityVulnerability.advisory.severity
        if ($node.dependencyScope -eq "RUNTIME") {
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
    }
    #Write-Host "Dependabot status: " $($response | ConvertTo-Json -Depth 10)
    return @{
        moderate = $moderate
        high = $high
        critical = $critical
    }
}

function Test-AccessTokens {
    Param (
        [string] $accessToken,
        [string] $access_token_destination,
        [int] $numberOfReposToDo
    )
    
    # Validate that accessToken is not null or empty
    if ([string]::IsNullOrWhiteSpace($accessToken)) {
        Write-Error "Missing GitHub access token (ACCESS_TOKEN). Please ensure the secret is configured in the repository."
        throw "No access token provided, please provide one!"
    }
    
    # Validate that access_token_destination is not null or empty
    if ([string]::IsNullOrWhiteSpace($access_token_destination)) {
        Write-Error "Missing GitHub access token for destination (Automation_App_Key). Please ensure the secret is configured in the repository."
        throw "No access token for destination provided, please provide one!"
    }
    
    #store the given access token as the environment variable GITHUB_TOKEN so that it will be used in the Workflow run
    $env:GITHUB_TOKEN = $accessToken
    
    Write-Host "Got an access token with a length of [$($accessToken.Length)], running for [$($numberOfReposToDo)] repos"

    if ($access_token_destination -ne $accessToken) {
        Write-Host "Got an access token for the destination with a length of [$($access_token_destination.Length)]"
    }
}

function GetFoundSecretCount {
    Param (
        [Parameter(Mandatory=$true)]
        [string] $access_token_destination
    )
    Write-Message "Getting secret scanning alerts" -logToSummary $true

    $url = "/orgs/$forkOrg/secret-scanning/alerts"

    try {
        $alertsResult = ApiCall -method GET -url $url -access_token $access_token_destination -hideFailedCall $false
        Write-Message "" -logToSummary $true
        Write-Message "## Secret scanning alerts" -logToSummary $true
        $totalAlerts = 0

        # summarize the number of alerts per secret_type_display_name
        $alertTypes = @{}
        Write-Message "|Alert type| Count |" -logToSummary $true
        Write-Message "|---| ---: |" -logToSummary $true
        foreach ($alert in $alertsResult) {
            $totalAlerts += $alert.number
            #$key = "$($alert.secret_type) - $($alert.secret_type_display_name)" # note: currently does not give extra info
            $key = "$($alert.secret_type_display_name)"
            if ($alertTypes.ContainsKey($key)) {
                $alertTypes[$key] += $alert.number
            }
            else {
                $alertTypes.Add($key, $alert.number)
            }
        }
        $alertTypes = $alertTypes.GetEnumerator() | Sort-Object -Descending -Property Value
        foreach ($alertType in $alertTypes) {
            Write-Message "| $($alertType.Key) | $($alertType.Value) |" -logToSummary $true
        }

        Write-Message "" -logToSummary $true
        Write-Message "Found [$($totalAlerts)] alerts for the organization in [$($alertsResult.Length)] repositories" -logToSummary $true
        Write-Message "" -logToSummary $true

        # log all resuls into a json file
        Set-Content -Path secretScanningAlerts.json -Value (ConvertTo-Json $alertsResult)
    }
    catch {
        Write-Message "Failed to get secret scanning alerts" -logToSummary $true
        Write-Message "Error: $($_.Exception.Message)" -logToSummary $true
    }
}

function Write-Message {
    param(
        [string] $message,
        [bool] $logToSummary = $false
    )
    Write-Host $message
    if ($logToSummary) {
        $message >> $env:GITHUB_STEP_SUMMARY
    }
}

function GetForkedActionRepos {
    Param (
        $actions,
        $access_token
    )
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

        Write-Host "Found [$($status.Count)] existing repos in status file"
        Write-Host "Found [$($failedForks.Count)] existing records in the failed forks file"
    }
    else {
        # build up status from scratch
        Write-Host "Loading current forks and status from scratch"

        # get all existing repos in target org
        $forkedRepos = GetForkedActionRepoList -access_token $access_token
        Write-Host "Found [$($forkedRepos.Count)] existing repos in target org"
        # convert list of forkedRepos to a new array with only the name of the repo
        $status = New-Object System.Collections.ArrayList
        foreach ($repo in $forkedRepos) {
            $status.Add(@{name = $repo.name; dependabot = $null}) | Out-Null
        }
        Write-Host "Found [$($status.Count)] existing repos in target org"
        # for each repo, get the Dependabot status
        foreach ($repo in $status) {
            $repo.dependabot = $(GetDependabotStatus -owner $forkOrg -repo $repo.name -access_token $access_token)
        }

        $failedForks = New-Object System.Collections.ArrayList
    }

    Write-Host "Updating actions with split RepoUrl from the list of [$($actions.Count)] actions"
    if ($null -ne $actions -And $actions.Count -gt 0) {
        Write-Host "This is the first action on the list: "
        Write-Host "$($actions[0] | ConvertTo-Json)"
    }

    # prep the actions file so that we only have to split the repourl once
    $counter = 0
    foreach ($actionStatus in $actions){
        ($owner, $repo) = SplitUrl -url $actionStatus.RepoUrl

        $actionStatus | Add-Member -Name name -Value (GetForkedRepoName -owner $owner -repo $repo) -MemberType NoteProperty
        $counter++
    }
    Write-Host "Updated [$($counter)] actions with split RepoUrl"

    # convert the static array into a collection so we can add items to it
    $status = {$status}.Invoke()
    Write-Host "And this is the first status on the list:"
    Write-Host "$($status[0] | ConvertTo-Json)"

    Write-Host "Update the status file with newly found actions"
    # find any new action that is not yet in the status file

    # Convert $status to a hashtable for faster lookup
    $statusTable = @{}
    foreach ($item in $status) {
        if ($null -ne $item.name -And $item.name -ne "") {
            $statusTable[$item.name] = $item
        }
    }

    foreach ($action in $actions) {
        # check if action is already in $statusTable
        $found = $statusTable[$action.name]

        if (!$found) {
            Write-Host "Adding new action to the list: [$($action.owner)/$($action.name)]"
            # add to status
            $statusTable.Add($action.name, @{
                name = $action.name;
                owner = $action.owner;
                dependabot = $null;
                verified = $action.Verified;
            }) | Out-Null
        }
        else {
            # get the item from the status lists as it is already in it
            if (Get-Member -inputobject $found -name "Verified" -Membertype Properties) {
                #Write-Host "Verified already on object"
            }
            else {
                #Write-Host "Verified not on object"
                $found | Add-Member -Name verified -Value $action.Verified -MemberType NoteProperty
            }
        }
    }

    # convert the hashtable back to an array
    $status = $statusTable.Values
    $statusVerified = $status | Where-Object {$_.verified}
    Write-Host "Found [$($statusVerified.Count)] verified repos in status file of total $($status.Count) repos"
    return ($status, $failedForks)
}


<#
    .DESCRIPTION
    Get-TokenFromApp uses the paramsas credentials
    for the GitHub App to load an aceess token with. Be aware that this token is only valid for an hour.
    Note: this token has only access to the repositories that the App has been installed to.
    We cannot use this token to create new repositories or install the app in a repo.
#>
function Get-TokenFromApp {
    param (
        [string] $appId,
        [string] $installationId,
        [string] $pemKey
    )
    # get a temporary jwt token from the key file and app id (hardcoded in the file:)
    $generated_jwt = $(bash ./github-app-jwt.sh $appId $pemKey)
    $github_api_url = "https://api.github.com/app"

    #Write-Host "Loaded jwt token: [$($generated_jwt)]"
    $github_api_url="https://api.github.com/app/installations"
    Write-Debug "Calling [${github_api_url}]"
    $installationId = ""
    try {
        $response = Invoke-RestMethod -Uri $github_api_url -Headers @{Authorization = "Bearer $generated_jwt" } -ContentType "application/json" -Method Get

        Write-Debug "Found installationId: [$($response[0].id)]"
        $installationId = $response[0].id
    }
    catch
    {
        Write-Error "Error in finding the app installations: $($_)"
    }

    $github_api_url="https://api.github.com/app/installations/$installationId/access_tokens"
    Write-Host "Calling [${github_api_url}]"
    $token = ""
    try {
        $response = Invoke-RestMethod -Uri $github_api_url -Headers @{Authorization = "Bearer $generated_jwt" } -ContentType "application/json" -Method POST -Body "{}"
        $token = $response.token
        Write-Host "Got an access token that will expire at: [$($response.expires_at)]"
    }
    catch
    {
        Write-Error "Error in getting an access token: $($_)"
    }

    Write-Host "Found token with [$($token.length)]"
    return $token
}

function SyncMirrorWithUpstream {
    Param (
        $owner,
        $repo,
        $upstreamOwner,
        $upstreamRepo,
        $access_token = $env:GITHUB_TOKEN
    )
    
    # Sync a mirror repository by pulling from upstream and pushing to mirror
    # This is different from fork sync - these are mirrors created by cloning upstream repos
    # Mirror repos are named: actions-marketplace-validations/upstreamOwner_upstreamRepo
    # Upstream repos are at: github.com/upstreamOwner/upstreamRepo
    
    Write-Debug "Syncing mirror [$owner/$repo] with upstream [$upstreamOwner/$upstreamRepo]"
    
    # Create temp directory if it doesn't exist
    $syncTempDir = "$tempDir/sync-$(Get-Random)"
    if (-not (Test-Path $syncTempDir)) {
        New-Item -ItemType Directory -Path $syncTempDir | Out-Null
    }
    
    try {
        # Save current directory
        $originalDir = Get-Location
        Set-Location $syncTempDir | Out-Null
        
        # Clone the mirror repo
        Write-Debug "Cloning mirror repo [https://github.com/$owner/$repo.git]"
        $cloneResult = git clone "https://x:$access_token@github.com/$owner/$repo.git" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clone mirror repo: $cloneResult"
        }
        
        Set-Location $repo | Out-Null
        
        # Get the current branch name
        $currentBranch = $(git branch --show-current)
        if ([string]::IsNullOrEmpty($currentBranch)) {
            # Try to get default branch
            $currentBranch = $(git symbolic-ref refs/remotes/origin/HEAD 2>$null | ForEach-Object { $_ -replace 'refs/remotes/origin/', '' })
            if ([string]::IsNullOrEmpty($currentBranch)) {
                $currentBranch = "main"
            }
        }
        Write-Debug "Current branch: [$currentBranch]"
        
        # Add upstream remote
        Write-Debug "Adding upstream remote [https://github.com/$upstreamOwner/$upstreamRepo.git]"
        git remote add upstream "https://github.com/$upstreamOwner/$upstreamRepo.git" 2>&1 | Out-Null
        
        # Fetch from upstream
        Write-Debug "Fetching from upstream"
        $fetchResult = git fetch upstream 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to fetch from upstream: $fetchResult"
        }
        
        # Check if upstream has the same branch
        $upstreamBranchExists = git ls-remote --heads upstream $currentBranch 2>&1
        if ([string]::IsNullOrEmpty($upstreamBranchExists) -and $currentBranch -eq "main") {
            # Try master branch
            $currentBranch = "master"
            $upstreamBranchExists = git ls-remote --heads upstream $currentBranch 2>&1
        }
        
        if ([string]::IsNullOrEmpty($upstreamBranchExists)) {
            throw "Upstream branch [$currentBranch] not found"
        }
        
        # Get the current commit hash
        $beforeHash = $(git rev-parse HEAD)
        
        # Configure git user identity before merge
        git config user.email "actions-marketplace-checks@example.com" | Out-Null
        git config user.name "actions-marketplace-checks" | Out-Null
        
        # Try to merge upstream changes
        Write-Debug "Merging upstream/$currentBranch"
        $mergeResult = git merge "upstream/$currentBranch" --no-edit 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            # Check if it's a conflict
            if ($mergeResult -like "*conflict*" -or $mergeResult -like "*CONFLICT*") {
                # Abort the merge
                git merge --abort 2>&1 | Out-Null
                throw "Merge conflict detected"
            }
            else {
                throw "Failed to merge: $mergeResult"
            }
        }
        
        # Get the commit hash after merge
        $afterHash = $(git rev-parse HEAD)
        
        # Check if there were any changes
        if ($beforeHash -eq $afterHash) {
            Write-Debug "Mirror [$owner/$repo] is already up to date"
            # Clean up
            Set-Location $originalDir | Out-Null
            Remove-Item -Path $syncTempDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
            return @{
                success = $true
                message = "Already up to date"
                merge_type = "none"
            }
        }
        
        # Push changes back to mirror
        Write-Debug "Pushing changes to mirror"
        $pushResult = git push origin $currentBranch 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to push to mirror: $pushResult"
        }
        
        Write-Debug "Successfully synced mirror [$owner/$repo]"
        
        # Clean up
        Set-Location $originalDir | Out-Null
        Remove-Item -Path $syncTempDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        
        return @{
            success = $true
            message = "Successfully fetched and merged from upstream"
            merge_type = "merge"
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Warning "Error syncing mirror [$owner/$repo]: $errorMessage"
        
        # Clean up
        try {
            Set-Location $originalDir | Out-Null
            Remove-Item -Path $syncTempDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
            # Ignore cleanup errors
        }
        
        # Check for common errors
        if ($errorMessage -like "*Merge conflict*") {
            return @{
                success = $false
                message = "Merge conflict detected"
            }
        }
        elseif ($errorMessage -like "*not found*" -or $errorMessage -like "*does not exist*") {
            return @{
                success = $false
                message = "Repository or branch not found"
            }
        }
        
        return @{
            success = $false
            message = $errorMessage
        }
    }
}
