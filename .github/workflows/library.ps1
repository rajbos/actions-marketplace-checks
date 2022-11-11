function ApiCall {
    Param (
        $method,
        $url,
        $body,
        $expected,
        [int] $backOff = 5,
        [int] $maxResultCount = 0,
        [int] $currentResultCount
    )
    $headers = @{
        Authorization = GetBasicAuthenticationHeader
    }
    if ($null -ne $body) {
        $headers.Add('Content-Type', 'application/json')
        $headers.Add('User-Agent', 'rajbos')
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
                    $nextResult = ApiCall -method $method -url $nextUrl -body $body -expected $expected -backOff $backOff -maxResultCount $maxResultCount -currentResultCount $currentResultCount
                    $response += $nextResult
                }
            }            
        }
        
        $rateLimitRemaining = $result.Headers["X-RateLimit-Remaining"]
        $rateLimitReset = $result.Headers["X-RateLimit-Reset"]
        if ($rateLimitRemaining -And $rateLimitRemaining[0] -lt 1) {
            # convert rateLimitReset from epoch to ms
            $rateLimitResetInt = [int]$rateLimitReset[0]
            $oUNIXDate=(Get-Date 01.01.1970)+([System.TimeSpan]::fromseconds($rateLimitResetInt))
            $rateLimitReset = $oUNIXDate - [DateTime]::UtcNow
            if ($rateLimitReset.TotalMilliseconds -gt 0) {
                Write-Host ""
                Write-Host "Rate limit is low or hit, waiting for [$([math]::Round($rateLimitReset.TotalSeconds, 0))] seconds before continuing"
                Write-Host ""
                "Rate limit is low or hit, waiting for [$([math]::Round($rateLimitReset.TotalSeconds, 0))] seconds before continuing" >> $env:GITHUB_STEP_SUMMARY
                Start-Sleep -Milliseconds $rateLimitReset.TotalMilliseconds
            }
            return ApiCall -method $method -url $url -body $body -expected $expected -backOff ($backOff*2)
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
            GetRateLimitInfo
            return ApiCall -method $method -url $url -body $body -expected $expected -backOff ($backOff*2)
        }
        else {
            Write-Host "Log message: $($messageData.message)"
        }

        if ($messageData.message -And ($messageData.message.StartsWith("You have exceeded a secondary rate limit"))) {
            $backOff = $backOff*2
            Write-Host "Secondary rate limit exceeded, waiting for [$backOff] seconds before continuing"
            Start-Sleep -Seconds $backOff

            return ApiCall -method $method -url $url -body $body -expected $expected -backOff $backOff
        }

        if ($messageData.message -And ($messageData.message.StartsWith("API rate limit exceeded for user ID"))) {
            $rateLimitReset = $_.Exception.Response.Headers["X-RateLimit-Reset"]
            $rateLimitRemaining = $result.Headers["X-RateLimit-Remaining"]
            if ($rateLimitRemaining -And $rateLimitRemaining[0] -lt 1) {
                # convert rateLimitReset from epoch to ms
                $rateLimitResetInt = [int]$rateLimitReset[0]
                $oUNIXDate=(Get-Date 01.01.1970)+([System.TimeSpan]::fromseconds($rateLimitResetInt))
                $rateLimitReset = $oUNIXDate - [DateTime]::UtcNow
                if ($rateLimitReset.TotalMilliseconds -gt 0) {
                    Write-Host "Rate limit is low or hit, waiting for [$($rateLimitReset.TotalSeconds)] seconds before continuing"
                    Start-Sleep -Milliseconds $rateLimitReset.TotalMilliseconds
                }
            }
            return ApiCall -method $method -url $url -body $body -expected $expected -backOff ($backOff*2)
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

function GetBasicAuthenticationHeader(){
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
    $url = "rate_limit"	
    $response = ApiCall -method GET -url $url

    #Write-Host "Ratelimit info: $($response.rate | ConvertTo-Json)"
    Write-Host "Ratelimit info: $($response.rate | ConvertTo-Json)"
    Write-Host " - GraphQL: $($response.resources.graphql | ConvertTo-Json)"
    #Write-Host " - GraphQL: $($response | ConvertTo-Json)"
}

function SaveStatus {
    Param (
        $existingForks,
        $failedForks
    )
    if ("" -ne $env:CI) {
        # We are running in CI, so let's pull before we overwrite the file
        git pull --quiet | Out-Null
    }
    if ($existingForks) {
        Write-Host "Storing the information of [$($existingForks.Count)] existing forks to the status file"
        $existingForks | ConvertTo-Json -Depth 10 | Out-File -FilePath $statusFile -Encoding UTF8
        Write-Host "Saved"

        # get number of forks that have repo information
        $existingForksWithRepoInfo = $existingForks | Where-Object { $_.repoInfo -And ($null -ne $_.repoInfo.updated_at) }
        "Found [$($existingForksWithRepoInfo.Length) out of $($existingForks.Length)] repos that have repo information" >> GITHUB_STEP_SUMMARY
    }

    if ($failedForks) {
        Write-Host "Storing the information of [$($failedForks.Count)] failed forks to the failed status file"
        $failedForks | ConvertTo-Json -Depth 10 | Out-File -FilePath $failedStatusFile -Encoding UTF8
        Write-Host "Saved"
    }
}
