<#
.SYNOPSIS
Tests the Azure DevOps token check against a local stand-in server: a token Azure DevOps does not accept
must be refused - including when it answers 203 and the HTML of its sign-in page, which is what it does
and which a plain REST call does not report as an error.
#>
[CmdletBinding()]
param([string] $KitRoot = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $KitRoot "lib\AzureDevOpsToken.ps1")

$failures = [System.Collections.Generic.List[string]]::new()
function Assert-That([bool] $Condition, [string] $Message) {
  if ($Condition) { Write-Host "  ok   $Message" } else { Write-Host "  FAIL $Message" -ForegroundColor Red; $failures.Add($Message) }
}

# token -> behaviour. Basic auth carries ":<token>".
$behaviour = @{
  "good"       = "ok"
  "noprojects" = "noprojects"
  "expired"    = "signin"
  "revoked"    = "unauthorized"
}

$port = Get-Random -Minimum 20000 -Maximum 40000
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Start()
$job = Start-ThreadJob -ArgumentList $listener, $behaviour -ScriptBlock {
  param($listener, $behaviour)
  while ($listener.IsListening) {
    try { $context = $listener.GetContext() } catch { break }
    $header = $context.Request.Headers["Authorization"]
    $token = ""
    if ($header -match "^Basic (.+)$") { $token = ([Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($Matches[1]))).TrimStart(":") }
    $mode = if ($behaviour.ContainsKey($token)) { $behaviour[$token] } else { "signin" }
    $path = $context.Request.Url.AbsolutePath
    $status = 200; $type = "application/json"
    $body = "{}"
    switch ($mode) {
      "signin" { $status = 203; $type = "text/html"; $body = "<html><title>Sign In</title></html>" }
      "unauthorized" { $status = 401; $type = "text/html"; $body = "Unauthorized" }
      default {
        if ($path -like "*connectionData") { $body = '{"authenticatedUser":{"id":"u1","properties":{"Account":{"$type":"System.String","$value":"owner@contoso.com"}}}}' }
        elseif ($path -like "*projects") {
          if ($mode -eq "noprojects") { $status = 403; $type = "application/json"; $body = '{"message":"TF400813"}' } else { $body = '{"count":1,"value":[{"name":"p"}]}' }
        }
      }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $context.Response.StatusCode = $status
    $context.Response.ContentType = $type
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.Close()
  }
}
try {
  $url = "http://127.0.0.1:$port/org"
  function Get-Result([string] $Token) { try { @{ Ok = $true; Value = (Test-AzureDevOpsToken -OrganizationUrl $url -Token $Token) } } catch { @{ Ok = $false; Value = $_.Exception.Message } } }

  $good = Get-Result "good"
  Assert-That ($good.Ok -and $good.Value -eq "owner@contoso.com") "a working token is accepted and its owner's address returned"
  $expired = Get-Result "expired"
  Assert-That (-not $expired.Ok -and $expired.Value -match "does not accept this token" -and $expired.Value -match "answer 203") "a token answered with the sign-in page (203 + HTML) is refused, with the likely causes"
  $unknown = Get-Result "never-seen"
  Assert-That (-not $unknown.Ok -and $unknown.Value -match "does not accept") "an unknown token is refused"
  $revoked = Get-Result "revoked"
  Assert-That (-not $revoked.Ok -and $revoked.Value -match "answer 401") "a 401 is refused"
  $scope = Get-Result "noprojects"
  Assert-That (-not $scope.Ok -and $scope.Value -match "may not read projects") "a token that cannot read projects says which scope is missing"
  $unreachable = try { Test-AzureDevOpsToken -OrganizationUrl "http://127.0.0.1:1/org" -Token "good"; "no error" } catch { $_.Exception.Message }
  Assert-That ($unreachable -match "Could not reach") "an unreachable organization is reported as such"
}
finally {
  $listener.Stop()
  Remove-Job $job -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) { Write-Host "`n$($failures.Count) check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nAzure DevOps token check tests passed."
