import Foundation
import AVFoundation
import Speech

/// Portable on-device-only backend. No network fallback. Each chunk is <=45 seconds.
/// API boundary lets a future WhisperKit backend replace Apple Speech.
protocol TranscriptionService {
    func transcribe(file: URL, language: String, progress: @escaping (Double) -> Void) async throws -> [SpeechSegment]
}

enum SpeechServiceError: LocalizedError {
    case unavailable, notAuthorized, exportFailed, noResult, badDuration
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Локальное распознавание для этого языка недоступно. Можно импортировать SRT/VTT."
        case .notAuthorized: return "Разреши распознавание речи в настройках iOS/LiveContainer."
        case .exportFailed: return "Не удалось извлечь аудио. Проверь формат файла."
        case .noResult: return "Речь в этом фрагменте не распознана."
        case .badDuration: return "Длительность файла неизвестна."
        }
    }
}

final class AppleOfflineSpeech: TranscriptionService {
    func transcribe(file: URL, language: String, progress: @escaping (Double) -> Void) async throws -> [SpeechSegment] {
        let permission = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus,Never>) in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status) }
        }
        guard permission == .authorized else { throw SpeechServiceError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.supportsOnDeviceRecognition else { throw SpeechServiceError.unavailable }
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite && duration > 0 else { throw SpeechServiceError.badDuration }
        let chunkSize = 45.0
        var segments: [SpeechSegment] = []
        var offset = 0.0
        while offset < duration {
            try Task.checkCancellation()
            let interval = min(chunkSize, duration - offset)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mediamind-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw SpeechServiceError.exportFailed }
            exporter.outputURL = tmp
            exporter.outputFileType = .m4a
            exporter.timeRange = CMTimeRange(start: CMTime(seconds: offset, preferredTimescale: 600), duration: CMTime(seconds: interval, preferredTimescale: 600))
            await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
                exporter.exportAsynchronously { continuation.resume() }
            }
            guard exporter.status == .completed else { throw exporter.error ?? SpeechServiceError.exportFailed }
            let chunk = try await recognize(url: tmp, recognizer: recognizer)
            for part in chunk {
                segments.append(SpeechSegment(start: part.start + offset, end: part.end + offset, text: part.text))
            }
            offset += interval
            progress(min(1.0,offset/duration))
        }
        return segments
    }
    private func recognize(url: URL, recognizer: SFSpeechRecognizer) async throws -> [SpeechSegment] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SpeechSegment],Error>) in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            var completed = false
            // The recognizer retains the task for the lifetime of the callback.
            _ = recognizer.recognitionTask(with: request) { result, error in
                guard !completed else { return }
                if let error { completed = true; continuation.resume(throwing: error); return }
                if let result, result.isFinal {
                    completed = true
                    let parts = result.bestTranscription.segments.map { item in
                        SpeechSegment(start:item.timestamp,end:item.timestamp + item.duration,text:item.substring)
                    }
                    continuation.resume(returning: parts)
                }
            }
        }
    }
}
