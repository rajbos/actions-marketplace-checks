Param (
    [Parameter(Mandatory = $false)]
    [int]$topActionsCount = 5
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
        Write-Host "  - $($action.owner)/$($action.name)"
    }
    
    return $topActions
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
        [string]$token
    )
    
    $repository = "$($action.owner)/$($action.name)"
    Write-Host ""
    Write-Host "====================================="
    Write-Host "Testing: $repository"
    Write-Host "====================================="
    
    $result = @{
        Repository = $repository
        Owner = $action.owner
        Name = $action.name
        Success = $false
        Issues = @()
        Output = ""
        Error = $null
    }
    
    try {
        # Run the semver check with PassThru to get detailed results
        Write-Host "Running Test-GitHubActionVersioning for $repository..."
        
        $checkResult = Test-GitHubActionVersioning `
            -Repository $repository `
            -Token $token `
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
    } catch {
        $result.Error = $_.Exception.Message
        Write-Host "Error: $($result.Error)"
    }
    
    return $result
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
    Write-Message -message "- **Actions Without Issues**: $(($results | Where-Object { $_.Success -and $_.Issues.Count -eq 0 }).Count)" -logToSummary $true
    Write-Message -message "- **Actions With Issues**: $(($results | Where-Object { $_.Issues.Count -gt 0 }).Count)" -logToSummary $true
    Write-Message -message "- **Actions With Errors**: $(($results | Where-Object { $_.Error }).Count)" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
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
    
    # Actions with issues
    $actionsWithIssues = $results | Where-Object { $_.Issues.Count -gt 0 }
    if ($actionsWithIssues.Count -gt 0) {
        Write-Message -message "## ⚠️ Actions With Issues" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        foreach ($action in $actionsWithIssues) {
            Write-Message -message "### $($action.Repository)" -logToSummary $true
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
        }
    }
    
    # Actions with errors
    $actionsWithErrors = $results | Where-Object { $_.Error }
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
    
    # Get GitHub token
    Write-Host "Getting GitHub token..."
    $tokenManager = Get-GitHubAppTokenManagerInstance
    if ($null -eq $tokenManager) {
        Write-Error "Failed to initialize GitHub App token manager"
        exit 1
    }
    
    $tokenResult = $tokenManager.GetTokenForOrganization($env:APP_ORGANIZATION)
    if (-not $tokenResult -or -not $tokenResult.Token) {
        Write-Error "Failed to get GitHub token"
        exit 1
    }
    
    $token = $tokenResult.Token
    Write-Host "Token acquired successfully (length: $($token.Length))"
    
    # Run semver checks for each action
    Write-Host ""
    Write-Host "Starting semver checks for $($topActions.Count) actions..."
    
    foreach ($action in $topActions) {
        $checkResult = Test-ActionSemver -action $action -token $token
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
