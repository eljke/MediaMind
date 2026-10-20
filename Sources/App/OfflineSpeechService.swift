import Foundation
import AVFoundation
import Speech

@MainActor
protocol TranscriptionService {
    func transcribe(file: URL, checkpoint: TranscriptionCheckpoint,
                    save: @escaping (TranscriptionCheckpoint) async throws -> Void,
                    progress: @escaping (Double) -> Void) async throws -> [SpeechSegment]
}

enum SpeechServiceError: LocalizedError {
    case unavailable, notAuthorized, exportFailed, noResult, badDuration, timedOut
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Локальное распознавание для этого языка недоступно. Проверь офлайн-модель в настройках iOS или импортируй SRT/VTT."
        case .notAuthorized: return "Разреши распознавание речи в настройках iOS/LiveContainer."
        case .exportFailed: return "Не удалось извлечь аудио. Проверь формат файла и свободное место."
        case .noResult: return "Речь не найдена. Прежняя расшифровка сохранена."
        case .badDuration: return "Длительность файла неизвестна."
        case .timedOut: return "Движок не ответил. Прогресс сохранён — можно продолжить позже."
        }
    }
}

@MainActor
final class AppleOfflineSpeech: TranscriptionService {
    func transcribe(file: URL, checkpoint: TranscriptionCheckpoint,
                    save: @escaping (TranscriptionCheckpoint) async throws -> Void,
                    progress: @escaping (Double) -> Void) async throws -> [SpeechSegment] {
        let permission = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        guard permission == .authorized else { throw SpeechServiceError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: checkpoint.language)),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw SpeechServiceError.unavailable }
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite && duration > 0 else { throw SpeechServiceError.badDuration }
        var checkpoint = checkpoint
        progress(min(1, checkpoint.nextOffset / duration))
        while checkpoint.nextOffset < duration {
            try Task.checkCancellation()
            let offset = checkpoint.nextOffset
            let interval = min(45, duration - offset)
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
            let chunk = try await SpeechRecognitionSession().run(url: tmp, recognizer: recognizer)
            checkpoint.segments += Transcript.phrases(chunk).map {
                SpeechSegment(start: $0.start + offset, end: min(duration, $0.end + offset), text: $0.text)
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
