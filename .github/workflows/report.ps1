Param (
  $actions,
  $logSummary
)

Write-Host "Found [$($actions.Count)] actions to report on"
Write-Host "Log summary path: [$logSummary]"

$highAlerts = 0
$criticalAlerts = 0
$vulnerableRepos = 0
$maxHighAlerts = 0
$maxCriticalAlerts = 0
$reposAnalyzed = 0
foreach ($action in $actions) {
        
    if ($action.vulnerabilityStatus) {
        $reposAnalyzed++
        if ($action.vulnerabilityStatus.high -gt 0) {
            $highAlerts++

            if ($action.vulnerabilityStatus.high -gt $maxHighAlerts) {
                $maxHighAlerts = $action.vulnerabilityStatus.high
            }
        }

        if ($action.vulnerabilityStatus.critical -gt 0) {
            $criticalAlerts++

            if ($action.vulnerabilityStatus.critical -gt $maxCriticalAlerts) {
                $maxCriticalAlerts = $action.vulnerabilityStatus.critical
            }
        }

        if ($action.vulnerabilityStatus.critical -gt 0 -or $action.vulnerabilityStatus.high -gt 0) {
            $vulnerableRepos++
        }

        if ($action.vulnerabilityStatus.critical + $action.vulnerabilityStatus.high -gt 10) {
            "https://github.com/actions-marketplace-validations/$($action.name)" | Out-File -FilePath VulnerableRepos.txt -Append
        }   


    }
}

function LogMessage {
    Param (
        $message
    )

    Write-Host $message 
    if ($logSummary) {
        $message | Out-File $logSummary -Append
    }
}

# calculations
$averageHighAlerts = $highAlerts / $reposAnalyzed
$averageCriticalAlerts = $criticalAlerts / $reposAnalyzed

Write-Host "Summary: "
LogMessage "# Vulnerable Repos: $vulnerableRepos out of $reposAnalyzed analyzed repos"
LogMessage "-----------------------------------"
LogMessage "High Alerts: $highAlerts"
LogMessage "Critical Alerts: $criticalAlerts"
LogMessage "-----------------------------------"
LogMessage "Max High Alerts: $maxHighAlerts"
LogMessage "Max Critical Alerts: $maxCriticalAlerts"
LogMessage "-----------------------------------"
LogMessage "Average High Alerts per vulnerable repo: $([math]::Round($averageHighAlerts, 1))"
LogMessage "Average Critical Alerts per vulnerable repo: $([math]::Round($averageCriticalAlerts, 1))"

function ReportInMarkdown {
    if (!$logSummary) {
        # do not report locally
        return
    }

    LogMessage ""
    LogMessage "``````mermaid"
    LogMessage "%%{init: {'theme':'dark', 'themeVariables': { 'darkMode':'true','primaryColor': '#000000', 'pie1':'#686362', 'pie2':'#d35130' }}}%%"
    LogMessage "pie title Potentially vulnerable actions"
    LogMessage "    ""Unknown: $($actions.Count - $reposAnalyzed)"" : $($actions.Count - $reposAnalyzed)"
    LogMessage "    ""Vulnerable actions: $($vulnerableRepos)"" : $($vulnerableRepos)"
    LogMessage "``````"
}

# call the report function
ReportInMarkdown