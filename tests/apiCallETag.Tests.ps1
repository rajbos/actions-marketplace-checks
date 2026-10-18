BeforeAll {
    # Import the library functions
    . $PSScriptRoot/../.github/workflows/library.ps1
}

Describe "ApiCall Conditional Request (ETag) Tests" {
    BeforeEach {
        $global:RateLimitExceeded = $false
    }

    Context "Backward compatibility: callers that don't opt in are unaffected" {
        BeforeAll {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            Mock Invoke-WebRequest {
                return New-Object PSObject -Property @{
                    StatusCode = 200
                    Content    = '{"hello":"world"}'
                    Headers    = @{ "ETag" = @('"abc123"') }
                }
            }
        }

        It "Should return the raw response body when -returnETag is not used" {
            $result = ApiCall -method GET -url "some/endpoint" -access_token "test_token"
            $result.hello | Should -Be "world"
        }

        It "Should not send an If-None-Match header when -etag is passed without -returnETag" {
            $capturedHeaders = $null
            Mock Invoke-WebRequest {
                $script:capturedHeaders = $Headers
                return New-Object PSObject -Property @{
                    StatusCode = 200
                    Content    = '{"hello":"world"}'
                    Headers    = @{ "ETag" = @('"abc123"') }
                }
            }
            ApiCall -method GET -url "some/endpoint" -access_token "test_token" -etag '"old-etag"' | Out-Null
            $script:capturedHeaders.ContainsKey('If-None-Match') | Should -Be $false
        }
    }

    Context "Successful request with -returnETag opted in" {
        BeforeAll {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            $script:capturedHeaders = $null
            Mock Invoke-WebRequest {
                $script:capturedHeaders = $Headers
                return New-Object PSObject -Property @{
                    StatusCode = 200
                    Content    = '{"hello":"world"}'
                    Headers    = @{ "ETag" = @('"new-etag-value"') }
                }
            }
        }

        It "Should send If-None-Match when a previous ETag is supplied" {
            ApiCall -method GET -url "some/endpoint" -access_token "test_token" -etag '"old-etag"' -returnETag $true | Out-Null
            $script:capturedHeaders.ContainsKey('If-None-Match') | Should -Be $true
            $script:capturedHeaders['If-None-Match'] | Should -Be '"old-etag"'
        }

        It "Should wrap the response with NotModified=false, the new ETag, and the body in Data" {
            $result = ApiCall -method GET -url "some/endpoint" -access_token "test_token" -etag '"old-etag"' -returnETag $true
            $result.NotModified | Should -Be $false
            $result.ETag | Should -Be '"new-etag-value"'
            $result.Data.hello | Should -Be "world"
        }

        It "Should not send If-None-Match on the very first call (no stored ETag yet)" {
            ApiCall -method GET -url "some/endpoint" -access_token "test_token" -returnETag $true | Out-Null
            $script:capturedHeaders.ContainsKey('If-None-Match') | Should -Be $false
        }
    }

    Context "304 Not Modified response" {
        BeforeAll {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
            Mock Invoke-WebRequest {
                $webResponse = New-Object PSObject -Property @{
                    StatusCode = 304
                    Headers    = @{}
                }
                $exception = New-Object System.Net.WebException("Not Modified")
                $exception | Add-Member -NotePropertyName Response -NotePropertyValue $webResponse -Force
                $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                    $exception,
                    "WebException",
                    [System.Management.Automation.ErrorCategory]::InvalidOperation,
                    $null
                )
                throw $errorRecord
            }
        }

        It "Should return NotModified=true with the original ETag echoed back, and Data=null" {
            $result = ApiCall -method GET -url "some/endpoint" -access_token "test_token" -etag '"unchanged-etag"' -returnETag $true
            $result.NotModified | Should -Be $true
            $result.ETag | Should -Be '"unchanged-etag"'
            $result.Data | Should -Be $null
        }

        It "Should not set the global rate-limit-exceeded flag on a 304" {
            ApiCall -method GET -url "some/endpoint" -access_token "test_token" -etag '"unchanged-etag"' -returnETag $true | Out-Null
            $global:RateLimitExceeded | Should -Be $false
        }

        It "Should not retry (only call Invoke-WebRequest once) on a 304" {
            ApiCall -method GET -url "some/endpoint" -access_token "test_token" -etag '"unchanged-etag"' -returnETag $true | Out-Null
            Assert-MockCalled Invoke-WebRequest -Times 1
        }
    }

    Context "GetRepoTagInfo and GetRepoReleases conditional request wiring" {
        BeforeAll {
            Mock GetBasicAuthenticationHeader { return "Basic test" }
        }

        It "GetRepoTagInfo should return NotModified=true and Data=null on a 304" {
            Mock Invoke-WebRequest {
                $webResponse = New-Object PSObject -Property @{
                    StatusCode = 304
                    Headers    = @{}
                }
                $exception = New-Object System.Net.WebException("Not Modified")
                $exception | Add-Member -NotePropertyName Response -NotePropertyValue $webResponse -Force
                $errorRecord = New-Object System.Management.Automation.ErrorRecord(
                    $exception, "WebException", [System.Management.Automation.ErrorCategory]::InvalidOperation, $null
                )
                throw $errorRecord
            }
            $result = GetRepoTagInfo -owner "octo" -repo "hello" -accessToken "token" -startTime (Get-Date) -etag '"tags-etag"'
            $result.NotModified | Should -Be $true
            $result.Data | Should -Be $null
        }

        It "GetRepoReleases should return the parsed release array and a new ETag on 200" {
            Mock Invoke-WebRequest {
                return New-Object PSObject -Property @{
                    StatusCode = 200
                    Content    = '[{"tag_name":"v1.0.0","target_commitish":"main"}]'
                    Headers    = @{ "ETag" = @('"releases-etag"') }
                }
            }
            $result = GetRepoReleases -owner "octo" -repo "hello" -accessToken "token" -startTime (Get-Date) -etag $null
            $result.NotModified | Should -Be $false
            $result.ETag | Should -Be '"releases-etag"'
            $firstRelease = @($result.Data)[0]
            $firstRelease.tag_name | Should -Be "v1.0.0"
        }
    }
}
