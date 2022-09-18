Param (
  $actions,
  $logSummary
)

Write-Host "Found [$($actions.Count)] actions to report on"
Write-Host "Log summary path: [$logSummary]"

$global:highAlerts = 0
$global:criticalAlerts = 0
$global:vulnerableRepos = 0
$global:maxHighAlerts = 0
$global:maxCriticalAlerts = 0
$global:reposAnalyzed = 0

$nodeBasedActions = 0
$dockerBasedActions = 0
$localDockerFile = 0
$remoteDockerfile = 0
$actionYmlFile = 0
$actionYamlFile = 0
$actionDockerFile = 0
$compositeAction = 0
$unknownActionType = 

function GetVulnerableIfo {
    Param (
        $action
    )
    if ($action.vulnerabilityStatus) {
        $global:reposAnalyzed++
        if ($action.vulnerabilityStatus.high -gt 0) {
            $global:highAlerts++

            if ($action.vulnerabilityStatus.high -gt $maxHighAlerts) {
                $global:maxHighAlerts = $action.vulnerabilityStatus.high
            }
        }

        if ($action.vulnerabilityStatus.critical -gt 0) {
            $global:criticalAlerts++

            if ($action.vulnerabilityStatus.critical -gt $maxCriticalAlerts) {
                $global:maxCriticalAlerts = $action.vulnerabilityStatus.critical
            }
        }

        if ($action.vulnerabilityStatus.critical -gt 0 -or $action.vulnerabilityStatus.high -gt 0) {
            $global:vulnerableRepos++
        }

        if ($action.vulnerabilityStatus.critical + $action.vulnerabilityStatus.high -gt 10) {
            "https://github.com/actions-marketplace-validations/$($action.name) Critical: $($action.vulnerabilityStatus.critical) High: $($action.vulnerabilityStatus.high)" | Out-File -FilePath VulnerableRepos.txt -Append
        }
    }
}

foreach ($action in $actions) {
        
    GetVulnerableIfo $action

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
        elseif (($action.actionType.actionType -eq "Unkown") -or ($null -eq $action.actionType.actionType)){
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
    else {
        $unknownActionType++
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
function VulnerabilityCalculations {
    $averageHighAlerts = 0
    $averageCriticalAlerts = 0
    if ($reposAnalyzed -eq 0) {
        Write-Error "No repos analyzed"        
    } 
    else {
        $averageHighAlerts = $global:highAlerts / $global:reposAnalyzed
        $averageCriticalAlerts = $global:criticalAlerts / $global:reposAnalyzed
    }

    Write-Host "Summary: "
    LogMessage "## Potentially vulnerable Repos: $vulnerableRepos out of $reposAnalyzed analyzed repos [Total: $($actions.Count)]"

    LogMessage "| Type                  | Count           |"
    LogMessage "|---|---|"
    LogMessage "| Total high alerts     | $($global:highAlerts)     |"
    LogMessage "| Total critical alerts | $($global:criticalAlerts) |"
    LogMessage ""
    LogMessage "| Maximum number of alerts per repo | Count              |"
    LogMessage "|---|---|"
    LogMessage "| High alerts                       | $($global:maxHighAlerts)     |"
    LogMessage "| Critical alerts                   | $($global:maxCriticalAlerts) |"
    LogMessage ""
    LogMessage "| Average number of alerts per vuln. repo | Count              |"
    LogMessage "|---|---|"
    LogMessage "| High alerts per vulnerable repo         | $([math]::Round($averageHighAlerts, 1))|"
    LogMessage "| Critical alerts per vulnerable repo     | $([math]::Round($averageCriticalAlerts, 1))|"
}

function ReportVulnChartInMarkdown {
    Param (
        $chartTitle,
        $actions
    )
    if (!$logSummary) {
        # do not report locally
        return
    }

    Write-Host "Writing chart [$chartTitle] with information about [$($actions.Count)] actions and [$global:reposAnalyzed] reposAnalyzed"

    LogMessage ""
    LogMessage "``````mermaid"
    LogMessage "%%{init: {'theme':'dark', 'themeVariables': { 'darkMode':'true','primaryColor': '#000000', 'pie1':'#686362', 'pie2':'#d35130' }}}%%"
    LogMessage "pie title Potentially vulnerable $chartTitle"
    LogMessage "    ""Unknown: $($actions.Count - $global:reposAnalyzed)"" : $($actions.Count - $global:reposAnalyzed)"
    LogMessage "    ""Vulnerable actions: $($global:vulnerableRepos)"" : $($global:vulnerableRepos)"
    LogMessage "    ""Non vulnerable actions: $($global:reposAnalyzed - $global:vulnerableRepos)"" : $($global:reposAnalyzed - $global:vulnerableRepos)"
    LogMessage "``````"
}

function ReportInsightsInMarkdown {
    if (!$logSummary) {
        # do not report locally
        return
    }

    LogMessage "## Action type"
    LogMessage "Action type is determined by the action definition file and can be either Node (JavaScript/TypeScript) or Docker based, or it can be a composite action. A remote image means it is pulled directly from a container registry, instead of a local file."
    LogMessage "``````mermaid"
    LogMessage "flowchart LR"
    LogMessage "  A[$reposAnalyzed Actions]-->B[$nodeBasedActions Node based]"
    LogMessage "  A-->C[$dockerBasedActions Docker based]"
    LogMessage "  A-->D[$compositeAction Composite actions]"
    LogMessage "  C-->E[$localDockerFile Local Dockerfile]"
    LogMessage "  C-->F[$remoteDockerfile Remote image]"
    LogMessage "  A-->G[$unknownActionType Unknown]"
    LogMessage "``````"
    LogMessage ""
    LogMessage "## Action definition setup"
    LogMessage "How is the action defined? The runner can pick it up from these files in the root of the repo: action.yml, action.yaml, or Dockerfile. The Dockerfile can also be referened from the action definition file. If that is the case, it will show up as one of those two files in this overview."
    LogMessage "``````mermaid"
    LogMessage "flowchart LR"
    $ymlPercentage = [math]::Round($actionYmlFile/$reposAnalyzed * 100 , 1)
    LogMessage "  A[$reposAnalyzed Actions]-->B[$actionYmlFile action.yml - $ymlPercentage%]"
    $yamlPercentage = [math]::Round($actionYamlFile/$reposAnalyzed * 100 , 1)
    LogMessage "  A-->C[$actionYamlFile action.yaml - $yamlPercentage%]"
    $dockerPercentage = [math]::Round($actionDockerFile/$reposAnalyzed * 100 , 1)
    LogMessage "  A-->D[$actionDockerFile Dockerfile - $dockerPercentage%]"
    $unknownActionDefinitionCount = $reposAnalyzed - $actionYmlFile - $actionYamlFile - $actionDockerFile
    $unknownActionPercentage = [math]::Round($unknownActionDefinitionCount/$reposAnalyzed * 100 , 1)
    LogMessage "  A-->E[$unknownActionDefinitionCount Unknown - $unknownActionPercentage%]"
    LogMessage "``````"
}

# call the report function
VulnerabilityCalculations
ReportVulnChartInMarkdown -chartTitle "actions"  -actions $actions

LogMessage ""

ReportInsightsInMarkdown

# reset everything for just the Node actions
$global:highAlerts = 0
$global:criticalAlerts = 0
$global:vulnerableRepos = 0
$global:maxHighAlerts = 0
$global:maxCriticalAlerts = 0
$global:reposAnalyzed = 0
$nodeBasedActions = $actions | Where-Object {($null -ne $_.actionType) -and ($_.actionType.actionType -eq "Node")}
foreach ($action in $nodeBasedActions) {        
    GetVulnerableIfo $action
}
ReportVulnChartInMarkdown -chartTitle "Node actions" -actions $nodeBasedActions


# reset everything for just the Composite actions
$global:highAlerts = 0
$global:criticalAlerts = 0
$global:vulnerableRepos = 0
$global:maxHighAlerts = 0
$global:maxCriticalAlerts = 0
$global:reposAnalyzed = 0
$compositeActions = $actions | Where-Object {($null -ne $_.actionType) -and ($_.actionType.actionType -eq "Composite")}
foreach ($action in $compositeActions) {        
    GetVulnerableIfo $action
}
ReportVulnChartInMarkdown -chartTitle "Composite actions"  -actions $compositeActions
