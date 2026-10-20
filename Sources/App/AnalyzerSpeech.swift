import AVFoundation
import Speech

@available(iOS 26.0, *)
enum AnalyzerSpeech {
    static func modelStatus(language: String) async -> SpeechReadiness.Model {
        guard SpeechTranscriber.isAvailable else { return .unsupportedDevice }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else { return .unsupportedLanguage }
        let module = transcriber(locale)
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return .installed
        case .supported: return .missing
        case .downloading: return .downloading
        case .unsupported: return .unsupportedLanguage
        @unknown default: return .unsupportedDevice
        }
    }

    @MainActor
    static func install(language: String, progress: @escaping (Double) -> Void) async throws {
        guard SpeechTranscriber.isAvailable else { throw SpeechServiceError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else { throw SpeechServiceError.unsupportedLanguage }
        let module = transcriber(locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { value, _ in
                let fraction = value.fractionCompleted
                Task { @MainActor in
                    if fraction.isFinite { progress(min(1, max(0, fraction))) }
                }
            }
            defer { observation.invalidate() }
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await request.downloadAndInstall()
                try Task.checkCancellation()
            } onCancel: { request.progress.cancel() }
        }
        guard await modelStatus(language: language) == .installed else { throw SpeechServiceError.modelPending }
    }

    static func recognize(url: URL, language: String) async throws -> [SpeechSegment] {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else { throw SpeechServiceError.unsupportedLanguage }
        let module = transcriber(locale)
        guard await AssetInventory.status(forModules: [module]) == .installed else { throw SpeechServiceError.modelRequired }
        let analyzer = SpeechAnalyzer(modules: [module])
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: [SpeechSegment].self) { group in
                group.addTask {
                    async let phrases = collect(module)
                    do {
                        let file = try AVAudioFile(forReading: url)
                        if let end = try await analyzer.analyzeSequence(from: file) {
                            try await analyzer.finalizeAndFinish(through: end)
                        } else { await analyzer.cancelAndFinishNow() }
                        try Task.checkCancellation()
                        return try await phrases
                    } catch {
                        await analyzer.cancelAndFinishNow()
                        throw error
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(90))
                    throw SpeechServiceError.timedOut
                }
                do {
                    // Both workers either return results or throw; an empty group is impossible.
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                } catch {
                    group.cancelAll()
                    await analyzer.cancelAndFinishNow()
                    throw error
                }
            }
        } onCancel: { Task { await analyzer.cancelAndFinishNow() } }
    }

    private static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    private static func collect(_ module: SpeechTranscriber) async throws -> [SpeechSegment] {
        var phrases: [SpeechSegment] = []
        for try await result in module.results where result.isFinal {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let ranges = result.text.runs.compactMap(\.audioTimeRange)
            guard let first = ranges.first, let last = ranges.last else { throw SpeechServiceError.invalidResult }
            phrases.append(SpeechSegment(start: first.start.seconds, end: CMTimeRangeGetEnd(last).seconds, text: text))
        }
        return phrases
    }
}
