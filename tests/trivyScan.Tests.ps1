BeforeAll {
    # Note: We can't directly test Invoke-TrivyScan because it requires:
    # 1. Docker to be installed and running
    # 2. Trivy to be installed
    # 3. Network access to download Dockerfiles
    # 4. API tokens for GitHub
    # 
    # Instead, we test the logic around when scans should be triggered
    
    function Get-MockContainerScanField {
        param (
            [DateTime]$lastScanned
        )
        return @{
            critical = 0
            high = 0
            lastScanned = $lastScanned.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            scanError = $null
        }
    }
}

Describe "Trivy Container Scan Logic" {
    Context "Scan timing logic" {
        It "Should need scan when containerScan field is missing" {
            # Arrange
            $action = @{
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Dockerfile"
                }
            }
            
            # Act
            $hasContainerScanField = Get-Member -inputobject $action.actionType -name "containerScan" -Membertype Properties
            $needsContainerScan = !$hasContainerScanField
            
            # Assert
            $needsContainerScan | Should -Be $true
        }
        
        It "Should need scan when last scan is older than 7 days" {
            # Arrange
            $oldScanDate = (Get-Date).AddDays(-8)
            $lastScanned = $oldScanDate.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            
            # Act
            $parsedDate = [DateTime]::Parse($lastScanned)
            $daysSinceLastScan = ((Get-Date) - $parsedDate).Days
            $needsContainerScan = $daysSinceLastScan -gt 7
            
            # Assert
            $needsContainerScan | Should -Be $true
        }
        
        It "Should not need scan when last scan is within 7 days" {
            # Arrange
            $recentScanDate = (Get-Date).AddDays(-3)
            $lastScanned = $recentScanDate.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            
            # Act
            $parsedDate = [DateTime]::Parse($lastScanned)
            $daysSinceLastScan = ((Get-Date) - $parsedDate).Days
            $needsContainerScan = $daysSinceLastScan -gt 7
            
            # Assert
            $needsContainerScan | Should -Be $false
        }
        
        It "Should only scan Dockerfile-based Docker actions" {
            # Arrange - Docker action using remote image
            $action = @{
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Image"
                }
            }
            
            # Act
            $shouldScan = $action.actionType.actionDockerType -eq "Dockerfile"
            
            # Assert
            $shouldScan | Should -Be $false
        }
        
        It "Should scan Docker actions with Dockerfile" {
            # Arrange
            $action = @{
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Dockerfile"
                }
            }
            
            # Act
            $shouldScan = $action.actionType.actionDockerType -eq "Dockerfile"
            
            # Assert
            $shouldScan | Should -Be $true
        }
    }
    
    Context "Container scan result structure" {
        It "Should have expected fields in scan result" {
            # Arrange
            $scanResult = @{
                critical = 5
                high = 10
                lastScanned = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ")
                scanError = $null
            }
            
            # Assert
            $scanResult.ContainsKey("critical") | Should -Be $true
            $scanResult.ContainsKey("high") | Should -Be $true
            $scanResult.ContainsKey("lastScanned") | Should -Be $true
            $scanResult.ContainsKey("scanError") | Should -Be $true
        }
        
        It "Should handle scan error in result" {
            # Arrange
            $scanResult = @{
                critical = 0
                high = 0
                lastScanned = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ")
                scanError = "Docker build failed"
            }
            
            # Assert
            $scanResult.scanError | Should -Be "Docker build failed"
        }
    }
    
    Context "Action type detection" {
        It "Should identify Docker action correctly" {
            # Arrange
            $action = @{
                actionType = @{
                    actionType = "Docker"
                    actionDockerType = "Dockerfile"
                }
            }
            
            # Act & Assert
            $action.actionType.actionType | Should -Be "Docker"
        }
        
        It "Should identify Node action and skip scan" {
            # Arrange
            $action = @{
                actionType = @{
                    actionType = "Node"
                    nodeVersion = "20"
                }
            }
            
            # Act & Assert
            $action.actionType.actionType | Should -Be "Node"
            # Node actions don't have actionDockerType, so scan should be skipped
        }
        
        It "Should identify Composite action and skip scan" {
            # Arrange
            $action = @{
                actionType = @{
                    actionType = "Composite"
                }
            }
            
            # Act & Assert
            $action.actionType.actionType | Should -Be "Composite"
        }
    }
}

Describe "Trivy scan result handling" {
    It "Should store successful scan results" {
        # Arrange
        $action = @{
            owner = "test-owner"
            name = "test-repo"
            actionType = @{
                actionType = "Docker"
                actionDockerType = "Dockerfile"
            }
        }
        $scanResult = @{
            critical = 2
            high = 5
            lastScanned = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ")
            scanError = $null
        }

        # Act
        $hasContainerScanField = Get-Member -inputobject $action.actionType -name "containerScan" -Membertype Properties
        if ($null -ne $scanResult -and $null -eq $scanResult.scanError) {
            if (!$hasContainerScanField) {
                $action.actionType | Add-Member -Name containerScan -Value $scanResult -MemberType NoteProperty
            }
            else {
                $action.actionType.containerScan = $scanResult
            }
        }

        # Assert
        $action.actionType.containerScan.critical | Should -Be 2
        $action.actionType.containerScan.high | Should -Be 5
    }

    It "Should not store failed scan results so they can be retried" {
        # Arrange
        $action = @{
            owner = "test-owner"
            name = "test-repo"
            actionType = @{
                actionType = "Docker"
                actionDockerType = "Dockerfile"
                fileFound = "action.yml"
            }
        }
        $scanResult = @{
            critical = 0
            high = 0
            lastScanned = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ")
            scanError = "Trivy installation failed"
        }
        $trivyScanFailures = @()

        # Act
        $hasContainerScanField = Get-Member -inputobject $action.actionType -name "containerScan" -Membertype Properties
        if ($null -ne $scanResult -and $null -eq $scanResult.scanError) {
            if (!$hasContainerScanField) {
                $action.actionType | Add-Member -Name containerScan -Value $scanResult -MemberType NoteProperty
            }
            else {
                $action.actionType.containerScan = $scanResult
            }
        }
        elseif ($null -ne $scanResult -and $null -ne $scanResult.scanError) {
            $dockerSource = if ($action.actionType.fileFound) { $action.actionType.fileFound } else { $action.actionType.actionDockerType }
            $trivyScanFailures += @{
                ownerRepo = "$($action.owner)/$($action.name)"
                dockerSource = $dockerSource
                error = $scanResult.scanError
                timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ")
            }
        }

        # Assert
        $action.actionType.PSObject.Properties.Name | Should -Not -Contain "containerScan"
        $trivyScanFailures.Count | Should -Be 1
        $trivyScanFailures[0].ownerRepo | Should -Be "test-owner/test-repo"
        $trivyScanFailures[0].dockerSource | Should -Be "action.yml"
        $trivyScanFailures[0].error | Should -Be "Trivy installation failed"
    }
}

Describe "Trivy scan failure artifact" {
    It "Should write failures to JSON file" {
        # Arrange
        $tempDir = [System.IO.Path]::GetTempPath()
        $testFile = Join-Path $tempDir "trivy-scan-failures-test.json"
        if (Test-Path $testFile) {
            Remove-Item $testFile -Force
        }

        $trivyScanFailures = @(
            @{
                ownerRepo = "owner/repo"
                dockerSource = "action.yml"
                error = "Trivy installation failed"
                timestamp = "2026-07-26T22:00:00.000Z"
            }
        )

        # Act
        $trivyScanFailures | ConvertTo-Json -Depth 5 | Out-File -FilePath $testFile -Encoding UTF8

        # Assert
        Test-Path $testFile | Should -Be $true
        $content = Get-Content $testFile -Raw | ConvertFrom-Json
        $content.Count | Should -Be 1
        $content[0].ownerRepo | Should -Be "owner/repo"
        $content[0].dockerSource | Should -Be "action.yml"
        $content[0].error | Should -Be "Trivy installation failed"

        # Cleanup
        Remove-Item $testFile -Force
    }
}

Describe "Trivy install caching and fail-fast behaviour" {
    Context "Ensure-TrivyInstalled state machine" {
        BeforeEach {
            # Load only the state machine contract, not the whole repoInfo.ps1 script (which
            # needs API tokens). These mirror the tri-state cache in repoInfo.ps1.
            $script:trivyState = $null
            $script:trivyUnavailableReason = $null
            $script:installAttempts = 0

            function Ensure-TrivyInstalledMock {
                if ($script:trivyState -eq 'available') { return $true }
                if ($script:trivyState -eq 'unavailable') { return $false }
                $script:installAttempts++
                $script:trivyState = 'unavailable'
                $script:trivyUnavailableReason = "simulated 404 from the download CDN"
                return $false
            }
        }

        It "Attempts the install only once even when called for many repos" {
            1..50 | ForEach-Object { Ensure-TrivyInstalledMock | Out-Null }
            $script:installAttempts | Should -Be 1
        }

        It "Keeps returning false after a failed install without retrying" {
            Ensure-TrivyInstalledMock | Should -Be $false
            Ensure-TrivyInstalledMock | Should -Be $false
            $script:installAttempts | Should -Be 1
        }

        It "Records a reason that is surfaced in the scan error" {
            Ensure-TrivyInstalledMock | Out-Null
            $scanError = "Trivy unavailable: $($script:trivyUnavailableReason)"
            $scanError | Should -Match "simulated 404"
        }

        It "Short-circuits further scans once state is unavailable" {
            Ensure-TrivyInstalledMock | Out-Null
            $skipped = 0
            1..10 | ForEach-Object {
                if ($script:trivyState -eq 'unavailable') { $skipped++ }
            }
            $skipped | Should -Be 10
        }
    }

    Context "Pinned Trivy version" {
        It "repoInfo.ps1 pins a Trivy version rather than tracking latest" {
            $content = Get-Content "$PSScriptRoot/../.github/workflows/repoInfo.ps1" -Raw
            $content | Should -Match '\$script:trivyDefaultVersion\s*=\s*"v\d+\.\d+\.\d+"'
        }

        It "does not use the old sudo pipe install that failed silently" {
            $content = Get-Content "$PSScriptRoot/../.github/workflows/repoInfo.ps1" -Raw
            $content | Should -Not -Match 'sudo sh -s'
            $content | Should -Not -Match 'Invoke-Expression \$installCmd'
        }

        It "captures install output instead of discarding it" {
            $content = Get-Content "$PSScriptRoot/../.github/workflows/repoInfo.ps1" -Raw
            $content | Should -Match 'Trivy install script exit code'
        }
    }

    Context "status.json schema compatibility" {
        It "keeps the containerScan shape unchanged" {
            $result = @{
                critical = 0
                high = 0
                lastScanned = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ")
                scanError = "Trivy unavailable: reason"
            }
            $result.Keys | Sort-Object | Should -Be @('critical', 'high', 'lastScanned', 'scanError')
        }
    }
}

Describe "Ensure-TrivyInstalled (real implementation)" {
    # Unlike the mock-based tests above, these extract and execute the actual
    # Ensure-TrivyInstalled function body from repoInfo.ps1 via its AST, so a regression in the
    # real curl/bash invocation, exit-code handling, or caching logic would actually be caught
    # here. External commands (curl, bash, trivy) are shadowed with PowerShell functions of the
    # same name for the duration of each test - command resolution prefers functions over
    # native executables, so Ensure-TrivyInstalled's calls to them are redirected here without
    # touching the network or the real trivy binary.
    BeforeAll {
        $repoInfoPath = "$PSScriptRoot/../.github/workflows/repoInfo.ps1"
        $src = Get-Content $repoInfoPath -Raw
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
        $fnAst = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Ensure-TrivyInstalled' }, $true)
        if ($fnAst.Count -ne 1) { throw "Expected exactly 1 Ensure-TrivyInstalled function in repoInfo.ps1, found $($fnAst.Count)" }
        Invoke-Expression $fnAst[0].Extent.Text
    }

    BeforeEach {
        $script:trivyState = $null
        $script:trivyUnavailableReason = $null
        $script:trivyDefaultVersion = "v9.9.9"
        # Shadow functions in the tests below are defined as `function global:X` so they are
        # visible to Ensure-TrivyInstalled (which does not share a scope with the `It` block
        # that defines them) - they must be removed from the global function table too, or
        # they leak into later tests and make Get-Command find a stale shadow instead of
        # nothing.
        Remove-Item function:curl -ErrorAction SilentlyContinue
        Remove-Item function:bash -ErrorAction SilentlyContinue
        Remove-Item function:trivy -ErrorAction SilentlyContinue
        $env:TRIVY_VERSION = $null

        # The real Ensure-TrivyInstalled prepends a fixed temp directory to $env:PATH on a
        # successful install and leaves it there for the rest of the process (by design - it is
        # meant to persist for the life of a real workflow job). That mutation, plus the fake
        # binary a test's `bash` mock writes to that same real path, otherwise leak into later
        # tests: Get-Command would find the previous test's leftover file on disk even after its
        # shadow functions are gone. Snapshot PATH and clean the directory before every test.
        $script:savedPath = $env:PATH
        $script:trivyTestInstallDir = Join-Path $([System.IO.Path]::GetTempPath()) "trivy-bin"
        Remove-Item $script:trivyTestInstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $([System.IO.Path]::GetTempPath()) "trivy-install.sh") -Force -ErrorAction SilentlyContinue
    }

    AfterEach {
        $env:PATH = $script:savedPath
        Remove-Item $script:trivyTestInstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $([System.IO.Path]::GetTempPath()) "trivy-install.sh") -Force -ErrorAction SilentlyContinue
    }

    AfterAll {
        Remove-Item function:curl -ErrorAction SilentlyContinue
        Remove-Item function:bash -ErrorAction SilentlyContinue
        Remove-Item function:trivy -ErrorAction SilentlyContinue
    }

    It "Detects a working trivy already on PATH without downloading anything" {
        function global:trivy { $global:LASTEXITCODE = 0; "Version: 9.9.9" }
        function global:curl { throw "curl should not be called when trivy is already on PATH" }

        $result = Ensure-TrivyInstalled

        $result | Should -Be $true
        $script:trivyState | Should -Be 'available'
    }

    It "Caches a broken trivy-on-PATH as unavailable instead of trusting it" {
        function global:trivy { $global:LASTEXITCODE = 1; "unsupported architecture" }
        function global:curl { throw "curl should not be called for a broken trivy-on-PATH" }

        # Ensure-TrivyInstalled's contract is to *preserve* whatever $LASTEXITCODE held before
        # it ran, not to force it to any particular value - asserting against a distinctive
        # sentinel (rather than 0) proves genuine preservation instead of coincidentally passing
        # because some earlier native command in the process happened to leave a 0 behind.
        $global:LASTEXITCODE = 42
        $result = Ensure-TrivyInstalled

        $result | Should -Be $false
        $script:trivyState | Should -Be 'unavailable'
        $script:trivyUnavailableReason | Should -Match "not runnable"
        $LASTEXITCODE | Should -Be 42
    }

    It "Downloads and runs the install script via bash when trivy is not on PATH, then verifies it" {
        $global:installedViaBash = $false
        function global:curl {
            # `-o $path` is the last two args in Ensure-TrivyInstalled's curl invocation
            $outPath = $args[$args.IndexOf('-o') + 1]
            Set-Content -Path $outPath -Value "#!/bin/sh`necho fake install script"
            $global:LASTEXITCODE = 0
        }
        function global:bash {
            $global:installedViaBash = $true
            $installDir = $args[$args.IndexOf('-b') + 1]
            New-Item -ItemType Directory -Path $installDir -Force | Out-Null
            Set-Content -Path (Join-Path $installDir "trivy") -Value "fake binary"
            # Simulate the install actually landing a usable `trivy` on PATH: on Windows there
            # is no bare-extensionless-file resolution the way there is on Linux, so this shadow
            # function stands in for the real installed binary that Ensure-TrivyInstalled's
            # post-install Get-Command/--version check expects to find. Defined here, inside the
            # bash mock, rather than before the call - trivy must not exist until "install" runs.
            function global:trivy { $global:LASTEXITCODE = 0; "Version: 9.9.9" }
            $global:LASTEXITCODE = 0
        }

        $result = Ensure-TrivyInstalled

        $result | Should -Be $true
        $script:trivyState | Should -Be 'available'
        $global:installedViaBash | Should -Be $true
        Remove-Item variable:global:installedViaBash -ErrorAction SilentlyContinue
    }

    It "Marks Trivy unavailable, with a captured reason, when the install script itself fails" {
        function global:curl {
            $outPath = $args[$args.IndexOf('-o') + 1]
            Set-Content -Path $outPath -Value "#!/bin/sh`necho fake install script"
            $global:LASTEXITCODE = 0
        }
        function global:bash {
            "aquasecurity/trivy debug http_download_curl received HTTP status 404"
            $global:LASTEXITCODE = 1
        }

        # See the sentinel-value note in "Caches a broken trivy-on-PATH..." above.
        $global:LASTEXITCODE = 42
        $result = Ensure-TrivyInstalled

        $result | Should -Be $false
        $script:trivyState | Should -Be 'unavailable'
        $script:trivyUnavailableReason | Should -Match "404"
        $LASTEXITCODE | Should -Be 42
    }

    It "Does not re-download or re-run bash on a second call once installed" {
        $global:bashCallCount = 0
        function global:curl {
            $outPath = $args[$args.IndexOf('-o') + 1]
            Set-Content -Path $outPath -Value "#!/bin/sh`necho fake install script"
            $global:LASTEXITCODE = 0
        }
        function global:bash {
            $global:bashCallCount++
            $installDir = $args[$args.IndexOf('-b') + 1]
            New-Item -ItemType Directory -Path $installDir -Force | Out-Null
            Set-Content -Path (Join-Path $installDir "trivy") -Value "fake binary"
            # See the "Downloads and runs..." test above for why the shadow is defined here.
            function global:trivy { $global:LASTEXITCODE = 0; "Version: 9.9.9" }
            $global:LASTEXITCODE = 0
        }

        Ensure-TrivyInstalled | Out-Null
        Ensure-TrivyInstalled | Out-Null

        $global:bashCallCount | Should -Be 1
        Remove-Item variable:global:bashCallCount -ErrorAction SilentlyContinue
    }

    It "Does not re-attempt the download after a failed install (fail-fast)" {
        $global:curlCallCount = 0
        function global:curl {
            $global:curlCallCount++
            $global:LASTEXITCODE = 1
        }

        Ensure-TrivyInstalled | Out-Null
        Ensure-TrivyInstalled | Out-Null
        Ensure-TrivyInstalled | Out-Null

        $global:curlCallCount | Should -Be 1
        Remove-Item variable:global:curlCallCount -ErrorAction SilentlyContinue
    }

    It "Fetches the fallback install script from a pinned commit, not the mutable main branch" {
        $content = Get-Content "$PSScriptRoot/../.github/workflows/repoInfo.ps1" -Raw
        $content | Should -Match 'raw\.githubusercontent\.com/aquasecurity/trivy/\$installScriptCommit/contrib/install\.sh'
        $content | Should -Not -Match 'raw\.githubusercontent\.com/aquasecurity/trivy/main/contrib/install\.sh'
    }
}
