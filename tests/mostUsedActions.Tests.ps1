Import-Module Pester

BeforeAll {
    # import library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
    
    # Mock LogMessage function to capture output
    $script:logMessages = @()
    function LogMessage {
        Param (
            $message
        )
        $script:logMessages += $message
    }
    
    # Define the GetMostUsedActionsList function inline since we can't source report.ps1 without executing it
    function GetMostUsedActionsList {
        if ($null -eq $script:actions) {
            LogMessage "No actions found, so cannot check for Most Used Actions"
            return
        }
        
        # Get all actions with dependents info
        $dependentsInfoAvailable = $script:actions | Where-Object {
            $null -ne $_ -and $null -ne $_.name -and $null -ne $_.dependents -and $_.dependents?.dependents -ne ""
        }

        LogMessage "Found [$($dependentsInfoAvailable.Count)] actions with dependents info available"
        LogMessage ""
        
        # Table 1: All most used actions (including actions org)
        LogMessage "## Most used actions:"
        LogMessage "| Repository | Dependent repos |"
        LogMessage "|---|---:|"

        $top10All = $dependentsInfoAvailable
            | Sort-Object -Property {[int]($_.dependents?.dependents?.Replace(" ", ""))} -Descending
            | Select-Object -First 10

        foreach ($item in $top10All)
        {
            ($owner, $repo) = GetOrgActionInfo -forkedOwnerRepo $item.name
            LogMessage "| $owner/$repo | $($item.dependents?.dependents) |"
        }
        
        LogMessage ""
        
        # Table 2: Most used actions excluding actions org
        LogMessage "## Most used actions (excluding actions org):"
        LogMessage "| Repository | Dependent repos | Last Updated |"
        LogMessage "|---|---:|---|"
        
        $dependentsExcludingActionsOrg = $dependentsInfoAvailable | Where-Object {
            $null -ne $_.name -and -not $_.name.StartsWith("actions_")
        }

        $top10ExcludingActionsOrg = $dependentsExcludingActionsOrg
            | Sort-Object -Property {[int]($_.dependents?.dependents?.Replace(" ", ""))} -Descending
            | Select-Object -First 10

        foreach ($item in $top10ExcludingActionsOrg)
        {
            ($owner, $repo) = GetOrgActionInfo -forkedOwnerRepo $item.name
            $lastUpdated = "N/A"
            if ($item.repoInfo -and $item.repoInfo.updated_at) {
                $lastUpdated = $item.repoInfo.updated_at.ToString("yyyy-MM-dd")
            }
            LogMessage "| $owner/$repo | $($item.dependents?.dependents) | $lastUpdated |"
        }
    }
}

Describe "GetMostUsedActionsList" {
    BeforeEach {
        $script:logMessages = @()
    }
    
    It "Should create two separate tables" {
        # Arrange
        $script:actions = @(
            @{ name = "actions_checkout"; dependents = @{ dependents = "1000" } }
            @{ name = "actions_setup-node"; dependents = @{ dependents = "800" } }
            @{ name = "docker_build-push-action"; dependents = @{ dependents = "900" } }
            @{ name = "github_codeql-action"; dependents = @{ dependents = "700" } }
        )
        
        # Act
        GetMostUsedActionsList
        
        # Assert
        $output = $script:logMessages -join "`n"
        $output | Should -Match "## Most used actions:"
        $output | Should -Match "## Most used actions \(excluding actions org\):"
    }
    
    It "Should include actions org in first table" {
        # Arrange
        $script:actions = @(
            @{ name = "actions_checkout"; dependents = @{ dependents = "1000" } }
            @{ name = "docker_build-push-action"; dependents = @{ dependents = "900" } }
        )
        
        # Act
        GetMostUsedActionsList
        
        # Assert
        $output = $script:logMessages -join "`n"
        # First table should have actions/checkout as the top action
        $firstTableIndex = ($script:logMessages | Select-String "## Most used actions:").LineNumber
        $secondTableIndex = ($script:logMessages | Select-String "## Most used actions \(excluding actions org\):").LineNumber
        
        # Check that actions/checkout appears in the first table
        $firstTableContent = $script:logMessages[$firstTableIndex..($secondTableIndex-2)] -join "`n"
        $firstTableContent | Should -Match "actions/checkout"
    }
    
    It "Should exclude actions org from second table" {
        # Arrange
        $script:actions = @(
            @{ name = "actions_checkout"; dependents = @{ dependents = "1000" } }
            @{ name = "actions_setup-node"; dependents = @{ dependents = "800" } }
            @{ name = "docker_build-push-action"; dependents = @{ dependents = "900" } }
            @{ name = "github_codeql-action"; dependents = @{ dependents = "700" } }
        )
        
        # Act
        GetMostUsedActionsList
        
        # Assert
        # Find the second table start
        $secondTableTitle = "## Most used actions (excluding actions org):"
        $secondTableIndex = -1
        for ($i = 0; $i -lt $script:logMessages.Count; $i++) {
            if ($script:logMessages[$i] -eq $secondTableTitle) {
                $secondTableIndex = $i
                break
            }
        }
        
        $secondTableIndex | Should -BeGreaterThan -1
        
        # Get content from second table onwards
        $secondTableContent = $script:logMessages[$secondTableIndex..($script:logMessages.Count-1)] -join "`n"
        
        # Check that actions org is NOT in the data rows of second table
        # Look specifically for the data rows (not headers)
        $secondTableDataRows = $script:logMessages[($secondTableIndex+3)..($script:logMessages.Count-1)] | Where-Object { $_ -match "^\|[^-]" }
        $secondTableData = $secondTableDataRows -join "`n"
        
        $secondTableData | Should -Not -Match "actions/checkout"
        $secondTableData | Should -Not -Match "actions/setup-node"
        
        # But should contain other actions
        $secondTableData | Should -Match "docker/build-push-action"
        $secondTableData | Should -Match "github/codeql-action"
    }
    
    It "Should sort by dependent count descending" {
        # Arrange
        $script:actions = @(
            @{ name = "lowcount_action"; dependents = @{ dependents = "100" } }
            @{ name = "highcount_action"; dependents = @{ dependents = "900" } }
            @{ name = "mediumcount_action"; dependents = @{ dependents = "500" } }
        )
        
        # Act
        GetMostUsedActionsList
        
        # Assert - First repo in table should be highcount_action
        $tableStartIndex = ($script:logMessages | Select-String "## Most used actions:").LineNumber
        # Skip header lines (title, header row, separator row)
        $firstDataRow = $script:logMessages[$tableStartIndex + 2]
        $firstDataRow | Should -Match "highcount/action"
    }
    
    It "Should handle null actions gracefully" {
        # Arrange
        $script:actions = $null
        
        # Act
        GetMostUsedActionsList
        
        # Assert
        $output = $script:logMessages -join "`n"
        $output | Should -Match "No actions found"
    }
    
    It "Should filter out actions without dependents info" {
        # Arrange
        # Note: PowerShell's -ne "" will treat $null as not equal to ""
        # The filter checks: $null -ne $_.dependents AND $_.dependents?.dependents -ne ""
        # So both null dependents and empty string dependents should be filtered
        $script:actions = @(
            @{ name = "action1"; dependents = @{ dependents = "100" } }
            @{ name = "action2"; dependents = $null }  # This should be filtered (dependents is null)
            @{ name = "action3"; dependents = @{ dependents = "" } }  # This should be filtered (dependents.dependents is empty)
            @{ name = "action4"; dependents = @{ dependents = "200" } }
        )
        
        # Act
        GetMostUsedActionsList
        
        # Assert
        # The filter should keep action1 and action4 only (count = 2)
        # However, PowerShell's behavior with -ne "" and null is complex
        # Let's verify by checking if only 2 actions appear in the tables
        $dataRows = $script:logMessages | Where-Object { $_ -match "^\| [^R|].*\|.*\|$" }
        # We expect 2 actions * 2 tables = 4 total data rows
        $dataRows.Count | Should -Be 4
    }
    
    It "Should limit to top 10 in each table" {
        # Arrange - Create 15 actions
        $script:actions = @()
        for ($i = 1; $i -le 15; $i++) {
            $script:actions += @{ 
                name = "owner$i`_action$i"
                dependents = @{ dependents = "$(1000 - $i * 10)" }
            }
        }
        
        # Act
        GetMostUsedActionsList
        
        # Assert - Count data rows in first table
        # Find table indices
        $firstTableIndex = -1
        $secondTableIndex = -1
        for ($i = 0; $i -lt $script:logMessages.Count; $i++) {
            if ($script:logMessages[$i] -eq "## Most used actions:") {
                $firstTableIndex = $i
            }
            if ($script:logMessages[$i] -eq "## Most used actions (excluding actions org):") {
                $secondTableIndex = $i
            }
        }
        
        # Count data rows between first and second table
        # Data rows are those that start with | and contain actual data (not header or separator)
        $dataRows = $script:logMessages[$firstTableIndex..($secondTableIndex-1)] | Where-Object { 
            $_ -match "^\| [^R]" -and $_ -notmatch "^---" 
        }
        $dataRows.Count | Should -Be 10
    }
    
    It "Should include Last Updated column in second table only" {
        # Arrange
        $script:actions = @(
            @{ 
                name = "actions_checkout"
                dependents = @{ dependents = "1000" }
                repoInfo = @{ updated_at = (Get-Date "2024-01-15") }
            }
            @{ 
                name = "docker_build-push-action"
                dependents = @{ dependents = "900" }
                repoInfo = @{ updated_at = (Get-Date "2024-02-20") }
            }
            @{ 
                name = "github_codeql-action"
                dependents = @{ dependents = "700" }
                repoInfo = @{ updated_at = (Get-Date "2024-03-10") }
            }
        )
        
        # Act
        GetMostUsedActionsList
        
        # Assert
        $output = $script:logMessages -join "`n"
        
        # First table should NOT have 3 columns in header
        $firstTableIndex = -1
        $secondTableIndex = -1
        for ($i = 0; $i -lt $script:logMessages.Count; $i++) {
            if ($script:logMessages[$i] -eq "## Most used actions:") {
                $firstTableIndex = $i
            }
            if ($script:logMessages[$i] -eq "## Most used actions (excluding actions org):") {
                $secondTableIndex = $i
            }
        }
        
        # First table header should have 2 columns
        $firstTableHeader = $script:logMessages[$firstTableIndex + 1]
        $firstTableHeader | Should -Match "^\| Repository \| Dependent repos \|$"
        
        # Second table header should have 3 columns including Last Updated
        $secondTableHeader = $script:logMessages[$secondTableIndex + 1]
        $secondTableHeader | Should -Match "^\| Repository \| Dependent repos \| Last Updated \|$"
        
        # Second table should have date values in the third column
        $secondTableDataRows = $script:logMessages[($secondTableIndex+3)..($script:logMessages.Count-1)] | Where-Object { 
            $_ -match "^\| [^-R]" 
        }
        # Check that at least one row has a date format (yyyy-MM-dd) or "N/A"
        $secondTableData = $secondTableDataRows -join "`n"
        $secondTableData | Should -Match "\| \d{4}-\d{2}-\d{2} \|"
    }
    
    It "Should show N/A for actions without repoInfo" {
        # Arrange
        $script:actions = @(
            @{ 
                name = "docker_build-push-action"
                dependents = @{ dependents = "900" }
                # No repoInfo
            }
        )
        
        # Act
        GetMostUsedActionsList
        
        # Assert
        $secondTableIndex = -1
        for ($i = 0; $i -lt $script:logMessages.Count; $i++) {
            if ($script:logMessages[$i] -eq "## Most used actions (excluding actions org):") {
                $secondTableIndex = $i
            }
        }
        
        # Get data rows from second table
        $secondTableDataRows = $script:logMessages[($secondTableIndex+3)..($script:logMessages.Count-1)] | Where-Object { 
            $_ -match "^\| [^-R]" 
        }
        $secondTableData = $secondTableDataRows -join "`n"
        $secondTableData | Should -Match "N/A"
    }
}
