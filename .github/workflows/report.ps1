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

$nodeBasedActions = 0
$dockerBasedActions = 0
$localDockerFile = 0
$remoteDockerfile = 0
$actionYmlFile = 0
$actionYamlFile = 0
$actionDockerFile = 0
$compositeAction = 0

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
            "https://github.com/actions-marketplace-validations/$($action.name) Critical: $($action.vulnerabilityStatus.critical) High: $($action.vulnerabilityStatus.high)" | Out-File -FilePath VulnerableRepos.txt -Append
        }
    }

    if ($action.actionType) {
        if ($action.actionType.actionType -eq "Docker") {
            $dockerBasedActions++
            if ($action.actionType.actionDockerType -eq "Dockerfile") {
                $localDockerFile++
            }
            elseif ($action.actionType.actionDockerType -eq "Image") {
                $remoteDockerfile++
            }
        }
        elseif ($action.actionType.actionType -eq "Node") {
            $nodeBasedActions++
        }

        if ($action.actionType.fileFound -eq "action.yml") {
            $actionYmlFile++
        }
        elseif ($action.actionType.fileFound -eq "action.yaml") {
            $actionYamlFile++
        }
        elseif ($action.actionType.fileFound -eq "Dockerfile") {
            $actionDockerFile++
        }
        elseif ($action.actionType.fileFound -eq "Composite") {
            $compositeAction++
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
LogMessage "## Potentially vulnerable Repos: $vulnerableRepos out of $reposAnalyzed analyzed repos [Total: $($actions.Count)]"

LogMessage "Total high alerts: $highAlerts"
LogMessage "Total critical alerts: $criticalAlerts"
LogMessage ""
LogMessage "Max high alerts: $maxHighAlerts"
LogMessage "Max critical alerts: $maxCriticalAlerts"
LogMessage ""
LogMessage "Average high alerts per vulnerable repo: $([math]::Round($averageHighAlerts, 1))"
LogMessage "Average critical alerts per vulnerable repo: $([math]::Round($averageCriticalAlerts, 1))"

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
    LogMessage "    ""Non vulnerable actions: $($reposAnalyzed - $vulnerableRepos)"" : $($reposAnalyzed - $vulnerableRepos)"
    LogMessage "``````"
}

# call the report function
ReportInMarkdown


LogMessage ""
LogMessage "## General information"

LogMessage "Node based actions: $nodeBasedActions"
LogMessage "Docker based actions: $dockerBasedActions"
LogMessage "Composite actions: $compositeAction"
LogMessage ""
LogMessage "Docker actions using a local Dockerfile: $localDockerFile"
LogMessage "Docker actions using a remote image: $remoteDockerfile"
LogMessage ""
LogMessage "Actions defined as:"
LogMessage "* ``action.yml``: $actionYmlFile"
LogMessage "* ``action.yaml``: $actionYamlFile"
LogMessage "* ``Dockerfile``: $actionDockerFile"