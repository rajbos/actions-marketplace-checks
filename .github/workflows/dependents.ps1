function GetDependentsForRepo {
    Param (
        [Parameter(Mandatory=$true)]
        [string]$repo,
        [Parameter(Mandatory=$true)]
        [string]$owner
    )

    try {
        # make the request
        $url = "https://github.com/$owner/$repo/network/dependents"
        $content = Invoke-WebRequest -Uri $url -UseBasicParsing

        # check for 404 status code
        if ($response.StatusCode -eq 404) {
            Write-Host "404 Not Found: The repository or owner does not exist."
            return ""
        }

        # find the text where it says "10 repositories"
        $regex = [regex]"\d{1,3}(,\d{1,3})*\s*\n\s*Repositories"
        $myMatches = $regex.Matches($content.Content)
        # check for regex matches
        if ($myMatches.Count -eq 1) {
            # replace all spaces with nothing
            $found = $myMatches[0].Value.Replace(" ", "").Replace("`n", "").Replace("Repositories", "")
            Write-Debug "Found match: $found"

            return $found
        }
        else {
            Write-Debug "Found $($myMatches.Count) matches for owner [$owner] and repo [$repo]: https://github.com/$owner/$repo/network/dependents"
            return ""
        }
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            Write-Host "404 Not Found: The repository or owner does not exist for [$owner/$repo]"
        } else {
            Write-Host "Error loading dependents for owner [$owner/$repo]:"
            Write-Host "$_"
        }
        return ""
    }
}

function main {
    $repo = "load-available-actions"
    $owner = "devops-actions"
    $dependents = GetDependentsForRepo -repo $repo -owner $owner
    Write-Host "Dependents: $dependents repositories"
}