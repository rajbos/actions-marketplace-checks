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

        # find the text where it says "10 repositories"
        $regex = [regex]"\d+\s*\n\s*Repositories"
        $myMatches = $regex.Matches($content.Content)
        # check for regex matches
        if ($myMatches.Count -eq 1) { 
            # replace all spaces with nothing
            $found = $myMatches[0].Value.Replace(" ", "").Replace("`n", " ").Replace("Repositories", "")
            Write-Debug "Found match: $found"
            
            return $found
        }
        else {
            Write-Debug "Found $($myMatches.Count) matches for owner [$owner] and repo [$repo]: https://github.com/$owner/$repo/network/dependents"
            return ""
        }
    }
    catch {
        Write-Host "Error loading dependents for owner [$owner] and repo [$repo]:"
        Write-Host "$_"
        return ""
    }
}

function main {
    $repo = "load-available-actions"
    $owner = "devops-actions"
    $dependents = GetDependentsForRepo -repo $repo -owner $owner
    Write-Host "Dependents: $dependents repositories"
}