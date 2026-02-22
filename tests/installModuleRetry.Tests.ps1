Import-Module Pester

BeforeAll {
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "Install-ModuleWithRetry" {
    Context "Parameter validation" {
        It "Should throw when ModuleName is empty string" {
            { Install-ModuleWithRetry -ModuleName "" } | Should -Throw
        }
    }

    Context "Successful installation" {
        It "Should succeed on first attempt when Install-Module works" {
            Mock Install-Module { }
            Mock Write-Host { }

            Install-ModuleWithRetry -ModuleName "TestModule"

            Should -Invoke Install-Module -Times 1 -Exactly
        }
    }

    Context "Retry behavior" {
        It "Should retry on failure and succeed on second attempt" {
            $script:callCount = 0
            Mock Install-Module {
                $script:callCount++
                if ($script:callCount -eq 1) {
                    throw "Unable to find repository 'PSGallery'"
                }
            }
            Mock Write-Host { }
            Mock Write-Warning { }
            Mock Start-Sleep { }

            Install-ModuleWithRetry -ModuleName "TestModule" -InitialDelaySeconds 1

            Should -Invoke Install-Module -Times 2 -Exactly
            Should -Invoke Start-Sleep -Times 1 -Exactly
        }

        It "Should throw after all retries are exhausted" {
            Mock Install-Module { throw "Unable to find repository 'PSGallery'" }
            Mock Write-Host { }
            Mock Write-Warning { }
            Mock Start-Sleep { }

            { Install-ModuleWithRetry -ModuleName "TestModule" -MaxRetries 3 -InitialDelaySeconds 1 } |
                Should -Throw -ExpectedMessage "Failed to install module*after 3 attempts*"

            Should -Invoke Install-Module -Times 3 -Exactly
            Should -Invoke Start-Sleep -Times 2 -Exactly
        }

        It "Should use exponential backoff for delays" {
            $script:delays = @()
            Mock Install-Module { throw "Transient error" }
            Mock Write-Host { }
            Mock Write-Warning { }
            Mock Start-Sleep { $script:delays += $Seconds }

            try {
                Install-ModuleWithRetry -ModuleName "TestModule" -MaxRetries 3 -InitialDelaySeconds 5
            } catch {
                # Expected
            }

            $script:delays.Count | Should -Be 2
            $script:delays[0] | Should -Be 5
            $script:delays[1] | Should -Be 10
        }

        It "Should succeed on third attempt after two failures" {
            $script:callCount = 0
            Mock Install-Module {
                $script:callCount++
                if ($script:callCount -le 2) {
                    throw "Transient error"
                }
            }
            Mock Write-Host { }
            Mock Write-Warning { }
            Mock Start-Sleep { }

            Install-ModuleWithRetry -ModuleName "TestModule" -MaxRetries 3 -InitialDelaySeconds 1

            Should -Invoke Install-Module -Times 3 -Exactly
        }
    }

    Context "Default parameters" {
        It "Should use PSGallery as default repository" {
            Mock Install-Module { } -ParameterFilter { $Repository -eq "PSGallery" }
            Mock Write-Host { }

            Install-ModuleWithRetry -ModuleName "TestModule"

            Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $Repository -eq "PSGallery" }
        }

        It "Should default to 3 max retries" {
            Mock Install-Module { throw "Error" }
            Mock Write-Host { }
            Mock Write-Warning { }
            Mock Start-Sleep { }

            try {
                Install-ModuleWithRetry -ModuleName "TestModule" -InitialDelaySeconds 1
            } catch {
                # Expected
            }

            Should -Invoke Install-Module -Times 3 -Exactly
        }
    }
}
