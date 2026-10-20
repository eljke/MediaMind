# MediaMind — native SwiftUI for LiveContainer

**Status: native app with automated arm64 IPA builds; LiveContainer permissions and playback require verification on your iPhone.**

Find any moment in locally imported audio/video. Start with SRT/VTT import, transcript search and timecoded playback; transcribe selected recordings offline with Apple Speech when on-device language models work; keep media private.

## Implemented

SwiftUI media library, cancellable file import, local AVPlayer with playback speed and saved position, SRT/VTT import+export, timecoded transcript, Russian/English phrase search and playback from search results. Apple Speech uses on-device recognition only, with a saved checkpoint after each 45-second chunk. Library updates preserve transcripts. Deleted recordings stay in a persistent trash with restore and explicit permanent deletion. No recording from Spotify/YouTube/other apps.

Import limits: 2 GB per media file, 10 MB per subtitle file; UTF-8/UTF-16 subtitles. Files are copied into local storage, with a free-space check. Existing subtitles are replaced only after a successful import or complete transcription. Switching speech language starts a new transcription; checkpoints use the original language. Search shows the first 200 matches and ignores case and diacritics (including е/ё).

## Known gaps

Apple offline speech depends on installed language/system permission and may not work inside LiveContainer; no WhisperKit bundled. Processing needs the app foreground; moving to the background cancels the current operation. Completed speech chunks remain resumable after relaunch; the unfinished chunk is repeated. Audio gaps and interrupted speech requests still depend on Apple's engine. No speaker diarization, semantic search, automatic media download, translation or guaranteed speed benchmarks.

## Windows 11 Quick Start

1. Follow [WINDOWS11_BUILD.md](WINDOWS11_BUILD.md). Install Git and GitHub CLI, authenticate, set Git author name/email.
2. Run `powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\publish_windows.ps1` from the unpacked project root.
3. In GitHub Actions select **Build IPA** → **Run workflow**. Download the artifact and unpack the unsigned `.ipa`.
4. Import/sign under your LiveContainer setup; verify app launch and features on the device.

## Developer operations

- Portable unit tests: `swift test` on supported Swift environment, with SQLite development headers installed (`libsqlite3-dev` on Linux). Release tooling: `python tools/test_release.py`.
- Regenerate Xcode: `python tools/generate_xcodeproj.py` (checked into Git).
- Deterministic SemVer planner: `python tools/release.py plan` (requires Git history).
- Release on `master`: Conventional Commit changes cause GitHub Actions to create `release/vX.Y.Z`, compile IPA, publish GitHub Release, then merge branch back to master when allowed.
- Master prompt: [MASTER_PROMPT.md](MASTER_PROMPT.md). Agent instructions: [AGENTS.md](AGENTS.md). Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Current constraints

- System clipboard/audio cannot be intercepted across other apps; LiveContainer does not grant extra privileges.
- The artifact is **unsigned**; a compiled IPA is not proof of successful import/run in LiveContainer.
- Developer cannot run Xcode locally on Windows; the Xcode 27 GitHub runner performs compilation.
- Automated branch merge works in non-protected `master`. If protection denies direct pushes, release branch and PR remain for authorized merge (see Windows doc).

Copyright and app identifiers are placeholders; change `Config/project.json` bundle ID before public distribution.
