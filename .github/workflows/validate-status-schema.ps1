#!/usr/bin/env pwsh
<#
.SYNOPSIS
Validates the schema of status.json against expected structure.

.DESCRIPTION
This script downloads status.json from blob storage and validates each object
against the expected schema. It checks for required fields, validates field types,
and reports any discrepancies. The workflow fails if validation errors are found.

.PARAMETER sasToken
The blob storage SAS token for downloading status.json

.PARAMETER statusFilePath
Path to the status.json file (if already downloaded). If not provided, downloads from blob.

.EXAMPLE
.\validate-status-schema.ps1 -sasToken $env:BLOB_SAS_TOKEN

.EXAMPLE
.\validate-status-schema.ps1 -statusFilePath "status.json"
#>

Param (
    [Parameter(Mandatory=$false)]
    [string] $sasToken,
    
    [Parameter(Mandatory=$false)]
    [string] $statusFilePath = "status.json"
)

# Import library functions
. $PSScriptRoot/library.ps1

<#
.SYNOPSIS
Defines the expected schema for status.json objects.

.DESCRIPTION
This class represents the structure of action objects in status.json.
Fields can be:
- Required: Must be present in all objects
- Optional: May or may not be present
- Conditional: Present based on certain conditions

Note: Not all objects have identical fields. This class documents the known
schema variations found in the dataset.
#>
class StatusJsonSchema {
    # Core identification fields (typically present)
    [string] $owner
    [string] $name
    
    # Fork and mirror tracking (typically present)
    [object] $forkFound  # Can be boolean or null
    [object] $mirrorLastUpdated  # Can be string (datetime) or null
    [object] $repoSize  # Can be int or null
    [object] $mirrorCommitSha  # Can be string (git SHA) or null; set after a successful mirror sync
    
    # Action type information (typically present but can have varied content)
    [object] $actionType  # Hashtable with fileFound, actionType, nodeVersion, actionDockerType, dockerBaseImage, dockerfileHasCustomCode, containerScan

    # Short blurb from the action's action.yml (optional, null when not found or not yet parsed)
    [object] $description

    # Repository information (typically present)
    [object] $repoInfo  # Hashtable with disabled, archived, updated_at, latest_release_published_at
    
    # Version information (can be string, array, or null)
    [object] $tagInfo
    [object] $releaseInfo
    
    # Security features (typically present)
    [object] $secretScanningEnabled  # Can be boolean or null
    [object] $dependabotEnabled  # Can be boolean or null
    [object] $dependabot  # Can be object or null
    
    # Vulnerability tracking (typically present)
    [object] $vulnerabilityStatus  # Hashtable with critical, high, lastUpdated
    
    # OpenSSF Scorecard (optional)
    [object] $ossf  # Can be boolean or null
    [object] $ossfScore  # Can be int, int64, double, decimal, or null
    [object] $ossfDateLastUpdate  # Can be string (date) or null
    
    # Dependents information (optional)
    [object] $dependents  # Hashtable with dependentsLastUpdated, dependents
    
    # Verification status (typically present)
    [object] $verified  # Can be boolean or null

    # Immutable-release policy tri-state (optional; issue #264). status is one
    # of "enabled"/"disabled"/"unknown" - never inferred as "disabled" when
    # unavailable. checkedAt/source/reason exist to audit the displayed state;
    # reason is only expected to be set when status is "unknown".
    [object] $immutableReleasePolicy  # "enabled", "disabled" or "unknown"
    [object] $immutableReleasePolicyCheckedAt  # Can be string (datetime) or null
    [object] $immutableReleasePolicyReason  # Machine-readable reason string or null
    [object] $immutableReleasePolicySource  # String describing the API call used, or null
    # When the observed immutableReleasePolicy status last actually changed value
    # (issue #266) - distinct from immutableReleasePolicyCheckedAt, which is bumped
    # on every check regardless of whether the value changed.
    [object] $immutableReleasePolicyChangedAt  # Can be string (datetime) or null

    # Append-only per-release immutable-release observation history (optional;
    # issue #265). Unlike immutableReleasePolicy above (current policy only),
    # this is an array with one or more entries per release, built by
    # Merge-ImmutableReleaseObservations so existing entries are never rewritten.
    # Each entry is expected to have:
    #   releaseId              - the GitHub release id (stable key)
    #   tagName                - the release's tag name
    #   publishedAt            - the release's published_at timestamp, or null
    #   immutabilityState      - "immutable", "notImmutable" or "unknown"
    #   status                 - "present" or "deleted" (whether the release existed
    #                             as of this specific observation)
    #   observedAt             - when this observation entry was recorded
    #   source                 - string describing the API call used, for audit purposes
    #   releaseTargetCommitish - the release's recorded target_commitish (branch name
    #                             or commit SHA), or null (optional; issue #267)
    #   resolvedCommitSha      - the release's tag resolved/peeled to its target commit
    #                             SHA (annotated tags are peeled - see
    #                             Resolve-ReleaseTagCommitSha in repoInfo.ps1), or null
    #                             when not resolved (bounded to the newest releases
    #                             only, to limit extra API calls) (optional; issue #267)
    #   tagReleaseMismatch     - boolean, only set when releaseTargetCommitish is
    #                             itself a full commit SHA that can be honestly
    #                             compared against resolvedCommitSha; null/absent
    #                             otherwise (e.g. target is a branch name) - never
    #                             guessed (optional; issue #267)
    [object] $immutableReleaseObservations  # Array of observation objects, or null
    [object] $immutableReleaseObservationsCheckedAt  # Can be string (datetime) or null

    # Derived immutable-release coverage summary for the ten newest published,
    # non-draft releases (optional; issue #266). Pure derivation from
    # immutableReleaseObservations via Get-ImmutableReleaseCoverage - never
    # inspects raw release data itself, and never pads the denominator with
    # unknown/absent releases as if they were known-good or known-bad.
    #   releasesConsidered     - number of releases actually included (<= 10, never padded)
    #   immutableCount         - count of considered releases known immutable
    #   notImmutableCount      - count of considered releases known not immutable
    #   unknownCount           - count of considered releases with unknown state
    #   knownCount             - immutableCount + notImmutableCount (the summary's denominator)
    #   latestReleaseImmutable - "immutable", "notImmutable" or "unknown" for the single newest release
    #   summary                - human-readable string, e.g. "7 of 8 known releases immutable (last 10; 2 unknown)"
    [object] $immutableReleaseCoverage  # Object with the fields above, or null

    # Concise human-readable rendering combining the current policy with the
    # recent-release coverage summary (optional; issue #267), produced by
    # Get-ImmutableReleaseSummary (library.ps1), e.g.
    # "Enabled; 7 of 8 known releases immutable (last 10; 2 unknown)". A current
    # "enabled"/"disabled" policy is always shown *alongside*, never in place of,
    # the recent-release coverage - an enabled-today policy does not by itself
    # establish that older releases are immutable.
    [object] $immutableReleaseSummary  # String, or null
}

<#
.SYNOPSIS
Validates an action object against the expected schema.

.DESCRIPTION
Checks each field in the action object and validates:
1. Field types are appropriate
2. Nested objects have expected structure
3. Values are in valid formats

.PARAMETER action
The action object to validate

.PARAMETER index
The index of the object in the array (for reporting)

.OUTPUTS
Returns validation result with any warnings or errors
#>
function Test-ActionSchema {
    Param (
        [Parameter(Mandatory=$true)]
        [object] $action,
        
        [Parameter(Mandatory=$true)]
        [int] $index
    )
    
    $warnings = @()
    $errors = @()
    
    # Get all properties of the action
    $actionProperties = $action.PSObject.Properties.Name
    
    # Core fields validation
    if (-not $action.owner) {
        $warnings += "Object ${index}: Missing 'owner' field"
    }
    if (-not $action.name) {
        $warnings += "Object ${index}: Missing 'name' field"
    }
    
    # Validate actionType structure if present
    if ($null -ne $action.actionType) {
        if ($action.actionType -is [hashtable] -or $action.actionType -is [PSCustomObject]) {
            # Expected fields: fileFound, actionType, nodeVersion, actionDockerType, dockerImageReference, dockerBaseImage, dockerfileHasCustomCode, containerScan (all optional)
            # These are all optional as content varies
            
            # Validate containerScan structure if present (for Docker actions)
            if ($null -ne $action.actionType.containerScan) {
                if ($action.actionType.containerScan -is [hashtable] -or $action.actionType.containerScan -is [PSCustomObject]) {
                    # Check for expected nested fields
                    if ($null -eq $action.actionType.containerScan.critical) {
                        $warnings += "Object ${index} ($($action.name)): actionType.containerScan missing 'critical' field"
                    }
                    if ($null -eq $action.actionType.containerScan.high) {
                        $warnings += "Object ${index} ($($action.name)): actionType.containerScan missing 'high' field"
                    }
                    if ($null -eq $action.actionType.containerScan.lastScanned) {
                        $warnings += "Object ${index} ($($action.name)): actionType.containerScan missing 'lastScanned' field"
                    }
                }
                else {
                    $errors += "Object ${index} ($($action.name)): actionType.containerScan should be object, found: $($action.actionType.containerScan.GetType().Name)"
                }
            }
        }
        elseif ($action.actionType -isnot [string]) {
            $warnings += "Object ${index} ($($action.name)): actionType should be object or string, found: $($action.actionType.GetType().Name)"
        }
    }
    
    # Validate repoInfo structure if present
    if ($null -ne $action.repoInfo) {
        if ($action.repoInfo -is [hashtable] -or $action.repoInfo -is [PSCustomObject]) {
            # Check for expected nested fields
            $repoInfoProps = $action.repoInfo.PSObject.Properties.Name
            # Common fields: disabled, archived, updated_at, latest_release_published_at
            if ($null -ne $action.repoInfo.updated_at) {
                # Validate ISO 8601 date format (basic check for YYYY-MM-DD pattern)
                if ($action.repoInfo.updated_at -notmatch '^\d{4}-\d{2}-\d{2}') {
                    $warnings += "Object ${index} ($($action.name)): repoInfo.updated_at has unexpected format: $($action.repoInfo.updated_at)"
                }
            }
        }
        else {
            $warnings += "Object ${index} ($($action.name)): repoInfo should be object, found: $($action.repoInfo.GetType().Name)"
        }
    }
    
    # Validate vulnerabilityStatus structure if present
    if ($null -ne $action.vulnerabilityStatus) {
        if ($action.vulnerabilityStatus -is [hashtable] -or $action.vulnerabilityStatus -is [PSCustomObject]) {
            # Check for expected nested fields
            if ($null -eq $action.vulnerabilityStatus.critical) {
                $warnings += "Object ${index} ($($action.name)): vulnerabilityStatus missing 'critical' field"
            }
            if ($null -eq $action.vulnerabilityStatus.high) {
                $warnings += "Object ${index} ($($action.name)): vulnerabilityStatus missing 'high' field"
            }
            if ($null -eq $action.vulnerabilityStatus.lastUpdated) {
                $warnings += "Object ${index} ($($action.name)): vulnerabilityStatus missing 'lastUpdated' field"
            }
        }
        else {
            $errors += "Object ${index} ($($action.name)): vulnerabilityStatus should be object, found: $($action.vulnerabilityStatus.GetType().Name)"
        }
    }
    
    # Validate dependents structure if present
    if ($null -ne $action.dependents) {
        if ($action.dependents -is [hashtable] -or $action.dependents -is [PSCustomObject]) {
            # Check for expected nested fields
            if ($null -eq $action.dependents.dependentsLastUpdated) {
                $warnings += "Object ${index} ($($action.name)): dependents missing 'dependentsLastUpdated' field"
            }
            if ($null -eq $action.dependents.dependents) {
                $warnings += "Object ${index} ($($action.name)): dependents missing 'dependents' field"
            }
        }
        else {
            $errors += "Object ${index} ($($action.name)): dependents should be object, found: $($action.dependents.GetType().Name)"
        }
    }
    
    # Validate immutableReleasePolicy tri-state if present (issue #264)
    if ($null -ne $action.immutableReleasePolicy) {
        $validPolicyValues = @('enabled', 'disabled', 'unknown')
        if ($validPolicyValues -notcontains $action.immutableReleasePolicy) {
            $errors += "Object ${index} ($($action.name)): immutableReleasePolicy should be one of 'enabled', 'disabled', 'unknown', found: $($action.immutableReleasePolicy)"
        }
        elseif ($action.immutableReleasePolicy -eq 'unknown' -and [string]::IsNullOrWhiteSpace($action.immutableReleasePolicyReason)) {
            $warnings += "Object ${index} ($($action.name)): immutableReleasePolicy is 'unknown' but missing 'immutableReleasePolicyReason'"
        }

        if ($null -eq $action.immutableReleasePolicyCheckedAt) {
            $warnings += "Object ${index} ($($action.name)): immutableReleasePolicy missing 'immutableReleasePolicyCheckedAt' field"
        }
        elseif ($action.immutableReleasePolicyCheckedAt -isnot [string] -and $action.immutableReleasePolicyCheckedAt -isnot [datetime]) {
            $warnings += "Object ${index} ($($action.name)): immutableReleasePolicyCheckedAt should be a date/string, found: $($action.immutableReleasePolicyCheckedAt.GetType().Name)"
        }
        elseif ($action.immutableReleasePolicyCheckedAt -is [string]) {
            $parsedDate = [datetime]::MinValue
            if (-not [datetime]::TryParse($action.immutableReleasePolicyCheckedAt, [ref]$parsedDate)) {
                $warnings += "Object ${index} ($($action.name)): immutableReleasePolicyCheckedAt has unexpected format: $($action.immutableReleasePolicyCheckedAt)"
            }
        }
    }

    # Validate immutableReleaseObservations append-only history if present (issue #265)
    if ($null -ne $action.immutableReleaseObservations) {
        if ($action.immutableReleaseObservations -isnot [array] -and $action.immutableReleaseObservations -isnot [System.Collections.IEnumerable]) {
            $errors += "Object ${index} ($($action.name)): immutableReleaseObservations should be an array, found: $($action.immutableReleaseObservations.GetType().Name)"
        }
        else {
            $validImmutabilityStates = @('immutable', 'notImmutable', 'unknown')
            $validObservationStatuses = @('present', 'deleted')
            $observationIndex = 0
            foreach ($observation in @($action.immutableReleaseObservations)) {
                if ($null -eq $observation) {
                    $warnings += "Object ${index} ($($action.name)): immutableReleaseObservations[$observationIndex] is null"
                    $observationIndex++
                    continue
                }

                if ($null -eq $observation.releaseId) {
                    $warnings += "Object ${index} ($($action.name)): immutableReleaseObservations[$observationIndex] missing 'releaseId' field"
                }

                if ([string]::IsNullOrWhiteSpace($observation.tagName)) {
                    $warnings += "Object ${index} ($($action.name)): immutableReleaseObservations[$observationIndex] missing 'tagName' field"
                }

                if ($validImmutabilityStates -notcontains $observation.immutabilityState) {
                    $errors += "Object ${index} ($($action.name)): immutableReleaseObservations[$observationIndex].immutabilityState should be one of 'immutable', 'notImmutable', 'unknown', found: $($observation.immutabilityState)"
                }

                if ($validObservationStatuses -notcontains $observation.status) {
                    $errors += "Object ${index} ($($action.name)): immutableReleaseObservations[$observationIndex].status should be one of 'present', 'deleted', found: $($observation.status)"
                }

                if ($null -eq $observation.observedAt) {
                    $warnings += "Object ${index} ($($action.name)): immutableReleaseObservations[$observationIndex] missing 'observedAt' field"
                }
                elseif ($observation.observedAt -is [string]) {
                    $parsedDate = [datetime]::MinValue
                    if (-not [datetime]::TryParse($observation.observedAt, [ref]$parsedDate)) {
                        $warnings += "Object ${index} ($($action.name)): immutableReleaseObservations[$observationIndex].observedAt has unexpected format: $($observation.observedAt)"
                    }
                }

                # Release-integrity context is optional (issue #267) - only the
                # newest releases get it resolved, and resolution itself can fail
                # - so absence is expected and never a warning by itself. Only
                # flag a mismatch flag that was set without a resolved SHA to back
                # it up, since that combination should never happen.
                if ($null -ne $observation.tagReleaseMismatch -and [string]::IsNullOrWhiteSpace($observation.resolvedCommitSha)) {
                    $warnings += "Object ${index} ($($action.name)): immutableReleaseObservations[$observationIndex].tagReleaseMismatch is set without a 'resolvedCommitSha'"
                }
                if (-not [string]::IsNullOrWhiteSpace($observation.resolvedCommitSha) -and $observation.resolvedCommitSha -notmatch '^[0-9a-f]{40}$') {
                    $warnings += "Object ${index} ($($action.name)): immutableReleaseObservations[$observationIndex].resolvedCommitSha has unexpected format: $($observation.resolvedCommitSha)"
                }

                $observationIndex++
            }
        }

        if ($null -eq $action.immutableReleaseObservationsCheckedAt) {
            $warnings += "Object ${index} ($($action.name)): immutableReleaseObservations missing 'immutableReleaseObservationsCheckedAt' field"
        }
        elseif ($action.immutableReleaseObservationsCheckedAt -isnot [string] -and $action.immutableReleaseObservationsCheckedAt -isnot [datetime]) {
            $warnings += "Object ${index} ($($action.name)): immutableReleaseObservationsCheckedAt should be a date/string, found: $($action.immutableReleaseObservationsCheckedAt.GetType().Name)"
        }
        elseif ($action.immutableReleaseObservationsCheckedAt -is [string]) {
            $parsedDate = [datetime]::MinValue
            if (-not [datetime]::TryParse($action.immutableReleaseObservationsCheckedAt, [ref]$parsedDate)) {
                $warnings += "Object ${index} ($($action.name)): immutableReleaseObservationsCheckedAt has unexpected format: $($action.immutableReleaseObservationsCheckedAt)"
            }
        }
    }

    # Validate the derived immutableReleaseCoverage summary if present (issue #266)
    if ($null -ne $action.immutableReleaseCoverage) {
        if ($action.immutableReleaseCoverage -isnot [hashtable] -and $action.immutableReleaseCoverage -isnot [PSCustomObject]) {
            $errors += "Object ${index} ($($action.name)): immutableReleaseCoverage should be an object, found: $($action.immutableReleaseCoverage.GetType().Name)"
        }
        else {
            $coverage = $action.immutableReleaseCoverage
            $validLatestReleaseStates = @('immutable', 'notImmutable', 'unknown')
            if ($validLatestReleaseStates -notcontains $coverage.latestReleaseImmutable) {
                $errors += "Object ${index} ($($action.name)): immutableReleaseCoverage.latestReleaseImmutable should be one of 'immutable', 'notImmutable', 'unknown', found: $($coverage.latestReleaseImmutable)"
            }

            if ($null -eq $coverage.releasesConsidered) {
                $warnings += "Object ${index} ($($action.name)): immutableReleaseCoverage missing 'releasesConsidered' field"
            }
            elseif ($coverage.releasesConsidered -gt 10) {
                $errors += "Object ${index} ($($action.name)): immutableReleaseCoverage.releasesConsidered should never exceed 10, found: $($coverage.releasesConsidered)"
            }

            if ($null -ne $coverage.immutableCount -and $null -ne $coverage.notImmutableCount -and $null -ne $coverage.knownCount) {
                if (($coverage.immutableCount + $coverage.notImmutableCount) -ne $coverage.knownCount) {
                    $errors += "Object ${index} ($($action.name)): immutableReleaseCoverage.knownCount should equal immutableCount + notImmutableCount, found: $($coverage.knownCount) vs $($coverage.immutableCount + $coverage.notImmutableCount)"
                }
            }

            if ([string]::IsNullOrWhiteSpace($coverage.summary)) {
                $warnings += "Object ${index} ($($action.name)): immutableReleaseCoverage missing 'summary' field"
            }
        }
    }

    # Validate the composed immutableReleaseSummary rendering if present (issue #267).
    # This must never collapse the tri-state policy or the unknown/known coverage
    # counts into a bare pass/fail - it is expected to always start with one of the
    # three policy labels below, so callers relying on it can still tell "disabled"
    # and "unknown" apart from "enabled" at a glance.
    if ($null -ne $action.immutableReleaseSummary) {
        if ($action.immutableReleaseSummary -isnot [string]) {
            $errors += "Object ${index} ($($action.name)): immutableReleaseSummary should be a string, found: $($action.immutableReleaseSummary.GetType().Name)"
        }
        else {
            $validSummaryPrefixes = @('Enabled;', 'Disabled;', 'Unknown;')
            $hasValidPrefix = $false
            foreach ($prefix in $validSummaryPrefixes) {
                if ($action.immutableReleaseSummary.StartsWith($prefix)) {
                    $hasValidPrefix = $true
                    break
                }
            }
            if (-not $hasValidPrefix) {
                $warnings += "Object ${index} ($($action.name)): immutableReleaseSummary does not start with a recognized policy label ('Enabled;'/'Disabled;'/'Unknown;'), found: $($action.immutableReleaseSummary)"
            }
        }
    }

    # Validate boolean fields
    $booleanFields = @('forkFound', 'secretScanningEnabled', 'dependabotEnabled', 'verified', 'ossf')
    foreach ($field in $booleanFields) {
        if ($null -ne $action.$field) {
            $value = $action.$field
            if ($value -isnot [bool] -and $value -ne $true -and $value -ne $false) {
                # Allow null but warn about unexpected types
                if ($value -ne "true" -and $value -ne "false") {
                    $warnings += "Object ${index} ($($action.name)): $field should be boolean or null, found: $value (type: $($value.GetType().Name))"
                }
            }
        }
    }
    
    # Validate numeric fields
    if ($null -ne $action.ossfScore) {
        if ($action.ossfScore -isnot [int] -and $action.ossfScore -isnot [int64] -and $action.ossfScore -isnot [double] -and $action.ossfScore -isnot [decimal]) {
            $warnings += "Object ${index} ($($action.name)): ossfScore should be numeric, found: $($action.ossfScore) (type: $($action.ossfScore.GetType().Name))"
        }
    }
    
    return @{
        Valid = ($errors.Count -eq 0)
        Warnings = $warnings
        Errors = $errors
    }
}

<#
.SYNOPSIS
Validates all objects in status.json

.DESCRIPTION
Iterates through all action objects in status.json and validates each one.
Collects and reports all warnings and errors.

.PARAMETER statusData
The parsed status.json array

.OUTPUTS
Returns summary of validation results
#>
function Test-StatusJsonSchema {
    Param (
        [Parameter(Mandatory=$true)]
        [array] $statusData
    )
    
    Write-Message -message "# Status.json Schema Validation" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "Validating [$(DisplayIntWithDots $statusData.Count)] objects in status.json..." -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    $totalWarnings = 0
    $totalErrors = 0
    $allWarnings = [System.Collections.ArrayList]@()
    $allErrors = [System.Collections.ArrayList]@()
    
    # Sample validation on first 100 objects for detailed reporting
    $sampleSize = [Math]::Min(100, $statusData.Count)
    
    # Validate all objects but only report details for sample
    for ($i = 0; $i -lt $statusData.Count; $i++) {
        $action = $statusData[$i]
        $result = Test-ActionSchema -action $action -index $i
        
        if (-not $result.Valid) {
            $totalErrors += $result.Errors.Count
            foreach ($error in $result.Errors) {
                [void]$allErrors.Add($error)
            }
        }
        
        if ($result.Warnings.Count -gt 0) {
            $totalWarnings += $result.Warnings.Count
            if ($i -lt $sampleSize) {
                foreach ($warning in $result.Warnings) {
                    [void]$allWarnings.Add($warning)
                }
            }
        }
    }
    
    # Report statistics
    Write-Message -message "## Validation Summary" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "| Metric | Count |" -logToSummary $true
    Write-Message -message "|--------|-------|" -logToSummary $true
    Write-Message -message "| Total Objects | $(DisplayIntWithDots $statusData.Count) |" -logToSummary $true
    Write-Message -message "| Validation Errors | $(DisplayIntWithDots $totalErrors) |" -logToSummary $true
    Write-Message -message "| Validation Warnings | $(DisplayIntWithDots $totalWarnings) |" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Report detailed warnings (sample only to avoid overwhelming output)
    if ($allWarnings.Count -gt 0) {
        Write-Message -message "## Warnings (Sample from first $sampleSize objects)" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        Write-Message -message "_Note: Only showing warnings from first $sampleSize objects to avoid overwhelming output._" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        
        # Group warnings by type (pattern) - normalize by removing object indices, names, and specific values
        $warningGroups = $allWarnings | Group-Object { 
            # Remove "Object N (name):" prefix
            $normalized = $_ -replace 'Object \d+( \([^)]+\))?:\s*', ''
            
            # Normalize specific patterns to group similar warnings
            # Remove specific dates/times (e.g., "10/27/2022 13:14:18" -> "date/time value")
            $normalized = $normalized -replace '\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2}', '<date>'
            # Remove specific dates (e.g., "2023-05-01T16:10:08Z" -> "date value")
            $normalized = $normalized -replace '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}', '<date>'
            # Remove specific numeric values in "found: X (type: Y)" patterns
            $normalized = $normalized -replace 'found: \d+(\.\d+)? \(type: \w+\)', 'found: <value> (type: <type>)'
            # Remove specific type names
            $normalized = $normalized -replace '\(type: \w+\)', '(type: <type>)'
            
            return $normalized
        } | Sort-Object Count -Descending
        
        foreach ($group in $warningGroups | Select-Object -First 10) {
            # Extract the warning type description
            $typeDescription = $group.Name
            $count = $group.Count
            
            Write-Message -message "### [$count x] $typeDescription" -logToSummary $true
            Write-Message -message "" -logToSummary $true
            
            # Show first 3 actual examples with object names (original format)
            $examples = $group.Group | Select-Object -First 3
            foreach ($example in $examples) {
                Write-Message -message "- $example" -logToSummary $true
            }
            
            if ($group.Count -gt 3) {
                Write-Message -message "- ... and $(DisplayIntWithDots ($group.Count - 3)) more" -logToSummary $true
            }
            
            Write-Message -message "" -logToSummary $true
        }
        
        if ($warningGroups.Count -gt 10) {
            Write-Message -message "_... and $(DisplayIntWithDots ($warningGroups.Count - 10)) more warning types_" -logToSummary $true
            Write-Message -message "" -logToSummary $true
        }
    }
    
    # Report all errors (these are critical)
    if ($allErrors.Count -gt 0) {
        Write-Message -message "## ⚠️ Critical Errors" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        foreach ($error in $allErrors) {
            Write-Message -message "- $error" -logToSummary $true
        }
        Write-Message -message "" -logToSummary $true
    }
    
    return @{
        Success = ($totalErrors -eq 0)
        TotalObjects = $statusData.Count
        TotalWarnings = $totalWarnings
        TotalErrors = $totalErrors
        Warnings = $allWarnings
        Errors = $allErrors
    }
}

# Main execution
Write-Host "Starting status.json schema validation..."

# Check if status file exists first
if (Test-Path $statusFilePath) {
    Write-Host "Using existing status.json at: $statusFilePath"
}
elseif (-not [string]::IsNullOrEmpty($sasToken)) {
    Write-Host "Downloading status.json from blob storage..."
    $result = Get-StatusFromBlobStorage -sasToken $sasToken
    if (-not $result) {
        Write-Error "Failed to download status.json from blob storage"
        exit 1
    }
}
else {
    Write-Error "status.json not found at '$statusFilePath' and no SAS token provided for download"
    exit 1
}

# Validate file exists and is not empty
if (-not (Test-Path $statusFilePath)) {
    Write-Error "status.json file not found at: $statusFilePath"
    exit 1
}

$fileSize = (Get-Item $statusFilePath).Length
Write-Host "status.json file size: $fileSize bytes"

if ($fileSize -le 5) {
    Write-Error "status.json is too small ($fileSize bytes) - likely corrupted or empty"
    exit 1
}

# Parse JSON
try {
    Write-Host "Parsing status.json..."
    $jsonContent = Get-Content $statusFilePath -Raw
    $jsonContent = $jsonContent -replace '^\uFEFF', ''  # Remove UTF-8 BOM
    $statusData = $jsonContent | ConvertFrom-Json
    
    if ($null -eq $statusData) {
        Write-Error "Failed to parse status.json - result is null"
        exit 1
    }
    
    # Ensure it's always an array (handle both array and single object)
    if ($statusData -isnot [array]) {
        $statusData = @($statusData)
    }
    
    Write-Host "Successfully parsed status.json with $($statusData.Count) objects"
}
catch {
    Write-Error "Failed to parse status.json: $($_.Exception.Message)"
    exit 1
}

# Validate schema
$validationResult = Test-StatusJsonSchema -statusData $statusData

# Exit with appropriate code
if ($validationResult.Success) {
    Write-Message -message "✅ Schema validation completed successfully!" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "All $($validationResult.TotalObjects) objects validated." -logToSummary $true
    if ($validationResult.TotalWarnings -gt 0) {
        Write-Message -message "" -logToSummary $true
        Write-Message -message "⚠️ Note: $($validationResult.TotalWarnings) warnings were found but do not indicate schema violations." -logToSummary $true
    }
    exit 0
}
else {
    Write-Message -message "❌ Schema validation FAILED!" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    Write-Message -message "Found $($validationResult.TotalErrors) critical errors that indicate schema changes." -logToSummary $true
    exit 1
}
