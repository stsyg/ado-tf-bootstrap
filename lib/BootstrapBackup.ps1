# Keeps the bootstrap - the kit and the output folder with its state - in the project's own main
# repository, on a branch called "bootstrap", so it can be pulled on another laptop. Dot-sourced by
# New-ProjectBootstrap.ps1 (which pushes it after a successful apply, or with -Mode Backup) and by
# Restore-ProjectBootstrap.ps1 (which unpacks it). Functions only.
#
# Why a branch, not main: main of the repository is protected (pull request, a passing CI run), and the
# bootstrap is not the project's Terraform. The pipelines run from main only; a push to this branch
# starts nothing.
#
# Why the state is encrypted: the bootstrap's state holds the agent registration token (sensitive, but
# stored in the clear in a state file). A repository is read by many more people than the one who ran
# the bootstrap, so the state is committed as bootstrap.tfstate.enc - AES-256-GCM, key derived from a
# passphrase with PBKDF2-SHA256 (600,000 rounds) - and only a person who knows the passphrase can read
# it. -UnencryptedState commits it as it is, which is only safe where the repository's readers are
# exactly the people who may see every secret in the state.

$script:StateMagic = [System.Text.Encoding]::ASCII.GetBytes("PBST1")
$script:StatePbkdf2Rounds = 600000

function Protect-BootstrapState {
  param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Destination, [Parameter(Mandatory)] [string] $Passphrase)
  if ($Passphrase.Length -lt 12) { throw "The passphrase must be at least 12 characters." }
  $plain = [System.IO.File]::ReadAllBytes($Path)
  $salt = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(16)
  $nonce = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(12)
  $key = [System.Security.Cryptography.Rfc2898DeriveBytes]::Pbkdf2($Passphrase, $salt, $script:StatePbkdf2Rounds, [System.Security.Cryptography.HashAlgorithmName]::SHA256, 32)
  $cipher = [byte[]]::new($plain.Length)
  $tag = [byte[]]::new(16)
  $aes = [System.Security.Cryptography.AesGcm]::new($key, 16)
  try { $aes.Encrypt($nonce, $plain, $cipher, $tag, $script:StateMagic) } finally { $aes.Dispose() }
  $stream = [System.IO.File]::Create($Destination)
  try { foreach ($part in @($script:StateMagic, $salt, $nonce, $tag, $cipher)) { $stream.Write($part, 0, $part.Length) } } finally { $stream.Dispose() }
}

function Unprotect-BootstrapState {
  param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Destination, [Parameter(Mandatory)] [string] $Passphrase)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $magicLength = $script:StateMagic.Length
  if ($bytes.Length -lt ($magicLength + 16 + 12 + 16) -or [System.Text.Encoding]::ASCII.GetString($bytes, 0, $magicLength) -ne "PBST1") {
    throw "$Path is not an encrypted bootstrap state (wrong header)."
  }
  $salt = [byte[]]$bytes[$magicLength..($magicLength + 15)]
  $nonce = [byte[]]$bytes[($magicLength + 16)..($magicLength + 27)]
  $tag = [byte[]]$bytes[($magicLength + 28)..($magicLength + 43)]
  $cipher = if ($bytes.Length -gt ($magicLength + 44)) { [byte[]]$bytes[($magicLength + 44)..($bytes.Length - 1)] } else { [byte[]]::new(0) }
  $key = [System.Security.Cryptography.Rfc2898DeriveBytes]::Pbkdf2($Passphrase, $salt, $script:StatePbkdf2Rounds, [System.Security.Cryptography.HashAlgorithmName]::SHA256, 32)
  $plain = [byte[]]::new($cipher.Length)
  $aes = [System.Security.Cryptography.AesGcm]::new($key, 16)
  try { $aes.Decrypt($nonce, $cipher, $tag, $plain, $script:StateMagic) }
  catch { throw "The passphrase is wrong, or $Path was changed after it was written." }
  finally { $aes.Dispose() }
  [System.IO.File]::WriteAllBytes($Destination, $plain)
}

# The passphrase: BOOTSTRAP_STATE_PASSPHRASE, else asked (twice when writing). Never written anywhere.
function Get-StatePassphrase {
  param([switch] $Confirm, [switch] $NonInteractive)
  if ($env:BOOTSTRAP_STATE_PASSPHRASE) { return $env:BOOTSTRAP_STATE_PASSPHRASE }
  if ($NonInteractive) { throw "Set BOOTSTRAP_STATE_PASSPHRASE: the state is encrypted with it before it is stored in the repository." }
  if ($Confirm) {
    Write-Host "The bootstrap state holds a token in the clear, so it is encrypted before it goes into the repository."
    Write-Host "Choose a passphrase (12+ characters). Keep it in your password manager: without it the stored state cannot be read." -ForegroundColor Yellow
  }
  while ($true) {
    $first = [System.Net.NetworkCredential]::new("", (Read-Host "State passphrase" -AsSecureString)).Password
    if ($first.Length -lt 12) { Write-Host "  At least 12 characters." -ForegroundColor Yellow; continue }
    if (-not $Confirm) { return $first }
    $second = [System.Net.NetworkCredential]::new("", (Read-Host "Again" -AsSecureString)).Password
    if ($first -eq $second) { return $first }
    Write-Host "  They differ." -ForegroundColor Yellow
  }
}

# git with the access token as an HTTP header kept in the environment, not on the command line (where
# another process could read it) and not in a config file or the remote's URL.
function Invoke-BootstrapGit {
  param([Parameter(Mandatory)] [string] $Directory, [Parameter(Mandatory)] [string[]] $Arguments, [string] $Token, [switch] $AllowFailure)
  $saved = @{}
  foreach ($name in "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0", "GIT_TERMINAL_PROMPT") { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
  try {
    $env:GIT_TERMINAL_PROMPT = "0"
    if ($Token) {
      $env:GIT_CONFIG_COUNT = "1"
      $env:GIT_CONFIG_KEY_0 = "http.extraHeader"
      $env:GIT_CONFIG_VALUE_0 = "AUTHORIZATION: Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Token"))
    }
    $output = & git -C $Directory -c core.autocrlf=false -c core.safecrlf=false @Arguments 2>&1
    $code = $LASTEXITCODE
  }
  finally { foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
  if ($code -ne 0 -and -not $AllowFailure) { throw "git $($Arguments -join ' ') failed (exit $code): $(($output | Out-String).Trim())" }
  [pscustomobject]@{ ExitCode = $code; Output = ($output | Out-String).Trim() }
}

# Copies the kit (without runs and scratch) and one output folder into the working copy of the branch.
function Copy-BootstrapContent {
  param([string] $KitRoot, [string] $OutputDirectory, [string] $WorkTree, [string] $StatePassphrase, [switch] $UnencryptedState)
  foreach ($item in Get-ChildItem -LiteralPath $WorkTree -Force | Where-Object { $_.Name -ne ".git" }) { Remove-Item -LiteralPath $item.FullName -Recurse -Force }

  $skip = @("output", ".terraform", ".git")
  foreach ($item in Get-ChildItem -LiteralPath $KitRoot -Force) {
    if ($item.Name -in $skip -or $item.Name -like "*.tfstate*" -or $item.Name -like "*.tfplan") { continue }
    Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $WorkTree $item.Name) -Recurse -Force
  }
  # Nothing a run leaves behind inside the copied kit may travel.
  Get-ChildItem -LiteralPath $WorkTree -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch "\\\.git(\\|$)" -and ($_.Name -eq ".terraform" -or $_.Name -like "*.tfstate*" -or $_.Name -like "*.tfplan" -or $_.Name -like "*.tfvars") } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

  $name = Split-Path -Leaf $OutputDirectory
  $target = Join-Path $WorkTree "output\$name"
  New-Item -ItemType Directory -Path $target -Force | Out-Null
  foreach ($file in "bootstrap.tfvars", "answers.json", "outputs.json") {
    $source = Join-Path $OutputDirectory $file
    if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $target $file) -Force }
  }
  $state = Join-Path $OutputDirectory "bootstrap.tfstate"
  if (-not (Test-Path -LiteralPath $state)) { throw "No bootstrap.tfstate in $OutputDirectory : nothing to keep." }
  if ($UnencryptedState) { Copy-Item -LiteralPath $state -Destination (Join-Path $target "bootstrap.tfstate") -Force }
  else { Protect-BootstrapState -Path $state -Destination (Join-Path $target "bootstrap.tfstate.enc") -Passphrase $StatePassphrase }

  # When this branch is cloned and used, the decrypted state, the saved plan and Terraform's working
  # folder stay on that laptop. (Unencrypted state is the one case where the state is meant to travel.)
  $ignore = @("output/*/*.tfplan", "output/*/.terraform/", ".terraform/")
  if (-not $UnencryptedState) { $ignore = @("output/*/bootstrap.tfstate", "output/*/bootstrap.tfstate.backup") + $ignore }
  Set-Content -LiteralPath (Join-Path $WorkTree ".gitignore") -Encoding utf8 -Value (@("# Stays on the laptop: decrypted state, saved plan, Terraform's working folder.") + $ignore)

  $restore = @(
    "# Pull this bootstrap on another laptop",
    "",
    "This branch (``bootstrap``) of the project's main repository holds the bootstrap kit and the state of what it built.",
    "",
    "~~~pwsh",
    "git clone --branch bootstrap <the repository's URL> project-bootstrap",
    "cd project-bootstrap",
    $(if ($UnencryptedState) { "# the state is stored as it is: output\$name\bootstrap.tfstate" } else { "`$env:BOOTSTRAP_STATE_PASSPHRASE = '<the passphrase>'   # or leave it out and be asked" }),
    $(if ($UnencryptedState) { $null } else { ".\Restore-ProjectBootstrap.ps1                                # decrypts the state into output\$name" }),
    "az login",
    "`$env:TF_VAR_azure_devops_personal_access_token = '<your token>'",
    "`$env:TF_VAR_azure_devops_agent_pat = '<the agent token>'",
    ".\New-ProjectBootstrap.ps1 -OutputPath .\output\$name -Mode Plan   # the answers are the earlier ones; a plan with no changes proves the state matches",
    "~~~",
    "",
    "Terraform, the Azure CLI, git and PowerShell 7 are needed (see README.md). After a change, ``-Mode Apply`` stores the new state here again.")
  Set-Content -LiteralPath (Join-Path $WorkTree "RESTORE.md") -Encoding utf8 -Value ($restore | Where-Object { $null -ne $_ })
}

function Publish-BootstrapToRepository {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $KitRoot,
    [Parameter(Mandatory)] [string] $OutputDirectory,
    [Parameter(Mandatory)] [string] $RepositoryUrl,
    # Azure DevOps personal access token with Code (read & write); empty for a remote that needs none.
    [string] $Token,
    [string] $Branch = "bootstrap",
    [string] $StatePassphrase,
    [switch] $UnencryptedState,
    [string] $AuthorName = "project-bootstrap",
    [string] $AuthorEmail = "project-bootstrap@localhost"
  )
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "git is not installed: the bootstrap cannot be stored in the repository." }
  if (-not $UnencryptedState -and -not $StatePassphrase) { throw "A passphrase is needed to encrypt the state (or -UnencryptedState)." }
  $url = $RepositoryUrl -replace "^(https?://)[^@/]+@", '$1'   # the user name Azure DevOps puts in a clone URL
  $work = Join-Path ([System.IO.Path]::GetTempPath()) ("bootstrap-publish-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
  New-Item -ItemType Directory -Path $work -Force | Out-Null
  try {
    Invoke-BootstrapGit $work @("init", "-q") | Out-Null
    Invoke-BootstrapGit $work @("remote", "add", "origin", $url) | Out-Null
    $fetch = Invoke-BootstrapGit $work @("fetch", "-q", "origin", $Branch) -Token $Token -AllowFailure
    if ($fetch.ExitCode -eq 0) { Invoke-BootstrapGit $work @("checkout", "-q", "-B", $Branch, "FETCH_HEAD") | Out-Null }
    elseif ($fetch.Output -match "(?i)couldn't find remote ref") { Invoke-BootstrapGit $work @("checkout", "-q", "--orphan", $Branch) | Out-Null }
    else { throw "Could not read $url : $($fetch.Output)" }

    Copy-BootstrapContent -KitRoot $KitRoot -OutputDirectory $OutputDirectory -WorkTree $work -StatePassphrase $StatePassphrase -UnencryptedState:$UnencryptedState
    Invoke-BootstrapGit $work @("add", "-A") | Out-Null
    $changes = (Invoke-BootstrapGit $work @("status", "--porcelain")).Output
    if (-not $changes) { Write-Host "The repository already holds this bootstrap: nothing new to store."; return [pscustomobject]@{ Pushed = $false; Branch = $Branch; Url = $url } }
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm 'UTC'")
    $detail = "Stored by New-ProjectBootstrap.ps1.$(if (-not $UnencryptedState) { ' The state is encrypted.' })"
    Invoke-BootstrapGit $work @("-c", "user.name=$AuthorName", "-c", "user.email=$AuthorEmail", "commit", "-q", "-m", "Bootstrap and state, $stamp", "-m", $detail) | Out-Null
    Invoke-BootstrapGit $work @("push", "-q", "origin", "${Branch}:${Branch}") -Token $Token | Out-Null
    [pscustomobject]@{ Pushed = $true; Branch = $Branch; Url = $url }
  }
  finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
