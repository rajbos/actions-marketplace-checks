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

        $storedRepoUpdatedAt = $action.actionType.repoUpdatedAt
        if ($null -eq $storedRepoUpdatedAt) {
            return $true
        }

        $currentRepoUpdatedAt = $action.mirrorLastUpdated
        if ($null -ne $currentRepoUpdatedAt) {
            $repoChanged = $false
            try {
                $storedDate = [datetime]$storedRepoUpdatedAt
                $currentDate = [datetime]$currentRepoUpdatedAt
                if ($currentDate -gt $storedDate) {
                    $repoChanged = $true
                }
            }
            catch {
                if ("$currentRepoUpdatedAt" -ne "$storedRepoUpdatedAt") {
                    $repoChanged = $true
                }
            }
            if ($repoChanged) {
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

Describe "CheckForInfoUpdateNeeded ties action re-parsing to repo change date" {
    It "requests an update for a legacy record without a stored repoUpdatedAt" {
        $action = [PSCustomObject]@{
            name              = "actions/checkout"
            mirrorFound       = $true
            mirrorLastUpdated = "2024-01-10T10:00:00Z"
            actionType = [PSCustomObject]@{
                actionType  = "Node"
                nodeVersion = "16"
            }
        }
        $result = CheckForInfoUpdateNeeded -action $action -hasActionTypeField $true -hasNodeVersionField $true -startTime (Get-Date)
        $result | Should -Be $true
    }

    It "requests an update when the repo changed since it was last parsed" {
        $action = [PSCustomObject]@{
            name              = "actions/checkout"
            mirrorFound       = $true
            mirrorLastUpdated = "2024-06-01T12:00:00Z"
            actionType = [PSCustomObject]@{
                actionType    = "Node"
                nodeVersion   = "16"
                repoUpdatedAt = "2024-01-10T10:00:00Z"
            }
        }
        $result = CheckForInfoUpdateNeeded -action $action -hasActionTypeField $true -hasNodeVersionField $true -startTime (Get-Date)
        $result | Should -Be $true
    }

    It "does not request an update when the repo is unchanged since last parse" {
        $action = [PSCustomObject]@{
            name              = "actions/checkout"
            mirrorFound       = $true
            mirrorLastUpdated = "2024-01-10T10:00:00Z"
            actionType = [PSCustomObject]@{
                actionType    = "Node"
                nodeVersion   = "24"
                repoUpdatedAt = "2024-01-10T10:00:00Z"
            }
        }
        $result = CheckForInfoUpdateNeeded -action $action -hasActionTypeField $true -hasNodeVersionField $true -startTime (Get-Date)
        $result | Should -Be $false
    }

    It "does not request an update when the current repo date is missing" {
        $action = [PSCustomObject]@{
            name              = "actions/checkout"
            mirrorFound       = $true
            mirrorLastUpdated = $null
            actionType = [PSCustomObject]@{
                actionType    = "Node"
                nodeVersion   = "24"
                repoUpdatedAt = "2024-01-10T10:00:00Z"
            }
        }
        $result = CheckForInfoUpdateNeeded -action $action -hasActionTypeField $true -hasNodeVersionField $true -startTime (Get-Date)
        $result | Should -Be $false
    }

    It "requests an update when dates are unparseable but differ" {
        $action = [PSCustomObject]@{
            name              = "actions/checkout"
            mirrorFound       = $true
            mirrorLastUpdated = "changed-marker-b"
            actionType = [PSCustomObject]@{
                actionType    = "Node"
                nodeVersion   = "16"
                repoUpdatedAt = "changed-marker-a"
            }
        }
        $result = CheckForInfoUpdateNeeded -action $action -hasActionTypeField $true -hasNodeVersionField $true -startTime (Get-Date)
        $result | Should -Be $true
    }
}
