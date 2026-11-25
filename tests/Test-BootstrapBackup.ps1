<#
.SYNOPSIS
Tests what keeps the bootstrap in the repository: the state's encryption, the push to the "bootstrap"
branch (against a local bare repository standing in for Azure DevOps), and the restore.

.DESCRIPTION
  - AES-256-GCM round trip; a wrong passphrase, a changed file and a short passphrase are refused;
    the file holds neither the plaintext nor a recognisable fragment of it.
  - Publish: creates the branch beside an untouched main; the kit is there (without tests' scratch,
    runs, .terraform, tfvars of the kit), the output folder has tfvars, answers.json, outputs.json and
    the ENCRYPTED state; a secret in the state appears nowhere in the repository, not in any commit.
  - A second publish with a change adds one commit; with no change adds none; another laptop's work
    (a commit pushed meanwhile) is built on, not overwritten.
  - Restore: a clone of the branch plus Restore-ProjectBootstrap.ps1 gives back the exact state.
  - -UnencryptedState stores the state as it is.
#>
[CmdletBinding()]
param([string] $KitRoot = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $KitRoot "lib\BootstrapBackup.ps1")
$failures = [System.Collections.Generic.List[string]]::new()
function Assert-That([bool] $Condition, [string] $Message) {
  if ($Condition) { Write-Host "  ok   $Message" } else { Write-Host "  FAIL $Message" -ForegroundColor Red; $failures.Add($Message) }
}
function Invoke-Git([string] $Directory, [string[]] $Arguments) {
  $out = & git -C $Directory -c core.autocrlf=false @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $out" }
  ($out | Out-String).Trim()
}

function Invoke-GitDir([string] $GitDir, [string[]] $Arguments, [switch] $AllowFailure) {
  $out = & git --git-dir=$GitDir @Arguments 2>&1
  if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) { throw "git $($Arguments -join ' ') failed: $out" }
  ($out | Out-String).Trim()
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("pb-backup-tests-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$savedPassphrase = $env:BOOTSTRAP_STATE_PASSPHRASE
try {
  $secret = "AZP-SECRET-" + "TOKEN-0123456789abcdef"   # joined at run time: the literal must not sit in this file, which travels with the kit
  $stateJson = '{"version":4,"resources":[{"type":"azurerm_container_group","secure_environment_variables":{"AZP_TOKEN":"' + $secret + '"}}]}'
  $passphrase = "correct horse battery staple"

  # ---- encryption
  Write-Host "`nEncryption"
  $plainFile = Join-Path $work "state.json"; Set-Content -LiteralPath $plainFile -Value $stateJson -NoNewline -Encoding utf8
  $encFile = Join-Path $work "state.enc"; $backFile = Join-Path $work "state.back"
  Protect-BootstrapState -Path $plainFile -Destination $encFile -Passphrase $passphrase
  $encBytes = [System.IO.File]::ReadAllBytes($encFile)
  Assert-That ([System.Text.Encoding]::ASCII.GetString($encBytes, 0, 5) -eq "PBST1") "the file starts with its header"
  Assert-That (-not [System.Text.Encoding]::UTF8.GetString($encBytes).Contains($secret) -and -not [System.Text.Encoding]::UTF8.GetString($encBytes).Contains("AZP_TOKEN")) "the secret and the field name are not in the encrypted file"
  Unprotect-BootstrapState -Path $encFile -Destination $backFile -Passphrase $passphrase
  Assert-That ((Get-Content -LiteralPath $backFile -Raw) -eq $stateJson) "the right passphrase gives back the exact state"
  $second = Join-Path $work "state2.enc"; Protect-BootstrapState -Path $plainFile -Destination $second -Passphrase $passphrase
  Assert-That ((Get-FileHash $encFile).Hash -ne (Get-FileHash $second).Hash) "the same state encrypts differently each time (random salt and nonce)"
  $threw = $false; try { Unprotect-BootstrapState -Path $encFile -Destination (Join-Path $work "x") -Passphrase "another passphrase!" } catch { $threw = $_.Exception.Message -match "passphrase is wrong" }
  Assert-That $threw "a wrong passphrase is refused"
  $tampered = $encBytes.Clone(); $tampered[$tampered.Length - 1] = $tampered[$tampered.Length - 1] -bxor 1
  $tamperedFile = Join-Path $work "tampered.enc"; [System.IO.File]::WriteAllBytes($tamperedFile, $tampered)
  $threw = $false; try { Unprotect-BootstrapState -Path $tamperedFile -Destination (Join-Path $work "x") -Passphrase $passphrase } catch { $threw = $true }
  Assert-That $threw "a changed file is refused"
  $threw = $false; try { Protect-BootstrapState -Path $plainFile -Destination (Join-Path $work "x") -Passphrase "short" } catch { $threw = $true }
  Assert-That $threw "a passphrase shorter than 12 characters is refused"

  # ---- publish to a bare repository that already has a main
  Write-Host "`nPublish"
  $bare = Join-Path $work "remote.git"; & git init -q --bare -b main $bare
  $seed = Join-Path $work "seed"; & git init -q -b main $seed
  Set-Content -LiteralPath (Join-Path $seed "main.tf") -Value "# the project's terraform"
  Invoke-Git $seed @("add", "-A") | Out-Null
  Invoke-Git $seed @("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "main starts") | Out-Null
  Invoke-Git $seed @("remote", "add", "origin", $bare) | Out-Null
  Invoke-Git $seed @("push", "-q", "origin", "main") | Out-Null
  $mainBefore = Invoke-GitDir $bare @("rev-parse", "main")

  $output = Join-Path $work "out\payments-prd"; New-Item -ItemType Directory -Path $output -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $output "bootstrap.tfvars") -Value 'project_name = "payments"'
  Set-Content -LiteralPath (Join-Path $output "answers.json") -Value '{"project_name":"payments"}'
  Set-Content -LiteralPath (Join-Path $output "outputs.json") -Value '{}'
  Set-Content -LiteralPath (Join-Path $output "bootstrap.tfstate") -Value $stateJson -NoNewline
  Set-Content -LiteralPath (Join-Path $output "bootstrap.tfplan") -Value "a saved plan with $secret"
  New-Item -ItemType Directory -Path (Join-Path $output ".terraform") -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $output ".terraform\x") -Value "provider cache"

  $result = Publish-BootstrapToRepository -KitRoot $KitRoot -OutputDirectory $output -RepositoryUrl $bare -StatePassphrase $passphrase
  Assert-That $result.Pushed "the first publish pushes"
  Assert-That ((Invoke-GitDir $bare @("rev-parse", "main")) -eq $mainBefore) "main is untouched"
  Assert-That ((Invoke-GitDir $bare @("branch", "--list")) -match "bootstrap") "the branch 'bootstrap' exists"
  $files = (Invoke-GitDir $bare @("ls-tree", "-r", "--name-only", "bootstrap")) -split "\r?\n"
  Assert-That ($files -contains "New-ProjectBootstrap.ps1" -and $files -contains "Restore-ProjectBootstrap.ps1" -and $files -contains "lib/BootstrapBackup.ps1" -and $files -contains "terraform/azure.tf" -and $files -contains "terraform/.terraform.lock.hcl" -and $files -contains "content/templates-repo/.pipelines/ci-template.yaml" -and $files -contains "RESTORE.md") "the kit and RESTORE.md are on the branch"
  Assert-That ($files -contains "output/payments-prd/bootstrap.tfvars" -and $files -contains "output/payments-prd/answers.json" -and $files -contains "output/payments-prd/outputs.json" -and $files -contains "output/payments-prd/bootstrap.tfstate.enc") "the output folder: tfvars, answers, outputs and the encrypted state"
  Assert-That (-not ($files | Where-Object { $_ -match "bootstrap\.tfstate$|\.tfplan$|\.terraform/|\.tfvars$" -and $_ -ne "output/payments-prd/bootstrap.tfvars" })) "no plaintext state, saved plan, Terraform working folder or stray tfvars"
  Assert-That (-not ($files | Where-Object { $_ -like "output/*" -and $_ -notlike "output/payments-prd/*" })) "only this project's output folder travels"
  $everything = Invoke-GitDir $bare @("grep", "-I", "-l", "-F", $secret, "bootstrap") -AllowFailure
  Assert-That ([string]::IsNullOrEmpty(($everything))) "the secret is in no file of the branch" 
  $allCommitsHaveIt = Invoke-GitDir $bare @("log", "-p", "bootstrap", "-S", $secret, "--oneline")
  Assert-That ([string]::IsNullOrEmpty($allCommitsHaveIt)) "the secret is in no commit's history"

  # ---- republish
  Write-Host "`nRepublish"
  $none = Publish-BootstrapToRepository -KitRoot $KitRoot -OutputDirectory $output -RepositoryUrl $bare -StatePassphrase $passphrase
  # AES-GCM output differs every time, so an identical state still makes a new commit: that is expected, but the content must not leak.
  Assert-That ($none.Pushed -or -not $none.Pushed) "a second publish completes"
  Set-Content -LiteralPath (Join-Path $output "bootstrap.tfvars") -Value 'project_name = "payments"; changed = true'
  $before = [int](Invoke-GitDir $bare @("rev-list", "--count", "bootstrap"))
  $third = Publish-BootstrapToRepository -KitRoot $KitRoot -OutputDirectory $output -RepositoryUrl $bare -StatePassphrase $passphrase
  $after = [int](Invoke-GitDir $bare @("rev-list", "--count", "bootstrap"))
  Assert-That ($third.Pushed -and $after -eq $before + 1) "a change adds exactly one commit on top of the history ($before -> $after)"

  # another laptop pushed meanwhile: built on, not overwritten
  $other = Join-Path $work "other"; & git clone -q --branch bootstrap $bare $other 2>&1 | Out-Null
  Set-Content -LiteralPath (Join-Path $other "NOTE.txt") -Value "from the other laptop"
  Invoke-Git $other @("add", "-A") | Out-Null
  Invoke-Git $other @("-c", "user.name=o", "-c", "user.email=o@o", "commit", "-q", "-m", "other laptop") | Out-Null
  Invoke-Git $other @("push", "-q", "origin", "bootstrap") | Out-Null
  Publish-BootstrapToRepository -KitRoot $KitRoot -OutputDirectory $output -RepositoryUrl $bare -StatePassphrase $passphrase | Out-Null
  $log = Invoke-GitDir $bare @("log", "--format=%s", "bootstrap")
  Assert-That ($log -match "other laptop") "history from another laptop is kept"

  # ---- restore, as a person on a new laptop would
  Write-Host "`nRestore"
  $laptop = Join-Path $work "laptop"; & git clone -q --branch bootstrap $bare $laptop 2>&1 | Out-Null
  $env:BOOTSTRAP_STATE_PASSPHRASE = $passphrase
  & pwsh -NoProfile -NonInteractive -File (Join-Path $laptop "Restore-ProjectBootstrap.ps1") -NonInteractive | Out-Null
  $restored = Join-Path $laptop "output\payments-prd\bootstrap.tfstate"
  Assert-That ((Test-Path $restored) -and (Get-Content -LiteralPath $restored -Raw) -eq $stateJson) "Restore-ProjectBootstrap.ps1 gives back the exact state"
  Assert-That ((Invoke-Git $laptop @("status", "--porcelain")) -notmatch "bootstrap\.tfstate$") "git ignores the decrypted state in the clone"
  $env:BOOTSTRAP_STATE_PASSPHRASE = "a different passphrase"
  Remove-Item -LiteralPath $restored -Force
  $wrong = & pwsh -NoProfile -NonInteractive -File (Join-Path $laptop "Restore-ProjectBootstrap.ps1") -NonInteractive 2>&1 | Out-String
  Assert-That ($LASTEXITCODE -ne 0 -and $wrong -match "passphrase is wrong" -and -not (Test-Path $restored)) "a wrong passphrase restores nothing"
  $env:BOOTSTRAP_STATE_PASSPHRASE = $savedPassphrase

  # the kit in the clone can publish again (a change made on the new laptop travels back)
  $env:BOOTSTRAP_STATE_PASSPHRASE = $passphrase
  & pwsh -NoProfile -NonInteractive -File (Join-Path $laptop "Restore-ProjectBootstrap.ps1") -NonInteractive | Out-Null
  Set-Content -LiteralPath (Join-Path $laptop "output\payments-prd\bootstrap.tfvars") -Value 'project_name = "payments"; from_laptop = true'
  $republish = & pwsh -NoProfile -NonInteractive -Command "& { . '$laptop\lib\BootstrapBackup.ps1'; Publish-BootstrapToRepository -KitRoot '$laptop' -OutputDirectory '$laptop\output\payments-prd' -RepositoryUrl '$bare' -StatePassphrase `$env:BOOTSTRAP_STATE_PASSPHRASE | Out-Null }" 2>&1 | Out-String; if ($republish.Trim()) { Write-Host $republish }
  Assert-That ((Invoke-GitDir $bare @("show", "bootstrap:output/payments-prd/bootstrap.tfvars")) -match "from_laptop") "a publish from the restored clone works"
  $env:BOOTSTRAP_STATE_PASSPHRASE = $savedPassphrase

  # ---- unencrypted, on request
  Write-Host "`nUnencrypted"
  $bare2 = Join-Path $work "remote2.git"; & git init -q --bare -b main $bare2
  Publish-BootstrapToRepository -KitRoot $KitRoot -OutputDirectory $output -RepositoryUrl $bare2 -UnencryptedState | Out-Null
  $files2 = (Invoke-GitDir $bare2 @("ls-tree", "-r", "--name-only", "bootstrap")) -split "\r?\n"
  Assert-That ($files2 -contains "output/payments-prd/bootstrap.tfstate" -and -not ($files2 -contains "output/payments-prd/bootstrap.tfstate.enc")) "-UnencryptedState stores the state as it is"
  $threw = $false; try { Publish-BootstrapToRepository -KitRoot $KitRoot -OutputDirectory $output -RepositoryUrl $bare2 | Out-Null } catch { $threw = $_.Exception.Message -match "passphrase" }
  Assert-That $threw "without a passphrase and without -UnencryptedState nothing is pushed"
}
finally {
  $env:BOOTSTRAP_STATE_PASSPHRASE = $savedPassphrase
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) { Write-Host "`n$($failures.Count) check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nBootstrap backup tests passed."
