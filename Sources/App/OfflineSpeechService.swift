import Foundation
import AVFoundation
import Speech

@MainActor
protocol TranscriptionService {
    func readiness(language: String) async -> SpeechReadiness
    func requestPermission() async
    func installModel(language: String, progress: @escaping (Double) -> Void) async throws
    func transcribe(file: URL, checkpoint: TranscriptionCheckpoint,
                    save: @escaping (TranscriptionCheckpoint) async throws -> Void,
                    progress: @escaping (Double) -> Void) async throws -> [SpeechSegment]
}

enum SpeechServiceError: LocalizedError {
    case unavailable, notAuthorized, exportFailed, noResult, badDuration, timedOut, invalidCheckpoint, invalidResult, noAudio, noSpace, modelRequired, modelPending, unsupportedLanguage, restricted
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Локальное распознавание для этого языка недоступно. Проверь офлайн-модель в настройках iOS или импортируй SRT/VTT."
        case .notAuthorized: return "Разреши распознавание речи в настройках iOS/LiveContainer."
        case .exportFailed: return "Не удалось извлечь аудио. Проверь формат файла и свободное место."
        case .noResult: return "Речь не найдена. Прежняя расшифровка сохранена."
        case .badDuration: return "Длительность файла неизвестна."
        case .timedOut: return "Движок не ответил. Прогресс сохранён — можно продолжить позже."
        case .invalidCheckpoint: return "Сохранённый прогресс не соответствует записи. Выбери «Начать заново»; прежняя расшифровка сохранится до успешного завершения."
        case .invalidResult: return "Движок вернул некорректные временные отметки. Завершённые фрагменты сохранены."
        case .noAudio: return "В записи нет звуковой дорожки. Импортируй субтитры или выбери файл со звуком."
        case .noSpace: return "Недостаточно места для временного аудиофрагмента. Освободи хотя бы 20 МБ и повтори попытку."
        case .modelRequired: return "Офлайн-модель не установлена. Подготовь её в разделе «Распознавание»."
        case .modelPending: return "iOS ещё загружает модель или ожидает подключения. Обнови проверку позже."
        case .unsupportedLanguage: return "Выбранный язык не поддерживается доступными локальными движками. Можно импортировать SRT/VTT."
        case .restricted: return "Распознавание ограничено настройками устройства. Проверь ограничения iOS или LiveContainer."
        }
    }
}

@MainActor
final class AppleOfflineSpeech: TranscriptionService {
    func readiness(language: String) async -> SpeechReadiness {
        let permission: SpeechReadiness.Permission
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: permission = .authorized
        case .denied: permission = .denied
        case .restricted: permission = .restricted
        case .notDetermined: permission = .notRequested
        @unknown default: permission = .restricted
        }
        let legacy: SpeechReadiness.Legacy
        if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) {
            if !recognizer.supportsOnDeviceRecognition { legacy = .offlineUnavailable }
            else { legacy = recognizer.isAvailable ? .ready : .temporarilyUnavailable }
        } else { legacy = .unsupportedLanguage }
        let model: SpeechReadiness.Model
        let dictation: SpeechReadiness.Model
        if #available(iOS 26.0, *) {
            model = await AnalyzerSpeech.modelStatus(language:language,engine:.analyzer)
            dictation = await AnalyzerSpeech.modelStatus(language:language,engine:.dictation)
        } else { model = .unsupportedSystem; dictation = .unsupportedSystem }
        return SpeechReadiness(permission:permission,model:model,legacy:legacy,dictation:dictation)
    }

    func requestPermission() async {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    func installModel(language: String, progress: @escaping (Double) -> Void) async throws {
        guard #available(iOS 26.0, *) else { throw SpeechServiceError.unavailable }
        let status = await readiness(language:language)
        if status.model == .installed || status.dictation == .installed, !status.canInstall { progress(1); return }
        guard let engine = status.installationEngine else { throw SpeechServiceError.unsupportedLanguage }
        try await AnalyzerSpeech.install(language:language,engine:engine,progress:progress)
    }

    func transcribe(file: URL, checkpoint: TranscriptionCheckpoint,
                    save: @escaping (TranscriptionCheckpoint) async throws -> Void,
                    progress: @escaping (Double) -> Void) async throws -> [SpeechSegment] {
        var status = await readiness(language: checkpoint.language)
        if status.issue == .permissionRequired {
            await requestPermission()
            status = await readiness(language: checkpoint.language)
        }
        try Task.checkCancellation()
        guard let engine = status.engine else { throw Self.error(for: status.issue) }
        if engine != .recognizer, #available(iOS 26.0, *) {
            return try await transcribeChunks(file: file, checkpoint: checkpoint, save: save, progress: progress) { url in
                try await AnalyzerSpeech.recognize(url:url,language:checkpoint.language,engine:engine)
            }
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: checkpoint.language)) else { throw SpeechServiceError.unsupportedLanguage }
        return try await transcribeChunks(file: file, checkpoint: checkpoint, save: save, progress: progress) { url in
            try await SpeechRecognitionSession().run(url: url, recognizer: recognizer)
        }
    }

    private static func error(for issue: SpeechReadiness.Issue?) -> SpeechServiceError {
        switch issue {
        case .permissionRequired, .permissionDenied: return .notAuthorized
        case .restricted: return .restricted
        case .modelRequired: return .modelRequired
        case .modelDownloading: return .modelPending
        case .unsupportedLanguage: return .unsupportedLanguage
        case .unavailable, nil: return .unavailable
        }
    }

    func transcribeChunks(file: URL, checkpoint: TranscriptionCheckpoint,
                          save: @escaping (TranscriptionCheckpoint) async throws -> Void,
                          progress: @escaping (Double) -> Void,
                          recognize: (URL) async throws -> [SpeechSegment]) async throws -> [SpeechSegment] {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite && duration > 0 else { throw SpeechServiceError.badDuration }
        guard checkpoint.isValid(for: duration) else { throw SpeechServiceError.invalidCheckpoint }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw SpeechServiceError.noAudio }
        var checkpoint = checkpoint
        progress(min(1, checkpoint.nextOffset / duration))
        while checkpoint.nextOffset < duration {
            try Task.checkCancellation()
            let offset = checkpoint.nextOffset
            let interval = min(45, duration - offset)
            let available = try FileManager.default.attributesOfFileSystem(forPath: FileManager.default.temporaryDirectory.path)[.systemFreeSize] as? NSNumber
            if let available, available.int64Value < 20 * 1024 * 1024 { throw SpeechServiceError.noSpace }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mediamind-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw SpeechServiceError.exportFailed }
            exporter.outputURL = tmp
            exporter.outputFileType = .m4a
            exporter.timeRange = CMTimeRange(start: CMTime(seconds: offset, preferredTimescale: 600), duration: CMTime(seconds: interval, preferredTimescale: 600))
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    exporter.exportAsynchronously { continuation.resume() }
                }
            } onCancel: {
                exporter.cancelExport()
            }
            try Task.checkCancellation()
            guard exporter.status == .completed else { throw exporter.error ?? SpeechServiceError.exportFailed }
            let chunk = try await recognize(tmp)
            try Task.checkCancellation()
            guard chunk.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }) else { throw SpeechServiceError.invalidResult }
            checkpoint.segments += Transcript.phrases(chunk).filter { $0.start < interval }.map {
                SpeechSegment(start: $0.start + offset, end: min(offset + interval, $0.end + offset), text: $0.text)
            }
            checkpoint.nextOffset = offset + interval
            try await save(checkpoint)
            progress(min(1, checkpoint.nextOffset / duration))
        }
        return checkpoint.segments
    }
}

@MainActor
private final class SpeechRecognitionSession {
    private var continuation: CheckedContinuation<[SpeechSegment], Error>?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?

    func run(url: URL, recognizer: SFSpeechRecognizer) async throws -> [SpeechSegment] {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let request = SFSpeechURLRecognitionRequest(url: url)
                request.requiresOnDeviceRecognition = true
                request.shouldReportPartialResults = false
                request.addsPunctuation = true
                recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    let parts = result?.isFinal == true ? result?.bestTranscription.segments.map {
                        SpeechSegment(start: $0.timestamp, end: $0.timestamp + $0.duration, text: $0.substring)
                    } : nil
                    Task { @MainActor in
                        if let parts { self?.finish(.success(parts)) }
                        else if let error { self?.finish(.failure(error)) }
                    }
                }
                timeout = Task {
                    try? await Task.sleep(for: .seconds(90))
                    if !Task.isCancelled { finish(.failure(SpeechServiceError.timedOut)) }
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<[SpeechSegment], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        let task = recognitionTask
        recognitionTask = nil
        task?.cancel()
        continuation.resume(with: result)
    }
}
