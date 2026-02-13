Param (
    [Parameter(Mandatory = $false)]
    [int]$topActionsCount = 5,
    [Parameter(Mandatory = $false)]
    [int]$waitBetweenReposSeconds = 5
)

Write-Host "Starting semver check workflow"

. $PSScriptRoot/library.ps1

# Store results for each action
$script:results = @()

function Select-TopActions {
    Param (
        [Parameter(Mandatory = $true)]
        $actions,
        [Parameter(Mandatory = $true)]
        [int]$count
    )
    
    Write-Host "Selecting top $count actions from dataset..."
    
    # Filter for valid actions with:
    # - Valid owner and name
    # - Not archived
    # - Have repo info
    # - Prefer actions from verified organizations (actions, github, microsoft, azure)
    $validActions = $actions | Where-Object {
        $_.owner -and 
        $_.name -and 
        $_.repoInfo -and 
        -not $_.repoInfo.archived -and
        -not $_.repoInfo.disabled
    }
    
    Write-Host "Found $($validActions.Count) valid actions"
    
    # Prioritize well-known organizations
    $verifiedOrgs = @('actions', 'github', 'microsoft', 'azure', 'docker')
    $verifiedActions = $validActions | Where-Object { 
        $_.owner -and ($verifiedOrgs -contains $_.owner.ToLower()) 
    }
    
    # If we have enough verified actions, use those; otherwise mix with others
    if ($verifiedActions.Count -ge $count) {
        $topActions = $verifiedActions | 
            Sort-Object { $_.repoInfo.updated_at } -Descending | 
            Select-Object -First $count
    } else {
        # Mix verified and other popular actions (by update recency)
        $topActions = $validActions | 
            Sort-Object { 
                if ($_.owner -and ($verifiedOrgs -contains $_.owner.ToLower())) { 0 } else { 1 }
            }, { $_.repoInfo.updated_at } -Descending | 
            Select-Object -First $count
    }
    
    Write-Host "Selected $($topActions.Count) actions for semver checking:"
    foreach ($action in $topActions) {
        $upstreamOwner, $upstreamRepo = Get-UpstreamRepoName -action $action
        Write-Host "  - $upstreamOwner/$upstreamRepo"
    }
    
    return $topActions
}

function Get-UpstreamRepoName {
    Param (
        [Parameter(Mandatory = $true)]
        $action
    )
    
    # Parse the mirror repo name to get the actual upstream repo name
    # The action.name field contains the mirror name (e.g., "github_docs")
    # Construct the full path and use SplitUrl to parse it correctly
    # SplitUrl handles duplicate prefixes like "github/github_docs" -> "github/docs"
    $fullPath = "$($action.owner)/$($action.name)"
    $upstreamOwner, $upstreamRepo = SplitUrl -url $fullPath
    
    # If parsing failed, fall back to original values
    if ([string]::IsNullOrEmpty($upstreamOwner) -or [string]::IsNullOrEmpty($upstreamRepo)) {
        $upstreamOwner = $action.owner
        $upstreamRepo = $action.name
    }
    
    return $upstreamOwner, $upstreamRepo
}

function Install-SemverCheckerModule {
    Write-Host "Installing GitHubActionVersioning module..."
    
    # Check if module is already installed
    $module = Get-Module -ListAvailable -Name GitHubActionVersioning
    if ($module) {
        Write-Host "Module already installed, forcing reimport..."
        Import-Module GitHubActionVersioning -Force
        return $true
    }
    
    # Try to install from PowerShell Gallery first (reported to be available at version 2.0.2)
    # Reference: https://www.powershellgallery.com/packages/GitHubActionVersioning/2.0.2
    Write-Host "Attempting to install from PowerShell Gallery..."
    try {
        Install-Module -Name GitHubActionVersioning -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Import-Module GitHubActionVersioning -Force -ErrorAction Stop
        Write-Host "✓ Module installed successfully from PowerShell Gallery"
        return $true
    } catch {
        Write-Host "PowerShell Gallery installation failed: $($_.Exception.Message)"
        Write-Host "Falling back to cloning from GitHub repository..."
    }
    
    # Fallback: Clone the repository if PowerShell Gallery installation fails
    # The module's README documents "From Local Files" as an installation method
    # Reference: https://github.com/jessehouwing/actions-semver-checker/blob/main/module/README.md
    $tempDir = "/tmp/semver-checker-module"
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force
    }
    
    Write-Host "Cloning actions-semver-checker repository to access PowerShell module..."
    try {
        $cloneResult = git clone https://github.com/jessehouwing/actions-semver-checker.git $tempDir 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to clone repository: $cloneResult"
            return $false
        }
        
        # Module files are in the root of the repository, not in a subdirectory
        $modulePath = Join-Path $tempDir "GitHubActionVersioning.psd1"
        if (Test-Path $modulePath) {
            Write-Host "Importing module from: $modulePath"
            Import-Module $modulePath -Force
            Write-Host "Module imported successfully"
            return $true
        } else {
            Write-Host "Module file not found at: $modulePath"
            return $false
        }
    } catch {
        Write-Host "Error installing module: $($_.Exception.Message)"
        return $false
    }
}

function Test-ActionSemver {
    Param (
        [Parameter(Mandatory = $true)]
        $action,
        [Parameter(Mandatory = $true)]
        $tokenManager,
        [Parameter(Mandatory = $false)]
        [int]$waitBetweenReposSeconds = 5
    )
    
    # Configuration constants
    $maxRetries = 3
    $maxGraphQLWaitSeconds = 900  # Maximum 15 minutes wait for GraphQL rate limit reset
    $graphQLCriticalThreshold = 100  # Critical threshold for GraphQL remaining requests
    
    # Get the parsed upstream repo name
    $upstreamOwner, $upstreamRepo = Get-UpstreamRepoName -action $action
    
    $repository = "$upstreamOwner/$upstreamRepo"
    Write-Host ""
    Write-Host "====================================="
    Write-Host "Testing: $repository"
    Write-Host "====================================="
    
    # Extract dependents count if available
    $dependentsCount = $null
    if ($action.dependents -and $action.dependents.dependents) {
        $dependentsCount = $action.dependents.dependents
        Write-Host "Dependents: $dependentsCount"
    }
    
    $result = @{
        Repository = $repository
        Owner = $upstreamOwner
        Name = $upstreamRepo
        Success = $false
        Issues = @()
        Output = ""
        Error = $null
        RateLimited = $false
        Dependents = $dependentsCount
    }
    
    # Retry count starts at 0 for initial attempt
    $retryCount = 0
    
    while ($retryCount -le $maxRetries) {
        try {
            # Get a fresh token for this action to avoid rate limit exhaustion
            # The token manager will try different GitHub Apps in round-robin fashion
            $tokenResult = $tokenManager.GetTokenForOrganization($env:APP_ORGANIZATION)
            if (-not $tokenResult -or -not $tokenResult.Token) {
                $result.Error = "Failed to get GitHub token"
                Write-Host "Error: Failed to get GitHub token"
                return $result
            }
            
            $token = $tokenResult.Token
            
            # Check rate limits before making the API call
            Write-Host "Checking rate limits before processing..."
            try {
                $headers = @{
                    Authorization = GetBasicAuthenticationHeader -access_token $token
                }
                $rateUrl = "https://api.github.com/rate_limit"
                $rateCheck = Invoke-WebRequest -Uri $rateUrl -Headers $headers -Method GET -ErrorAction Stop
                $rateData = ($rateCheck.Content | ConvertFrom-Json)
                
                # Check Core API rate limit
                if ($null -ne $rateData.rate -and $rateData.rate.remaining -lt 100) {
                    Write-Host "⚠️ Warning: Core API rate limit is low (remaining: $($rateData.rate.remaining))"
                    Write-Message -message "⚠️ Warning: Core API rate limit is low for $repository (remaining: $($rateData.rate.remaining))" -logToSummary $true
                }
                
                # Check GraphQL API rate limit
                if ($null -ne $rateData.resources.graphql -and $rateData.resources.graphql.remaining -lt 500) {
                    Write-Host "⚠️ Warning: GraphQL API rate limit is low (remaining: $($rateData.resources.graphql.remaining))"
                    Write-Message -message "⚠️ Warning: GraphQL API rate limit is low for $repository (remaining: $($rateData.resources.graphql.remaining))" -logToSummary $true
                    
                    # If GraphQL rate limit is critically low, wait for reset
                    if ($rateData.resources.graphql.remaining -lt $graphQLCriticalThreshold) {
                        $resetTime = [DateTimeOffset]::FromUnixTimeSeconds($rateData.resources.graphql.reset).UtcDateTime
                        $timeUntilReset = ($resetTime - (Get-Date).ToUniversalTime()).TotalSeconds
                        
                        if ($timeUntilReset -gt 0 -and $timeUntilReset -lt $maxGraphQLWaitSeconds) {
                            $waitTime = [math]::Ceiling($timeUntilReset) + 5 # Add 5 seconds buffer
                            Write-Host "GraphQL rate limit critically low. Waiting $waitTime seconds for reset..."
                            Write-Message -message "⏱️ GraphQL rate limit critically low for $repository. Waiting $(Format-WaitTime -totalSeconds $waitTime) for reset..." -logToSummary $true
                            Start-Sleep -Seconds $waitTime
                            
                            # Move to next app after waiting
                            $tokenManager.MoveToNextApp()
                            continue
                        }
                    }
                }
            } catch {
                Write-Host "Warning: Could not check rate limits before processing: $($_.Exception.Message)"
            }
            
            # Run the semver check with PassThru to get detailed results
            Write-Host "Running Test-GitHubActionVersioning for $repository..."
            
            $checkResult = Test-GitHubActionVersioning `
                -Repository $repository `
                -Token $token `
                -CheckMinorVersion "none" `
                -PassThru `
                -ErrorAction SilentlyContinue `
                -WarningAction SilentlyContinue
            
            if ($checkResult) {
                $result.Success = ($checkResult.ReturnCode -eq 0)
                $result.Output = "Return Code: $($checkResult.ReturnCode), Fixed: $($checkResult.FixedCount), Failed: $($checkResult.FailedCount), Unfixable: $($checkResult.UnfixableCount)"
                
                # Capture issues
                if ($checkResult.Issues) {
                    foreach ($issue in $checkResult.Issues) {
                        $result.Issues += @{
                            Severity = $issue.Severity
                            Message = $issue.Message
                            Status = $issue.Status
                        }
                    }
                }
                
                Write-Host "Result: $($result.Output)"
                Write-Host "Issues found: $($result.Issues.Count)"
            } else {
                $result.Error = "No result returned from Test-GitHubActionVersioning"
                Write-Host "Warning: No result returned"
            }
            
            # Move to next app for the next action to distribute load across GitHub Apps
            $tokenManager.MoveToNextApp()
            
            # Add wait time between repo processing to reduce rate limit pressure
            if ($waitBetweenReposSeconds -gt 0) {
                Write-Host "Waiting $waitBetweenReposSeconds seconds before next repository..."
                Start-Sleep -Seconds $waitBetweenReposSeconds
            }
            
            # Success - break out of retry loop
            break
            
        } catch {
            $errorMessage = $_.Exception.Message
            $result.Error = $errorMessage
            
            # Check if this is a rate limit error
            if ($errorMessage -match "rate limit exceeded|HTTP 403|429") {
                $result.RateLimited = $true
                Write-Host "⚠️ Rate limit error detected: $errorMessage"
                
                # Log detailed rate limit info
                Write-Host "Logging detailed rate limit information..."
                try {
                    $tokenResult = $tokenManager.GetTokenForOrganization($env:APP_ORGANIZATION)
                    if ($tokenResult -and $tokenResult.Token) {
                        Write-DetailedRateLimitInfo -access_token $tokenResult.Token -title "Rate Limit Info After Error for $repository"
                    }
                } catch {
                    Write-Host "Could not retrieve detailed rate limit info: $($_.Exception.Message)"
                }
                
                # Retry logic for rate limit errors
                if ($retryCount -lt $maxRetries) {
                    $retryCount++
                    $backoffSeconds = [math]::Pow(2, $retryCount) * 30 # 60s, 120s, 240s
                    Write-Host "Retry attempt $retryCount of $maxRetries. Backing off for $backoffSeconds seconds..."
                    Write-Message -message "⏱️ Rate limit hit for $repository. Retry $retryCount/$maxRetries after $(Format-WaitTime -totalSeconds $backoffSeconds)" -logToSummary $true
                    Start-Sleep -Seconds $backoffSeconds
                    
                    # Move to next app before retry
                    $tokenManager.MoveToNextApp()
                    continue
                } else {
                    Write-Host "Max retries reached for rate limit errors"
                    Write-Message -message "❌ Max retries reached for $repository due to rate limits" -logToSummary $true
                    
                    # Move to next app after exhausting retries
                    $tokenManager.MoveToNextApp()
                    break
                }
            } else {
                # Non-rate-limit error - don't retry
                Write-Host "Error: $errorMessage"
                break
            }
        }
    }
    
    return $result
}

function Get-IssueType {
    Param (
        [Parameter(Mandatory = $true)]
        [string]$message
    )
    
    # Extract short issue type from message
    # Order matters - check more specific patterns first
    if ($message -match "not immutable|immutability") {
        return "Not Immutable"
    } elseif ($message -match "tag.*(is\s+)?missing|missing.*tag|(major|minor|patch)\s+version\s+tag\s+missing") {
        # Captures "Tag v1 is missing", "Major version tag missing", etc.
        if ($message -match "major") {
            return "Missing MAJ Tag"
        } elseif ($message -match "minor") {
            return "Missing MIN Tag"
        } elseif ($message -match "patch") {
            return "Missing PAT Tag"
        }
        return "Missing Tag"
    } elseif ($message -match "incorrect\s+SHA|SHA\s+mismatch") {
        return "Incorrect SHA"
    } elseif ($message -match "may\s+be\s+outdated|outdated") {
        return "Outdated"
    } elseif ($message -match "inconsistent\s+format|format\s+could\s+be\s+improved|bad\s+format") {
        return "Format Issue"
    } elseif ($message -match "not\s+found") {
        return "Not Found"
    } elseif ($message -match "invalid|incorrect") {
        return "Invalid"
    } else {
        # Return the full message as-is for unrecognized patterns
        return $message
    }
}

function Write-SummaryReport {
    Param (
        [Parameter(Mandatory = $true)]
        $results
    )
    
    Write-Host ""
    Write-Host "Writing summary report to GITHUB_STEP_SUMMARY"
    
    # Summary header
    Write-Message -message "# Semver Checker Results" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "## Summary" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "- **Total Actions Checked**: $($results.Count)" -logToSummary $true
    Write-Message -message "- **Actions Without Issues**: $(@($results | Where-Object { $_.Success -and $_.Issues.Count -eq 0 }).Count)" -logToSummary $true
    Write-Message -message "- **Actions With Issues**: $(@($results | Where-Object { $_.Issues.Count -gt 0 }).Count)" -logToSummary $true
    Write-Message -message "- **Actions With Errors**: $(@($results | Where-Object { $_.Error -and -not $_.RateLimited }).Count)" -logToSummary $true
    Write-Message -message "- **Actions Rate Limited**: $(@($results | Where-Object { $_.RateLimited }).Count)" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Add overall statistics table
    $totalRepos = $results.Count
    $reposWithoutIssues = @($results | Where-Object { $_.Success -and $_.Issues.Count -eq 0 }).Count
    $reposWithIssues = @($results | Where-Object { $_.Issues.Count -gt 0 }).Count
    $reposWithMoreThan5Issues = @($results | Where-Object { $_.Issues.Count -gt 5 }).Count
    
    Write-Message -message "## Overall Statistics" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "| Status | Count | Percentage |" -logToSummary $true
    Write-Message -message "|--------|-------|------------|" -logToSummary $true
    
    if ($totalRepos -gt 0) {
        $percentWithIssues = [math]::Round(($reposWithIssues / $totalRepos) * 100, 2)
        $percentWithoutIssues = [math]::Round(($reposWithoutIssues / $totalRepos) * 100, 2)
        $percentWithMoreThan5 = [math]::Round(($reposWithMoreThan5Issues / $totalRepos) * 100, 2)
        
        # Format percentages - remove trailing zeros and decimal point if whole number
        $percentWithIssuesFormatted = if ($percentWithIssues -eq [math]::Floor($percentWithIssues)) { [int]$percentWithIssues } else { $percentWithIssues }
        $percentWithoutIssuesFormatted = if ($percentWithoutIssues -eq [math]::Floor($percentWithoutIssues)) { [int]$percentWithoutIssues } else { $percentWithoutIssues }
        $percentWithMoreThan5Formatted = if ($percentWithMoreThan5 -eq [math]::Floor($percentWithMoreThan5)) { [int]$percentWithMoreThan5 } else { $percentWithMoreThan5 }
        
        Write-Message -message "| Repos with issues | $reposWithIssues | $percentWithIssuesFormatted% |" -logToSummary $true
        Write-Message -message "| Repos without issues | $reposWithoutIssues | $percentWithoutIssuesFormatted% |" -logToSummary $true
        Write-Message -message "| Repos with more than 5 issues | $reposWithMoreThan5Issues | $percentWithMoreThan5Formatted% |" -logToSummary $true
    } else {
        Write-Message -message "| Repos with issues | 0 | 0% |" -logToSummary $true
        Write-Message -message "| Repos without issues | 0 | 0% |" -logToSummary $true
        Write-Message -message "| Repos with more than 5 issues | 0 | 0% |" -logToSummary $true
    }
    Write-Message -message "" -logToSummary $true
    
    # Build issue counters table
    $actionsWithIssues = $results | Where-Object { $_.Issues.Count -gt 0 }
    if ($actionsWithIssues.Count -gt 0) {
        Write-Message -message "## Issue Summary by Repository" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        
        # Sort by Dependents column (descending), treating null/N/A as 0 for sorting
        $actionsWithIssuesSorted = $actionsWithIssues | Sort-Object -Property {
            if ($null -eq $_.Dependents -or $_.Dependents -eq "N/A") {
                0
            } else {
                # Remove commas and spaces, then convert to int for proper numeric sorting
                [int]($_.Dependents -replace '[,\s]', '')
            }
        } -Descending
        
        # Create simple table header with Dependents column
        Write-Message -message "| Repository | Total Issues | Issue Types | Dependents |" -logToSummary $true
        Write-Message -message "|------------|-------------|-------------|------------|" -logToSummary $true
        
        # Process each action with issues
        foreach ($action in $actionsWithIssuesSorted) {
            # Collect unique issue types
            $issueTypes = @{}
            foreach ($issue in $action.Issues) {
                $type = Get-IssueType -message $issue.Message
                if ($issueTypes.ContainsKey($type)) {
                    $issueTypes[$type]++
                } else {
                    $issueTypes[$type] = 1
                }
            }
            
            # Format issue types with counts
            $issueTypesFormatted = ($issueTypes.GetEnumerator() | ForEach-Object {
                if ($_.Value -gt 1) {
                    "$($_.Key) ($($_.Value))"
                } else {
                    $_.Key
                }
            }) -join ", "
            
            # Get dependents count if available
            $dependentsCount = if ($action.Dependents) { $action.Dependents } else { "N/A" }
            
            $totalIssues = $action.Issues.Count
            Write-Message -message "| $($action.Repository) | $totalIssues | $issueTypesFormatted | $dependentsCount |" -logToSummary $true
        }
        Write-Message -message "" -logToSummary $true
    }
    
    # Actions without issues
    $cleanActions = $results | Where-Object { $_.Success -and $_.Issues.Count -eq 0 }
    if ($cleanActions.Count -gt 0) {
        Write-Message -message "## ✅ Actions Without Issues" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        foreach ($action in $cleanActions) {
            Write-Message -message "- **$($action.Repository)**: All semver checks passed" -logToSummary $true
        }
        Write-Message -message "" -logToSummary $true
    }
    
    # Actions with issues - detailed view
    if ($actionsWithIssues.Count -gt 0) {
        Write-Message -message "## ⚠️ Detailed Issue Information" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        foreach ($action in $actionsWithIssues) {
            Write-Message -message "<details>" -logToSummary $true
            Write-Message -message "<summary><b>$($action.Repository)</b> - $($action.Issues.Count) issue(s)</summary>" -logToSummary $true
            Write-Message -message "" -logToSummary $true
            Write-Message -message "**Status**: $($action.Output)" -logToSummary $true
            Write-Message -message "" -logToSummary $true
            
            if ($action.Issues.Count -gt 0) {
                Write-Message -message "**Issues**:" -logToSummary $true
                foreach ($issue in $action.Issues) {
                    $icon = if ($issue.Severity -eq "error") { "❌" } else { "⚠️" }
                    Write-Message -message "- $icon **$($issue.Severity)**: $($issue.Message) [Status: $($issue.Status)]" -logToSummary $true
                }
            }
            Write-Message -message "" -logToSummary $true
            Write-Message -message "</details>" -logToSummary $true
            Write-Message -message "" -logToSummary $true
        }
    }
    
    # Actions with rate limit errors
    $rateLimitedActions = $results | Where-Object { $_.RateLimited }
    if ($rateLimitedActions.Count -gt 0) {
        Write-Message -message "## 🚦 Actions Rate Limited" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        Write-Message -message "_These actions could not be checked due to GitHub API rate limits. They will be checked in the next run._" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        foreach ($action in $rateLimitedActions) {
            Write-Message -message "- **$($action.Repository)**: $($action.Error)" -logToSummary $true
        }
        Write-Message -message "" -logToSummary $true
    }
    
    # Actions with other errors
    $actionsWithErrors = $results | Where-Object { $_.Error -and -not $_.RateLimited }
    if ($actionsWithErrors.Count -gt 0) {
        Write-Message -message "## ❌ Actions With Errors" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        foreach ($action in $actionsWithErrors) {
            Write-Message -message "- **$($action.Repository)**: $($action.Error)" -logToSummary $true
        }
    }
}

function Save-ResultsAsJson {
    Param (
        [Parameter(Mandatory = $true)]
        $results
    )
    
    $outputFile = "semver-check-results.json"
    Write-Host "Saving results to: $outputFile"
    
    $results | ConvertTo-Json -Depth 10 | Out-File -FilePath $outputFile -Encoding utf8
    
    Write-Host "Results saved successfully"
}

# Main execution
try {
    # Load actions from status.json
    Write-Host "Loading status.json..."
    if (-not (Test-Path "status.json")) {
        Write-Error "status.json not found. Please download it from blob storage first."
        exit 1
    }
    
    # Clean BOM if present before parsing JSON
    $jsonContent = Get-Content status.json -Raw
    $jsonContent = $jsonContent -replace '^\uFEFF', ''  # Remove UTF-8 BOM (Unicode)
    $actions = $jsonContent | ConvertFrom-Json
    
    Write-Host "Loaded $($actions.Count) actions from status.json"
    
    # Select top actions
    $topActions = Select-TopActions -actions $actions -count $topActionsCount
    
    if ($topActions.Count -eq 0) {
        Write-Error "No actions selected for checking"
        exit 1
    }
    
    # Install semver checker module
    $moduleInstalled = Install-SemverCheckerModule
    if (-not $moduleInstalled) {
        Write-Error "Failed to install GitHubActionVersioning module"
        exit 1
    }
    
    # Get GitHub App token manager (we'll get fresh tokens for each action)
    Write-Host "Initializing GitHub App token manager..."
    $tokenManager = Get-GitHubAppTokenManagerInstance
    if ($null -eq $tokenManager) {
        Write-Error "Failed to initialize GitHub App token manager"
        exit 1
    }
    
    Write-Host "Token manager initialized successfully"
    
    # Run semver checks for each action
    Write-Host ""
    Write-Host "Starting semver checks for $($topActions.Count) actions..."
    Write-Host "Wait time between repos: $waitBetweenReposSeconds seconds"
    
    foreach ($action in $topActions) {
        $checkResult = Test-ActionSemver -action $action -tokenManager $tokenManager -waitBetweenReposSeconds $waitBetweenReposSeconds
        $script:results += $checkResult
    }
    
    # Save results
    Save-ResultsAsJson -results $script:results
    
    # Write summary report
    Write-SummaryReport -results $script:results
    
    Write-Host ""
    Write-Host "Semver check workflow completed successfully"
    
} catch {
    Write-Host "Error in main execution: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    exit 1
}
