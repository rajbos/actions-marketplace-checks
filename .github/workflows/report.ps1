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

$global:nodeBasedActions = 0
$global:dockerBasedActions = 0
$global:localDockerFile = 0
$global:remoteDockerfile = 0
$global:actionYmlFile = 0
$global:actionYamlFile = 0
$global:actionDockerFile = 0
$global:compositeAction = 0
$global:unknownActionType = 0
$global:repoInfo = 0
# store current datetime
$global:oldestRepo = Get-Date
$global:updatedLastMonth = 0
$global:updatedLastQuarter = 0
$global:updatedLast6Months = 0
$global:updatedLast12Months = 0
$global:moreThen12Months = 0
$global:sumDaysOld = 0
$global:archived = 0

function GetVulnerableIfo {
    Param (
        $action,
        $actionType
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
            "https://github.com/actions-marketplace-validations/$($action.name) Critical: $($action.vulnerabilityStatus.critical) High: $($action.vulnerabilityStatus.high)" | Out-File -FilePath VulnerableRepos-$actionType.txt -Append
        }
    }
}

function AnalyzeActionInformation {
    Param (
        $actions
    )

    # analyze action type, definition and age
    foreach ($action in $actions) {
            
        GetVulnerableIfo -action $action -actionType "Any"

        if ($action.actionType) {
            # actionType
            if ($action.actionType.actionType -eq "Docker") {
                $global:dockerBasedActions++
                if ($action.actionType.actionDockerType -eq "Dockerfile") {
                    $global:localDockerFile++
                }
                elseif ($action.actionType.actionDockerType -eq "Image") {
                    $global:remoteDockerfile++
                }
            }
            elseif ($action.actionType.actionType -eq "Node") {
                $global:nodeBasedActions++
            }        
            elseif ($action.actionType.actionType -eq "Composite") {
                $global:compositeAction++
            }
            elseif (($action.actionType.actionType -eq "Unkown") -or ($null -eq $action.actionType.actionType)){
                $global:unknownActionType++
            }

            # action definition sort
            if ($action.actionType.fileFound -eq "action.yml") {
                $global:actionYmlFile++
            }
            elseif ($action.actionType.fileFound -eq "action.yaml") {
                $global:actionYamlFile++
            }
            elseif ($action.actionType.fileFound -eq "Dockerfile") {
                $global:actionDockerFile++
            }
        }
        else {
            $unknownActionType++
        }

        if ($action.repoInfo -And $action.repoInfo.updated_at ) {
            $global:repoInfo++

            if ($action.repoInfo.updated_at -lt $oldestRepo) {
                $global:oldestRepo = $action.repoInfo.updated_at
            }

            if ($action.repoInfo.updated_at -gt (Get-Date).AddMonths(-1)) {
                $global:updatedLastMonth++
            }
            elseif ($action.repoInfo.updated_at -gt (Get-Date).AddMonths(-3)) {
                $global:updatedLastQuarter++
            } 
            elseif ($action.repoInfo.updated_at -gt (Get-Date).AddMonths(-6)) {
                $global:updatedLast6Months++
            }
            elseif ($action.repoInfo.updated_at -gt (Get-Date).AddMonths(-12)) {
                $global:updatedLast12Months++
            }
            else {
                $global:moreThen12Months++
            }

            $global:sumDaysOld += ((Get-Date) - $action.repoInfo.updated_at).Days

            if ($action.repoInfo.archived) {
                $global:archived++
            }
        }
    }
}

function GetTagReleaseInfo {
    $tagButNoRelease = 0
    $tagInfo = 0
    $releaseInfo = 0
    $countMismatch = 0
    foreach ($action in $actions) {
        if ($action.tagInfo) {
            $tagInfo++
            if (!$action.releaseInfo) {
                $tagButNoRelease++
            }
            else {                
                $releaseInfo++

                $tagCount = 0
                if ($action.tagInfo.GetType().FullName -eq "System.Object[]") {
                    $tagCount = $action.tagInfo.Count
                }
                elseif ($null -ne $action.tagInfo) {
                    $tagCount = 1
                }

                $releaseCount = 0
                if ($action.releaseInfo.GetType().FullName -eq "System.Object[]") {
                    $releaseCount = $action.releaseInfo.Count
                }
                elseif ($null -ne $action.releaseInfo.Length) {
                    $releaseCount = 1
                }

                if (($tagCount -gt 0) -And ($releaseCount -gt 0)) {
                    if ($tagCount -ne $releaseCount) {
                        $countMismatch++
                    }
                }
            }
        }
    }

    Write-Host ""
    Write-Host "Total actions: $($actions.Count) with $tagInfo tags and $releaseInfo release information"
    Write-Host "Repos with tag info but no releases: $tagButNoRelease"
    Write-Host "Repos with mismatches between tag and release count: $countMismatch"
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
    $ymlPercentage = [math]::Round($global:actionYmlFile/$global:reposAnalyzed * 100 , 1)
    LogMessage "  A[$reposAnalyzed Actions]-->B[$actionYmlFile action.yml - $ymlPercentage%]"
    $yamlPercentage = [math]::Round($global:actionYamlFile/$global:reposAnalyzed * 100 , 1)
    LogMessage "  A-->C[$actionYamlFile action.yaml - $yamlPercentage%]"
    $dockerPercentage = [math]::Round($globafix el:actionDockerFile/$global:reposAnalyzed * 100 , 1)
    LogMessage "  A-->D[$actionDockerFile Dockerfile - $dockerPercentage%]"
    $unknownActionDefinitionCount = $global:reposAnalyzed - $global:actionYmlFile - $global:actionYamlFile - $global:actionDockerFile
    $unknownActionPercentage = [math]::Round($global:unknownActionDefinitionCount/$global:reposAnalyzed * 100 , 1)
    LogMessage "  A-->E[$unknownActionDefinitionCount Unknown - $unknownActionPercentage%]"
    LogMessage "``````"
}

function ReportAgeInsights {
    LogMessage "## Repo age"
    LogMessage "How recent where the repos updated? Determined by looking at the last updated date."
    LogMessage "|Analyzed|Total: $repoInfo|Analyzed: $reposAnalyzed repos|100%|"
    LogMessage "|---|---|---|---|"
    $timeSpan = New-TimeSpan –Start $oldestRepo –End (Get-Date)
    LogMessage "|Oldest repository             |$($timeSpan.Days) days old            |||"
    LogMessage "|Updated last month             | $global:updatedLastMonth   |$global:repoInfo repos |$([math]::Round($global:updatedLastMonth   /$global:repoInfo * 100 , 1))%|"
    LogMessage "|Updated within last 3 months   | $global:updatedLastQuarter |$global:repoInfo repos |$([math]::Round($global:updatedLastQuarter /$global:repoInfo * 100 , 1))%|"
    LogMessage "|Updated within last 3-6 months | $global:updatedLast6Months |$global:repoInfo repos |$([math]::Round($global:updatedLast6Months /$global:repoInfo * 100 , 1))%|"
    LogMessage "|Updated within last 6-12 months| $global:updatedLast12Months|$global:repoInfo repos |$([math]::Round($global:updatedLast12Months/$global:repoInfo * 100 , 1))%|"
    LogMessage "|Updated more then 12 months ago| $global:moreThen12Months   |$global:repoInfo repos |$([math]::Round($global:moreThen12Months   /$global:repoInfo * 100 , 1))%|"
    LogMessage ""
    LogMessage "Average age: $([math]::Round($global:sumDaysOld / $global:repoInfo, 1)) days"
    LogMessage "Archived repos: $global:archived"

}

# call the report functions
AnalyzeActionInformation
ReportAgeInsights
LogMessage ""

ReportInsightsInMarkdown
VulnerabilityCalculations
ReportVulnChartInMarkdown -chartTitle "actions"  -actions $actions


# reset everything for just the Node actions
$global:highAlerts = 0
$global:criticalAlerts = 0
$global:vulnerableRepos = 0
$global:maxHighAlerts = 0
$global:maxCriticalAlerts = 0
$global:reposAnalyzed = 0
$nodeBasedActions = $actions | Where-Object {($null -ne $_.actionType) -and ($_.actionType.actionType -eq "Node")}
foreach ($action in $nodeBasedActions) {        
    GetVulnerableIfo -action $action -actionType "Node"
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
    GetVulnerableIfo -action $action -actionType "Composite"
}
ReportVulnChartInMarkdown -chartTitle "Composite actions"  -actions $compositeActions

GetTagReleaseInfo
