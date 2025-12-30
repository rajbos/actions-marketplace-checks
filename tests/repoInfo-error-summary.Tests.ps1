Import-Module Pester

BeforeAll {
    # Note: We duplicate the Format-ErrorSummaryTable function here rather than
    # importing from repoInfo.ps1 because that script has parameters and side effects
    # that would execute during import. This is a common pattern in PowerShell testing.
    
    function Format-ErrorSummaryTable {
        Param (
            [hashtable] $errorCounts,
            [hashtable] $errorDetails,
            [string] $forkOrg = "actions-marketplace-validations",
            [int] $limit = 10
        )
        
        # Calculate total errors
        $totalErrors = 0
        foreach ($key in $errorCounts.Keys) {
            $totalErrors += $errorCounts[$key]
        }
        
        # Build summary counts table
        $summaryTable = "| Error Type | Count |`n"
        $summaryTable += "| --- | --- |`n"
        $summaryTable += "| Upstream Repo 404 Errors | $($errorCounts.UpstreamRepo404) |`n"
        $summaryTable += "| Fork Repo 404 Errors | $($errorCounts.ForkRepo404) |`n"
        $summaryTable += "| Action File 404 Errors | $($errorCounts.ActionFile404) |`n"
        $summaryTable += "| Other Errors | $($errorCounts.OtherErrors) |`n"
        $summaryTable += "| **Total Errors** | **$totalErrors** |`n"
        
        # Build details section with clickable links
        $detailsSection = ""
        
        # Upstream Repo 404 Details
        if ($errorDetails.UpstreamRepo404.Count -gt 0) {
            $detailsSection += "`n### Upstream Repo 404 Details (first $limit):`n`n"
            $detailsSection += "| Repository | Mirror Link | Original Link |`n"
            $detailsSection += "| --- | --- | --- |`n"
            
            $errorDetails.UpstreamRepo404 | Select-Object -First $limit | ForEach-Object {
                $repoPath = $_
                $mirrorName = $repoPath -replace '/', '_'
                $mirrorUrl = "https://github.com/$forkOrg/$mirrorName"
                $originalUrl = "https://github.com/$repoPath"
                $detailsSection += "| $repoPath | [Mirror]($mirrorUrl) | [Original]($originalUrl) |`n"
            }
            
            if ($errorDetails.UpstreamRepo404.Count -gt $limit) {
                $detailsSection += "`n... and $($errorDetails.UpstreamRepo404.Count - $limit) more`n"
            }
        }
        
        # Fork Repo 404 Details
        if ($errorDetails.ForkRepo404.Count -gt 0) {
            $detailsSection += "`n### Fork Repo 404 Details (first $limit):`n`n"
            $detailsSection += "| Repository | Mirror Link |`n"
            $detailsSection += "| --- | --- |`n"
            
            $errorDetails.ForkRepo404 | Select-Object -First $limit | ForEach-Object {
                $repoPath = $_
                $mirrorUrl = "https://github.com/$repoPath"
                # Extract original repo from mirror name (format: org_repo)
                $parts = $repoPath -split '/'
                if ($parts.Length -eq 2) {
                    $mirrorName = $parts[1]
                    $originalParts = $mirrorName -split '_', 2
                    if ($originalParts.Length -eq 2) {
                        $originalUrl = "https://github.com/$($originalParts[0])/$($originalParts[1])"
                        $detailsSection += "| $repoPath | [Mirror]($mirrorUrl) | [Original]($originalUrl) |`n"
                    } else {
                        $detailsSection += "| $repoPath | [Mirror]($mirrorUrl) | N/A |`n"
                    }
                } else {
                    $detailsSection += "| $repoPath | [Mirror]($mirrorUrl) | N/A |`n"
                }
            }
            
            if ($errorDetails.ForkRepo404.Count -gt $limit) {
                $detailsSection += "`n... and $($errorDetails.ForkRepo404.Count - $limit) more`n"
            }
        }
        
        # Action File 404 Details
        if ($errorDetails.ActionFile404.Count -gt 0) {
            $detailsSection += "`n### Action File 404 Details (first $limit):`n`n"
            $errorDetails.ActionFile404 | Select-Object -First $limit | ForEach-Object {
                $detailsSection += "  - $_`n"
            }
            
            if ($errorDetails.ActionFile404.Count -gt $limit) {
                $detailsSection += "`n... and $($errorDetails.ActionFile404.Count - $limit) more`n"
            }
        }
        
        # Other Error Details
        if ($errorDetails.OtherErrors.Count -gt 0) {
            $detailsSection += "`n### Other Error Details (first 5):`n`n"
            $errorDetails.OtherErrors | Select-Object -First 5 | ForEach-Object {
                $detailsSection += "  - $_`n"
            }
            
            if ($errorDetails.OtherErrors.Count -gt 5) {
                $detailsSection += "`n... and $($errorDetails.OtherErrors.Count - 5) more`n"
            }
        }
        
        return @{
            SummaryTable = $summaryTable
            DetailsSection = $detailsSection
            TotalErrors = $totalErrors
        }
    }
}

Describe "RepoInfo Error Summary Formatting" {
    It "Should generate a valid markdown table with error counts" {
        # Arrange
        $errorCounts = @{
            UpstreamRepo404 = 160
            ForkRepo404 = 125
            ActionFile404 = 0
            OtherErrors = 0
        }
        $errorDetails = @{
            UpstreamRepo404 = @()
            ForkRepo404 = @()
            ActionFile404 = @()
            OtherErrors = @()
        }
        
        # Act
        $result = Format-ErrorSummaryTable -errorCounts $errorCounts -errorDetails $errorDetails
        
        # Assert
        $result.SummaryTable | Should -Match "\| Error Type \| Count \|"
        $result.SummaryTable | Should -Match "\| --- \| --- \|"
        $result.SummaryTable | Should -Match "\| Upstream Repo 404 Errors \| 160 \|"
        $result.SummaryTable | Should -Match "\| Fork Repo 404 Errors \| 125 \|"
        $result.SummaryTable | Should -Match "\| Action File 404 Errors \| 0 \|"
        $result.SummaryTable | Should -Match "\| Other Errors \| 0 \|"
        $result.SummaryTable | Should -Match "\| \*\*Total Errors\*\* \| \*\*285\*\* \|"
        $result.TotalErrors | Should -Be 285
    }
    
    It "Should generate clickable links for upstream repo 404 errors" {
        # Arrange
        $errorCounts = @{
            UpstreamRepo404 = 3
            ForkRepo404 = 0
            ActionFile404 = 0
            OtherErrors = 0
        }
        $errorDetails = @{
            UpstreamRepo404 = @(
                "relaxcloud-cn/mgoat-action"
                "bd-SrinathAkkem/bd-ai-pr-review"
                "khulnasoft-lab/codereviewer"
            )
            ForkRepo404 = @()
            ActionFile404 = @()
            OtherErrors = @()
        }
        
        # Act
        $result = Format-ErrorSummaryTable -errorCounts $errorCounts -errorDetails $errorDetails -forkOrg "actions-marketplace-validations"
        
        # Assert
        $result.DetailsSection | Should -Match "### Upstream Repo 404 Details"
        $result.DetailsSection | Should -Match "\| Repository \| Mirror Link \| Original Link \|"
        $result.DetailsSection | Should -Match "\| relaxcloud-cn/mgoat-action \| \[Mirror\]\(https://github.com/actions-marketplace-validations/relaxcloud-cn_mgoat-action\) \| \[Original\]\(https://github.com/relaxcloud-cn/mgoat-action\) \|"
        $result.DetailsSection | Should -Match "\| bd-SrinathAkkem/bd-ai-pr-review \| \[Mirror\]\(https://github.com/actions-marketplace-validations/bd-SrinathAkkem_bd-ai-pr-review\) \| \[Original\]\(https://github.com/bd-SrinathAkkem/bd-ai-pr-review\) \|"
        $result.DetailsSection | Should -Match "\| khulnasoft-lab/codereviewer \| \[Mirror\]\(https://github.com/actions-marketplace-validations/khulnasoft-lab_codereviewer\) \| \[Original\]\(https://github.com/khulnasoft-lab/codereviewer\) \|"
    }
    
    It "Should generate clickable links for fork repo 404 errors" {
        # Arrange
        $errorCounts = @{
            UpstreamRepo404 = 0
            ForkRepo404 = 3
            ActionFile404 = 0
            OtherErrors = 0
        }
        $errorDetails = @{
            UpstreamRepo404 = @()
            ForkRepo404 = @(
                "actions-marketplace-validations/overtrue_conventional-pr-title"
                "actions-marketplace-validations/jghiloni_concourse-trigger-job-action"
                "actions-marketplace-validations/BlendinAI_github-action"
            )
            ActionFile404 = @()
            OtherErrors = @()
        }
        
        # Act
        $result = Format-ErrorSummaryTable -errorCounts $errorCounts -errorDetails $errorDetails -forkOrg "actions-marketplace-validations"
        
        # Assert
        $result.DetailsSection | Should -Match "### Fork Repo 404 Details"
        $result.DetailsSection | Should -Match "\| Repository \| Mirror Link \|"
        $result.DetailsSection | Should -Match "\| actions-marketplace-validations/overtrue_conventional-pr-title \| \[Mirror\]\(https://github.com/actions-marketplace-validations/overtrue_conventional-pr-title\) \| \[Original\]\(https://github.com/overtrue/conventional-pr-title\) \|"
        $result.DetailsSection | Should -Match "\| actions-marketplace-validations/jghiloni_concourse-trigger-job-action \| \[Mirror\]\(https://github.com/actions-marketplace-validations/jghiloni_concourse-trigger-job-action\) \| \[Original\]\(https://github.com/jghiloni/concourse-trigger-job-action\) \|"
    }
    
    It "Should limit the number of displayed errors" {
        # Arrange
        $errorCounts = @{
            UpstreamRepo404 = 15
            ForkRepo404 = 0
            ActionFile404 = 0
            OtherErrors = 0
        }
        $upstreamErrors = @()
        for ($i = 1; $i -le 15; $i++) {
            $upstreamErrors += "owner$i/repo$i"
        }
        $errorDetails = @{
            UpstreamRepo404 = $upstreamErrors
            ForkRepo404 = @()
            ActionFile404 = @()
            OtherErrors = @()
        }
        
        # Act
        $result = Format-ErrorSummaryTable -errorCounts $errorCounts -errorDetails $errorDetails -limit 10
        
        # Assert
        $result.DetailsSection | Should -Match "owner1/repo1"
        $result.DetailsSection | Should -Match "owner10/repo10"
        $result.DetailsSection | Should -Not -Match "owner11/repo11"
        $result.DetailsSection | Should -Match "\.\.\. and 5 more"
    }
    
    It "Should handle empty error details gracefully" {
        # Arrange
        $errorCounts = @{
            UpstreamRepo404 = 0
            ForkRepo404 = 0
            ActionFile404 = 0
            OtherErrors = 0
        }
        $errorDetails = @{
            UpstreamRepo404 = @()
            ForkRepo404 = @()
            ActionFile404 = @()
            OtherErrors = @()
        }
        
        # Act
        $result = Format-ErrorSummaryTable -errorCounts $errorCounts -errorDetails $errorDetails
        
        # Assert
        $result.SummaryTable | Should -Not -BeNullOrEmpty
        $result.DetailsSection | Should -Be ""
        $result.TotalErrors | Should -Be 0
    }
    
    It "Should handle action file 404 errors" {
        # Arrange
        $errorCounts = @{
            UpstreamRepo404 = 0
            ForkRepo404 = 0
            ActionFile404 = 2
            OtherErrors = 0
        }
        $errorDetails = @{
            UpstreamRepo404 = @()
            ForkRepo404 = @()
            ActionFile404 = @(
                "owner1/repo1 : https://example.com/action.yml"
                "owner2/repo2 : https://example.com/action.yaml"
            )
            OtherErrors = @()
        }
        
        # Act
        $result = Format-ErrorSummaryTable -errorCounts $errorCounts -errorDetails $errorDetails
        
        # Assert
        $result.DetailsSection | Should -Match "### Action File 404 Details"
        $result.DetailsSection | Should -Match "owner1/repo1"
        $result.DetailsSection | Should -Match "owner2/repo2"
    }
    
    It "Should handle other errors with smaller limit" {
        # Arrange
        $errorCounts = @{
            UpstreamRepo404 = 0
            ForkRepo404 = 0
            ActionFile404 = 0
            OtherErrors = 10
        }
        $otherErrors = @()
        for ($i = 1; $i -le 10; $i++) {
            $otherErrors += "Error ${i}: Some error message"
        }
        $errorDetails = @{
            UpstreamRepo404 = @()
            ForkRepo404 = @()
            ActionFile404 = @()
            OtherErrors = $otherErrors
        }
        
        # Act
        $result = Format-ErrorSummaryTable -errorCounts $errorCounts -errorDetails $errorDetails
        
        # Assert
        $result.DetailsSection | Should -Match "### Other Error Details"
        $result.DetailsSection | Should -Match "Error 1"
        $result.DetailsSection | Should -Match "Error 5"
        $result.DetailsSection | Should -Not -Match "Error 6"
        $result.DetailsSection | Should -Match "\.\.\. and 5 more"
    }
}
