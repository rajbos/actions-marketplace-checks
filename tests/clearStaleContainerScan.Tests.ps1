BeforeAll {
    # Clear-StaleContainerScan / Remove-StaleContainerScans live in library.ps1
    . $PSScriptRoot/../.github/workflows/library.ps1

    # Build a status.json-shaped entry (PSCustomObject, like ConvertFrom-Json
    # produces) with an actionType and an optional containerScan.
    function New-ActionEntry {
        param (
            [string] $name = "owner_repo",
            [string] $actionType = "Docker",
            [string] $actionDockerType = "Dockerfile",
            [bool]   $withContainerScan = $true
        )

        $at = [PSCustomObject]@{
            actionType       = $actionType
            fileFound        = "action.yml"
            actionDockerType = $actionDockerType
        }
        if ($withContainerScan) {
            $at | Add-Member -Name containerScan -MemberType NoteProperty -Value ([PSCustomObject]@{
                critical    = 0
                high        = 0
                scanError   = $null
                lastScanned = "2026-07-01T00:00:00.000Z"
            })
        }

        return [PSCustomObject]@{
            name       = $name
            actionType = $at
        }
    }
}

Describe "Clear-StaleContainerScan" {
    It "clears containerScan when actionDockerType switched to Image" {
        $action = New-ActionEntry -actionType "Docker" -actionDockerType "Image"

        Clear-StaleContainerScan -action $action | Should -BeTrue
        $action.actionType.PSObject.Properties.Name | Should -Not -Contain "containerScan"
    }

    It "clears containerScan when the action became a Composite action" {
        $action = New-ActionEntry -actionType "Composite" -actionDockerType ""

        Clear-StaleContainerScan -action $action | Should -BeTrue
        $action.actionType.PSObject.Properties.Name | Should -Not -Contain "containerScan"
    }

    It "clears containerScan when the action definition can no longer be found" {
        $action = New-ActionEntry -actionType "No file found" -actionDockerType "No file found"

        Clear-StaleContainerScan -action $action | Should -BeTrue
        $action.actionType.PSObject.Properties.Name | Should -Not -Contain "containerScan"
    }

    It "keeps containerScan for a current Dockerfile-based Docker action" {
        $action = New-ActionEntry -actionType "Docker" -actionDockerType "Dockerfile"

        Clear-StaleContainerScan -action $action | Should -BeFalse
        $action.actionType.PSObject.Properties.Name | Should -Contain "containerScan"
    }

    It "is a no-op when there is no containerScan to begin with" {
        $action = New-ActionEntry -actionType "Node" -actionDockerType "" -withContainerScan $false

        Clear-StaleContainerScan -action $action | Should -BeFalse
    }

    It "is a no-op when the entry has no actionType at all" {
        $action = [PSCustomObject]@{ name = "owner_repo" }

        Clear-StaleContainerScan -action $action | Should -BeFalse
    }

    It "handles a hashtable actionType (Remove path)" {
        $action = @{
            name = "owner_repo"
            actionType = @{
                actionType       = "Docker"
                actionDockerType = "Image"
                containerScan    = @{ critical = 1; high = 2; lastScanned = "2026-07-01T00:00:00.000Z" }
            }
        }

        Clear-StaleContainerScan -action $action | Should -BeTrue
        $action.actionType.ContainsKey("containerScan") | Should -BeFalse
    }

    It "does not touch other actionType fields" {
        $action = New-ActionEntry -actionType "Docker" -actionDockerType "Image"

        Clear-StaleContainerScan -action $action | Out-Null
        $action.actionType.actionType | Should -Be "Docker"
        $action.actionType.actionDockerType | Should -Be "Image"
        $action.actionType.fileFound | Should -Be "action.yml"
    }
}

Describe "Remove-StaleContainerScans" {
    It "clears every stale record and leaves valid ones intact" {
        $forks = @(
            (New-ActionEntry -name "a" -actionType "Docker"        -actionDockerType "Dockerfile"),      # keep
            (New-ActionEntry -name "b" -actionType "Docker"        -actionDockerType "Image"),            # clear
            (New-ActionEntry -name "c" -actionType "Composite"     -actionDockerType ""),                 # clear
            (New-ActionEntry -name "d" -actionType "No file found" -actionDockerType "No file found"),    # clear
            (New-ActionEntry -name "e" -actionType "Node" -actionDockerType "" -withContainerScan $false) # nothing to do
        )

        $result = Remove-StaleContainerScans -existingForks $forks

        $result.Cleared | Should -Be 3
        ($forks | Where-Object { $_.name -eq "a" }).actionType.PSObject.Properties.Name | Should -Contain "containerScan"
        ($forks | Where-Object { $_.name -eq "b" }).actionType.PSObject.Properties.Name | Should -Not -Contain "containerScan"
        ($forks | Where-Object { $_.name -eq "c" }).actionType.PSObject.Properties.Name | Should -Not -Contain "containerScan"
        ($forks | Where-Object { $_.name -eq "d" }).actionType.PSObject.Properties.Name | Should -Not -Contain "containerScan"
    }

    It "reports a breakdown by actionType" {
        $forks = @(
            (New-ActionEntry -name "b" -actionType "Docker"    -actionDockerType "Image"),
            (New-ActionEntry -name "c" -actionType "Composite" -actionDockerType ""),
            (New-ActionEntry -name "c2" -actionType "Composite" -actionDockerType "")
        )

        $result = Remove-StaleContainerScans -existingForks $forks

        $result.Cleared | Should -Be 3
        $result.ByActionType["Composite"] | Should -Be 2
        $result.ByActionType["Docker"] | Should -Be 1
    }

    It "is a safe no-op on an empty / null collection" {
        (Remove-StaleContainerScans -existingForks @()).Cleared | Should -Be 0
        (Remove-StaleContainerScans -existingForks $null).Cleared | Should -Be 0
    }

    It "round-trips through JSON without schema drift for untouched entries" {
        $forks = @(
            (New-ActionEntry -name "keep" -actionType "Docker" -actionDockerType "Dockerfile"),
            (New-ActionEntry -name "drop" -actionType "Docker" -actionDockerType "Image")
        )

        Remove-StaleContainerScans -existingForks $forks | Out-Null
        $roundTripped = $forks | ConvertTo-Json -Depth 10 | ConvertFrom-Json

        $keep = ($roundTripped | Where-Object { $_.name -eq "keep" })
        $keep.actionType.PSObject.Properties.Name | Should -Contain "containerScan"
        $keep.actionType.containerScan.critical | Should -Be 0
        ($roundTripped | Where-Object { $_.name -eq "drop" }).actionType.PSObject.Properties.Name | Should -Not -Contain "containerScan"
    }
}
