import SwiftUI
import AVFoundation

@MainActor
final class MediaViewModel: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var trash: [MediaItem] = []
    @Published var results: [MediaHit] = []
    @Published var query = ""
    @Published var busy = false
    @Published var progress = 0.0
    @Published var operationTitle = ""
    @Published var operationItemID: UUID?
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var ready = false
    @Published var revision = 0
    @AppStorage("speechLanguage") var language = "ru-RU"
    private var db: MediaRepository?
    private let root: URL
    private let files = MediaFileImport()
    private let speech: TranscriptionService = AppleOfflineSpeech()
    private var operation: Task<Void, Never>?

    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MediaMind", isDirectory: true)
    }

    func location(_ item: MediaItem) -> URL { root.appendingPathComponent("files", isDirectory: true).appendingPathComponent(item.fileName) }

    func reload() async {
        do {
            if db == nil { db = try MediaRepository(url: root.appendingPathComponent("library.sqlite")) }
            guard let db else { return }
            items = try await db.all()
            trash = try await db.trashed()
            ready = true
        } catch { errorMessage = error.localizedDescription }
    }

    func importMedia(_ source: URL) {
        guard let db else { return }
        perform("Импорт файла") { [self] in
            let granted = source.startAccessingSecurityScopedResource()
            defer { if granted { source.stopAccessingSecurityScopedResource() } }
            let destination = try await files.copyMedia(from: source, to: root.appendingPathComponent("files")) { [weak self] value in
                Task { @MainActor in self?.progress = value }
            }
            do {
                let asset = AVURLAsset(url: destination)
                guard try await asset.load(.isPlayable) else { throw MediaFileImport.ImportError.unreadable }
                let seconds = try await asset.load(.duration).seconds
                guard seconds.isFinite && seconds > 0 else { throw SpeechServiceError.badDuration }
                try Task.checkCancellation()
                try await db.save(MediaItem(title: source.deletingPathExtension().lastPathComponent, fileName: destination.lastPathComponent, duration: seconds))
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            await reload()
            return "Запись добавлена в библиотеку"
        }
    }

    func importSubtitle(_ source: URL, for item: MediaItem) {
        guard let db else { return }
        perform("Импорт субтитров", item: item.id) { [self] in
            let granted = source.startAccessingSecurityScopedResource()
            defer { if granted { source.stopAccessingSecurityScopedResource() } }
            let parts = try await files.subtitles(from: source)
            try Task.checkCancellation()
            try await db.replaceSegments(parts, for: item.id)
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

    func runSearch() async {
        guard let db else { return }
        let text = query
        do {
            let hits = try await db.search(text)
            guard !Task.isCancelled, text == query else { return }
            results = hits
        } catch { errorMessage = error.localizedDescription }
    }

    func transcribe(_ item: MediaItem, restart: Bool = false) {
        guard let db else { return }
        let selectedLanguage = language
        perform("Распознавание речи", item: item.id) { [self] in
            let saved = try await db.checkpoint(for: item.id)
            let initial: TranscriptionCheckpoint
            if !restart, let saved, saved.language == selectedLanguage { initial = saved }
            else { initial = TranscriptionCheckpoint(language: selectedLanguage) }
            let parts = try await speech.transcribe(file: location(item), checkpoint: initial) { checkpoint in
                try await db.saveCheckpoint(checkpoint, for: item.id)
            } progress: { [weak self] value in self?.progress = value }
            try Task.checkCancellation()
            guard !parts.isEmpty else {
                try await db.clearCheckpoint(for: item.id)
                throw SpeechServiceError.noResult
            }
            try await db.replaceSegments(parts, for: item.id)
            await runSearch()
            return "Распознано фраз: \(parts.count)"
        }
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

    private func perform(_ title: String, item: UUID? = nil, action: @escaping () async throws -> String) {
        guard !busy else { return }
        busy = true; progress = 0; operationTitle = title; operationItemID = item; notice = nil
        UIApplication.shared.isIdleTimerDisabled = true
        operation = Task {
            defer {
                busy = false; operation = nil; operationItemID = nil; revision += 1
                UIApplication.shared.isIdleTimerDisabled = false
            }
            do { notice = try await action() }
            catch is CancellationError { notice = "Остановлено. Завершённые фрагменты распознавания сохранены." }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
