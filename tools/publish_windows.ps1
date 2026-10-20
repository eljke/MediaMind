param([string]$RepoName = "", [switch]$Public)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Install Git for Windows: winget install Git.Git' }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'Install GitHub CLI: winget install GitHub.cli' }
gh auth status
if ($LASTEXITCODE -ne 0) { throw 'First run: gh auth login' }
if ([string]::IsNullOrWhiteSpace($RepoName)) { $RepoName = (Get-Item (Get-Location)).Name }
if (-not (Test-Path .git)) {
    git init -b master
    git add .
    git commit -m 'chore: initialize iOS app and automation'
    if ($LASTEXITCODE -ne 0) { throw 'First commit failed: configure git user.name/email' }
}
$vis = if ($Public) { '--public' } else { '--private' }
gh repo create $RepoName $vis --source . --remote origin --push
if ($LASTEXITCODE -ne 0) { throw 'Repository creation/push failed (if it already exists, use git push)' }
gh repo view --web
Write-Host 'Actions -> Build IPA -> Run workflow; Release will run on future feat:/fix: pushes to master.'
