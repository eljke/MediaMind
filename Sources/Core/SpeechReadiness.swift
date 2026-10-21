import Foundation

public struct SpeechReadiness: Equatable, Sendable {
    public enum Permission: Sendable { case notRequested, authorized, denied, restricted }
    public enum Model: Sendable { case unsupportedSystem, unsupportedDevice, unsupportedLanguage, missing, downloading, installed }
    public enum Legacy: Sendable { case unsupportedLanguage, offlineUnavailable, temporarilyUnavailable, ready }
    public enum Engine: String, Sendable { case analyzer = "SpeechTranscriber", dictation = "DictationTranscriber", recognizer = "SFSpeechRecognizer" }
    public enum Issue: Sendable { case permissionRequired, permissionDenied, restricted, modelRequired, modelDownloading, unsupportedLanguage, unavailable }
    public var permission: Permission
    public var model: Model
    public var legacy: Legacy
    public var dictation: Model

    public init(permission: Permission, model: Model, legacy: Legacy, dictation: Model = .unsupportedSystem) {
        self.permission = permission; self.model = model; self.legacy = legacy; self.dictation = dictation
    }

    public var engine: Engine? {
        if model == .installed { return .analyzer }
        if dictation == .installed { return .dictation }
        if permission == .authorized && legacy == .ready { return .recognizer }
        return nil
    }

    public var installationEngine: Engine? {
        if model == .missing || model == .downloading { return .analyzer }
        if dictation == .missing || dictation == .downloading { return .dictation }
        return nil
    }
    public var canInstall: Bool { installationEngine != nil }

    public var issue: Issue? {
        if engine != nil { return nil }
        if legacy == .ready {
            switch permission {
            case .notRequested: return .permissionRequired
            case .denied: return .permissionDenied
            case .restricted: return .restricted
            case .authorized: break
            }
        }
        if model == .missing || dictation == .missing { return .modelRequired }
        if model == .downloading || dictation == .downloading { return .modelDownloading }
        if model == .unsupportedLanguage && legacy == .unsupportedLanguage &&
            (dictation == .unsupportedLanguage || dictation == .unsupportedSystem || dictation == .unsupportedDevice) { return .unsupportedLanguage }
        return .unavailable
    }
}

extension TranscriptionCheckpoint {
    public func isValid(for duration: Double) -> Bool {
        duration.isFinite && duration > 0 && nextOffset.isFinite && nextOffset >= 0 && nextOffset <= duration &&
        segments.allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= duration }
    }
}
