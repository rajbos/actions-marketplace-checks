#Install-Module -Name PSGraphQL -Repository PSGallery -Scope CurrentUser -Allowclobber


function GetBasicAuthenticationHeader(){
    $access_token=$env:GITHUB_TOKEN
    $CredPair = "x:$access_token"
    $EncodedCredentials = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($CredPair))
    
    return "Basic $EncodedCredentials";
}

$query = '
query($name:String!, $owner:String!){
    repository(name: $name, owner: $owner) {
        vulnerabilityAlerts(first: 100) {
            nodes {
                createdAt
                dismissedAt
                securityVulnerability {
                    package {
                        name
                    }
                    advisory {
                        description
                        severity
                    }
                }
            }
        }
    }
}'

$variables = '
    {
        "owner": "actions-marketplace-validations",
        "name": "delete-deployment-environment"
    }'

$uri = "https://api.github.com/graphql"
$requestHeaders = @{
    Authorization = GetBasicAuthenticationHeader
}

$response = Invoke-GraphQLQuery -Query $query -Variables $variables -Uri $uri -Headers $requestHeaders -Raw
Write-Host $response | ConvertTo-Json -Depth 10