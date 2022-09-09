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

Write-Host "Summary: "
LogMessage "#Vulnerable Repos: $vulnerableRepos out of $reposAnalyzed analyzed repos"
LogMessage "-----------------------------------"
LogMessage "High Alerts: $highAlerts"
LogMessage "Critical Alerts: $criticalAlerts"
LogMessage "-----------------------------------"
LogMessage "Max High Alerts: $maxHighAlerts"
LogMessage "Max Critical Alerts: $maxCriticalAlerts"

function ReportInMarkdown {
    if (!$logSummary) {
        # do not report locally
        #return
    }

    LogMessage ""
    LogMessage "``````mermaid"
    LogMessage "%%{init: {'theme':'dark'}}%%"
    LogMessage "pie title Potentially vulnerable actions"
    LogMessage "    ""Unknown"" : $($actions.Count - $reposAnalyzed)"
    LogMessage "    ""Vulnerable actions"" : $($vulnerableRepos)"
    LogMessage "``````"
}

# call the report function
ReportInMarkdown