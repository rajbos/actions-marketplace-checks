Param (
  $actions,
  $logSummary,
  $access_token_destination = $env:GITHUB_TOKEN
)

Write-Host "Found [$($actions.Count)] actions to report on"
Write-Host "Log summary path: [$logSummary]"
. $PSScriptRoot/library.ps1

class RepoInformation
{
    # Optionally, add attributes to prevent invalid values
    [int]$highAlerts
    [int]$criticalAlerts
    [int]$maxHighAlerts
    [int]$maxCriticalAlerts
    [int]$vulnerableRepos
    [int]$reposAnalyzed

    # constructor that sets all values to 0
    # RepoInformation() {
    #     $this.highAlerts = 0
    #     $this.criticalAlerts = 0
    #  }
}

$global:nodeBasedActions = 0
$global:dockerBasedActions = 0
$global:localDockerFile = 0
$global:remoteDockerfile = 0
$global:actionYmlFile = 0
$global:actionYamlFile = 0
$global:actionDockerFile = 0
$global:actiondDockerFile = 0
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
# string array to hold all used docker base images:
$global:dockerBaseImages = @()
$global:nodeVersions = @()
$global:maxRepoSize = 0
$global:sumRepoSize = 0
$global:countRepoSize = 0
$global:countRepoSizeBiggerThen100Mb = 0
function GetVulnerableInfo {
    Param (
        $action,
        $actionType,
        [repoInformation] $repoInformation
    )
    if ($action.vulnerabilityStatus) {
        $repoInformation.reposAnalyzed++
        if ($action.vulnerabilityStatus.high -gt 0) {
            $repoInformation.highAlerts++

            if ($action.vulnerabilityStatus.high -gt $maxHighAlerts) {
                $repoInformation.maxHighAlerts = $action.vulnerabilityStatus.high
            }
        }

        if ($action.vulnerabilityStatus.critical -gt 0) {
            $repoInformation.criticalAlerts++

            if ($action.vulnerabilityStatus.critical -gt $repoInformation.maxCriticalAlerts) {
                $repoInformation.maxCriticalAlerts = $action.vulnerabilityStatus.critical
            }
        }

        if ($action.vulnerabilityStatus.critical -gt 0 -or $action.vulnerabilityStatus.high -gt 0) {
            $repoInformation.vulnerableRepos++
        }

        if (($action.vulnerabilityStatus.critical + $action.vulnerabilityStatus.high -gt 10) -Or ($action.owner -eq "actions" -and $action.owner -eq "github")) {
            "https://github.com/actions-marketplace-validations/$($action.name) Critical: $($action.vulnerabilityStatus.critical) High: $($action.vulnerabilityStatus.high)" | Out-File -FilePath VulnerableRepos-$actionType.txt -Append
        }
    }
}

function AnalyzeActionInformation {
    Param (
        $actions
    )
    
    $repoInformation = New-Object RepoInformation
    # analyze action type, definition and age
    foreach ($action in $actions) {
            
        GetVulnerableInfo -action $action -actionType "Any" -repoInformation $repoInformation

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

                if ($action.actionType.dockerBaseImage) {
                    $global:dockerBaseImages += $action.actionType.dockerBaseImage
                }
            }
            elseif ($action.actionType.actionType -eq "Node") {
                $global:nodeBasedActions++

                $global:nodeVersions += $action.actionType.nodeVersion
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
            elseif ($action.actionType.fileFound -ceq "Dockerfile") {
                $global:actionDockerFile++
            }
            elseif ($action.actionType.fileFound -ceq "dockerfile") {
                $global:actiondDockerFile++
            }

            if ($action.repoSize) {
                if ($action.repoSize -gt $global:maxRepoSize) {
                    $global:maxRepoSize = $action.repoSize
                }
                $global:sumRepoSize += $action.repoSize
                $global:countRepoSize++

                if (($action.repoSize / 1024) -gt 100) {
                    $global:countRepoSizeBiggerThen100Mb++
                }
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

    return $repoInformation
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
    Param (
        [RepoInformation] $repoInformation,
        [RepoInformation] $github_RepoInformation
    )
    $averageHighAlerts = 0
    $averageCriticalAlerts = 0
    
    if ($repoInformation.reposAnalyzed -eq 0) {
        LogMessage "# No repos analyzed"        
    } 
    else {
        $averageHighAlerts = $repoInformation.highAlerts / $repoInformation.reposAnalyzed
        $averageCriticalAlerts = $repoInformation.criticalAlerts / $repoInformation.reposAnalyzed
    }

    Write-Host "Summary: "
    LogMessage "## Potentially vulnerable Repos: $($repoInformation.vulnerableRepos) out of $($repoInformation.reposAnalyzed) analyzed repos [Total: $($actions.Count)]"

    LogMessage "| Type                  | Count           | GitHub Count |"
    LogMessage "|---|---|---|"
    LogMessage "| Total high alerts     | $($repoInformation.highAlerts)     | $($github_RepoInformation.highAlerts) |"
    LogMessage "| Total critical alerts | $($repoInformation.criticalAlerts) | $($github_RepoInformation.criticalAlerts) |"
    LogMessage ""
    LogMessage "| Maximum number of alerts per repo | Count              |"
    LogMessage "|---|---|"
    LogMessage "| High alerts                       | $($repoInformation.maxHighAlerts)     |"
    LogMessage "| Critical alerts                   | $($repoInformation.maxCriticalAlerts) |"
    LogMessage ""
    LogMessage "| Average number of alerts per vuln. repo | Count              |"
    LogMessage "|---|---|"
    LogMessage "| High alerts per vulnerable repo         | $([math]::Round($averageHighAlerts, 1))|"
    LogMessage "| Critical alerts per vulnerable repo     | $([math]::Round($averageCriticalAlerts, 1))|"
}

function ReportVulnChartInMarkdown {
    Param (
        $chartTitle,
        $actions,
        [RepoInformation] $repoInformation
    )
    if (!$logSummary) {
        # do not report locally
        return
    }

    Write-Host "Writing chart [$chartTitle] with information about [$($actions.Count)] actions and [$($repoInformation.reposAnalyzed)] reposAnalyzed"

    LogMessage ""
    LogMessage "``````mermaid"
    LogMessage "%%{init: {'theme':'dark', 'themeVariables': { 'darkMode':'true','primaryColor': '#000000', 'pie1':'#686362', 'pie2':'#d35130' }}}%%"
    LogMessage "pie title Potentially vulnerable $chartTitle"
    LogMessage "    ""Unknown: $($actions.Count - $repoInformation.reposAnalyzed)"" : $($actions.Count - $repoInformation.reposAnalyzed)"
    LogMessage "    ""Vulnerable actions: $($repoInformation.vulnerableRepos)"" : $($repoInformation.vulnerableRepos)"
    LogMessage "    ""Non vulnerable actions: $($repoInformation.reposAnalyzed - $repoInformation.vulnerableRepos)"" : $($repoInformation.reposAnalyzed - $repoInformation.vulnerableRepos)"
    LogMessage "``````"
}

function GroupNodeVersionsAndCount {
    Param (
        $nodeVersions
    )

    # count items per node version
    $nodeVersionCount = @{}
    foreach ($nodeVersion in $nodeVersions) {
        if ($nodeVersionCount.ContainsKey($nodeVersion)) {
            $nodeVersionCount[$nodeVersion]++
        }
        else {
            $nodeVersionCount.Add($nodeVersion, 1)
        }
    }
    $nodeVersionCount = ($nodeVersionCount.GetEnumerator() | Sort-Object Key)
    return $nodeVersionCount
}

function ReportInsightsInMarkdown {
    param (
        [RepoInformation] $repoInformation
    )
    $nodeVersionCount = GroupNodeVersionsAndCount -nodeVersions $global:nodeVersions

    LogMessage "## Action type"
    LogMessage "Action type is determined by the action definition file and can be either Node (JavaScript/TypeScript) or Docker based, or it can be a composite action. A remote image means it is pulled directly from a container registry, instead of a local file."
    LogMessage "``````mermaid"
    LogMessage "flowchart LR"
    LogMessage "  A[$($repoInformation.reposAnalyzed) Actions]-->B[$nodeBasedActions Node based]"
    LogMessage "  A-->C[$dockerBasedActions Docker based]"
    LogMessage "  A-->D[$compositeAction Composite actions]"
    LogMessage "  C-->E[$localDockerFile Local Dockerfile]"
    LogMessage "  C-->F[$remoteDockerfile Remote image]"
    LogMessage "  A-->G[$unknownActionType Unknown]"
    $currentLetter = 7 # start at H
    foreach ($nodeVersion in $nodeVersionCount) {
        # calculate percentage of node version
        $percentage = [math]::Round($nodeVersion.Value/$nodeBasedActions * 100 , 1)
        LogMessage "  B-->$([char]($currentLetter+65))[$($nodeVersion.Value) Node $($nodeVersion.Key) - $percentage%]"
        $currentLetter++
    }
    LogMessage "``````"
    LogMessage ""
    LogMessage "## Action definition setup"
    LogMessage "How is the action defined? The runner can pick it up from these files in the root of the repo: action.yml, action.yaml, dockerfile or Dockerfile. The Dockerfile can also be referened from the action definition file. If that is the case, it will show up as one of those two files in this overview."
    LogMessage "``````mermaid"
    LogMessage "flowchart LR"
    $ymlPercentage = [math]::Round($global:actionYmlFile/$repoInformation.reposAnalyzed * 100 , 1)
    LogMessage "  A[$($repoInformation.reposAnalyzed) actions]-->B[$actionYmlFile action.yml - $ymlPercentage%]"
    $yamlPercentage = [math]::Round($global:actionYamlFile/$repoInformation.reposAnalyzed * 100 , 1)
    LogMessage "  A-->C[$actionYamlFile action.yaml - $yamlPercentage%]"
    $DockerPercentage = [math]::Round($global:actionDockerFile/$repoInformation.reposAnalyzed * 100 , 1)
    LogMessage "  A-->D[$global:actionDockerFile Dockerfile - $DockerPercentage%]"
    $dDockerPercentage = [math]::Round($global:actiondDockerFile/$repoInformation.reposAnalyzed * 100 , 1)
    LogMessage "  A-->E[$global:actiondDockerFile dockerfile - $dDockerPercentage%]"
    LogMessage "``````"
    LogMessage ""
    LogMessage "## Docker based actions, most used base images: "
    # calculate unique items in dockerBaseImages
    $dockerBaseImagesUnique = $dockerBaseImages | Sort-Object | Get-Unique
    LogMessage "Found $($global:dockerBaseImages.Length) base images with $($dockerBaseImagesUnique.Length) uniques. The top 10 are listed below."
    # summarize the string list dockerBaseImages to count each item
    $dockerBaseImagesGrouped = $global:dockerBaseImages | Group-Object | Sort-Object -Descending -Property Count | Select-Object -Property Name, Count
    $dockerBaseImagesGrouped | Sort-Object -Property Count -Descending | Select-Object -First 10 | ForEach-Object {
        LogMessage "- $($_.Name): $($_.Count)"
    }
    LogMessage ""
}

function ReportAgeInsights {
    if ($global:repoInfo -eq 0) {
        # prevent division by 0 errors
        return
    }
    LogMessage "## Repo age"
    LogMessage "How recent where the repos updated? Determined by looking at the last updated date."
    LogMessage "|Analyzed|Total: $($global:repoInfo)|Analyzed: $($repoInformation.reposAnalyzed) repos|100%|"
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

    if ($global:countRepoSize -gt 0) {
        LogMessage ""
        LogMessage "## Action's repo size"
        LogMessage "How big are the repos? Determined by looking at the size of the repo in Mib."
        LogMessage "|Description    | Info|"
        LogMessage "|---            | ---:|"    
        LogMessage "|Total          | $($global:repoInfo)"
        LogMessage "|Analyzed       | $($global:countRepoSize)|"
        LogMessage "|Sum reposizes  | $([math]::Round($global:sumRepoSize / 1024, 0)) GiB|"
        LogMessage "|Repos > 100MiB | $($global:countRepoSizeBiggerThen100Mb)|"
        LogMessage "|Average size   | $([math]::Round(($global:sumRepoSize / 1024) / $global:countRepoSize, 2)) MiB|"
        LogMessage "|Largest size   | $([math]::Round( $global:maxRepoSize / 1024, 2)) MiB|"
    }
}

function GetOSSFInfo {
    $ossfInfoCount = 0
    $total = 0
    $ossfChecked = 0
    foreach ($action in $actions) {
        if ($action.ossf) {
            $ossfInfoCount++
        }

        if ($action.ossfDateLastUpdate) {
            $ossfChecked++
        }

        $total++
    }
    LogMessage "Found [$ossfInfoCount] actions with OSSF info available for [$ossfChecked] repos out of a [$total] total."
}

function GetMostUsedActionsList {
    LogMessage "## Most used actions:"
    #sort the actions with most dependents
    $actions | Sort-Object -Property dependents.dependents -Descending | Select-Object -First 10 | ForEach-Object {
        LogMessage "- $($_.name) (used in $($_.dependents.dependents) repos)"
    }
}

# call the report functions
$repoInformation = AnalyzeActionInformation -actions $actions
ReportAgeInsights
LogMessage ""

ReportInsightsInMarkdown -repoInformation $repoInformation

# filter actions to the ones owned by GitHub
$githubActions = $actions | Where-Object { $_.owner -eq "github" -or $_.owner -eq "actions" }
# reset node versions
$global:nodeVersions = @()
$github_RepoInformation = AnalyzeActionInformation -actions $githubactions
# report information:
VulnerabilityCalculations -repoInformation $repoInformation -github_RepoInformation $github_RepoInformation
ReportVulnChartInMarkdown -chartTitle "actions" -actions $actions -repoInformation $repoInformation

# reset everything for just the Node actions
$nodeBasedActions = $actions | Where-Object {($null -ne $_.actionType) -and ($_.actionType.actionType -eq "Node")}
$nodeRepoInformation = New-Object RepoInformation
foreach ($action in $nodeBasedActions) {        
    GetVulnerableInfo -action $action -actionType "Node" -repoInformation $nodeRepoInformation
}
ReportVulnChartInMarkdown -chartTitle "Node actions" -actions $nodeBasedActions -repoInformation $nodeRepoInformation

# reset everything for just the Composite actions
$compositeActions = $actions | Where-Object {($null -ne $_.actionType) -and ($_.actionType.actionType -eq "Composite")}
$compositeRepoInformation = New-Object RepoInformation
foreach ($action in $compositeActions) {        
    GetVulnerableInfo -action $action -actionType "Composite" -repoInformation $compositeRepoInformation
}
ReportVulnChartInMarkdown -chartTitle "Composite actions"  -actions $compositeActions -repoInformation $compositeRepoInformation

GetTagReleaseInfo
GetOSSFInfo

GetFoundSecretCount -access_token_destination $access_token_destination

GetMostUsedActionsList
