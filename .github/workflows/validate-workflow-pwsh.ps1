Param()

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    try {
        Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to install powershell-yaml: $($_.Exception.Message)"
        throw
    }
}

Import-Module powershell-yaml -Force

$hasErrors = $false

Get-ChildItem -Path $PSScriptRoot -Filter '*.yml' | ForEach-Object {
    $wfItem = $_
    $wfPath = $wfItem.FullName
    Write-Host "Scanning $wfPath..."

    $yaml = Get-Content $wfPath -Raw | ConvertFrom-Yaml
    $jobs = $yaml.jobs
    if (-not $jobs) { return }

    foreach ($jobProp in $jobs.PSObject.Properties) {
        $job = $jobProp.Value
        if (-not $job.steps) { continue }

        $stepIndex = 0
        foreach ($step in $job.steps) {
            $stepIndex++

            $shell = $step.shell
            if (-not $shell -or ($shell -notlike 'pwsh*' -and $shell -notlike 'PowerShell*')) { continue }
            if (-not $step.run) { continue }

            $script = [string]$step.run

            # Sanitize GitHub expression syntax like ${{ ... }} so the
            # PowerShell parser doesn't treat it as invalid variable syntax.
            try {
                $script = [System.Text.RegularExpressions.Regex]::Replace(
                    $script,
                    '\${{.*?}}',
                    '0',
                    [System.Text.RegularExpressions.RegexOptions]::Singleline
                )
            }
            catch {
                # If sanitization fails for any reason, fall back to the
                # original script so we still see parsing errors.
            }
            $tokens = $null
            $errors = $null

            [void][System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$errors)

            if ($errors -and $errors.Count -gt 0) {
                $hasErrors = $true
                $stepName = $step.name
                if ([string]::IsNullOrWhiteSpace($stepName)) {
                    $stepName = "(no step name)"
                }

                Write-Host "Syntax errors in $($wfItem.Name) job '$($jobProp.Name)' step #$stepIndex ('$stepName')" -ForegroundColor Red
                foreach ($err in $errors) {
                    $line = $err.Extent.StartLineNumber
                    $col = $err.Extent.StartColumnNumber
                    $msg = $err.Message
                    Write-Host ("  Line {0}, Col {1}: {2}" -f $line, $col, $msg) -ForegroundColor Red
                }
            }
        }
    }
}

if (-not $hasErrors) {
    Write-Host 'All pwsh run blocks parsed without syntax errors.' -ForegroundColor Green
    exit 0
}
else {
    exit 1
}
