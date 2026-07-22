BeforeAll {
    # Define CheckForInfoUpdateNeeded inline (mirrors repoInfo.ps1) to avoid
    # loading repoInfo.ps1's script-level code that requires GitHub tokens.
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

        $recheckAfterDays = 30
        $hasActionTypeUpdated = $null -ne $action.actionType.actionTypeLastUpdated
        if (!$hasActionTypeUpdated) {
            return $true
        }
        else {
            try {
                $actionTypeUpdated = [datetime]$action.actionType.actionTypeLastUpdated
                $daysSinceActionTypeUpdate = ((Get-Date) - $actionTypeUpdated).TotalDays
                if ($daysSinceActionTypeUpdate -gt $recheckAfterDays) {
                    return $true
                }
            }
            catch {
                return $true
            }
        }

        # Check if we are nearing the 50-minute mark
        $timeSpan = (Get-Date) - $startTime
        if ($timeSpan.TotalMinutes -gt 50) {
            Write-Host "Stopping the run, since we are nearing the 50-minute mark"
            return
        }

        return $false
    }
}

Describe "CheckForInfoUpdateNeeded node version staleness" {
    It "requests an update for a legacy Node action without a lastUpdated timestamp" {
        $action = [PSCustomObject]@{
            name       = "actions/checkout"
            mirrorFound = $true
            actionType = [PSCustomObject]@{
                actionType  = "Node"
                nodeVersion = "16"
            }
        }
        $result = CheckForInfoUpdateNeeded -action $action -hasActionTypeField $true -hasNodeVersionField $true -startTime (Get-Date)
        $result | Should -Be $true
    }

    It "requests an update when the actionType is older than the recheck window" {
        $action = [PSCustomObject]@{
            name       = "actions/checkout"
            mirrorFound = $true
            actionType = [PSCustomObject]@{
                actionType            = "Node"
                nodeVersion           = "16"
                actionTypeLastUpdated = (Get-Date).AddDays(-31)
            }
        }
        $result = CheckForInfoUpdateNeeded -action $action -hasActionTypeField $true -hasNodeVersionField $true -startTime (Get-Date)
        $result | Should -Be $true
    }

    It "does not request an update when the actionType was checked recently" {
        $action = [PSCustomObject]@{
            name       = "actions/checkout"
            mirrorFound = $true
            actionType = [PSCustomObject]@{
                actionType            = "Node"
                nodeVersion           = "24"
                actionTypeLastUpdated = (Get-Date).AddDays(-1)
            }
        }
        $result = CheckForInfoUpdateNeeded -action $action -hasActionTypeField $true -hasNodeVersionField $true -startTime (Get-Date)
        $result | Should -Be $false
    }

    It "requests an update when the stored timestamp cannot be parsed" {
        $action = [PSCustomObject]@{
            name       = "actions/checkout"
            mirrorFound = $true
            actionType = [PSCustomObject]@{
                actionType            = "Node"
                nodeVersion           = "16"
                actionTypeLastUpdated = "not-a-date"
            }
        }
        $result = CheckForInfoUpdateNeeded -action $action -hasActionTypeField $true -hasNodeVersionField $true -startTime (Get-Date)
        $result | Should -Be $true
    }
}
