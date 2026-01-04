Param (
    $actions,
    $logSummary,
    $numberOfReposToDo = 10,
    $access_token = $env:GITHUB_TOKEN,
    $access_token_destination = $env:GITHUB_TOKEN
)

. $PSScriptRoot/library.ps1

if ([string]::IsNullOrWhiteSpace($access_token)) {
    try {
        $tokenManager = New-GitHubAppTokenManagerFromEnvironment
        # Share the token manager instance with library.ps1 so ApiCall can
        # coordinate app switching and failover across all requests in this run.
        $script:GitHubAppTokenManagerInstance = $tokenManager
        $tokenResult = $tokenManager.GetTokenForOrganization($env:APP_ORGANIZATION)
        $access_token = $tokenResult.Token
    }
    catch {
        Write-Error "Failed to obtain GitHub App token for organization [$($env:APP_ORGANIZATION)]: $($_.Exception.Message)"
        throw
    }
}

if ([string]::IsNullOrWhiteSpace($access_token_destination)) {
    $access_token_destination = $access_token
}

Test-AccessTokens -accessToken $access_token -numberOfReposToDo $numberOfReposToDo

function Get-OSSFInfoForRepo {
    Param (
        [string] $owner,
        [string] $repo,
        [string] $access_token,
        [string] $access_token_destination)

        try {
            $url = "https://api.securityscorecards.dev/projects/github.com/$owner/$repo"
            $result = Invoke-WebRequest -Uri $url -Method GET | ConvertFrom-Json

            return ($true, $result.score, $result.date)
        }
        catch {
            if ($_.Exception.Response.StatusCode -eq 404) {
                Write-Debug "OSSF information not found for [$($owner)/$($repo)]"
                Start-Sleep .5
                return ($false, 0, $null)
            }

            Write-Error "Failed to get OSSF information for [$($owner)/$($repo)], response: [$($_.Exception.Response.StatusCode)]"            
            return ($false, 0, $null)
        }        
}

function Get-OSSFInfo {
    Param (
        $existingForks
    )

    $i = 0
    $max = $numberOfReposToDo
    $reposWithOSSFEnabled = 0
    foreach ($action in $existingForks) {
        if ($i -ge $max) {
            # do not run to long
            Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
            break
        }
        
        $hasField = Get-Member -inputobject $action -name "ossfDateLastUpdate" -Membertype Properties
        if($hasField) {
            if ($action.ossfDateLastUpdate -gt (Get-Date).AddDays(-7)) {
                Write-Host "Skipping retrieving OSSF info for [$($action.name)] as it was updated less than 7 days ago"
                continue
            }
        }
        ($owner, $repo) = GetOrgActionInfo($action.name)
        Write-Host "$i/$max - Checking OSSF information for [$($owner)/$($repo)]"
        ($enabled, $score, $date) = Get-OSSFInfoForRepo -owner $owner -repo $repo -access_token $access_token -access_token_destination $access_token_destination
        if ($enabled) {
            $reposWithOSSFEnabled++ | Out-Null
            
            $hasField = Get-Member -inputobject $action -name "ossf" -Membertype Properties
            if (!$hasField) {
                $action | Add-Member -Name ossf -Value $true -MemberType NoteProperty
            }
            else {
                $action.ossf = $true
            }

            $hasField = Get-Member -inputobject $action -name "ossfScore" -Membertype Properties
            if (!$hasField) {
                $action | Add-Member -Name ossfScore -Value $score -MemberType NoteProperty
            }
            else {
                $action.ossfScore = $score
            }

            $hasField = Get-Member -inputobject $action -name "ossfDateLastUpdate" -Membertype Properties
            if (!$hasField) {
                $action | Add-Member -Name ossfDateLastUpdate -Value $date -MemberType NoteProperty
            }
            else {
                $action.ossfDateLastUpdate = $date
            }
        }
        else {
            $hasField = Get-Member -inputobject $action -name "ossfDateLastUpdate" -Membertype Properties
            if (!$hasField) {
                $action | Add-Member -Name ossfDateLastUpdate -Value (Get-Date) -MemberType NoteProperty
            } else {
                $action.ossfDateLastUpdate = Get-Date
            }
        }

        $i++ | Out-Null
    }

    Write-Message -message "Found [$($reposWithOSSFEnabled)] repos with OSSF enabled" -logToSummary $true
    return $existingForks
}

function Run {
    Param (
        $access_token, 
        $access_token_destination
    )
    Write-Host "Got $($actions.Length) actions to get the repo information for"    
    GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination

    ($existingForks, $failedForks) = GetForkedActionRepos -access_token $access_token

    $existingForks = Get-OSSFInfo -existingForks $existingForks
    SaveStatus -existingForks $existingForks

    GetRateLimitInfo -access_token $access_token -access_token_destination $access_token_destination -waitForRateLimit $false
}

# main call
Run -access_token $access_token -access_token_destination $access_token_destination        