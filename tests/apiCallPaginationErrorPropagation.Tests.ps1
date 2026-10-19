BeforeAll {
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "ApiCall pagination error propagation" {
    # Review comment: with returnErrorInfo = $true, a failed later page used to be
    # appended to the successful records by '$response += $nextResult'. Consumers that
    # only check the top-level result then treated the error hashtable as a (null-fielded)
    # record and reported incomplete results as success. The whole-result error must be
    # propagated instead of concatenated.
    BeforeEach {
        $global:RateLimitExceeded = $false
        Mock GetBasicAuthenticationHeader { return "Basic test" }
        $script:invokeCount = 0
    }

    Context "Second page fails with returnErrorInfo" {
        It "Should return the page error as the whole result, not appended to the first page records" {
            Mock Invoke-WebRequest {
                $script:invokeCount++
                if ($script:invokeCount -eq 1) {
                    # First page: succeeds and advertises a next page
                    return New-Object PSObject -Property @{
                        StatusCode = 200
                        Headers = @{
                            "X-RateLimit-Remaining" = @("5000")
                            "X-RateLimit-Reset" = @("9999999999")
                            "X-RateLimit-Used" = @("100")
                            "Link" = '<https://api.github.com/repos/test-org/test-repo/releases?page=2>; rel="next"'
                        }
                        Content = '[{"id":1},{"id":2}]'
                    }
                }
                # Second page (the recursive next-page call): 404 Not Found
                $notFoundException = New-Object System.Net.WebException("Not Found")
                $notFoundResponse = New-Object PSObject -Property @{
                    Headers = @{}
                    StatusCode = [System.Net.HttpStatusCode]::NotFound
                }
                $notFoundException | Add-Member -NotePropertyName Response -NotePropertyValue $notFoundResponse -Force
                $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                    $notFoundException, "WebException",
                    [System.Management.Automation.ErrorCategory]::InvalidOperation, $null
                )
                $errorRecord.ErrorDetails = New-Object System.Management.Automation.ErrorDetails('{"message":"Not Found","status":"404"}')
                throw $errorRecord
            }

            $result = ApiCall -method GET -url "repos/test-org/test-repo/releases" -access_token "test_token" -returnErrorInfo $true -maxRetries 2

            # The error must come back as the whole result...
            $result | Should -BeOfType [hashtable]
            $result.Error | Should -Be $true
            $result.StatusCode | Should -Be 404
            # ...not concatenated behind the first page's records
            $result | Should -Not -BeOfType [array]
        }

        It "Should keep the first page's success shape when the second page also succeeds" {
            Mock Invoke-WebRequest {
                $script:invokeCount++
                if ($script:invokeCount -eq 1) {
                    return New-Object PSObject -Property @{
                        StatusCode = 200
                        Headers = @{
                            "X-RateLimit-Remaining" = @("5000")
                            "X-RateLimit-Reset" = @("9999999999")
                            "X-RateLimit-Used" = @("100")
                            "Link" = '<https://api.github.com/repos/test-org/test-repo/releases?page=2>; rel="next"'
                        }
                        Content = '[{"id":1},{"id":2}]'
                    }
                }
                return New-Object PSObject -Property @{
                    StatusCode = 200
                    Headers = @{
                        "X-RateLimit-Remaining" = @("5000")
                        "X-RateLimit-Reset" = @("9999999999")
                        "X-RateLimit-Used" = @("101")
                    }
                    Content = '[{"id":3}]'
                }
            }

            $result = ApiCall -method GET -url "repos/test-org/test-repo/releases" -access_token "test_token" -maxRetries 2

            # Both pages concatenated
            $result.Count | Should -Be 3
        }
    }
}

Describe "ApiCall same-URL retries replay the entry result counter" {
    # Review comment: the pagination handling advances $currentResultCount with each
    # fetched page, but same-URL retries (rate limit waits, app switches, backoff) re-fetch
    # the current page and must replay with the counter supplied to this invocation -
    # forwarding the advanced value would count the current page twice and stop
    # pagination early when maxResultCount is set.
    BeforeAll {
        $script:libraryContent = Get-Content "$PSScriptRoot/../.github/workflows/library.ps1" -Raw
    }

    It "Should capture the counter as supplied to this invocation at entry" {
        $script:libraryContent | Should -Match '\$currentResultCountAtEntry\s*=\s*\$currentResultCount'
    }

    It "Should replay the entry counter from every same-URL retry call" {
        $retryLines = ($script:libraryContent -split "`n") | Where-Object { $_ -match 'return\s+ApiCall\s+-method\s+\$method\s+-url\s+\$url\s' }
        $retryLines.Count | Should -BeGreaterThan 0
        $offenders = $retryLines | Where-Object { $_ -notmatch '-currentResultCount\s+\$currentResultCountAtEntry' }
        $offenders.Count | Should -Be 0 -Because "every same-URL retry must replay the entry counter, offending lines: [$($offenders -join ' | ')]"
    }

    It "Should still forward the advanced counter when fetching the next page" {
        $paginationLine = ($script:libraryContent -split "`n") | Where-Object { $_ -match '\$nextResult\s*=\s*ApiCall\s+-method\s+\$method\s+-url\s+\$nextUrl\s' }
        $paginationLine.Count | Should -Be 1
        $paginationLine | Should -Match '-currentResultCount\s+\$currentResultCount\b'
        $paginationLine | Should -Not -Match '-currentResultCount\s+\$currentResultCountAtEntry'
    }
}
