# MediaMind — native SwiftUI for LiveContainer

**Status: native app with automated arm64 IPA builds; LiveContainer permissions and playback require verification on your iPhone.**

Find any moment in locally imported audio/video. Start with SRT/VTT import, transcript search and timecoded playback; transcribe selected recordings offline with Apple Speech when on-device language models work; keep media private.

## Implemented

SwiftUI media library, cancellable file import, local AVPlayer with playback speed and saved position, SRT/VTT import+export, timecoded transcript, Russian/English phrase search and playback from search results. Apple Speech uses on-device recognition only, with a saved checkpoint after each 45-second chunk. Library updates preserve transcripts. Deleted recordings stay in a persistent trash with restore and explicit permanent deletion. No recording from Spotify/YouTube/other apps.

Import limits: 2 GB per media file, 10 MB per subtitle file; UTF-8/UTF-16 subtitles. Files are copied into local storage, with a free-space check. Existing subtitles are replaced only after a successful import or complete transcription. Switching speech language starts a new transcription; checkpoints use the original language. Search shows the first 200 matches and ignores case and diacritics (including е/ё).

## Importing video on iPhone

**Add recording** offers **Video from Photos** and **Audio or video from Files**. Photos uses Apple's video-only PhotosPicker with the current encoding and file-based transfer, without requesting access to the entire photo library. Its temporary file is copied while the provider still owns the source URL and is removed after use. Both sources pass through the same extension, size, disk-space, AVFoundation playback/duration and SQLite checks. Photos transfer temporarily needs room for an additional copy. MOV (including `.MOV`), MP4 and M4V remain supported; a supported container does not guarantee a supported codec.

Files intentionally accepts generic `public.data`: some providers can classify media outside the movie/audio type hierarchy. Validation happens after selection, so other files may be selectable but are rejected explicitly without being saved. The old `.audio`/`.movie` filter acted before the import callback. QuickTime MOV normally conforms to `.movie`, and the importer already lowercased extensions, so neither a general lack of MOV support nor uppercase `.MOV` explains every disabled file. The reported file's exact provider UTI and LiveContainer behavior require device verification. There is no HTML `accept`, MIME upload validation, Safari/PWA frontend or server processing in this native app. `video/quicktime` maps to Apple's QuickTime type; the import pipeline validates the local file instead of trusting MIME metadata.

Manual check on iOS 27 / LiveContainer:

1. Install the new IPA over the existing app while preserving its data. Open **Add recording > Audio or video from Files** and select the reported `export_1792506531523.MOV` from **On My iPhone > Media**. Confirm it becomes a library item and plays for approximately 27 seconds.
2. Repeat with independent copies named `.mov`, `.MoV`, `.mp4`, `.MP4`, `.m4v` and `.M4V`; verify sound, seeking, relaunch persistence, and SRT/VTT import on the resulting items. Renaming a MOV to MP4 does not convert its container; use actual files of each format.
3. Choose **Video from Photos**, select a locally stored video, then select the same video a second time. Verify import and playback both times. Try an iCloud-only video if needed: downloading the selected asset requires a network connection to iCloud, not a MediaMind server.
4. Cancel each picker, then import another file. Stop an active import or switch away from the app during transfer; confirm no incomplete library item is left and a later import works.
5. Select an unrelated text file and a damaged file with a `.MOV` extension through Files. Expect a clear error, no library item and no deletion of the original. Recheck an existing audio import.

Simulator import tests use generated H.264 MOV/MP4, mixed-case suffixes, an M4V-named MP4 container, WAV, malformed media and a disappearing provider source. They exercise local copying, AVFoundation validation, SQLite persistence and temporary-file lifetime. They do not automate the Photos/Files system UI, download iCloud assets or prove compatibility with the reported video or LiveContainer permissions.

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
- Pull requests changing the app run an iPhone simulator launch check and attach a screenshot. The same check is available manually through **iPhone simulator smoke test** in Actions. This verifies simulator launch, not LiveContainer capabilities.
- Deterministic SemVer planner: `python tools/release.py plan` (requires Git history).
- Release on `master`: Conventional Commit changes cause GitHub Actions to create `release/vX.Y.Z`, compile IPA, publish GitHub Release, then merge branch back to master when allowed.
- Master prompt: [MASTER_PROMPT.md](MASTER_PROMPT.md). Agent instructions: [AGENTS.md](AGENTS.md). Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Current constraints

- System clipboard/audio cannot be intercepted across other apps; LiveContainer does not grant extra privileges.
- The artifact is **unsigned**; a compiled IPA is not proof of successful import/run in LiveContainer.
- Developer cannot run Xcode locally on Windows; the Xcode 27 GitHub runner performs compilation.
- Automated branch merge works in non-protected `master`. If protection denies direct pushes, release branch and PR remain for authorized merge (see Windows doc).

Copyright and app identifiers are placeholders; change `Config/project.json` bundle ID before public distribution.
