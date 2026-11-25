<#
.SYNOPSIS
Unpacks a bootstrap that New-ProjectBootstrap.ps1 stored in the project's repository (branch "bootstrap")
on a new laptop: decrypts its state, so the next -Mode Plan or Apply continues from it.

.DESCRIPTION
Run it inside a clone of that branch:

  git clone --branch bootstrap <repository URL> project-bootstrap
  cd project-bootstrap
  .\Restore-ProjectBootstrap.ps1

It finds output\<name>\bootstrap.tfstate.enc, asks for the passphrase (or reads BOOTSTRAP_STATE_PASSPHRASE)
and writes output\<name>\bootstrap.tfstate beside it - a file the branch's .gitignore keeps out of git.
Then it says what to run next. Nothing is sent anywhere.
#>
[CmdletBinding()]
param(
  # Which output folder, when the branch holds more than one. Default: the only one.
  [string] $Name,
  [switch] $NonInteractive
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\BootstrapBackup.ps1")

$outputRoot = Join-Path $PSScriptRoot "output"
if (-not (Test-Path -LiteralPath $outputRoot)) { throw "No output folder here. Run this inside a clone of the bootstrap branch." }
$folders = @(Get-ChildItem -LiteralPath $outputRoot -Directory)
if ($Name) { $folders = @($folders | Where-Object { $_.Name -eq $Name }) }
if ($folders.Count -ne 1) { throw "Expected one output folder, found $($folders.Count): $((Get-ChildItem -LiteralPath $outputRoot -Directory).Name -join ', '). Use -Name." }
$folder = $folders[0].FullName

$encrypted = Join-Path $folder "bootstrap.tfstate.enc"
$plain = Join-Path $folder "bootstrap.tfstate"
if (-not (Test-Path -LiteralPath $encrypted)) {
  if (Test-Path -LiteralPath $plain) { Write-Host "The state is stored unencrypted: $plain is ready." }
  else { throw "No bootstrap.tfstate.enc or bootstrap.tfstate in $folder." }
}
else {
  if ((Test-Path -LiteralPath $plain) -and -not $NonInteractive) {
    if ((Read-Host "$plain exists and will be replaced. Type 'yes' to go on") -ne "yes") { Write-Host "Nothing changed."; exit 1 }
  }
  $passphrase = Get-StatePassphrase -NonInteractive:$NonInteractive
  Unprotect-BootstrapState -Path $encrypted -Destination $plain -Passphrase $passphrase
  Write-Host "Decrypted the state into $plain (git ignores it)."
}

$leaf = Split-Path -Leaf $folder
Write-Host ""
Write-Host "Next:"
Write-Host "  az login"
Write-Host "  `$env:TF_VAR_azure_devops_personal_access_token = '<your token>'"
Write-Host "  `$env:TF_VAR_azure_devops_agent_pat = '<the agent token>'"
Write-Host "  .\New-ProjectBootstrap.ps1 -OutputPath .\output\$leaf -Mode Plan     # no changes = the state matches what exists"
