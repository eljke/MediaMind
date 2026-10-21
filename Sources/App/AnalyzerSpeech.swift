import AVFoundation
import Speech

@available(iOS 26.0, *)
enum AnalyzerSpeech {
    static func modelStatus(language: String, engine: SpeechReadiness.Engine) async -> SpeechReadiness.Model {
        if engine == .analyzer && !SpeechTranscriber.isAvailable { return .unsupportedDevice }
        guard let module = await module(language:language,engine:engine) else { return .unsupportedLanguage }
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return .installed
        case .supported: return .missing
        case .downloading: return .downloading
        case .unsupported: return .unsupportedLanguage
        @unknown default: return .unsupportedDevice
        }
    }

    @MainActor
    static func install(language: String, engine: SpeechReadiness.Engine, progress: @escaping (Double) -> Void) async throws {
        guard let module = await module(language:language,engine:engine) else { throw SpeechServiceError.unsupportedLanguage }
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
        guard await modelStatus(language:language,engine:engine) == .installed else { throw SpeechServiceError.modelPending }
    }

    static func recognize(url: URL, language: String, engine: SpeechReadiness.Engine) async throws -> [SpeechSegment] {
        guard let module = await module(language:language,engine:engine) else { throw SpeechServiceError.unsupportedLanguage }
        guard await AssetInventory.status(forModules: [module]) == .installed else { throw SpeechServiceError.modelRequired }
        if let transcriber = module as? SpeechTranscriber {
            return try await recognize(url:url,module:transcriber) { try await collect(transcriber.results,text:{ $0.text }) }
        }
        if let transcriber = module as? DictationTranscriber {
            return try await recognize(url:url,module:transcriber) { try await collect(transcriber.results,text:{ $0.text }) }
        }
        throw SpeechServiceError.unavailable
    }

    private static func recognize(url: URL, module: any SpeechModule, results: @escaping @Sendable () async throws -> [SpeechSegment]) async throws -> [SpeechSegment] {
        let analyzer = SpeechAnalyzer(modules: [module])
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: [SpeechSegment].self) { group in
                group.addTask {
                    async let phrases = results()
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

    private static func module(language: String, engine: SpeechReadiness.Engine) async -> (any SpeechModule)? {
        let requested = Locale(identifier:language)
        switch engine {
        case .analyzer:
            guard SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo:requested) else { return nil }
            return SpeechTranscriber(locale:locale,transcriptionOptions:[],reportingOptions:[],attributeOptions:[.audioTimeRange])
        case .dictation:
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo:requested) else { return nil }
            return DictationTranscriber(locale:locale,contentHints:[],transcriptionOptions:[],reportingOptions:[],attributeOptions:[.audioTimeRange])
        case .recognizer: return nil
        }
    }

    static func collect<Results: AsyncSequence & Sendable>(_ results: Results, text: @Sendable (Results.Element) -> AttributedString) async throws -> [SpeechSegment] where Results.Element: SpeechModuleResult & Sendable {
        var phrases: [SpeechSegment] = []
        for try await result in results where result.isFinal {
            let attributed = text(result)
            let value = String(attributed.characters).trimmingCharacters(in:.whitespacesAndNewlines)
            if value.isEmpty { continue }
            let ranges = attributed.runs.compactMap(\.audioTimeRange)
            let start = ranges.first?.start.seconds ?? result.range.start.seconds
            let end = ranges.last.map { CMTimeRangeGetEnd($0).seconds } ?? CMTimeRangeGetEnd(result.range).seconds
            guard start.isFinite, end.isFinite, start >= 0, end >= start else { throw SpeechServiceError.invalidResult }
            phrases.append(SpeechSegment(start:start,end:end,text:value))
        }
        return phrases
    }
}
