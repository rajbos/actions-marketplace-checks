Param (
  $actions,
  $numberOfReposToDo = 10,
  $access_token = $env:GITHUB_TOKEN,
  $access_token_destination = $env:GITHUB_TOKEN
)

. $PSScriptRoot/library.ps1
. $PSScriptRoot/dependents.ps1

$accessToken = $access_token

if ([string]::IsNullOrWhiteSpace($accessToken)) {
    try {
        $tokenManager = New-GitHubAppTokenManagerFromEnvironment
        # Share the token manager instance with library.ps1 so ApiCall can
        # coordinate app switching and failover across all requests in this run.
        $script:GitHubAppTokenManagerInstance = $tokenManager
        $tokenResult = $tokenManager.GetTokenForOrganization($env:APP_ORGANIZATION)
        $accessToken = $tokenResult.Token
    }
    catch {
        Write-Error "Failed to obtain GitHub App token for organization [$($env:APP_ORGANIZATION)]: $($_.Exception.Message)"
        throw
    }
}
$env:GITHUB_TOKEN = $accessToken
$accessTokenDestination = $access_token_destination
if ([string]::IsNullOrWhiteSpace($accessTokenDestination)) {
    $accessTokenDestination = $accessToken
}

Test-AccessTokens -accessToken $accessToken -numberOfReposToDo $numberOfReposToDo

Import-Module powershell-yaml -Force

# default variables
$forkOrg = "actions-marketplace-validations"

# Helper function to check if an error is a 404
function Is404Error {
    Param (
        [string]$errorMessage
    )
    return $errorMessage -like "*404*" -or $errorMessage -like "*Not Found*"
}

# Helper function to report error details
function ReportErrorDetails {
    Param (
        [string]$errorType,
        [array]$errorDetails,
        [int]$limit = 10
    )
    
    if ($errorDetails.Count -gt 0) {
        Write-Host ""
        Write-Host "$errorType Details (first $limit):"
        $errorDetails | Select-Object -First $limit | ForEach-Object { Write-Host "  - $_" }
        if ($errorDetails.Count -gt $limit) {
            Write-Host "  ... and $($errorDetails.Count - $limit) more"
        }
    }
}

# Helper function to format repository information summary as a table
function Format-RepoInfoSummaryTable {
    Param (
        [hashtable] $metrics
    )
    
    $table = "| Metric | Started | Ended | Delta |`n"
    $table += "| --- | --- | --- | --- |`n"
    
    foreach ($key in $metrics.Keys | Sort-Object) {
        $started = $metrics[$key].Started
        $ended = $metrics[$key].Ended
        $delta = $ended - $started
        $deltaStr = if ($delta -ge 0) { "+$(DisplayIntWithDots $delta)" } else { DisplayIntWithDots $delta }
        $table += "| $key | $(DisplayIntWithDots $started) | $(DisplayIntWithDots $ended) | $deltaStr |`n"
    }
    
    return $table
}

# Helper function to calculate priority score for a repo
function Get-RepoPriorityScore {
    Param (
        $action
    )
    
    $score = 0
    
    # Critical missing fields (highest priority)
    $hasOwner = Get-Member -inputobject $action -name "owner" -Membertype Properties
    if (!$hasOwner) {
        $score += 100
    }
    
    $hasMirrorFound = Get-Member -inputobject $action -name "mirrorFound" -Membertype Properties
    if (!$hasMirrorFound -or !$action.mirrorFound) {
        $score += 90
    }
    
    $hasActionType = Get-Member -inputobject $action -name "actionType" -Membertype Properties
    if (!$hasActionType -or ($null -eq $action.actionType.actionType)) {
        $score += 80
    }
    
    # Important fields (medium priority)
    $hasRepoInfo = Get-Member -inputobject $action -name "repoInfo" -Membertype Properties
    if (!$hasRepoInfo -or ($null -eq $action.repoInfo.updated_at)) {
        $score += 50
    }
    
    $hasRepoSize = Get-Member -inputobject $action -name "repoSize" -Membertype Properties
    if (!$hasRepoSize) {
        $score += 40
    }
    
    $hasDependents = Get-Member -inputobject $action -name "dependents" -Membertype Properties
    if (!$hasDependents) {
        $score += 30
    }
    
    # Stale data checks (lower priority)
    if ($hasDependents -and $action.dependents.dependentsLastUpdated) {
        $daysSinceLastUpdate = ((Get-Date) - $action.dependents.dependentsLastUpdated).Days
        if ($daysSinceLastUpdate -gt 7) {
            $score += 20
        }
    }
    
    $hasFundingInfo = Get-Member -inputobject $action -name "fundingInfo" -Membertype Properties
    if ($hasFundingInfo -and $action.fundingInfo.lastChecked) {
        $daysSinceLastCheck = ((Get-Date) - $action.fundingInfo.lastChecked).Days
        if ($daysSinceLastCheck -gt 30) {
            $score += 10
        }
    }
    
    return $score
}

# Helper function to filter and prioritize repos that need processing
function Get-PrioritizedReposToProcess {
    Param (
        $existingForks,
        $numberOfReposToDo
    )
    
    Write-Host "Prioritizing repos for processing..."
    
    # Calculate priority scores for all repos
    $scoredRepos = @()
    foreach ($action in $existingForks) {
        $score = Get-RepoPriorityScore -action $action
        if ($score -gt 0) {
            $scoredRepos += @{
                Action = $action
                Score = $score
            }
        }
    }
    
    Write-Host "Found [$($scoredRepos.Count)] repos that need processing out of [$($existingForks.Count)] total"
    
    # Sort by score (highest first) and take top N
    $prioritizedRepos = $scoredRepos | Sort-Object -Property Score -Descending | Select-Object -First $numberOfReposToDo
    
    Write-Host "Prioritized top [$($prioritizedRepos.Count)] repos for processing"
    
    # Return just the actions
    return $prioritizedRepos | ForEach-Object { $_.Action }
}

# Helper function to format error summary as a table with clickable links
function Format-ErrorSummaryTable {
    Param (
        [hashtable] $errorCounts,
        [hashtable] $errorDetails,
        [string] $forkOrg = "actions-marketplace-validations",
        [int] $limit = 10
    )
    
    # Calculate total errors
    $totalErrors = 0
    foreach ($key in $errorCounts.Keys) {
        $totalErrors += $errorCounts[$key]
    }
    
    # Build summary counts table
    $summaryTable = "| Error Type | Count |`n"
    $summaryTable += "| --- | --- |`n"
    $summaryTable += "| Upstream Repo 404 Errors | $(DisplayIntWithDots $errorCounts.UpstreamRepo404) |`n"
    $summaryTable += "| Fork Repo 404 Errors | $(DisplayIntWithDots $errorCounts.ForkRepo404) |`n"
    $summaryTable += "| Action File 404 Errors | $(DisplayIntWithDots $errorCounts.ActionFile404) |`n"
    $summaryTable += "| Other Errors | $(DisplayIntWithDots $errorCounts.OtherErrors) |`n"
    $summaryTable += "| **Total Errors** | **$(DisplayIntWithDots $totalErrors)** |`n"
    
    # Build details section with clickable links
    $detailsSection = ""
    
    # Upstream Repo 404 Details
    if ($errorDetails.UpstreamRepo404.Count -gt 0) {
        $detailsSection += "`n### Upstream Repo 404 Details (first $limit):`n`n"
        $detailsSection += "| Repository | Mirror Link | Original Link |`n"
        $detailsSection += "| --- | --- | --- |`n"
        
        $errorDetails.UpstreamRepo404 | Select-Object -First $limit | ForEach-Object {
            $repoPath = $_
            $mirrorName = $repoPath -replace '/', '_'
            $mirrorUrl = "https://github.com/$forkOrg/$mirrorName"
            $originalUrl = "https://github.com/$repoPath"
            $detailsSection += "| $repoPath | [Mirror]($mirrorUrl) | [Original]($originalUrl) |`n"
        }
        
        if ($errorDetails.UpstreamRepo404.Count -gt $limit) {
            $detailsSection += "`n... and $(DisplayIntWithDots ($errorDetails.UpstreamRepo404.Count - $limit)) more`n"
        }
    }
    
    # Fork Repo 404 Details
    if ($errorDetails.ForkRepo404.Count -gt 0) {
        $detailsSection += "`n### Fork Repo 404 Details (first $limit):`n`n"
        $detailsSection += "| Repository | Mirror Link | Original Link |`n"
        $detailsSection += "| --- | --- | --- |`n"
        
        $errorDetails.ForkRepo404 | Select-Object -First $limit | ForEach-Object {
            $repoPath = $_
            $mirrorUrl = "https://github.com/$repoPath"
            # Extract original repo from mirror name (format: org_repo)
            $parts = $repoPath -split '/'
            if ($parts.Length -eq 2) {
                $mirrorName = $parts[1]
                $originalParts = $mirrorName -split '_', 2
                if ($originalParts.Length -eq 2) {
                    $originalUrl = "https://github.com/$($originalParts[0])/$($originalParts[1])"
                    $detailsSection += "| $repoPath | [Mirror]($mirrorUrl) | [Original]($originalUrl) |`n"
                } else {
                    $detailsSection += "| $repoPath | [Mirror]($mirrorUrl) | N/A |`n"
                }
            } else {
                $detailsSection += "| $repoPath | [Mirror]($mirrorUrl) | N/A |`n"
            }
        }
        
        if ($errorDetails.ForkRepo404.Count -gt $limit) {
            $detailsSection += "`n... and $(DisplayIntWithDots ($errorDetails.ForkRepo404.Count - $limit)) more`n"
        }
    }
    
    # Action File 404 Details
    if ($errorDetails.ActionFile404.Count -gt 0) {
        $detailsSection += "`n### Action File 404 Details (first $limit):`n`n"
        $errorDetails.ActionFile404 | Select-Object -First $limit | ForEach-Object {
            $detailsSection += "  - $_`n"
        }
        
        if ($errorDetails.ActionFile404.Count -gt $limit) {
            $detailsSection += "`n... and $(DisplayIntWithDots ($errorDetails.ActionFile404.Count - $limit)) more`n"
        }
    }
    
    # Other Error Details
    if ($errorDetails.OtherErrors.Count -gt 0) {
        $detailsSection += "`n### Other Error Details (first 5):`n`n"
        $errorDetails.OtherErrors | Select-Object -First 5 | ForEach-Object {
            $detailsSection += "  - $_`n"
        }
        
        if ($errorDetails.OtherErrors.Count -gt 5) {
            $detailsSection += "`n... and $(DisplayIntWithDots ($errorDetails.OtherErrors.Count - 5)) more`n"
        }
    }
    
    return @{
        SummaryTable = $summaryTable
        DetailsSection = $detailsSection
        TotalErrors = $totalErrors
    }
}


function GetRepoInfo {
    Param (
        $owner,
        $repo,
        [Parameter(Mandatory=$true)]
        [Alias('access_token')]
        $accessToken,
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
        $response = ApiCall -method GET -url $url
        try {
            $url = "/repos/$owner/$repo/releases/latest"
            $release = ApiCall -method GET -url $url
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
        [Alias('access_token')]
        $accessToken,
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
    $response = ApiCall -method GET -url $url

    # Return array of objects with tag name and SHA
    $response = $response | ForEach-Object { 
        @{
            tag = SplitUrlLastPart($_.ref)
            sha = $_.object.sha
        }
    }

    return $response
}

function GetRepoReleases {
    Param (
        $owner,
        $repo,
        [Alias('access_token')]
        $accessToken,
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
    $response = ApiCall -method GET -url $url

    # Return array of objects with tag name and target_commitish (SHA)
    # Note: tag_name from releases API is already a direct string, not a URL path
    $response = $response | ForEach-Object { 
        @{
            tag_name = $_.tag_name
            target_commitish = $_.target_commitish
        }
    }

    return $response
}

function GetFundingInfo {
    Param (
        $owner,
        $repo,
        [Alias('access_token')]
        $accessToken,
        $startTime
    )

    if ($null -eq $owner -or $owner.Length -eq 0) {
        return $null
    }

    # Check if we are nearing the 50-minute mark
    $timeSpan = (Get-Date) - $startTime
    if ($timeSpan.TotalMinutes -gt 50) {
        Write-Host "Stopping the run, since we are nearing the 50-minute mark"
        return $null
    }

    # Check for FUNDING.yml in .github folder (as per GitHub documentation)
    $fundingFileContent = $null
    $fundingFileLocation = "/repos/$owner/$repo/contents/.github/FUNDING.yml"

    try {
        Write-Debug "Checking for FUNDING.yml at [$fundingFileLocation]"
        $response = ApiCall -method GET -url $fundingFileLocation -hideFailedCall $true
        
        if ($response -and $response.download_url) {
            Write-Message "Found FUNDING.yml for [$owner/$repo] at [$fundingFileLocation]"
            # Download the file content
            $fundingFileContent = ApiCall -method GET -url $response.download_url -returnErrorInfo $true
        }
    }
    catch {
        Write-Debug "No FUNDING.yml found at [$fundingFileLocation]"
    }

    if ($null -eq $fundingFileContent) {
        Write-Debug "No FUNDING.yml found for [$owner/$repo]"
        return $null
    }

    # Parse the FUNDING.yml content to count platforms
    # FUNDING.yml can have platforms like: github, patreon, open_collective, ko_fi, etc.
    # Each line typically has format: platform: username or platform: [user1, user2]
    
    try {
        $platformCount = 0
        $platforms = @()
        
        # Split content by lines and process each line
        $lines = $fundingFileContent -split "`n"
        foreach ($line in $lines) {
            $line = $line.Trim()
            
            # Skip comments and empty lines
            if ($line -match "^#" -or $line -eq "") {
                continue
            }
            
            # Match lines like "github: username" or "patreon: username"
            if ($line -match "^([a-z_]+):\s*(.+)$") {
                $platform = $matches[1].Trim()
                $value = $matches[2].Trim()
                
                # Skip if value is empty or just whitespace
                if ($value -ne "" -and $value -ne "[]" -and $value -ne "null") {
                    $platformCount++
                    $platforms += $platform
                    Write-Debug "Found funding platform: [$platform] with value: [$value]"
                }
            }
        }
        
        Write-Message "Parsed FUNDING.yml for [$owner/$repo]: $platformCount platforms found"
        
        return @{
            hasFunding = $true
            platformCount = $platformCount
            platforms = $platforms
            fileLocation = $fundingFileLocation
            lastChecked = Get-Date
        }
    }
    catch {
        Write-Host "Error parsing FUNDING.yml for [$owner/$repo]: $($_.Exception.Message)"
        return @{
            hasFunding = $true
            platformCount = 0
            platforms = @()
            fileLocation = $fundingFileLocation
            lastChecked = Get-Date
            parseError = $true
        }
    }
}

function GetActionType {
    Param (
        $owner,
        $repo,
        [Alias('access_token')]
        $accessToken,
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
        $response = ApiCall -method GET -url $url -hideFailedCall $true
        $fileFound = "action.yml"
    }
    catch {
        Write-Debug "No action.yml, checking for action.yaml"
        try {
            $url = "/repos/$owner/$repo/contents/action.yaml"
            $response = ApiCall -method GET -url $url -hideFailedCall $true
            $fileFound = "action.yaml"
        }
        catch {
            try {
                $url = "/repos/$owner/$repo/contents/Dockerfile"
                $response = ApiCall -method GET -url $url -hideFailedCall $true
                $fileFound = "Dockerfile"
                $actionDockerType = "Dockerfile"
                $actionType = "Docker"

                return ($actionType, $fileFound, $actionDockerType)
            }
            catch {
                try {
                    $url = "/repos/$owner/$repo/contents/dockerfile"
                    $response = ApiCall -method GET -url $url -hideFailedCall $true
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
    $fileContent = ApiCall -method GET -url $response.download_url -returnErrorInfo $true
    
    # Check if ApiCall returned an error
    if (($fileContent -is [hashtable]) -and ($fileContent.ContainsKey('Error'))) {
        Write-Host "Error downloading action definition file for [$owner/$repo]: StatusCode $($fileContent.StatusCode), Message: $($fileContent.Message)"
        
        # Track action file 404 errors if error tracking is initialized
        if ($null -ne $script:errorCounts) {
            if ($fileContent.StatusCode -eq 404) {
                $script:errorCounts.ActionFile404++
                $script:errorDetails.ActionFile404 += "$owner/$repo : $($response.download_url)"
            }
            else {
                $script:errorCounts.OtherErrors++
                $script:errorDetails.OtherErrors += "$owner/$repo : StatusCode $($fileContent.StatusCode)"
            }
        }
        
        return ("Error downloading file", "No file found", "No file found")
    }
    
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
    if (!$action.mirrorFound) {
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
        [Alias('access_token')]
        $accessToken,
        $startTime
    )

    # Check if we are nearing the 50-minute mark
    $timeSpan = (Get-Date) - $startTime
    if ($timeSpan.TotalMinutes -gt 50) {
        Write-Host "Stopping the run, since we are nearing the 50-minute mark"
        return
    }

    # try to load repo info
    $url = "/repos/$forkOrg/$($action.name)"
    try {
        $response = ApiCall -method GET -url $url -hideFailedCall $true
    }
    catch {
        if (Is404Error -errorMessage $errorMsg) {
            Write-Host "Mirror repo [$forkOrg/$($action.name)] not found (404), will be mirrored in a different workflow."
        }
        else {
            $errorMsg = $_.Exception.Message
            Write-Host "Error getting last updated repo info for mirror [$forkOrg/$($action.name)]: $errorMsg"
        }

        # Track fork 404 errors if error tracking is initialized
        if ($null -ne $script:errorCounts) {
            if (Is404Error -errorMessage $errorMsg) {
                $script:errorCounts.ForkRepo404++
                $script:errorDetails.ForkRepo404 += "$forkOrg/$($action.name)"

                # Mark this fork as missing so future runs and other workflows
                # can skip it entirely. This is a lightweight persistent hint
                # stored on the action object and respected by
                # CheckForInfoUpdateNeeded and Split-ForksIntoChunks.
                if (-not (Get-Member -InputObject $action -Name "mirrorFound" -MemberType Properties)) {
                    $action | Add-Member -Name mirrorFound -Value $false -MemberType NoteProperty
                } else {
                    $action.mirrorFound = $false
                }
            }
            else {
                $script:errorCounts.OtherErrors++
                $script:errorDetails.OtherErrors += "$forkOrg/$($action.name) : $errorMsg"
            }
        }

        # Ensure we only make this repo info call once per action per run.
        # Returning a non-null sentinel object prevents additional calls that
        # check for $null -eq $response from retrying this failing request.
        $response = [PSCustomObject]@{ error = $errorMsg }
    }

    return $response
}
function GetInfo {
    Param (
        $existingForks,
        [Alias('access_token')]
        $accessToken,
        $startTime
    )

    # Initialize error tracking
    $script:errorCounts = @{
        UpstreamRepo404 = 0
        ForkRepo404 = 0
        ActionFile404 = 0
        OtherErrors = 0
    }
    $script:errorDetails = @{
        UpstreamRepo404 = @()
        ForkRepo404 = @()
        ActionFile404 = @()
        OtherErrors = @()
    }

    # Initialize tracking for summary
    $script:processMetrics = @{
        TotalReposExamined = 0
        ReposWithUpdates = 0
        ReposSkipped = 0
    }

    # get information from the action files
    $i = $existingForks.Count
    $max = $existingForks.Count + ($numberOfReposToDo * 1)
    foreach ($action in $existingForks) {
        $script:processMetrics.TotalReposExamined++
        # Reset flag for each repo to track if this specific repo gets updates
        $repoHadUpdates = $false

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
            $hasField = Get-Member -inputobject $action -name "mirrorFound" -Membertype Properties
            if ($hasField -and !$action.mirrorFound) {
                # skip this one to prevent us from keeping checking on erroneous repos
                $script:processMetrics.ReposSkipped++
                continue
            }
            # load owner from repo info out of the fork
            $response = MakeRepoInfoCall -action $action -forkOrg $forkOrg -accessToken $accessToken -startTime $startTime
            Write-Host "Loading repo information for fork [$forkOrg/$($action.name)]"
                if ($response -and $response.parent) {
                    # load owner info from parent
                    $action | Add-Member -Name owner -Value $response.parent.owner.login -MemberType NoteProperty
                } else {
                    # new entry with leading owner name
                    $action | Add-Member -Name owner -Value $forkOrg -MemberType NoteProperty
                }

                # ensure mirrorFound is set to true without duplicating the property
                $mirrorFoundField = Get-Member -InputObject $action -Name "mirrorFound" -MemberType Properties
                if (-not $mirrorFoundField) {
                    $action | Add-Member -Name mirrorFound -Value $true -MemberType NoteProperty
                }
                else {
                    $action.mirrorFound = $true
                }
        }
        else {
            # owner field is filled, let's check if mirrorFound field already exists
            $hasField = Get-Member -inputobject $action -name "mirrorFound" -Membertype Properties
            if (!$hasField) {
                # owner is known, so this fork exists
                $action | Add-Member -Name mirrorFound -Value $true -MemberType NoteProperty
                $i++ | Out-Null
                $repoHadUpdates = $true
            }
        }

        # check when the mirror was last updated
        $hasField = Get-Member -inputobject $action -name "mirrorLastUpdated" -Membertype Properties
        if (!$hasField) {
            if ($null -eq $response) {
                $response = MakeRepoInfoCall -action $action -forkOrg $forkOrg -accessToken $accessToken -startTime $startTime
            }
            if ($response -and $response.updated_at) {
                # add the new field
                $action | Add-Member -Name mirrorLastUpdated -Value $response.updated_at -MemberType NoteProperty
                $i++ | Out-Null
                $repoHadUpdates = $true
            }
        }
        else {
            $action.mirrorLastUpdated = $response.updated_at
        }

        # store repo size (only set when we have a valid value)
        $hasField = Get-Member -inputobject $action -name repoSize -Membertype Properties
        if ($null -eq $response) {
            # try fork first
            $response = MakeRepoInfoCall -action $action -forkOrg $forkOrg -accessToken $accessToken -startTime $startTime
        }

        $sizeValue = $null
        if ($null -ne $response -and $null -ne $response.size) {
            $sizeValue = $response.size
        }
        else {
            # fallback: try upstream repo to get size
            try {
                ($owner, $repo) = GetOrgActionInfo($action.name)
                if ($owner -and $repo) {
                    $upstreamUrl = "/repos/$owner/$repo"
                    $upstreamResponse = ApiCall -method GET -url $upstreamUrl -hideFailedCall $true
                    if ($null -ne $upstreamResponse -and $null -ne $upstreamResponse.size) {
                        $sizeValue = $upstreamResponse.size
                    }
                }
            }
            catch {
                # ignore and leave sizeValue as $null
            }
        }

        if (!$hasField) {
            if ($null -ne $sizeValue) {
                $action | Add-Member -Name repoSize -Value $sizeValue -MemberType NoteProperty
            }
            else {
                # explicitly mark as unknown when we cannot determine size
                $action | Add-Member -Name repoSize -Value $null -MemberType NoteProperty
            }
        }
        else {
            # only update when we have a valid size; do not overwrite non-null with null
            if ($null -ne $sizeValue) {
                $action.repoSize = $sizeValue
            }
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
                    $repoHadUpdates = $true
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
                    $repoHadUpdates = $true
                }
            }
        }

        $hasActionTypeField = Get-Member -inputobject $action -name "actionType" -Membertype Properties
        $hasNodeVersionField = $null -ne $action.actionType.nodeVersion
        $updateNeeded = CheckForInfoUpdateNeeded -action $action -hasActionTypeField $hasActionTypeField -hasNodeVersionField $hasNodeVersionField -startTime $startTime
        if ($updateNeeded) {
            ($owner, $repo) = GetOrgActionInfo($action.name)
            Write-Host "$i/$max - Checking action information for [$($owner)/$($repo)]"
            ($actionTypeResult, $fileFoundResult, $actionDockerTypeResult, $nodeVersion) = GetActionType -owner $owner -repo $repo -accessToken $accessToken -startTime $startTime

            If (!$hasActionTypeField) {
                $actionType = @{
                    actionType = $actionTypeResult
                    fileFound = $fileFoundResult
                    actionDockerType = $actionDockerTypeResult
                    nodeVersion = $nodeVersion
                }

                $action | Add-Member -Name actionType -Value $actionType -MemberType NoteProperty
                $i++ | Out-Null
                $repoHadUpdates = $true
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
                $repoHadUpdates = $true
            }

        }

        # store funding information
        $hasFundingField = Get-Member -inputobject $action -name "fundingInfo" -Membertype Properties
        if (!$hasFundingField) {
            ($owner, $repo) = GetOrgActionInfo($action.name)
            if ($repo -ne "" -and $owner -ne "") {
                Write-Debug "Checking funding information for [$($owner)/$($repo)]"
                $fundingInfo = GetFundingInfo -owner $owner -repo $repo -accessToken $accessToken -startTime $startTime
                if ($null -ne $fundingInfo) {
                    $action | Add-Member -Name fundingInfo -Value $fundingInfo -MemberType NoteProperty
                    $i++ | Out-Null
                    $repoHadUpdates = $true
                }
            }
        }
        else {
            # check if the last check was more than 30 days ago
            $lastChecked = $action.fundingInfo.lastChecked
            if ($null -ne $lastChecked) {
                $daysSinceLastCheck = (Get-Date) - $lastChecked
                if ($daysSinceLastCheck.Days -gt 30) {
                    # update the funding info
                    ($owner, $repo) = GetOrgActionInfo($action.name)
                    if ($repo -ne "" -and $owner -ne "") {
                        Write-Debug "Re-checking funding information for [$($owner)/$($repo)]"
                        $fundingInfo = GetFundingInfo -owner $owner -repo $repo -accessToken $accessToken -startTime $startTime
                        if ($null -ne $fundingInfo) {
                            $action.fundingInfo = $fundingInfo
                            $i++ | Out-Null
                            $repoHadUpdates = $true
                        }
                    }
                }
            }
        }
        
        # Track if this repo had any updates
        if ($repoHadUpdates) {
            $script:processMetrics.ReposWithUpdates++
        }
    }

    # Output processing summary
    $withUpdates = $script:processMetrics.ReposWithUpdates
    $examined = $script:processMetrics.TotalReposExamined
    $skipped = $script:processMetrics.ReposSkipped
    
    Write-Host ""
    Write-Host "GetInfo Processing Summary:"
    Write-Host "  Total repos examined: $examined"
    Write-Host "  Repos with updates: $withUpdates"
    Write-Host "  Repos skipped: $skipped"
    Write-Host ""

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

function Test-DockerfileHasCustomCode {
    <#
    .SYNOPSIS
        Analyzes Dockerfile content to determine if it contains custom code.
    
    .DESCRIPTION
        Checks if the Dockerfile contains COPY or ADD instructions that add files from the repository.
        Returns $true if custom code is being added to the image, $false otherwise.
        
        A Dockerfile is considered to have custom code if it contains:
        - COPY instructions (except for copying from other build stages)
        - ADD instructions (except for URLs)
    
    .PARAMETER dockerFileContent
        The content of the Dockerfile as a string
    
    .OUTPUTS
        Boolean indicating whether the Dockerfile contains custom code
    #>
    param (
        [string]$dockerFileContent
    )
    
    if ($null -eq $dockerFileContent -or "" -eq $dockerFileContent) {
        return $false
    }
    
    # Split into lines and normalize
    $lines = $dockerFileContent.Split("`n") | ForEach-Object { $_.Trim().TrimEnd("`r") }
    
    # Look for COPY or ADD instructions
    foreach ($line in $lines) {
        # Skip comments and empty lines
        if ($line -match '^\s*#' -or $line -match '^\s*$') {
            continue
        }
        
        # Check for COPY instruction (but not COPY --from=stage which is multi-stage build)
        if ($line -match '^COPY\s+(?!--from=)') {
            Write-Debug "Found COPY instruction indicating custom code: $line"
            return $true
        }
        
        # Check for ADD instruction (but not ADD with URLs which pulls external resources)
        if ($line -match '^ADD\s+(?!https?://)') {
            Write-Debug "Found ADD instruction indicating custom code: $line"
            return $true
        }
    }
    
    return $false
}

function GetRepoDockerBaseImage {
    <#
    .SYNOPSIS
        Gets Docker base image and analyzes if Dockerfile contains custom code.
    
    .DESCRIPTION
        Downloads and analyzes the Dockerfile to extract:
        1. The base image from the FROM instruction
        2. Whether the Dockerfile contains COPY/ADD instructions (custom code)
    
    .OUTPUTS
        Returns a hashtable with:
        - dockerBaseImage: The base image name
        - hasCustomCode: Boolean indicating if Dockerfile has COPY/ADD instructions
    #>
    Param (
        [string] $owner,
        [string] $repo,
        $actionType,
        [Alias('access_token')]
        $accessToken
    )

    $result = @{
        dockerBaseImage = ""
        hasCustomCode = $false
    }
    
    if ($actionType.actionDockerType -eq "Dockerfile") {
        $url = "/repos/$owner/$repo/contents/Dockerfile"
        $repoUrl = "https://github.com/$owner/$repo"
        $dockerfilePath = "Dockerfile"
        $contextInfo = "Repository: $repoUrl, File: $dockerfilePath"
        try {
            $dockerFile = ApiCall -method GET -url $url -hideFailedCall $true -contextInfo $contextInfo
            $hasValidDownloadUrl = $null -ne $dockerFile -and $null -ne $dockerFile.download_url -and $dockerFile.download_url -ne ""
            if ($hasValidDownloadUrl) {
                $dockerFileContent = ApiCall -method GET -url $dockerFile.download_url -contextInfo $contextInfo
                $result.dockerBaseImage = GetDockerBaseImageNameFromContent -dockerFileContent $dockerFileContent
                $result.hasCustomCode = Test-DockerfileHasCustomCode -dockerFileContent $dockerFileContent
            }
            else {
                Write-Host "Error: No download_url found for Dockerfile in [$owner/$repo]"
            }
        }
        catch {
            Write-Host "Error getting Dockerfile for [$owner/$repo]: $($_.Exception.Message), trying lowercase file"
            # retry with lowercase dockerfile name
            $url = "/repos/$owner/$repo/contents/dockerfile"
            $dockerfilePath = "dockerfile"
            $contextInfo = "Repository: $repoUrl, File: $dockerfilePath"
            try {
                $dockerFile = ApiCall -method GET -url $url -hideFailedCall $true -contextInfo $contextInfo
                $hasValidDownloadUrl = $null -ne $dockerFile -and $null -ne $dockerFile.download_url -and $dockerFile.download_url -ne ""
                if ($hasValidDownloadUrl) {
                    $dockerFileContent = ApiCall -method GET -url $dockerFile.download_url -contextInfo $contextInfo
                    $result.dockerBaseImage = GetDockerBaseImageNameFromContent -dockerFileContent $dockerFileContent
                    $result.hasCustomCode = Test-DockerfileHasCustomCode -dockerFileContent $dockerFileContent
                }
                else {
                    Write-Host "Error: No download_url found for dockerfile in [$owner/$repo]"
                }
            }
            catch {
                Write-Host "Error getting dockerfile for [$owner/$repo]: $($_.Exception.Message)"
            }
        }
    }
    else {
        Write-Host "Cant load docker base image for action type [$($actionType.actionType)] with [$($actionType.actionDockerType)] in [$owner/$repo]"
    }

    return $result
}

function EnableSecretScanning {
    param (
        [string] $owner,
        [string] $repo,
        [Alias('access_token')]
        [string] $accessToken
    )

    $url = "/repos/$owner/$repo"
    $body = "{""security_and_analysis"": {""secret_scanning"": {""status"": ""enabled""}}}"
    $patchResult = ApiCall -method PATCH -url $url -body $body -expected 200

    return $patchResult
}

function GetMoreInfo {
    param (
        $existingForks,
        [Alias('access_token')]
        $accessToken,
        $startTime
    )
    # get repo information
    $i = $existingForks.Length
    $max = $existingForks.Length + ($numberOfReposToDo * 1)
    
    # Track starting counts for metrics
    $startingRepoInfo = $($existingForks | Where-Object {$null -ne $_.repoInfo}).Length
    $startingTagInfo = $($existingForks | Where-Object {$null -ne $_.tagInfo}).Length
    $startingReleaseInfo = $($existingForks | Where-Object {$null -ne $_.releaseInfo}).Length
    
    # Initialize tracking for GetMoreInfo
    # Note: GetMoreInfo uses memberAdded/memberUpdate variables to track changes
    # so ReposWithUpdates is not needed here - those variables serve the same purpose
    $script:moreInfoMetrics = @{
        TotalReposExamined = 0
        ReposSkipped = 0
    }
    
    Write-Host "Loading repository information, starting with [$startingRepoInfo] already loaded"
    $memberAdded = 0
    $memberUpdate = 0
    $dockerBaseImageInfoAdded = 0
    # store the repos that no longer exists
    $originalRepoDoesNotExists = New-Object System.Collections.ArrayList
    # store the timestamp
    $startTime = Get-Date
    try {
        foreach ($action in $existingForks) {
            $script:moreInfoMetrics.TotalReposExamined++

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

            if (!$action.upstreamFound) {
                Write-Debug "Skipping this repo, since the fork was not found: [$($action.owner)/$($action.name)]"
                $script:moreInfoMetrics.ReposSkipped++
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
                    ($repo_archived, $repo_disabled, $repo_updated_at, $latest_release_published_at, $statusCode) = GetRepoInfo -owner $owner -repo $repo -accessToken $accessToken -startTime $startTime
                    if ($statusCode -and ($statusCode -eq "NotFound")) {
                        $action.upstreamFound = $false
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
                    $errorMsg = $_.Exception.Message
                    Write-Host "Error calling GetRepoInfo for [$owner/$repo]: $errorMsg"
                    
                    # Track upstream repo 404 errors
                    if (Is404Error -errorMessage $errorMsg) {
                        $script:errorCounts.UpstreamRepo404++
                        $script:errorDetails.UpstreamRepo404 += "$owner/$repo"
                    }
                    else {
                        $script:errorCounts.OtherErrors++
                        $script:errorDetails.OtherErrors += "$owner/$repo : $errorMsg"
                    }
                    
                    # Check if our forked copy exists
                    try {
                        $forkCheckUrl = "/repos/$forkOrg/$($action.name)"
                        $forkResponse = ApiCall -method GET -url $forkCheckUrl -hideFailedCall $true
                        if ($null -ne $forkResponse -and $forkResponse.id -gt 0) {
                            Write-Host "Our forked copy exists at [$forkOrg/$($action.name)] (id: $($forkResponse.id)), but upstream repo [$owner/$repo] may not exist or is inaccessible"
                        }
                        else {
                            Write-Host "Fork check returned unexpected response for [$forkOrg/$($action.name)]"
                        }
                    }
                    catch {
                        $forkErrorMsg = $_.Exception.Message
                        Write-Host "Our forked copy does not exist at [$forkOrg/$($action.name)]: $forkErrorMsg"
                        
                        # Track fork 404 errors
                        if (Is404Error -errorMessage $forkErrorMsg) {
                            $script:errorCounts.ForkRepo404++
                            $script:errorDetails.ForkRepo404 += "$forkOrg/$($action.name)"
                        }
                    }
                    # continue with next one
                }
            }

            $hasField = Get-Member -inputobject $action -name "tagInfo" -Membertype Properties
            if (!$hasField -or ($null -eq $action.tagInfo)) {
                #Write-Host "$i/$max - Checking tag information for [$forkOrg/$($action.name)]. hasField: [$hasField], actionType: [$($action.actionType.actionType)], updated_at: [$($action.repoInfo.updated_at)]"
                try {
                    $tagInfo = GetRepoTagInfo -owner $owner -repo $repo -accessToken $AccessToken -startTime $startTime
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
                    $secretScanningEnabled = EnableSecretScanning -owner $forkOrg -repo $action.name -accessToken $accessToken
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
                    $releaseInfo = GetRepoReleases -owner $owner -repo $repo -accessToken $accessToken -startTime $startTime
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
                $hasBaseImageField = Get-Member -inputobject $action.actionType -name "dockerBaseImage" -Membertype Properties
                $hasCustomCodeField = Get-Member -inputobject $action.actionType -name "dockerfileHasCustomCode" -Membertype Properties
                
                # Check if we need to get or update Docker info
                $needsDockerInfo = (!$hasBaseImageField -or ($null -eq $action.actionType.dockerBaseImage) -And $action.actionType.actionDockerType -ne "Image") -or !$hasCustomCodeField
                
                if ($needsDockerInfo) {
                    Write-Host "$i/$max - Checking Docker information for [$($owner)/$($repo)]. hasBaseImageField: [$hasBaseImageField], hasCustomCodeField: [$hasCustomCodeField], actionType: [$($action.actionType.actionType)], actionDockerType: [$($action.actionType.actionDockerType)]"
                    try {
                        # search for the docker file in the fork organization, since the original repo might already have seen updates
                        $dockerInfo = GetRepoDockerBaseImage -owner $owner -repo $repo -actionType $action.actionType -accessToken $accessToken
                        
                        if ($dockerInfo.dockerBaseImage -ne "") {
                            if (!$hasBaseImageField) {
                                Write-Host "Adding Docker base image information with image:[$($dockerInfo.dockerBaseImage)], hasCustomCode:[$($dockerInfo.hasCustomCode)] for [$($action.owner)/$($action.name))]"
                                $action.actionType | Add-Member -Name dockerBaseImage -Value $dockerInfo.dockerBaseImage -MemberType NoteProperty
                                $i++ | Out-Null
                                $dockerBaseImageInfoAdded++ | Out-Null
                            }
                            else {
                                Write-Host "Updating Docker base image information with image:[$($dockerInfo.dockerBaseImage)] for [$($owner)/$($repo))]"
                                $action.actionType.dockerBaseImage = $dockerInfo.dockerBaseImage
                            }
                            
                            # Add or update hasCustomCode field
                            if (!$hasCustomCodeField) {
                                $action.actionType | Add-Member -Name dockerfileHasCustomCode -Value $dockerInfo.hasCustomCode -MemberType NoteProperty
                            }
                            else {
                                $action.actionType.dockerfileHasCustomCode = $dockerInfo.hasCustomCode
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
    
    # Output GetMoreInfo processing summary
    $examined = $script:moreInfoMetrics.TotalReposExamined
    $skipped = $script:moreInfoMetrics.ReposSkipped
    
    Write-Host ""
    Write-Host "GetMoreInfo Processing Summary:"
    Write-Host "  Total repos examined: $examined"
    Write-Host "  Repos skipped: $skipped"
    Write-Host ""
    
    # Calculate ending counts
    $endingRepoInfo = $($existingForks | Where-Object {$null -ne $_.repoInfo}).Length
    $endingTagInfo = $($existingForks | Where-Object {$null -ne $_.tagInfo}).Length
    $endingReleaseInfo = $($existingForks | Where-Object {$null -ne $_.releaseInfo}).Length
    
    # Create metrics table
    $metrics = @{
        "Repository Information" = @{ Started = $startingRepoInfo; Ended = $endingRepoInfo }
        "Tag Information" = @{ Started = $startingTagInfo; Ended = $endingTagInfo }
        "Release Information" = @{ Started = $startingReleaseInfo; Ended = $endingReleaseInfo }
    }
    
    # Output as table to step summary
    $table = Format-RepoInfoSummaryTable -metrics $metrics
    
    # Calculate total delta
    $totalDelta = 0
    foreach ($key in $metrics.Keys) {
        $totalDelta += ($metrics[$key].Ended - $metrics[$key].Started)
    }
    
    # Add processing summary at the top
    $processingSummary = "## Processing Summary`n`n"
    $processingSummary += "| Metric | Count |`n"
    $processingSummary += "| --- | --- |`n"
    $processingSummary += "| Total repos in status file | $(DisplayIntWithDots $existingForks.Count) |`n"
    $processingSummary += "| Repos examined | $(DisplayIntWithDots $examined) |`n"
    $processingSummary += "| Repos skipped | $(DisplayIntWithDots $skipped) |`n"
    $processingSummary += "| Limit (numberOfReposToDo) | $(DisplayIntWithDots $numberOfReposToDo) |`n"
    $processingSummary += "`n"
    
    # Add explanation if no deltas occurred
    if ($totalDelta -eq 0) {
        $processingSummary += "> **Note**: No changes were made (0 total delta). This means all examined repos already had up-to-date information. "
        $processingSummary += "The workflow still examined $examined repos sequentially to check if updates were needed. "
        $processingSummary += "Future optimization: implement prioritization to process repos missing critical fields first.`n`n"
    }
    
    $summaryOutput = $processingSummary + "`n## Repository Information Summary`n`n$table"
    if ($dockerBaseImageInfoAdded -gt 0) {
        $summaryOutput += "`nDocker base image information added for [$(DisplayIntWithDots $dockerBaseImageInfoAdded)] actions"
    }
    Write-Message -message $summaryOutput -logToSummary $true

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

    # Report error summary
    Write-Host ""
    Write-Host "=================================="
    Write-Host "Error Summary for this run:"
    Write-Host "=================================="
    
    # Calculate total errors
    $totalErrors = 0
    foreach ($key in $script:errorCounts.Keys) {
        $totalErrors += $script:errorCounts[$key]
    }
    
    # Display error counts
    Write-Host "Upstream Repo 404 Errors: $($script:errorCounts.UpstreamRepo404)"
    Write-Host "Fork Repo 404 Errors: $($script:errorCounts.ForkRepo404)"
    Write-Host "Action File 404 Errors: $($script:errorCounts.ActionFile404)"
    Write-Host "Other Errors: $($script:errorCounts.OtherErrors)"
    Write-Host "Total Errors: $totalErrors"
    Write-Host "=================================="
    
    # Log detailed error information if there are errors
    ReportErrorDetails -errorType "Upstream Repo 404" -errorDetails $script:errorDetails.UpstreamRepo404 -limit 10
    ReportErrorDetails -errorType "Fork Repo 404" -errorDetails $script:errorDetails.ForkRepo404 -limit 10
    ReportErrorDetails -errorType "Action File 404" -errorDetails $script:errorDetails.ActionFile404 -limit 10
    ReportErrorDetails -errorType "Other Error" -errorDetails $script:errorDetails.OtherErrors -limit 5
    Write-Host ""
    
    # Add error summary to step summary with clickable links
    if ($totalErrors -gt 0) {
        $errorSummary = Format-ErrorSummaryTable -errorCounts $script:errorCounts -errorDetails $script:errorDetails -forkOrg $forkOrg -limit 10
        
        $stepSummaryOutput = "`n## Error Summary`n`n"
        $stepSummaryOutput += $errorSummary.SummaryTable
        $stepSummaryOutput += "`n<details>`n<summary>View Error Details</summary>`n"
        $stepSummaryOutput += $errorSummary.DetailsSection
        $stepSummaryOutput += "`n</details>`n"
        
        Write-Message -message $stepSummaryOutput -logToSummary $true
    }

    #return ($actions, $existingForks) ? where does this $actions come from?
    return ($null, $existingForks)
}

function Run {
    Param (
        $actions,

        [Parameter(Mandatory=$true)]
        [Alias('access_token')]
        $accessToken,

        [Parameter(Mandatory=$true)]
        [Alias('access_token_destination')]
        $accessTokenDestination
    )

    $startTime = Get-Date
    Write-Host "Run started at [$startTime]"

    Write-Host "Got $(DisplayIntWithDots($actions.Length)) actions to get the repo information for"
    GetRateLimitInfo -access_token $accessToken -access_token_destination $accessTokenDestination

    ($existingForks, $failedForks) = GetForkedActionRepos -actions $actions -access_token $accessTokenDestination

    $existingForks = GetInfo -existingForks $existingForks -accessToken $accessToken -startTime $startTime
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
    ($actions, $existingForks) = GetMoreInfo -existingForks $existingForks -accessToken $accessTokenDestination -startTime $startTime
    SaveStatus -existingForks $existingForks

    GetRateLimitInfo -access_token $accessToken -access_token_destination $accessTokenDestination -waitForRateLimit $false
}

# main call
Run -actions $actions -accessToken $accessToken -accessTokenDestination $accessTokenDestination

# Explicitly exit with success code to prevent PowerShell from inheriting exit codes from previous commands
exit 0
