# Windows 11 development and GitHub release flow

## No macOS needed on your PC

`Windows 11 (source & Git) -> GitHub (macOS arm64 xcode-27) -> unsigned *.ipa -> LiveContainer on iPhone`.
The IPA is a real compiled device archive (`Payload/MediaMind.app` with arm64 Mach-O), but it is **not signed** and **not yet verified to start inside LiveContainer**.

## First-time setup

1. PowerShell (non-admin in normal user environment):
   ```powershell
   winget install --id Git.Git -e
   winget install --id GitHub.cli -e
   winget install --id Microsoft.VisualStudioCode -e
   ```
2. Restart PowerShell, then:
   ```powershell
   gh auth login
   git config --global user.name "Your Name"
   git config --global user.email "your-github-email@example.com"
   ```
3. Unzip one project, open PowerShell from inside its own project root (where `Package.swift` exists).
4. Publish the first repo (private by default):
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\publish_windows.ps1
   ```
   Change repo name if desired: `-RepoName FlowPaste-iOS`; source project name stays unchanged.
5. GitHub repository **Actions > Build IPA > Run workflow**. After the green run: Artifacts -> download `unsigned-ipa-*` -> extract -> `*.ipa`.
6. On the iPhone import IPA in your configured LiveContainer. Device sign/import mode depends on LiveContainer and should be tested separately; no guarantee of JIT, system entitlements or background work.

## Day-to-day edit/commit/push from Windows

```powershell
git switch -c feature/better-import
# edit with VS Code (or instruct a local AI coding agent that has file/git permissions)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\commit_agent.ps1 -Message 'feat(import): add import preview' -Paths @('Sources/App', 'Tests')
git push -u origin feature/better-import
gh pr create --base master --fill
```

Review CI and merge PR (or configure GitHub's auto-merge in repository settings with required checks). The coding agent can execute these commands itself **only if its environment provides GitHub auth and permission**, and if your repo policy allows it. Writing a prompt does not start a persistent autonomous agent.

## Automatic releases

- On pushes/merges into `master`: `Auto release (Conventional Commits + SemVer)`.
- Commits since most recent `vX.Y.Z` tag determine the highest version bump:
  - `feat(scope): ...` -> minor
  - `fix(scope): ...` or `perf(scope): ...` -> patch
  - `feat!: ...`, `fix(api)!: ...` or `BREAKING CHANGE:` footer -> major
  - `docs/test/ci/chore/refactor/style/build` -> no release by themselves.
- Example: `0.1.0` + `feat:` => `0.2.0`. Releasing also increases the integer iOS bundle build number.
- Workflow creates `release/vX.Y.Z`, updates Xcode version and `CHANGELOG.md`, compiles/tests on `xcode-27`, verifies IPA and publishes GitHub Release with attached unsigned IPA, then fast-forward merges to master and deletes branch.
- If a protected `master` rejects pushing: release is published, release branch is retained, and a PR is attempted; **merging needs an authorized actor/approval**. Never disable branch protection automatically.
- Set repository **Settings > Actions > General > Workflow permissions** so jobs may receive necessary `contents:write` permission, subject to organization policy. To create PR fallback, repo settings may also need **Allow GitHub Actions to create and approve pull requests**.
- For better protected-branch automation install a narrowly scoped GitHub App with appropriate merge/PR privileges, enforce status checks and use repository auto-merge rules; this starter intentionally avoids storing elevated tokens.
- `GITHUB_TOKEN`-initiated pushes may not fire more workflows, so release job includes all checks without relying on a second workflow being triggered.
- Automatic release consumes GitHub-hosted Mac minutes; check GitHub Actions quotas and billing on private repos.

## What Windows can/cannot do

- Windows: edit Swift, run Python version scripts, manage Git/GitHub, inspect workflows, maybe run Swift core tests if Windows Swift and SQLite are configured.
- GitHub runner: compile native SwiftUI with iOS SDK, package proper unsigned IPA, run Swift core tests.
- iPhone: import/sign as needed, test system permissions and actual LiveContainer behaviour.
- Not possible: use Microsoft compiler or rename a ZIP to produce actual arm64 SwiftUI IPA on Windows alone.

## Debug a red build

Open GitHub Actions run -> failing step -> copy first real compiler error and Xcode command context. The most useful log sections are `Build unsigned device IPA`, `Swift Package tests` and `Verify`. Do not interpret a passing Swift/Linux test as a passing iOS build.
