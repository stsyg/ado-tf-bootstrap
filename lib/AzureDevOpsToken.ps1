# Asks Azure DevOps whether a personal access token is accepted, and says what is wrong when it is not.
# Dot-sourced by New-ProjectBootstrap.ps1; tests/Test-AzureDevOpsToken.ps1 runs it against a local stand-in.
#
# Why not simply "a call that does not throw": Azure DevOps answers a token it does not accept (expired,
# revoked, made for another organization, or made in another Microsoft Entra tenant) with 203 and the HTML
# of its sign-in page - which Invoke-RestMethod hands back as a string without error. Only a JSON body
# of the expected shape proves the token works.

function Invoke-AzureDevOpsProbe {
  param([string] $Uri, [string] $Token)
  $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Token"))
  try { $response = Invoke-WebRequest -Uri $Uri -Headers @{ Authorization = "Basic $basic" } -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 30 -ErrorAction SilentlyContinue }
  catch { return [pscustomobject]@{ Status = 0; Json = $null; Error = $_.Exception.Message } }
  if ($null -eq $response) { return [pscustomobject]@{ Status = 0; Json = $null; Error = "no answer" } }
  $json = $null
  $type = [string]($response.Headers["Content-Type"] | Select-Object -First 1)
  if ($type -match "json") { try { $json = $response.Content | ConvertFrom-Json } catch { $json = $null } }
  [pscustomobject]@{ Status = [int]$response.StatusCode; Json = $json; Error = $null }
}

# Returns the sign-in address of the token's owner when known; throws with the reason when the token is no good.
function Test-AzureDevOpsToken {
  param([Parameter(Mandatory)] [string] $OrganizationUrl, [Parameter(Mandatory)] [string] $Token)
  $organization = $OrganizationUrl.TrimEnd("/")

  $who = Invoke-AzureDevOpsProbe "$organization/_apis/connectionData?api-version=7.1-preview" $Token
  if ($who.Error) { throw "Could not reach $organization ($($who.Error))." }
  $hasUser = $who.Json -and ($who.Json.PSObject.Properties.Name -contains "authenticatedUser") -and $who.Json.authenticatedUser
  if (-not $hasUser -or $who.Status -ne 200) {
    throw "Azure DevOps does not accept this token for $organization (answer $($who.Status); it did not identify a signed-in user). Typical causes: it has expired or was revoked; it was created for a different organization (the 'Organization' box of the token); it was created under a different Microsoft Entra tenant than the organization's; or the variable still holds an old value. Create a new token for exactly this organization with the scopes in the README, set it in TF_VAR_azure_devops_personal_access_token, and run again."
  }
  $user = $who.Json.authenticatedUser
  $account = $null
  if ($user.properties -and ($user.properties.PSObject.Properties.Name -contains "Account") -and $user.properties.Account) { $account = [string]$user.properties.Account.'$value' }

  $projects = Invoke-AzureDevOpsProbe "$organization/_apis/projects?`$top=1&api-version=7.1" $Token
  if ($projects.Status -ne 200 -or -not $projects.Json) {
    throw "The token is accepted for $organization but may not read projects (answer $($projects.Status)). Give it the scope Project and Team (read, write, manage) - and the others listed in the README - or create a new one."
  }
  $account
}
