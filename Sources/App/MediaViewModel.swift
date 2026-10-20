import SwiftUI
import AVFoundation
import PhotosUI

@MainActor
final class MediaViewModel: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var trash: [MediaItem] = []
    @Published var results: [LibrarySearchHit] = []
    @Published var searchScope = SearchScope.all
    @Published var searchKind = MediaKind.all
    @Published var searching = false
    @Published var moreSearchResults = false
    @Published var transcriptUndo: TranscriptUndo?
    @Published var query = ""
    @Published var busy = false
    @Published var progress = 0.0
    @Published var operationTitle = ""
    @Published var operationItemID: UUID?
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var ready = false
    @Published var revision = 0
    @Published var overview: [UUID: MediaOverview] = [:]
    @Published var bookmarkRevision = 0
    @Published var deletedBookmark: MediaBookmark?
    @Published var speechReadiness: SpeechReadiness?
    @Published var checkingSpeech = false
    @Published var language = UserDefaults.standard.string(forKey: "speechLanguage") ?? "ru-RU" {
        didSet {
            UserDefaults.standard.set(language, forKey: "speechLanguage")
            speechReadiness = nil; speechCheckGeneration += 1; checkingSpeech = false
        }
    }
    private var db: MediaRepository?
    private let root: URL
    private let files = MediaFileImport()
    private let speech: TranscriptionService
    private var operation: Task<Void, Never>?
    private var reloadGeneration = 0
    private var speechCheckGeneration = 0
    private var operationGeneration = 0
    private var searchGeneration = 0
    private var activeSearch = ""

    struct TranscriptUndo {
        let item: MediaItem
        let previous: [SpeechSegment]
        let updated: [SpeechSegment]
    }
    var canCancel: Bool { operation != nil }
    var searchKey: String { "\(query)\u{0}\(searchScope.rawValue)\u{0}\(searchKind.rawValue)" }

    convenience init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MediaMind", isDirectory: true)) {
        self.init(root: root, speech: AppleOfflineSpeech())
    }

    init(root: URL, speech: TranscriptionService) {
        self.root = root
        self.speech = speech
    }

    var continuing: [MediaItem] {
        Array(items.filter { overview[$0.id]?.playback?.canResume(duration: $0.duration) == true }
            .sorted { (overview[$0.id]?.playback?.playedAt ?? .distantPast) > (overview[$1.id]?.playback?.playedAt ?? .distantPast) }.prefix(3))
    }

    func location(_ item: MediaItem) -> URL { root.appendingPathComponent("files", isDirectory: true).appendingPathComponent(item.fileName) }

    var canTranscribe: Bool { speechReadiness?.engine != nil || speechReadiness?.issue == .permissionRequired }

    func checkSpeech() async {
        speechCheckGeneration += 1
        let generation = speechCheckGeneration
        let selected = language
        checkingSpeech = true
        let status = await speech.readiness(language: selected)
        guard generation == speechCheckGeneration, selected == language else { return }
        speechReadiness = status
        checkingSpeech = false
    }

    func requestSpeechPermission() {
        perform("Разрешение на распознавание") { [self] in
            await speech.requestPermission()
            try Task.checkCancellation()
            await checkSpeech()
            return "Проверка разрешения завершена"
        }
    }

    func installSpeechModel() {
        let selected = language
        perform("Загрузка офлайн-модели", cancelled: "Ожидание загрузки остановлено. iOS может продолжить загрузку модели; обнови проверку позже.") { [self] in
            let generation = operationGeneration
            do {
                try await speech.installModel(language: selected) { [weak self] value in
                    guard let self, self.busy, self.operationGeneration == generation else { return }
                    self.progress = value.isFinite ? min(1, max(0, value)) : 0
                }
                try Task.checkCancellation()
                await checkSpeech()
                return "Офлайн-модель установлена"
            } catch {
                await checkSpeech()
                throw error
            }
        }
    }

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        do {
            if db == nil { db = try MediaRepository(url: root.appendingPathComponent("library.sqlite")) }
            guard let db else { return }
            let library = try await db.all()
            let removed = try await db.trashed()
            var next = try await db.overview()
            var migrated = false
            for item in library + removed {
                let key = "position-\(item.id)"
                if let legacy = UserDefaults.standard.object(forKey: key) as? Double {
                    if next[item.id]?.playback == nil && legacy.isFinite && legacy > 0 {
                        try await db.savePlayback(PlaybackPosition(position: legacy, playedAt: item.addedAt), for: item.id)
                        migrated = true
                    }
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            if migrated { next = try await db.overview() }
            guard generation == reloadGeneration else { return }
            for (id, current) in overview {
                if let saved = current.playback, let incoming = next[id], saved.playedAt > (incoming.playback?.playedAt ?? .distantPast) {
                    next[id]?.playback = saved
                }
            }
            items = library
            trash = removed
            overview = next
            ready = true
        } catch { errorMessage = error.localizedDescription }
    }

    func importMedia(_ source: URL) {
        guard ready else { return }
        perform("Импорт файла") { [self] in
            try await storeMedia(source)
            return "Запись добавлена в библиотеку"
        }
    }

    func importVideo(_ selection: PhotosPickerItem) {
        guard ready else { return }
        perform("Импорт видео из Фото") { [self] in
            guard let video = try await selection.loadTransferable(type: ImportedVideo.self) else { throw MediaFileImport.ImportError.unreadable }
            defer { try? FileManager.default.removeItem(at: video.file) }
            try Task.checkCancellation()
            try await storeMedia(video.file, title: video.title)
            return "Видео добавлено в библиотеку"
        }
    }

    func storeMedia(_ source: URL, title: String? = nil) async throws {
        guard let db else { throw MediaRepository.Error.open }
        let granted = source.startAccessingSecurityScopedResource()
        defer { if granted { source.stopAccessingSecurityScopedResource() } }
        let destination = try await files.copyMedia(from: source, to: root.appendingPathComponent("files")) { [weak self] value in
            Task { @MainActor in self?.progress = value }
        }
        do {
            let asset = AVURLAsset(url: destination)
            guard try await asset.load(.isPlayable) else { throw MediaFileImport.ImportError.unplayable }
            let seconds = try await asset.load(.duration).seconds
            guard seconds.isFinite && seconds > 0 else { throw SpeechServiceError.badDuration }
            try Task.checkCancellation()
            try await db.save(MediaItem(title: title ?? source.deletingPathExtension().lastPathComponent, fileName: destination.lastPathComponent, duration: seconds))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        await reload()
    }

    func importSubtitle(_ source: URL, for item: MediaItem) {
        guard let db else { return }
        perform("Импорт субтитров", item: item.id) { [self] in
            let granted = source.startAccessingSecurityScopedResource()
            defer { if granted { source.stopAccessingSecurityScopedResource() } }
            let parts = try await files.subtitles(from: source)
            try Task.checkCancellation()
            try await db.replaceSegments(parts, for: item.id)
            if transcriptUndo?.item.id == item.id { transcriptUndo = nil }
            revision += 1
            await runSearch()
            return "Импортировано фрагментов: \(parts.count)"
        }
    }

    func segments(_ item: MediaItem) async -> [SpeechSegment] {
        guard let db else { return [] }
        do { return try await db.segments(for: item.id) }
        catch { errorMessage = error.localizedDescription; return [] }
    }

    func checkpoint(_ item: MediaItem) async -> TranscriptionCheckpoint? {
        guard let db else { return nil }
        do { return try await db.checkpoint(for: item.id) }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    func runSearch(more: Bool = false) async {
        guard let db else { return }
        let key = searchKey
        if more && (searching || !moreSearchResults || key != activeSearch) { return }
        searchGeneration += 1
        let generation = searchGeneration
        searching = true
        if !more { results = []; moreSearchResults = false; activeSearch = key }
        defer { if generation == searchGeneration { searching = false } }
        do {
            let hits = try await db.find(query,scope:searchScope,kind:searchKind,limit:51,offset:more ? results.count : 0)
            guard !Task.isCancelled, key == searchKey, generation == searchGeneration else { return }
            if more { results += hits.prefix(50) } else { results = Array(hits.prefix(50)) }
            moreSearchResults = hits.count > 50
        } catch { errorMessage = error.localizedDescription }
    }

    func reviseTranscript(_ item: MediaItem, previous: [SpeechSegment], updated: [SpeechSegment], discardPending: Bool) async throws {
        guard let db else { throw MediaRepository.Error.open }
        guard !busy else { throw TranscriptEditing.Error.busy }
        busy = true; operationTitle = "Сохранение текста"; operationItemID = item.id; progress = 0
        defer { busy = false; operationItemID = nil; revision += 1 }
        if try await db.checkpoint(for:item.id) != nil && !discardPending { throw TranscriptEditing.Error.pendingRecognition }
        try await db.reviseSegments(updated,replacing:previous,for:item.id)
        transcriptUndo = TranscriptUndo(item:item,previous:previous,updated:updated)
        deletedBookmark = nil
        notice = nil
        await reload(); await runSearch()
    }

    func undoTranscriptEdit() async {
        guard let change = transcriptUndo else { return }
        do {
            try await reviseTranscript(change.item,previous:change.updated,updated:change.previous,discardPending:false)
            transcriptUndo = nil
            notice = "Изменение текста отменено"
        } catch { errorMessage = error.localizedDescription }
    }

    func exportBookmarks(_ item: MediaItem) async -> URL? {
        guard let db else { return nil }
        do {
            let notes = try await db.bookmarks(for:item.id)
            guard !notes.isEmpty else { throw MediaFileImport.ImportError.noCues }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MediaMind-notes-\(item.id).txt")
            try BookmarkExport.text(title:item.title,bookmarks:notes).write(to:url,atomically:true,encoding:.utf8)
            return url
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func transcribe(_ item: MediaItem, restart: Bool = false) {
        guard let db else { return }
        let selectedLanguage = language
        perform("Распознавание речи", item: item.id, cancelled: "Распознавание остановлено. Завершённые фрагменты сохранены; можно продолжить позже.") { [self] in
            do {
                let saved = try await db.checkpoint(for: item.id)
                let initial: TranscriptionCheckpoint
                if !restart, let saved, saved.language == selectedLanguage { initial = saved }
                else { initial = TranscriptionCheckpoint(language: selectedLanguage) }
                try await db.saveCheckpoint(initial, for: item.id)
                try await db.clearTranscriptionFailure(for: item.id)
                let parts = try await speech.transcribe(file: location(item), checkpoint: initial) { checkpoint in
                    try await db.saveCheckpoint(checkpoint, for: item.id)
                } progress: { [weak self] value in self?.progress = value }
                try Task.checkCancellation()
                guard !parts.isEmpty else {
                    try await db.clearCheckpoint(for: item.id)
                    throw SpeechServiceError.noResult
                }
                try await db.replaceSegments(parts, for: item.id)
                if transcriptUndo?.item.id == item.id { transcriptUndo = nil }
                await runSearch()
                return "Распознано фраз: \(parts.count)"
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await db.recordTranscriptionFailure(error.localizedDescription, for: item.id)
                throw error
            }
        }
    }

    func recordPlayback(_ value: PlaybackPosition, for item: MediaItem) async {
        guard let db else { return }
        do {
            try await db.savePlayback(value, for: item.id)
            if overview[item.id] != nil && value.playedAt >= (overview[item.id]?.playback?.playedAt ?? .distantPast) {
                overview[item.id]?.playback = PlaybackPosition(position: min(value.position, item.duration), playedAt: value.playedAt)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func bookmarks(_ item: MediaItem) async -> [MediaBookmark] {
        guard let db else { return [] }
        do { return try await db.bookmarks(for: item.id) }
        catch { errorMessage = error.localizedDescription; return [] }
    }

    func saveBookmark(_ bookmark: MediaBookmark) async throws {
        guard let db else { throw MediaRepository.Error.open }
        try await db.saveBookmark(bookmark)
        bookmarkRevision += 1
        await runSearch()
    }

    func removeBookmark(_ bookmark: MediaBookmark) async {
        guard let db else { return }
        do {
            try await db.removeBookmark(bookmark.id)
            deletedBookmark = bookmark
            transcriptUndo = nil
            bookmarkRevision += 1
            await runSearch()
        } catch { errorMessage = error.localizedDescription }
    }

    func undoBookmarkDeletion() async {
        guard let bookmark = deletedBookmark else { return }
        do {
            try await saveBookmark(bookmark)
            deletedBookmark = nil
            notice = "Закладка восстановлена"
        } catch { errorMessage = error.localizedDescription }
    }

    func cancel() { operation?.cancel() }

    func moveToTrash(_ item: MediaItem) async {
        guard let db, !busy else { return }
        do {
            try await db.trash(item.id)
            await reload(); await runSearch()
            notice = "Запись в корзине. Её можно восстановить в настройках."
        } catch { errorMessage = error.localizedDescription }
    }

    func restore(_ item: MediaItem) async {
        guard let db, !busy else { return }
        do {
            try await db.restore(item.id)
            await reload(); await runSearch()
            notice = "Запись восстановлена"
        } catch { errorMessage = error.localizedDescription }
    }

    func removePermanently(_ item: MediaItem) async {
        guard let db, !busy else { return }
        do {
            let url = location(item)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try await db.remove(item.id)
            if deletedBookmark?.mediaID == item.id { deletedBookmark = nil }
            if transcriptUndo?.item.id == item.id { transcriptUndo = nil }
            UserDefaults.standard.removeObject(forKey: "position-\(item.id)")
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    func rename(_ item: MediaItem, title: String) async {
        guard let db, !busy else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            var updated = item; updated.title = String(title.prefix(200))
            try await db.save(updated)
            await reload(); await runSearch()
        } catch { errorMessage = error.localizedDescription }
    }

    func export(_ item: MediaItem, format: String) async -> URL? {
        guard let db else { return nil }
        do {
            let parts = try await db.segments(for: item.id)
            guard !parts.isEmpty else { throw MediaFileImport.ImportError.noCues }
            let text = format == "srt" ? Subtitles.encodeSRT(parts) : (format == "vtt" ? Subtitles.encodeVTT(parts) : parts.map(\.text).joined(separator: "\n"))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MediaMind-\(item.id.uuidString).\(format)")
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    private func perform(_ title: String, item: UUID? = nil, cancelled: String = "Действие остановлено.", action: @escaping () async throws -> String) {
        guard !busy else { return }
        operationGeneration += 1
        busy = true; progress = 0; operationTitle = title; operationItemID = item; notice = nil
        UIApplication.shared.isIdleTimerDisabled = true
        operation = Task {
            defer {
                busy = false; operation = nil; operationItemID = nil; revision += 1
                UIApplication.shared.isIdleTimerDisabled = false
            }
            do { notice = try await action() }
            catch is CancellationError { notice = cancelled }
            catch { errorMessage = error.localizedDescription }
            await reload()
        }
    }
}
