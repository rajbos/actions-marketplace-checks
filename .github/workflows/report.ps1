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
$unknownActionType = 0

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
        # actionType
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
        elseif ($action.actionType.actionType -eq "Composite") {
            $compositeAction++
        }
        elseif ($action.actionType.actionType -eq "Unkown"){
            $unknownActionType++
        }

        # action definition sort
        if ($action.actionType.fileFound -eq "action.yml") {
            $actionYmlFile++
        }
        elseif ($action.actionType.fileFound -eq "action.yaml") {
            $actionYamlFile++
        }
        elseif ($action.actionType.fileFound -eq "Dockerfile") {
            $actionDockerFile++
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

LogMessage "| Type                  | Count           |"
LogMessage "|---|---|"
LogMessage "| Total high alerts     | $highAlerts     |"
LogMessage "| Total critical alerts | $criticalAlerts |"
LogMessage ""
LogMessage "| Maximum number of alerts per repo | Count              |"
LogMessage "|---|---|"
LogMessage "| High alerts                       | $maxHighAlerts     |"
LogMessage "| Critical alerts                   | $maxCriticalAlerts |"
LogMessage ""
LogMessage "| Average number of alerts per vuln. repo | Count              |"
LogMessage "|---|---|"
LogMessage "| High alerts per vulnerable repo         | $([math]::Round($averageHighAlerts, 1))|"
LogMessage "| Critical alerts per vulnerable repo     | $([math]::Round($averageCriticalAlerts, 1))|"

function ReportVulnChartInMarkdown {
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

function ReportInsightsInMarkdown {
    if (!$logSummary) {
        # do not report locally
        return
    }

    LogMessage "## Action type"
    LogMessage "``````mermaid"
    LogMessage "flowchart LR"
    LogMessage "  A[$reposAnalyzed Actions]-->B[$nodeBasedActions Node based]"
    LogMessage "  A-->C[$dockerBasedActions Docker based]"
    LogMessage "  A-->D[$compositeAction Composite actions]"
    LogMessage "  C-->E[$localDockerFile Local Dockerfile]"
    LogMessage "  C-->F[$remoteDockerfileRemote image]"
    LogMessage "``````"
    LogMessage ""
    LogMessage "## Action definition setup"
    LogMessage "``````mermaid"
    LogMessage "flowchart LR"
    LogMessage "  A[$reposAnalyzed Actions]-->B[$actionYmlFile]"
    LogMessage "  A-->C[$actionYamlFile]"
    LogMessage "  A-->D[$actionDockerFile]"
    LogMessage "``````"
}

# call the report function
ReportVulnChartInMarkdown


LogMessage ""
LogMessage "## General information"

LogMessage "|Action type|Count|"
LogMessage "|---|---|"
LogMessage "|Node based actions   | $nodeBasedActions  |"
LogMessage "|Docker based actions | $dockerBasedActions|"
LogMessage "|Composite actions    | $compositeAction   |"
LogMessage "|Unkown action type   | $unknownActionType |"
LogMessage ""
LogMessage "|Docker definition method| Count            |"
LogMessage "|---|---|"
LogMessage "|Local Dockerfile        | $localDockerFile |"
LogMessage "|Remote image            | $remoteDockerfile|"
LogMessage ""
LogMessage "Actions defined as:"
LogMessage ""
LogMessage "|File name      | Count            |"
LogMessage "|---|---|"
LogMessage "|``action.yml`` | $actionYmlFile   |"
LogMessage "|``action.yaml``| $actionYamlFile  |"
LogMessage "|``Dockerfile`` | $actionDockerFile|"

ReportInsightsInMarkdown