param(
  [Parameter(Mandatory=$true)][string]$Message,
  [Parameter(Mandatory=$true)][string[]]$Paths
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
python tools/release.py check-message --message $Message
if ($LASTEXITCODE -ne 0) { throw 'Invalid Conventional Commit' }
git add -- $Paths
if ($LASTEXITCODE -ne 0) { throw 'git add failed' }
git diff --cached --check
if ($LASTEXITCODE -ne 0) { throw 'Whitespace check failed' }
git diff --cached --quiet
if ($LASTEXITCODE -eq 0) { throw 'No staged changes' }
git commit -m $Message
if ($LASTEXITCODE -ne 0) { throw 'Commit failed' }
