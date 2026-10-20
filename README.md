# MediaMind — native SwiftUI for LiveContainer

**Status: native app with automated arm64 IPA builds; LiveContainer permissions and playback require verification on your iPhone.**

Find any moment in locally imported audio/video. Start with SRT/VTT import, transcript search and timecoded playback; transcribe selected recordings offline with Apple Speech when on-device language models work; keep media private.

## Implemented

SwiftUI media library, cancellable file import, local AVPlayer with playback speed and saved position, SRT/VTT import+export, timecoded transcript, Russian/English phrase search and playback from search results. Apple Speech uses on-device recognition only, with a saved checkpoint after each 45-second chunk. SpeechAnalyzer uses installed models on supported systems; SFSpeechRecognizer provides the legacy offline path. Library updates preserve transcripts. Deleted recordings stay in a persistent trash with restore and explicit permanent deletion. No recording from Spotify/YouTube/other apps.

Import limits: 2 GB per media file, 10 MB per subtitle file; UTF-8/UTF-16 subtitles. Files are copied into local storage, with a free-space check. Existing subtitles are replaced only after a successful import or complete transcription. Switching speech language starts a new transcription; checkpoints use the original language. Search ignores case and diacritics (including е/ё), searches names, transcript text and bookmark notes, and loads 50 matches at a time.

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

## Returning to recordings

Each recording shows its transcript status: no transcript, ready, paused, recognition failed, or an active operation. A failed retry leaves the previous transcript intact; the last error and completed chunks survive relaunch. Importing subtitles or successfully completing recognition clears the error. Progress is indeterminate during preparation and shows a percentage once measured progress is available.

The library's **Continue listening** section shows up to three unfinished recordings ordered by last playback. Position is saved every five seconds during playback and flushed on native pause, leaving the recording and entering the background. Opening a recording without playing does not change listening history. Recordings with no progress or at most one second remaining are excluded; trashed recordings remain hidden until restored. Background entry pauses playback. Previous `position-*` preferences migrate into SQLite; their original add date is used until the next actual playback because old versions did not record listening dates.

Use **Bookmarks > Add** on a recording to capture the current timestamp, optionally with a note of up to 2000 characters. Tap a bookmark to play from that time; its menu edits the note or deletes the bookmark. Deletion can be undone using **Restore** in the message bar. Unsaved note edits require an explicit discard. Bookmarks remain attached to the recording when renamed, when its transcript is replaced and while it is in the trash. Permanent deletion removes them together with the recording.

Schema v2 adds bookmarks, playback and recognition-failure tables. Existing databases are backed up through SQLite's backup API before migration; backups stay beside `library.sqlite` as `library.sqlite.v0-backup.sqlite` or `library.sqlite.v1-backup.sqlite`. Migration failure does not rewrite existing recordings or transcripts. Downgrading requires restoring the older database backup; older app versions intentionally reject schema v2.

Manual verification: play a recording, pause using the native player, return to the library and resume from **Continue listening**. Relaunch and verify the same position. Add and edit a bookmark, jump to it, delete it and restore it. Replace subtitles and trash/restore the recording; verify the bookmark remains. Stop recognition and confirm the paused status; retry a failed recognition and verify the previous text remains available. Check large text, VoiceOver and light/dark appearance on the actual iPhone. Simulator tests cover the native player and persisted state; Apple Speech permissions still require device verification.

## Offline speech readiness

Open **Settings > Recognition** or expand the offline check on a recording. The check shows modern model status, legacy offline capability and the separate SFSpeechRecognizer permission. It never prompts for permission or downloads a model by itself. Refresh after changing iOS settings. Installed SpeechAnalyzer models take priority on supported iOS 26+ devices and languages; otherwise the existing offline recognizer is used when authorized and available. SpeechAnalyzer does not require the legacy recognition permission. The microphone is not used for imported recordings.

**Download SpeechAnalyzer model** explicitly requests Apple's system-managed model for the selected language and displays its progress. The initial download needs internet and disk space; media never goes to a server. iOS may retry or continue model downloads after an error, cancellation or leaving the app, so refresh to inspect the actual state. Legacy model installation is not managed by this app. Device/language support is queried at runtime; a ready model is not proof of successful operation in LiveContainer.

Both engines share bounded 45-second audio exports, cancellation, checkpoint validation and temporary-file cleanup. Each finalized chunk is saved before proceeding; silent successful chunks advance progress. Recognition has a 90-second per-chunk timeout. Resuming starts at the last saved boundary, and the unfinished chunk is repeated. Invalid timestamps or checkpoints fail explicitly. **Start over** requires confirmation and keeps the previously published transcript until successful completion. Temporary exports require at least 20 MB free space.

Manual check on iOS 27 / LiveContainer: inspect Russian and English readiness before granting permission; try denied/restricted legacy permission, then a supported installed SpeechAnalyzer model. Download a missing supported model explicitly, interrupt the download and refresh. In airplane mode transcribe a local recording longer than two minutes; stop during a later chunk, relaunch and resume. Check that saved phrases have correct timestamps and are not duplicated, and that old subtitles remain after a failed retry. Recheck a silent recording and video without audio. Test real model download, recognition quality, background interruption and permissions on the physical device; simulator fixtures do not prove those capabilities.

## Search and transcript editing

Search can be limited to names, transcripts or bookmark notes and filtered by audio/video. Results show their source and highlight matching text; phrases and notes open at their timestamp, while name matches open the recording normally. **Show more** loads the next 50 matches with stable ordering; changing the query or filters resets the page. Trash is excluded. SQL binds and escapes the query literally, including `%`, `_` and backslashes. The existing substring semantics are preserved without an extra indexing dependency.

Use the menu beside a transcript fragment to correct its text or merge it with the next fragment. The editor previews the text before saving and allows up to 20000 characters. Correction preserves the fragment's ID and timestamps; merging retains the first ID and extends its end to cover both fragments. Bookmark timestamps are independent and remain unchanged. Saving requires explicit consent to discard an unfinished recognition checkpoint. The message bar can undo the last text edit during the current session; undo restores text and time ranges, not discarded recognition progress or old errors. Stale edits or undo attempts cannot overwrite a newer transcript.

**Export notes with timestamps** creates a local TXT containing the recording title, bookmark times and notes. Existing SRT/VTT/TXT transcript export remains available. Manual check: find an item by name before it has a transcript, find a bookmark by note text, change search filters and load multiple pages. Correct and merge fragments, undo the change, then replace subtitles and verify old undo cannot overwrite them. Export notes and check timestamps and multiline text in Files.

## Known gaps

Apple offline speech depends on device/language support and installed models, and may not work inside LiveContainer; the legacy engine also requires recognition permission. No WhisperKit is bundled. Processing needs the app foreground; moving to the background cancels the current operation. Completed speech chunks remain resumable after relaunch; the unfinished chunk is repeated. Audio gaps and interrupted speech requests still depend on Apple's engine. No speaker diarization, semantic search, automatic media download, translation or guaranteed speed benchmarks.

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
