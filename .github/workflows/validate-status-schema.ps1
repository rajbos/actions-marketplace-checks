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
    
    # Action type information (typically present but can have varied content)
    [object] $actionType  # Hashtable with fileFound, actionType, nodeVersion, actionDockerType, dockerBaseImage
    
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
    [object] $ossfScore  # Can be number or null
    [object] $ossfDateLastUpdate  # Can be string (date) or null
    
    # Dependents information (optional)
    [object] $dependents  # Hashtable with dependentsLastUpdated, dependents
    
    # Verification status (typically present)
    [object] $verified  # Can be boolean or null
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
            # Expected fields: fileFound, actionType, nodeVersion, actionDockerType, dockerBaseImage (optional)
            # These are all optional as content varies
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
        if ($action.ossfScore -isnot [int] -and $action.ossfScore -isnot [double] -and $action.ossfScore -isnot [decimal]) {
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
    Write-Message -message "Validating [$($statusData.Count)] objects in status.json..." -logToSummary $true
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
    Write-Message -message "| Total Objects | $($statusData.Count) |" -logToSummary $true
    Write-Message -message "| Validation Errors | $totalErrors |" -logToSummary $true
    Write-Message -message "| Validation Warnings | $totalWarnings |" -logToSummary $true
    Write-Message -message "" -logToSummary $true
    
    # Report detailed warnings (sample only to avoid overwhelming output)
    if ($allWarnings.Count -gt 0) {
        Write-Message -message "## Warnings (Sample from first $sampleSize objects)" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        Write-Message -message "_Note: Only showing warnings from first $sampleSize objects to avoid overwhelming output._" -logToSummary $true
        Write-Message -message "" -logToSummary $true
        
        # Group warnings by type (pattern) - normalize by removing object indices and names
        $warningGroups = $allWarnings | Group-Object { 
            $normalized = $_ -replace 'Object \d+( \([^)]+\))?:', 'Object:'
            $normalized
        } | Sort-Object Count -Descending
        
        foreach ($group in $warningGroups | Select-Object -First 10) {
            # Extract the warning type description (after the normalized object reference)
            $typeDescription = $group.Name -replace '^Object:\s*', ''
            $count = $group.Count
            
            Write-Message -message "### [$count x] $typeDescription" -logToSummary $true
            Write-Message -message "" -logToSummary $true
            
            # Show first 3 actual examples with object names
            $examples = $group.Group | Select-Object -First 3
            foreach ($example in $examples) {
                Write-Message -message "- $example" -logToSummary $true
            }
            
            if ($group.Count -gt 3) {
                Write-Message -message "- ... and $($group.Count - 3) more" -logToSummary $true
            }
            
            Write-Message -message "" -logToSummary $true
        }
        
        if ($warningGroups.Count -gt 10) {
            Write-Message -message "_... and $($warningGroups.Count - 10) more warning types_" -logToSummary $true
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
