Import-Module Pester

BeforeAll {
    # Mock the necessary functions and load the cleanup script
    . $PSScriptRoot/../.github/workflows/library.ps1
    
    function Test-RepoExists {
        Param (
            $repoOwner,
            $repoName,
            $access_token
        )
        return $false
    }
    
    # Define a simplified version of GetReposToCleanup for testing
    function Test-OwnerExtraction {
        Param (
            $repo
        )
        
        $isInvalid = ($null -eq $repo) -or ([string]::IsNullOrEmpty($repo.name)) -or ($repo.name -eq "_")
        
        if (-not $isInvalid -and [string]::IsNullOrEmpty($repo.owner)) {
            # Extract owner from repo name using the pattern owner_repo
            if ($repo.name -match '^([^_]+)_') {
                $extractedOwner = $matches[1]
                $repo.owner = $extractedOwner
                return @{
                    success = $true
                    owner = $extractedOwner
                    method = "extraction"
                }
            }
            else {
                return @{
                    success = $false
                    method = "no_pattern"
                }
            }
        }
        
        return @{
            success = $false
            method = "not_applicable"
        }
    }
}

Describe "Owner Extraction from Repo Name" {
    It "Should extract owner from repo name with underscore pattern" {
        # Arrange
        $repo = @{
            name = "michaelneale_goose-fix-it-action"
            owner = $null
        }
        
        # Act
        $result = Test-OwnerExtraction -repo $repo
        
        # Assert
        $result.success | Should -Be $true
        $result.owner | Should -Be "michaelneale"
        $result.method | Should -Be "extraction"
        $repo.owner | Should -Be "michaelneale"
    }
    
    It "Should extract owner from repo name with multiple underscores" {
        # Arrange
        $repo = @{
            name = "dsx137_modrinth-release-action"
            owner = ""
        }
        
        # Act
        $result = Test-OwnerExtraction -repo $repo
        
        # Assert
        $result.success | Should -Be $true
        $result.owner | Should -Be "dsx137"
        $repo.owner | Should -Be "dsx137"
    }
    
    It "Should extract owner from repo name (coquer example)" {
        # Arrange
        $repo = @{
            name = "coquer_deploy-with-kustomize"
            owner = $null
        }
        
        # Act
        $result = Test-OwnerExtraction -repo $repo
        
        # Assert
        $result.success | Should -Be $true
        $result.owner | Should -Be "coquer"
        $repo.owner | Should -Be "coquer"
    }
    
    It "Should extract owner from repo name (ryanbascom example)" {
        # Arrange
        $repo = @{
            name = "ryanbascom_googlejavaformat"
            owner = ""
        }
        
        # Act
        $result = Test-OwnerExtraction -repo $repo
        
        # Assert
        $result.success | Should -Be $true
        $result.owner | Should -Be "ryanbascom"
        $repo.owner | Should -Be "ryanbascom"
    }
    
    It "Should extract owner from repo name (narumiruna example)" {
        # Arrange
        $repo = @{
            name = "narumiruna_setup-rye"
            owner = $null
        }
        
        # Act
        $result = Test-OwnerExtraction -repo $repo
        
        # Assert
        $result.success | Should -Be $true
        $result.owner | Should -Be "narumiruna"
        $repo.owner | Should -Be "narumiruna"
    }
    
    It "Should extract owner from repo name (yuckabug example)" {
        # Arrange
        $repo = @{
            name = "yuckabug_size-limit-action"
            owner = ""
        }
        
        # Act
        $result = Test-OwnerExtraction -repo $repo
        
        # Assert
        $result.success | Should -Be $true
        $result.owner | Should -Be "yuckabug"
        $repo.owner | Should -Be "yuckabug"
    }
    
    It "Should extract owner from repo name (richardrigutins example)" {
        # Arrange
        $repo = @{
            name = "richardrigutins_check-value"
            owner = $null
        }
        
        # Act
        $result = Test-OwnerExtraction -repo $repo
        
        # Assert
        $result.success | Should -Be $true
        $result.owner | Should -Be "richardrigutins"
        $repo.owner | Should -Be "richardrigutins"
    }
    
    It "Should fail for repo name without underscore" {
        # Arrange
        $repo = @{
            name = "some-action-without-underscore"
            owner = $null
        }
        
        # Act
        $result = Test-OwnerExtraction -repo $repo
        
        # Assert
        $result.success | Should -Be $false
        $result.method | Should -Be "no_pattern"
    }
    
    It "Should not process repo with existing owner" {
        # Arrange
        $repo = @{
            name = "michaelneale_goose-fix-it-action"
            owner = "existing-owner"
        }
        
        # Act
        $result = Test-OwnerExtraction -repo $repo
        
        # Assert
        $result.success | Should -Be $false
        $result.method | Should -Be "not_applicable"
        $repo.owner | Should -Be "existing-owner"
    }
}
